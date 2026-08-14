#!/usr/bin/env bash
# Emulation throughput with sound and the LCD active.
#
# Runs the Logic fixture with MAME's own throttle set far above real time, so
# the reported average speed is the achieved throughput rather than a paced
# playback rate. Sound is fully processed and the OpenGL LCD is presented in
# every arm; only the CPU set, nice level and SCHED_RR priority differ.
set -euo pipefail
export LC_ALL=C

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
binary=${MAME_BIN:-"$root/.cache/mame/mpc"}
launcher="$root/scripts/run-mpc.sh"
lua_script="$root/scripts/diagnostics/headroom-logic-mpc2000xl.lua"
project="$root/results/projects/mpc-tutor-logic-mpc2000xl.img"
artifact=${MPC_ARTIFACT_DIR:-"$root/results/diagnostics/headroom-$(date +%Y%m%d-%H%M%S)"}
speed_factor=${MPC_HEADROOM_SPEED_FACTOR:-100000}
repeats=${MPC_HEADROOM_REPEATS:-2}

declare -A arm_cpus=( [deploy-pcore]=0-11 [ecore]=12-19 [lpe-rr1]=20-21 )
declare -A arm_nice=( [deploy-pcore]=-10  [ecore]=-10   [lpe-rr1]=0 )
declare -A arm_prio=( [deploy-pcore]=20   [ecore]=20    [lpe-rr1]=1 )
read -r -a sequence <<<"${MPC_HEADROOM_ARMS:-deploy-pcore ecore lpe-rr1}"

mame_pid=

die()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

