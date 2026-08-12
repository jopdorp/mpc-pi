#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
expected_sha256=${MPC_V53_EVENT_REFERENCE_SHA256:-a65077eb074df2671731ea0e3f315f627044b4ece480c75de2871b8fd81b4014}
project="$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img"
capture_script="$repo_root/scripts/diagnostics/capture-logic-mpc2000xl.lua"
result_dir=$(mktemp -d "$repo_root/results/diagnostics/v53-event-service-hle-XXXXXX")
runtime_dir=$(mktemp -d "$repo_root/results/runtime/v53-event-service-hle-XXXXXX")

MAME_RUNTIME_DIR="$runtime_dir" MAME_NICE=0 \
    MPC_PANEL_MODE=event MPC_PANEL_TIMER_MODE=coalesced \
    MPC_MIDI_CLOCK_MODE=event MPC_V53_STATUS_MODE=hle \
    MPC_V53_EVENT_SERVICE_MODE=hle \
    "$repo_root/scripts/run-mpc.sh" mpc2000xl 32 \
    -flop "$project" \
    -skip_gameinfo \
    -video none \
    -sound none \
    -wavwrite "$result_dir/render-hle.wav" \
    -autoboot_script "$capture_script" \
    >"$result_dir/render-hle.log" 2>&1

if ! grep -q 'MPC2000XL BRK FD event-service HLE active' "$result_dir/render-hle.log"; then
    printf 'FAIL: V53 event-service HLE did not activate\n' >&2
    sed -n '1,120p' "$result_dir/render-hle.log" >&2
    exit 1
fi

render_sha256=$(sha256sum "$result_dir/render-hle.wav")
render_sha256=${render_sha256%% *}
if [[ "$render_sha256" != "$expected_sha256" ]]; then
    printf 'FAIL: V53 event-service HLE differs from the frozen event-mode reference PCM\n' >&2
    printf 'expected SHA-256 %s, got %s\n' "$expected_sha256" "$render_sha256" >&2
    exit 1
fi

printf 'PASS: V53 event-service HLE matches the frozen event-mode reference exactly\n'
printf 'Artifacts: %s\n' "$result_dir"
