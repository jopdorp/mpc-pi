#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
expected_sha256=${MPC_V53_STATUS_REFERENCE_SHA256:-a65077eb074df2671731ea0e3f315f627044b4ece480c75de2871b8fd81b4014}
project="$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img"
capture_script="$repo_root/scripts/diagnostics/capture-logic-mpc2000xl.lua"
result_dir=$(mktemp -d "$repo_root/results/diagnostics/v53-status-hle-XXXXXX")

render_hle() {
    local run=$1
    local runtime_dir
    runtime_dir=$(mktemp -d "$repo_root/results/runtime/v53-status-hle-${run}-XXXXXX")
    MAME_RUNTIME_DIR="$runtime_dir" MAME_NICE=0 \
        MPC_PANEL_MODE=event MPC_PANEL_TIMER_MODE=coalesced \
        MPC_MIDI_CLOCK_MODE=event MPC_V53_STATUS_MODE=hle \
        "$repo_root/scripts/run-mpc.sh" mpc2000xl 32 \
        -flop "$project" \
        -skip_gameinfo \
        -video none \
        -sound none \
        -wavwrite "$result_dir/render-hle-${run}.wav" \
        -autoboot_script "$capture_script" \
        >"$result_dir/render-hle-${run}.log" 2>&1

    if ! grep -q 'MPC2000XL BRK 88 status-service HLE active' "$result_dir/render-hle-${run}.log"; then
        printf 'FAIL: V53 status-service HLE did not activate in run %s\n' "$run" >&2
        sed -n '1,120p' "$result_dir/render-hle-${run}.log" >&2
        exit 1
    fi
}

render_hle a
render_hle b

if ! cmp -s "$result_dir/render-hle-a.wav" "$result_dir/render-hle-b.wav"; then
    printf 'FAIL: V53 status-service HLE renders differ; emulator jitter is non-zero\n' >&2
    exit 1
fi

for render in "$result_dir"/render-hle-*.wav; do
    render_sha256=$(sha256sum "$render")
    render_sha256=${render_sha256%% *}
    if [[ "$render_sha256" != "$expected_sha256" ]]; then
        printf 'FAIL: %s differs from the frozen event-mode reference PCM\n' "$render" >&2
        printf 'expected SHA-256 %s, got %s\n' "$expected_sha256" "$render_sha256" >&2
        exit 1
    fi
done

printf 'PASS: repeated V53 status-service HLE renders match the frozen event-mode reference exactly\n'
printf 'Artifacts: %s\n' "$result_dir"