cleanup()
{
	local status=$? pgid=
	trap - EXIT INT TERM HUP
	if [[ "$mame_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$mame_pid" 2>/dev/null; then
		pgid=$(ps -o pgid= -p "$mame_pid" 2>/dev/null | tr -d '[:space:]' || true)
		if [[ "$pgid" == "$mame_pid" ]]; then
			kill -TERM -- "-$mame_pid" 2>/dev/null || true
		else
			kill -TERM -- "$mame_pid" 2>/dev/null || true
		fi
		wait "$mame_pid" 2>/dev/null || true
	fi
	printf 'Artifacts preserved at %s\n' "$artifact" >&2
	exit "$status"
}

run_one()
{
	local index=$1 arm=$2 run_dir="$artifact/$1-$2"
	local runtime="$run_dir/runtime" mame_log="$run_dir/mame.log"
	local mame_status average_speed speed_percent
	local -a run_command
	mkdir -p -- "$runtime"

	run_command=(
		timeout --signal=TERM --kill-after=10s 300s
		env
		-u MAME_MPC_V53_REPLAY
		-u MAME_MPC_V53_HOTBLOCKS
		-u MAME_SOUND_EFFECTS_HANDSHAKE
		-u MAME_SOUND_EFFECTS_PRIORITY_BOOST
		-u MAME_SOUND_EFFECTS_INLINE
		-u MAME_SOUND_EFFECTS_PHASE_STATS
		-u MAME_PIPEWIRE_PRIMARY_OUTPUT
		-u MAME_PIPEWIRE_BATCH_OUTPUT_UPDATES
		-u MAME_PIPEWIRE_STATS
		-u MAME_VIDEO_STATS
		-u MAME_MPC_LCD_STATS
		-u MAME_PIPEWIRE_CAPTURE_WAV
		MAME_BIN="$binary"
		MAME_RUNTIME_DIR="$runtime"
		MAME_CPUSET="${arm_cpus[$arm]}"
		MAME_NICE="${arm_nice[$arm]}"
		MAME_RT_PRIORITY="${arm_prio[$arm]}"
		MPC_HEADROOM_SPEED_FACTOR="$speed_factor"
		MAME_TIMING_MASTER=video
		MPC_VIDEO_MODE=opengl
		MPC_VIEW_NAME='Screen 0'
		MPC_WINDOW_RESOLUTION=1240x300
		MPC_ARTWORK_RESOLUTION=auto
		MPC_GL_VBO=1
		MPC_OUTPUT_MODE=stereo
		MPC_ASYNC_PRESENT=1
		MPC_SDL_EXTERNAL_EVENT_LOOP=1
		MPC_PANEL_MODE=event
		MPC_PANEL_TIMER_MODE=coalesced
		MPC_MIDI_INPUT_MODE=accurate
		MPC_MIDI_CLOCK_MODE=event
		MPC_V53_STATUS_MODE=hle
		MPC_V53_EVENT_SERVICE_MODE=hle
		MPC_V53_DISPATCH_MODE=direct
		MPC_V53_DIVIDE_MODE=superblock
		MPC_LCD_UPDATE_MODE=changed
		"$launcher" mpc2000xl 32
		-flop "$project"
		-skip_gameinfo
		-seconds_to_run 60
		-autoboot_script "$lua_script"
	)

	{
		printf ' %q' "${run_command[@]}"
		printf '\n'
	} >"$run_dir/command.txt"

	set +e
	setsid "${run_command[@]}" >"$mame_log" 2>&1 &
	mame_pid=$!
	wait "$mame_pid"
	mame_status=$?
	set -e
	mame_pid=
	(( mame_status == 0 )) || die "$index-$arm MAME exited with status $mame_status"
	grep -Fq MPC_HEADROOM_END "$mame_log" || die "$index-$arm did not reach the end marker"
	grep -Fq 'LCD frame updates: changed-only' "$mame_log" || die "$index-$arm did not select changed LCD mode"
	grep -Fq 'Video: opengl' "$mame_log" || die "$index-$arm did not select the OpenGL renderer"

	average_speed=$(grep -F 'Average speed:' "$mame_log" | tail -1 || true)
	speed_percent=$(sed -n 's/.*Average speed: \([0-9][0-9.]*\)%.*/\1/p' <<<"$average_speed")
	[[ "$speed_percent" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$index-$arm average speed is not parseable"
	printf 'arm=%s cpus=%s nice=%s rr=%s average_speed_percent=%s\n' \
		"$arm" "${arm_cpus[$arm]}" "${arm_nice[$arm]}" "${arm_prio[$arm]}" "$speed_percent" \
		| tee "$run_dir/summary.txt"
}

for command in awk chrt grep sha256sum taskset timeout; do
	command -v "$command" >/dev/null || die "required command is unavailable: $command"
done
[[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] || die 'no graphical session is available'
[[ -x "$binary" ]] || die "binary is not executable: $binary"
[[ -f "$lua_script" ]] || die "fixture is missing: $lua_script"
for arm in "${sequence[@]}"; do
	[[ -n ${arm_cpus[$arm]:-} ]] || die "unknown arm: $arm"
	taskset --cpu-list "${arm_cpus[$arm]}" true 2>/dev/null || die "CPU list is unavailable for $arm"
done
for process in mpc make cc1plus pw-record bpftrace perf; do
	! pgrep -x "$process" >/dev/null || die "refusing to overlap active process: $process"
done

[[ ! -e "$artifact" ]] || die "refusing to reuse result directory $artifact"
mkdir -p -- "$artifact"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

{
	printf 'created=%s\n' "$(date --iso-8601=ns)"
	printf 'experiment=emulation throughput with sound and the OpenGL LCD active\n'
	printf 'binary=%s\nbinary_sha256=%s\n' "$binary" "$(sha256sum "$binary" | awk '{print $1}')"
	printf 'requested_speed_factor=%s (%s%% of real time)\n' "$speed_factor" "$((speed_factor / 10))"
	printf 'timing_master=video (MAME throttle bounds the run, not the PipeWire clock)\n'
	printf 'fixture=%s\n' "$lua_script"
	printf 'arms=%s repeats=%s\n' "${sequence[*]}" "$repeats"
} >"$artifact/manifest.txt"

index=0
for (( pass = 1; pass <= repeats; pass++ )); do
	for arm in "${sequence[@]}"; do
		(( index += 1 ))
		printf '\n=== pass %s run %s: %s ===\n' "$pass" "$index" "$arm"
		run_one "$index" "$arm"
	done
done

{
	printf 'requested=%s%% of real time\n' "$((speed_factor / 10))"
	cat "$artifact"/*/summary.txt
} >"$artifact/summary.txt"
printf '\n=== summary ===\n'
cat "$artifact/summary.txt"
