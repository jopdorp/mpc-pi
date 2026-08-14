#!/usr/bin/env bash
# Does the derived sound-update cadence (patch 0034) reduce xruns where the
# deadline is actually marginal?
#
# The deployment CPUs have roughly seven times the headroom needed and record
# zero playback underruns either way, so they cannot answer this. CPUs 20-21 at
# SCHED_RR 1 are this host's 2.5 GHz low-power E-cores at the lowest real-time
# priority; that configuration does miss deadlines, so it is the environment
# that can show a difference.
#
# Both arms use the same binary and the same options. The only difference is
# MPC_SOUND_UPDATES_PER_QUANTUM. Underruns are split at the
# "realtime audio-clock pacing started" marker, because everything before it is
# the fixture's muted, unpaced 400% boot phase and is not audible playback.
#
# MAME_PIPEWIRE_STATS is an observer and perturbs the path it measures, but it
# is applied identically to both arms, so the comparison remains matched.
set -euo pipefail
export LC_ALL=C

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
binary=${MAME_BIN:-"$root/.cache/mame/mpc"}
project="$root/results/projects/mpc-tutor-logic-mpc2000xl.img"
lua_script="$root/scripts/diagnostics/live-logic-mpc2000xl.lua"
artifact=${MPC_ARTIFACT_DIR:-"$root/results/diagnostics/cadence-marginal-$(date +%Y%m%d-%H%M%S)"}
workload_cpus=${MPC_MARGINAL_CPUS:-20-21}
mame_nice=${MPC_MARGINAL_NICE:-0}
mame_rt_priority=${MPC_MARGINAL_RT:-1}
updates_per_quantum=${MPC_MARGINAL_K:-2}
read -r -a sequence <<<"${MPC_MARGINAL_SEQUENCE:-control derived derived control control derived derived control}"

die()
{
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

for command in awk chrt grep pgrep taskset timeout; do
	command -v "$command" >/dev/null || die "required command is unavailable: $command"
done
[[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] || die 'no graphical session is available'
[[ -x "$binary" ]] || die "binary is not executable: $binary"
LC_ALL=C grep -aFq -- MAME_SOUND_UPDATE_FRAMES "$binary" \
	|| die 'binary lacks patch 0034; run scripts/build-mame.sh'
taskset --cpu-list "$workload_cpus" true 2>/dev/null || die "CPU list unavailable: $workload_cpus"
for process in mpc make cc1plus pw-record bpftrace perf; do
	! pgrep -x "$process" >/dev/null || die "refusing to overlap active process: $process"
done
[[ ! -e "$artifact" ]] || die "refusing to reuse result directory $artifact"
mkdir -p -- "$artifact"

{
	printf 'created=%s\n' "$(date --iso-8601=ns)"
	printf 'question=does MPC_SOUND_UPDATES_PER_QUANTUM=%s reduce playback underruns on a marginal deadline\n' \
		"$updates_per_quantum"
	printf 'binary=%s\nbinary_sha256=%s\n' "$binary" "$(sha256sum "$binary" | awk '{print $1}')"
	printf 'workload_cpus=%s nice=%s rt_priority=%s\n' "$workload_cpus" "$mame_nice" "$mame_rt_priority"
	printf 'exact_arm_delta=MPC_SOUND_UPDATES_PER_QUANTUM unset versus %s\n' "$updates_per_quantum"
	printf 'sequence=%s\n' "${sequence[*]}"
	printf 'observer=MAME_PIPEWIRE_STATS applied identically to both arms\n'
} >"$artifact/manifest.txt"

run_one()
{
	local index=$1 arm=$2 run_dir="$artifact/$1-$2" log
	local start boot playback cadence speed status
	mkdir -p -- "$run_dir/runtime"
	log="$run_dir/mame.log"

	set +e
	if [[ "$arm" == derived ]]; then
		MPC_SOUND_UPDATES_PER_QUANTUM="$updates_per_quantum" \
		MAME_PIPEWIRE_STATS=1 MAME_BIN="$binary" \
		MAME_CPUSET="$workload_cpus" MAME_NICE="$mame_nice" MAME_RT_PRIORITY="$mame_rt_priority" \
		MAME_RUNTIME_DIR="$run_dir/runtime" \
		timeout --signal=TERM --kill-after=10s 260s \
			"$root/scripts/run-mpc2000xl-fast.sh" \
			-flop "$project" -skip_gameinfo -verbose -seconds_to_run 60 \
			-autoboot_script "$lua_script" >"$log" 2>&1
	else
		env -u MPC_SOUND_UPDATES_PER_QUANTUM \
		MAME_PIPEWIRE_STATS=1 MAME_BIN="$binary" \
		MAME_CPUSET="$workload_cpus" MAME_NICE="$mame_nice" MAME_RT_PRIORITY="$mame_rt_priority" \
		MAME_RUNTIME_DIR="$run_dir/runtime" \
		timeout --signal=TERM --kill-after=10s 260s \
			"$root/scripts/run-mpc2000xl-fast.sh" \
			-flop "$project" -skip_gameinfo -verbose -seconds_to_run 60 \
			-autoboot_script "$lua_script" >"$log" 2>&1
	fi
	status=$?
	set -e
	(( status == 0 )) || die "$index-$arm exited with status $status"

	start=$(grep -n 'realtime audio-clock pacing started' "$log" | cut -d: -f1)
	[[ -n "$start" ]] || die "$index-$arm never started realtime pacing"
	boot=$(head -n "$start" "$log" | grep -oP 'underruns=\d+' | cut -d= -f2 | sort -n | tail -1)
	playback=$(tail -n +"$start" "$log" | grep -oP 'underruns=\d+' | cut -d= -f2 | sort -n | tail -1)
	cadence=$(grep -o 'Sound update cadence: .*' "$log" | head -1)
	speed=$(sed -n 's/.*Average speed: \([0-9][0-9.]*\)%.*/\1/p' "$log" | tail -1)

	# Guard against an arm silently running the other arm's cadence.
	if [[ "$arm" == derived ]]; then
		grep -Fq 'host update cadence derived from' "$log" \
			|| die "$index-$arm did not activate the derived cadence"
	else
		! grep -Fq 'host update cadence derived from' "$log" \
			|| die "$index-$arm unexpectedly activated the derived cadence"
	fi

	printf 'arm=%s boot_underruns=%s playback_underruns=%s speed=%s %s\n' \
		"$arm" "${boot:-0}" "${playback:-0}" "${speed:-unknown}" "$cadence" \
		| tee "$run_dir/summary.txt"
}

index=0
for arm in "${sequence[@]}"; do
	(( index += 1 ))
	printf '\n=== run %s: %s ===\n' "$index" "$arm"
	run_one "$index" "$arm"
done

{
	printf 'sequence=%s\n\n' "${sequence[*]}"
	cat "$artifact"/*/summary.txt
	printf '\n--- playback underruns by arm ---\n'
	for arm in control derived; do
		values=$(grep -h "^arm=$arm " "$artifact"/*/summary.txt \
			| grep -oP 'playback_underruns=\d+' | cut -d= -f2 | tr '\n' ' ')
		total=$(printf '%s\n' $values | awk '{ s += $1 } END { print s+0 }')
		count=$(printf '%s\n' $values | grep -c . || true)
		printf '%s: runs=[%s] total=%s mean=%s\n' "$arm" "${values% }" "$total" \
			"$(awk -v t="$total" -v c="$count" 'BEGIN { printf "%.2f", c ? t/c : 0 }')"
	done
} >"$artifact/summary.txt"
printf '\n=== summary ===\n'
cat "$artifact/summary.txt"
