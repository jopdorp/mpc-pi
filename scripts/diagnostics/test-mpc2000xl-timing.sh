#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
expected_sha256=${MPC_TIMING_REFERENCE_SHA256:-d85ba20372c3b709acaff0e765ea388ceb0d858e506a9978df7d9792da5d86fd}
project="$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img"
capture_script="$repo_root/scripts/diagnostics/capture-logic-mpc2000xl.lua"
clock_script="$repo_root/scripts/diagnostics/exercise-pipewire-clock-mpc2000xl.lua"
result_dir=$(mktemp -d "$repo_root/results/diagnostics/timing-regression-XXXXXX")

for run in a b; do
    runtime_dir=$(mktemp -d "$repo_root/results/runtime/timing-regression-${run}-XXXXXX")
    MAME_RUNTIME_DIR="$runtime_dir" MAME_NICE=0 \
        "$repo_root/scripts/run-mpc.sh" mpc2000xl 48 \
        -flop "$project" \
        -skip_gameinfo \
        -video none \
        -sound none \
        -wavwrite "$result_dir/render-${run}.wav" \
        -autoboot_script "$capture_script"
done

if ! cmp -s "$result_dir/render-a.wav" "$result_dir/render-b.wav"; then
    printf 'FAIL: intrinsic renders differ; emulator jitter is non-zero\n' >&2
    exit 1
fi
render_sha256=$(sha256sum "$result_dir/render-a.wav")
render_sha256=${render_sha256%% *}
if [[ "$render_sha256" != "$expected_sha256" ]]; then
    printf 'FAIL: render differs from the native-tempo reference PCM\n' >&2
    printf 'expected SHA-256 %s, got %s\n' "$expected_sha256" "$render_sha256" >&2
    exit 1
fi
printf 'PASS: intrinsic PCM is byte-identical (integer and fractional jitter 0.00 samples)\n'

runtime_dir=$(mktemp -d "$repo_root/results/runtime/pipewire-regression-XXXXXX")
MAME_RUNTIME_DIR="$runtime_dir" MAME_PIPEWIRE_STATS=1 \
    "$repo_root/scripts/run-mpc.sh" mpc2000xl 48 \
    -flop "$project" \
    -skip_gameinfo \
    -video none \
    -nothrottle \
    -autoboot_script "$clock_script" \
    >"$result_dir/pipewire.log" 2>&1

if ! awk '
    /PipeWire: realtime audio-clock pacing started/ { active = 1; next }
    active && /PipeWire: MAME audio buffer correction/ {
        reports++
        if ($0 !~ /underruns=0 \(\+0\), overruns=0 \(\+0\)/)
            bad = 1
    }
    END { exit !(active && reports >= 15 && !bad) }
' "$result_dir/pipewire.log"; then
    printf 'FAIL: live PipeWire path corrected, underflowed, or produced too little evidence\n' >&2
    sed -n '/PipeWire: realtime audio-clock pacing started/,$p' "$result_dir/pipewire.log" >&2
    exit 1
fi

printf 'PASS: live PipeWire path made zero corrections across all steady-state reports\n'
if ! awk '
    /PipeWire: audio clock:/ {
        generated = queued = wall = -1
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^generated=/) { split($i, a, "="); generated = a[2] + 0 }
            if ($i ~ /^queued=/)    { split($i, a, "="); queued = a[2] + 0 }
            if ($i ~ /^wall_us=/)   { split($i, a, "="); wall = a[2] + 0 }
        }
        if (generated >= 0 && queued >= 0 && wall >= 0) {
            delivered = generated - queued
            if (!count++) { first_delivered = delivered; first_wall = wall }
            last_delivered = delivered
            last_wall = wall
        }
    }
    END {
        if (count < 5) exit 1
        actual = last_delivered - first_delivered
        expected = (last_wall - first_wall) * 48000 / 1000000
        error = actual - expected
        if (error < 0) error = -error
        exit !(error <= 48)
    }
' "$result_dir/pipewire.log"; then
    printf 'FAIL: live audio clock rate differs from 48 kHz by more than one frame period\n' >&2
    grep 'PipeWire: audio clock:' "$result_dir/pipewire.log" >&2
    exit 1
fi
printf 'PASS: live PipeWire delivery rate tracks 48 kHz within one frame period\n'
printf 'Artifacts: %s\n' "$result_dir"
