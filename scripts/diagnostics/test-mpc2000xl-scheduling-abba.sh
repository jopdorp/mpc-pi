#!/usr/bin/env bash
# Live 44.1 kHz/q32 delivered-audio ABBA between the LP-E/RR1 measurement
# configuration used by earlier sound-tail experiments and the actual
# run-mpc.sh deployment configuration.
#
# Both arms use the same binary, the same fast-preset options and the same
# clean delivered capture. The only difference is CPU set, nice and SCHED_RR
# priority. Nothing in the emulator, the producer cadence, the sample rate or
# the buffering changes between arms.
set -euo pipefail
export LC_ALL=C

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
binary=${MAME_BIN:-"$root/.cache/mame/mpc"}
launcher="$root/scripts/run-mpc.sh"
lua_script="$root/scripts/diagnostics/live-logic-mpc2000xl.lua"
project="$root/results/projects/mpc-tutor-logic-mpc2000xl.img"
rom="$root/roms/mpc2000xl.zip"
comparator="$root/scripts/diagnostics/compare-live-audio-timing.py"
reference=${MPC_REFERENCE_WAV:-"$root/results/diagnostics/sound-effects-inline-0033-gate-20260813-215500/live-control/emulated.wav"}
artifact=${MPC_ARTIFACT_DIR:-"$root/results/diagnostics/scheduling-abba-$(date +%Y%m%d-%H%M%S)"}

pipewire_rate=44100
pipewire_frames=32

# arm name -> cpuset:nice:rt_priority
declare -A arm_cpus=(
	[lpe-rr1]=20-21 [deploy]=0-11 [deploy-4]=0-3 [deploy-6]=0-5 [deploy-2]=0-1
)
declare -A arm_nice=(
	[lpe-rr1]=0     [deploy]=-10  [deploy-4]=-10 [deploy-6]=-10 [deploy-2]=-10
)
declare -A arm_prio=(
	[lpe-rr1]=1     [deploy]=20   [deploy-4]=20  [deploy-6]=20  [deploy-2]=20
)
read -r -a sequence <<<"${MPC_ABBA_SEQUENCE:-lpe-rr1 deploy deploy lpe-rr1}"
for arm in "${sequence[@]}"; do
	[[ -n ${arm_cpus[$arm]:-} ]] || { printf 'FAIL: unknown arm: %s\n' "$arm" >&2; exit 1; }
done

mame_pid=
pipewire_forced=0
pipewire_lock_fd=
original_force_rate=
original_force_quantum=

die()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

sha()
{
	sha256sum -- "$1" | awk '{ print $1 }'
}

setting_value()
{
	pw-metadata -n settings 0 | sed -n "s/.*key:'$1' value:'\([^']*\)'.*/\1/p" | tail -1
}

restore_pipewire()
{
	local status=0 restored_rate restored_quantum
	(( pipewire_forced )) || return 0
	{
		pw-metadata -n settings 0 clock.force-quantum "$original_force_quantum"
		pw-metadata -n settings 0 clock.force-rate "$original_force_rate"
	} >"$artifact/pipewire-restore.log" 2>&1 || status=1
	sleep 0.25
	pw-metadata -n settings 0 >"$artifact/pipewire-settings-restored.txt" 2>&1 || status=1
	restored_rate=$(setting_value clock.force-rate 2>/dev/null || true)
	restored_quantum=$(setting_value clock.force-quantum 2>/dev/null || true)
	if [[ "$restored_rate" != "$original_force_rate" || "$restored_quantum" != "$original_force_quantum" ]]; then
		printf 'restore verification failed: rate=%s expected=%s quantum=%s expected=%s\n' \
			"$restored_rate" "$original_force_rate" "$restored_quantum" "$original_force_quantum" \
			>>"$artifact/pipewire-restore.log"
		status=1
	fi
	(( status != 0 )) || pipewire_forced=0
	return "$status"
}

release_pipewire_lock()
{
	if [[ "$pipewire_lock_fd" =~ ^[0-9]+$ ]]; then
		flock -u "$pipewire_lock_fd" || true
		exec {pipewire_lock_fd}>&-
		pipewire_lock_fd=
	fi
}

