#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
expected_sha256=${MPC_SOUND_CACHE_REFERENCE_SHA256:-a65077eb074df2671731ea0e3f315f627044b4ece480c75de2871b8fd81b4014}
project="$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img"
capture_script="$repo_root/scripts/diagnostics/capture-logic-mpc2000xl.lua"
hook_script="$repo_root/scripts/diagnostics/exercise-sound-interface-hooks.lua"
result_dir=$(mktemp -d "$repo_root/results/diagnostics/sound-interface-cache-XXXXXX")

run_mpc()
{
	local runtime_dir
	runtime_dir=$(mktemp -d "$repo_root/results/runtime/sound-interface-cache-XXXXXX")
	MAME_RUNTIME_DIR="$runtime_dir" MAME_NICE=0 \
		MPC_PANEL_MODE=event MPC_PANEL_TIMER_MODE=coalesced \
		MPC_MIDI_CLOCK_MODE=event MPC_V53_STATUS_MODE=hle \
		MPC_V53_EVENT_SERVICE_MODE=hle MPC_V53_DISPATCH_MODE=direct \
		"$repo_root/scripts/run-mpc.sh" mpc2000xl 32 "$@"
}

run_mpc \
	-flop "$project" \
	-skip_gameinfo \
	-video none \
	-sound none \
	-wavwrite "$result_dir/render.wav" \
	-autoboot_script "$capture_script" \
	>"$result_dir/render.log" 2>&1

render_sha256=$(sha256sum "$result_dir/render.wav")
render_sha256=${render_sha256%% *}
if [[ "$render_sha256" != "$expected_sha256" ]]; then
	printf 'FAIL: sound-interface caching differs from the frozen event-mode reference PCM\n' >&2
	printf 'expected SHA-256 %s, got %s\n' "$expected_sha256" "$render_sha256" >&2
	exit 1
fi

run_mpc \
	-skip_gameinfo \
	-video none \
	-sound none \
	-nothrottle \
	-autoboot_script "$hook_script" \
	>"$result_dir/hooks.log" 2>&1

if ! grep -q 'SOUND_INTERFACE_HOOKS_OK' "$result_dir/hooks.log"; then
	printf 'FAIL: live sound-interface hook toggling failed\n' >&2
	sed -n '1,160p' "$result_dir/hooks.log" >&2
	exit 1
fi

printf 'PASS: cached sound interfaces preserve reference PCM and live Lua hooks\n'
printf 'Artifacts: %s\n' "$result_dir"
