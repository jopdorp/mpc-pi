#!/usr/bin/env bash
# Symbol-level throughput profile of the MPC2000XL fast stack.
#
# Runs the unthrottled headroom fixture so the emulation thread is never
# blocked waiting on the audio clock; the samples therefore describe where
# emulation work actually goes rather than how long it idles.
#
# This host is an Intel hybrid part with separate cpu_core and cpu_atom PMUs.
# A plain "cycles" event resolves to only one of them, so a workload pinned to
# P-cores yields an empty profile. The PMU is selected explicitly.
set -euo pipefail
export LC_ALL=C

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
binary=${MAME_BIN:-"$root/.cache/mame/mpc"}
artifact=${MPC_ARTIFACT_DIR:-"$root/results/diagnostics/profile-$(date +%Y%m%d-%H%M%S)"}
workload_cpus=${MPC_PROFILE_CPUS:-0-11}
pmu=${MPC_PROFILE_PMU:-cpu_core}
seconds=${MPC_PROFILE_SECONDS:-12}
frequency=${MPC_PROFILE_FREQ:-4999}
call_graph=${MPC_PROFILE_CALLGRAPH:-none}

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v perf >/dev/null || die 'perf is unavailable'
[[ -x "$binary" ]] || die "binary is not executable: $binary"
[[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] || die 'no graphical session is available'
! pgrep -x mpc >/dev/null || die 'an mpc process is already running'
perf stat -e "$pmu/cycles/" -- true >/dev/null 2>&1 \
	|| die "PMU event $pmu/cycles/ cannot be counted on this host"
[[ ! -e "$artifact" ]] || die "refusing to reuse result directory $artifact"
mkdir -p -- "$artifact/runtime"

mame_pid=
cleanup() {
	local status=$?
	trap - EXIT INT TERM HUP
	[[ -z "$mame_pid" ]] || kill -TERM "$mame_pid" 2>/dev/null || true
	pkill -x mpc 2>/dev/null || true
	printf 'Artifacts preserved at %s\n' "$artifact" >&2
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A very large speed factor keeps MAME's own throttle from ever bounding the
# run, so the profile covers continuous emulation work.
MPC_HEADROOM_SPEED_FACTOR=${MPC_HEADROOM_SPEED_FACTOR:-100000} \
MAME_BIN="$binary" MAME_RUNTIME_DIR="$artifact/runtime" \
MAME_CPUSET="$workload_cpus" MAME_NICE=-10 MAME_RT_PRIORITY=20 \
MAME_TIMING_MASTER=video \
MPC_VIDEO_MODE=opengl MPC_VIEW_NAME='Screen 0' MPC_WINDOW_RESOLUTION=1240x300 \
MPC_OUTPUT_MODE=stereo MPC_ASYNC_PRESENT=1 MPC_SDL_EXTERNAL_EVENT_LOOP=1 \
MPC_PANEL_MODE=event MPC_PANEL_TIMER_MODE=coalesced \
MPC_MIDI_INPUT_MODE=accurate MPC_MIDI_CLOCK_MODE=event \
MPC_V53_STATUS_MODE=hle MPC_V53_EVENT_SERVICE_MODE=hle \
MPC_V53_DISPATCH_MODE=direct MPC_V53_DIVIDE_MODE=superblock \
MPC_LCD_UPDATE_MODE=changed MPC_SOUND_UPDATES_PER_QUANTUM=2 \
MAME_BIOS=default \
	timeout --signal=TERM --kill-after=10s 300s \
	"$root/scripts/run-mpc.sh" mpc2000xl 32 \
	-flop "$root/results/projects/mpc-tutor-logic-mpc2000xl.img" \
	-skip_gameinfo -seconds_to_run 600 \
	-autoboot_script "$root/scripts/diagnostics/headroom-logic-mpc2000xl.lua" \
	>"$artifact/run.log" 2>&1 &
launcher_pid=$!

for _ in $(seq 1 200); do
	mame_pid=$(pgrep -x mpc | head -1 || true)
	[[ -z "$mame_pid" ]] || break
	sleep 0.1
done
[[ -n "$mame_pid" ]] || die 'MAME never started'
# Let the driver finish device init so the profile covers steady-state work.
sleep 2
kill -0 "$mame_pid" 2>/dev/null || die 'MAME exited during warmup'

perf_args=(-e "$pmu/cycles/" -F "$frequency" -p "$mame_pid" -o "$artifact/perf.data")
[[ "$call_graph" == none ]] || perf_args+=(--call-graph "$call_graph")
perf record "${perf_args[@]}" -- sleep "$seconds" 2>"$artifact/perf-record.log" || true

kill -TERM "$launcher_pid" 2>/dev/null || true
kill -TERM "$mame_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
mame_pid=

{
	printf 'created=%s\n' "$(date --iso-8601=ns)"
	printf 'binary=%s\nbinary_sha256=%s\n' "$binary" "$(sha256sum "$binary" | awk '{print $1}')"
	printf 'pmu=%s frequency=%s seconds=%s cpus=%s call_graph=%s\n' \
		"$pmu" "$frequency" "$seconds" "$workload_cpus" "$call_graph"
	printf 'fixture=headroom (unthrottled; emulation thread never waits on the audio clock)\n'
} >"$artifact/manifest.txt"

perf report -i "$artifact/perf.data" --sort=comm --stdio >"$artifact/by-thread.txt" 2>/dev/null || true
perf report -i "$artifact/perf.data" --sort=symbol --stdio >"$artifact/by-symbol.txt" 2>/dev/null || true
perf report -i "$artifact/perf.data" --sort=dso --stdio >"$artifact/by-dso.txt" 2>/dev/null || true

printf '\n=== samples ===\n'
grep -m1 'Samples:' "$artifact/by-symbol.txt" || true
printf '\n=== by thread ===\n'
grep -E '^\s+[0-9]' "$artifact/by-thread.txt" | head -8
printf '\n=== top symbols ===\n'
grep -E '^\s+[0-9]' "$artifact/by-symbol.txt" | head -30
printf '\nArtifacts in %s\n' "$artifact"