cleanup()
{
	local status=$? restore_status=0 pgid=
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
	if (( pipewire_forced )); then
		set +e
		restore_pipewire
		restore_status=$?
		set -e
		(( status != 0 || restore_status == 0 )) || status=$restore_status
	fi
	release_pipewire_lock
	printf 'Artifacts preserved at %s\n' "$artifact" >&2
	exit "$status"
}

record_resource_gate()
{
	local label=$1 mem_kib cpu_psi io_psi runq
	mem_kib=$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo)
	cpu_psi=$(awk '/^some/ { sub("avg10=", "", $2); print $2 }' /proc/pressure/cpu)
	io_psi=$(awk '/^full/ { sub("avg10=", "", $2); print $2 }' /proc/pressure/io)
	runq=$(awk '{ split($4, a, "/"); print a[1] }' /proc/loadavg)
	{
		printf 'timestamp=%s\n' "$(date --iso-8601=ns)"
		printf 'mem_available_kib=%s cpu_psi_avg10=%s io_full_psi_avg10=%s runq=%s\n' \
			"$mem_kib" "$cpu_psi" "$io_psi" "$runq"
	} >"$artifact/resource-gate-$label.txt"
	awk -v mem="$mem_kib" -v cpu="$cpu_psi" -v io="$io_psi" -v runq="$runq" \
		'BEGIN { exit !(mem >= 16777216 && cpu < 35 && io < 5 && runq <= 12) }' \
		|| die "resource gate failed; see $artifact/resource-gate-$label.txt"
}

verify_mode_markers()
{
	local run_dir=$1 mame_log="$1/mame.log" marker count
	local -a markers=(
		'Timing master: audio'
		'Audio outputs: stereo mode'
		'V53 divide loop: superblock mode'
		'LCD frame updates: changed-only'
		'Video: opengl, async=1, event-loop-isolation=1, view=Screen 0'
		'MPC_TIMING_PLAYBACK_BEGIN'
		'MPC_TIMING_PLAYBACK_END'
		"quantum=$pipewire_frames/$pipewire_rate, latency=$pipewire_frames/$pipewire_rate"
	)
	: >"$run_dir/mode-markers.txt"
	for marker in "${markers[@]}"; do
		count=$(grep -Fc -- "$marker" "$mame_log" || true)
		printf 'count=%s marker=%s\n' "$count" "$marker" >>"$run_dir/mode-markers.txt"
		(( count >= 1 )) || die "missing mode marker: $marker"
	done
	if grep -Eiq 'V53 replay active|V53 hotblocks active|priority boost active|batch output updates active|selected primary output|phase stats:' "$mame_log"; then
		die 'an explicitly disabled experiment or observer became active'
	fi
}

