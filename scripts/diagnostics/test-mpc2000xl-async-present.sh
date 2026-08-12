#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
repetitions=${MPC_ASYNC_STRESS_REPETITIONS:-3}
project="$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img"
lua_script="$repo_root/scripts/diagnostics/stress-async-present-mpc2000xl.lua"
result_dir=$(mktemp -d "$repo_root/results/diagnostics/async-present-XXXXXX")

if [[ ! "$repetitions" =~ ^[1-9][0-9]*$ ]]; then
	printf 'error: MPC_ASYNC_STRESS_REPETITIONS must be a positive integer\n' >&2
	exit 2
fi
if [[ -z "${DISPLAY:-}" ]]; then
	printf 'error: DISPLAY must identify an X11 display for the OpenGL regression\n' >&2
	exit 2
fi

for run in $(seq 1 "$repetitions"); do
	runtime_dir=$(mktemp -d "$repo_root/results/runtime/async-present-XXXXXX")
	log="$result_dir/run-$run.log"

	MAME_RUNTIME_DIR="$runtime_dir" MAME_TIMING_MASTER=video \
	MAME_NICE=0 MAME_RT_PRIORITY=1 \
	MPC_VIDEO_MODE=opengl MPC_ASYNC_PRESENT=1 \
	MPC_SDL_EXTERNAL_EVENT_LOOP=1 MPC_VIEW_NAME='Default Layout' \
	MPC_WINDOW_RESOLUTION=1600x900 MPC_MAXIMIZE=0 MPC_FILTER_MODE=1 \
	MPC_PANEL_MODE=event MPC_PANEL_TIMER_MODE=coalesced \
	MPC_MIDI_CLOCK_MODE=event MPC_V53_STATUS_MODE=hle \
	MPC_V53_EVENT_SERVICE_MODE=hle MPC_V53_DISPATCH_MODE=direct \
		"$repo_root/scripts/run-mpc.sh" mpc2000xl 32 \
		-flop "$project" \
		-skip_gameinfo \
		-sound none \
		-autoboot_script "$lua_script" \
		>"$log" 2>&1

	if ! grep -q 'MPC_ASYNC_PRESENT_STRESS_BEGIN' "$log" ||
		! grep -q 'MPC_ASYNC_PRESENT_STRESS_END' "$log"; then
		printf 'FAIL: async presentation run %s did not complete its playback interval\n' "$run" >&2
		tail -100 "$log" >&2
		exit 1
	fi
	if ! grep -q 'OpenGL: async presenter first frame' "$log"; then
		printf 'FAIL: async presenter did not become active in run %s\n' "$run" >&2
		tail -100 "$log" >&2
		exit 1
	fi
done

printf 'PASS: %s full-layout asynchronous presentation runs completed cleanly\n' "$repetitions"
printf 'Artifacts: %s\n' "$result_dir"