verify_delivered_capture()
{
	local run_dir=$1 delivered_capture="$1/delivered.wav"
	local channels rate bits samples
	local -a wav_files
	mapfile -d '' wav_files < <(find "$run_dir" -type f -iname '*.wav' -print0)
	(( ${#wav_files[@]} == 1 )) || die "expected exactly one WAV, found ${#wav_files[@]}"
	[[ "${wav_files[0]}" == "$delivered_capture" ]] || die "unexpected WAV path: ${wav_files[0]}"
	channels=$(soxi -c "$delivered_capture")
	rate=$(soxi -r "$delivered_capture")
	bits=$(soxi -b "$delivered_capture")
	samples=$(soxi -s "$delivered_capture")
	printf 'channels=%s rate=%s bits=%s samples=%s\n' \
		"$channels" "$rate" "$bits" "$samples" >"$run_dir/delivered-info.txt"
	[[ "$channels" == 2 && "$rate" == "$pipewire_rate" && "$bits" == 16 ]] \
		|| die 'delivered capture is not stereo s16 at the forced rate'
	(( samples >= 661500 )) || die "delivered capture is shorter than 15 seconds: $samples frames"
}

run_one()
{
	local index=$1 arm=$2 run_dir="$artifact/$1-$2"
	local runtime="$run_dir/runtime" delivered_capture="$run_dir/delivered.wav"
	local mame_log="$run_dir/mame.log" mame_status comparison_status average_speed speed_percent argument
	local -a run_command
	mkdir -p -- "$runtime"
	record_resource_gate "$index-$arm"

	run_command=(
		timeout --signal=TERM --kill-after=10s 180s
		env
		-u MAME_MPC_V53_REPLAY
		-u MAME_MPC_V53_HOTBLOCKS
		-u MAME_SOUND_EFFECTS_HANDSHAKE
		-u MAME_SOUND_EFFECTS_PRIORITY_BOOST
		-u MAME_SOUND_EFFECTS_INLINE
		-u MAME_SOUND_EFFECTS_PHASE_STATS
		-u MAME_SOUND_EFFECTS_PENDING_STATS
		-u MAME_SOUND_EFFECTS_PENDING_WAKE
		-u MAME_PIPEWIRE_PRIMARY_OUTPUT
		-u MAME_PIPEWIRE_BATCH_OUTPUT_UPDATES
		-u MAME_PIPEWIRE_STATS
		-u MAME_VIDEO_STATS
		-u MAME_MPC_LCD_STATS
		MAME_BIN="$binary"
		MAME_RUNTIME_DIR="$runtime"
		MAME_CPUSET="${arm_cpus[$arm]}"
		MAME_NICE="${arm_nice[$arm]}"
		MAME_RT_PRIORITY="${arm_prio[$arm]}"
		PIPEWIRE_RATE_HZ="$pipewire_rate"
		PIPEWIRE_QUANTUM="$pipewire_frames/$pipewire_rate"
		PIPEWIRE_LATENCY="$pipewire_frames/$pipewire_rate"
		MAME_TIMING_MASTER=audio
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
		MAME_PIPEWIRE_CAPTURE_WAV="$delivered_capture"
		"$launcher" mpc2000xl "$pipewire_frames"
		-flop "$project"
		-skip_gameinfo
		-seconds_to_run 60
		-autoboot_script "$lua_script"
	)

	for argument in "${run_command[@]}"; do
		[[ "$argument" != -wavwrite ]] || die 'internal error: -wavwrite must not be used'
	done
	{
		printf 'setsid'
		printf ' %q' "${run_command[@]}"
		printf '\n'
	} >"$run_dir/command.txt"
	{
		printf 'index=%s arm=%s\n' "$index" "$arm"
		printf 'cpus=%s nice=%s rt_priority=%s\n' \
			"${arm_cpus[$arm]}" "${arm_nice[$arm]}" "${arm_prio[$arm]}"
		printf 'capture=MAME_PIPEWIRE_CAPTURE_WAV only; no wavwrite, stats or tracers\n'
	} >"$run_dir/manifest.txt"

	set +e
	setsid "${run_command[@]}" >"$mame_log" 2>&1 &
	mame_pid=$!
	wait "$mame_pid"
	mame_status=$?
	set -e
	mame_pid=
	printf '%s\n' "$mame_status" >"$run_dir/mame.exit"
	(( mame_status == 0 )) || die "$index-$arm MAME exited with status $mame_status"

	verify_mode_markers "$run_dir"
	verify_delivered_capture "$run_dir"
	grep -E 'cpu.list|SCHED_RR|Scheduling MAME' "$mame_log" >"$run_dir/scheduling.txt" || true
	set +e
	"$comparator" "$reference" "$delivered_capture" >"$run_dir/delivered-comparison.txt" 2>&1
	comparison_status=$?
	set -e
	average_speed=$(grep -F 'Average speed:' "$mame_log" | tail -1 || true)
	speed_percent=$(sed -n 's/.*Average speed: \([0-9][0-9.]*\)%.*/\1/p' <<<"$average_speed")
	{
		printf 'arm=%s cpus=%s nice=%s rt_priority=%s\n' \
			"$arm" "${arm_cpus[$arm]}" "${arm_nice[$arm]}" "${arm_prio[$arm]}"
		printf 'comparator_status=%s\n' "$comparison_status"
		printf 'average_speed_percent=%s\n' "${speed_percent:-unknown}"
		grep -E '^(integer_timeline_lags|trusted_windows|fractional_residual_(rms|max)_samples|PASS:|FAIL:)' \
			"$run_dir/delivered-comparison.txt" || true
	} >"$run_dir/summary.txt"
	cat "$run_dir/summary.txt"
}

for command in awk chrt find flock grep pw-metadata readelf sha256sum soxi taskset timeout; do
	command -v "$command" >/dev/null || die "required command is unavailable: $command"
done
[[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] || die 'no graphical session is available'
[[ -x "$binary" ]] || die "binary is not executable: $binary"
[[ -f "$reference" ]] || die "reference WAV is missing: $reference"
for capability in MAME_MPC_STEREO_ONLY MAME_MPC_V53_DIVIDE_SUPERBLOCK MAME_MPC_LCD_SKIP_UNCHANGED; do
	LC_ALL=C grep -aFq -- "$capability" "$binary" || die "binary lacks $capability"
done
for cpus in "${arm_cpus[@]}"; do
	taskset --cpu-list "$cpus" true 2>/dev/null || die "CPU list is unavailable: $cpus"
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

pipewire_lock_path=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/mpc-pi-pipewire-graph-${UID}.lock
exec {pipewire_lock_fd}>"$pipewire_lock_path"
flock -n "$pipewire_lock_fd" || die 'another MPC launch owns the PipeWire graph settings'
original_force_rate=$(setting_value clock.force-rate)
original_force_quantum=$(setting_value clock.force-quantum)
[[ "$original_force_rate" =~ ^[0-9]+$ && "$original_force_quantum" =~ ^[0-9]+$ ]] \
	|| die 'could not read numeric PipeWire force-rate/force-quantum values'
pw-metadata -n settings 0 >"$artifact/pipewire-settings-before.txt"
pipewire_forced=1
pw-metadata -n settings 0 clock.force-rate "$pipewire_rate" >/dev/null
pw-metadata -n settings 0 clock.force-quantum "$pipewire_frames" >/dev/null
sleep 0.5
[[ $(setting_value clock.force-rate) == "$pipewire_rate" ]] || die "PipeWire rejected $pipewire_rate Hz"
[[ $(setting_value clock.force-quantum) == "$pipewire_frames" ]] || die "PipeWire rejected q$pipewire_frames"
pw-metadata -n settings 0 >"$artifact/pipewire-settings-active.txt"

{
	printf 'created=%s\n' "$(date --iso-8601=ns)"
	printf 'experiment=same-binary scheduling ABBA: LP-E/RR1 measurement config versus run-mpc.sh deployment config\n'
	printf 'binary=%s\nbinary_sha256=%s\n' "$binary" "$(sha "$binary")"
	printf 'binary_build_id=%s\n' "$(readelf -n "$binary" | sed -n 's/.*Build ID: //p')"
	printf 'launcher_sha256=%s\n' "$(sha "$launcher")"
	printf 'lua_sha256=%s\n' "$(sha "$lua_script")"
	printf 'project_sha256=%s\n' "$(sha "$project")"
	printf 'rom_sha256=%s\n' "$(sha "$rom")"
	printf 'reference=%s\nreference_sha256=%s\n' "$reference" "$(sha "$reference")"
	printf 'comparator_sha256=%s\n' "$(sha "$comparator")"
	printf 'configuration=44.1 kHz q32; audio master; OpenGL Screen 0; stereo; fast preset options\n'
	printf 'exact_arm_delta=MAME_CPUSET/MAME_NICE/MAME_RT_PRIORITY only\n'
	printf 'sequence=%s\n' "${sequence[*]}"
	printf 'pipewire_original_force_rate=%s\npipewire_original_force_quantum=%s\n' \
		"$original_force_rate" "$original_force_quantum"
} >"$artifact/manifest.txt"

index=0
for arm in "${sequence[@]}"; do
	(( index += 1 ))
	printf '\n=== run %s: %s (cpus=%s nice=%s rr=%s) ===\n' \
		"$index" "$arm" "${arm_cpus[$arm]}" "${arm_nice[$arm]}" "${arm_prio[$arm]}"
	run_one "$index" "$arm"
done

{
	printf 'sequence=%s\n' "${sequence[*]}"
	for summary in "$artifact"/*/summary.txt; do
		printf -- '--- %s ---\n' "$(basename "$(dirname "$summary")")"
		cat "$summary"
	done
} >"$artifact/summary.txt"
printf '\nCombined summary written to %s\n' "$artifact/summary.txt"
