#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
expected_sha256=${MPC_TIMING_REFERENCE_SHA256:-22f76ffaaedc4364b8279a79672a07a35f93997f180b8665e9ef3a576ae176a9}
project="$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img"
capture_script="$repo_root/scripts/diagnostics/capture-logic-mpc2000xl.lua"
clock_script="$repo_root/scripts/diagnostics/exercise-pipewire-clock-mpc2000xl.lua"
result_dir=$(mktemp -d "$repo_root/results/diagnostics/timing-regression-XXXXXX")

render_mode() {
    local timer_mode=$1
    local run=$2
    local runtime_dir
    runtime_dir=$(mktemp -d "$repo_root/results/runtime/timing-regression-${timer_mode}-${run}-XXXXXX")
    MAME_RUNTIME_DIR="$runtime_dir" MAME_NICE=0 MPC_PANEL_MODE=accurate \
        MPC_PANEL_TIMER_MODE="$timer_mode" MPC_MIDI_CLOCK_MODE=accurate \
        "$repo_root/scripts/run-mpc.sh" mpc2000xl 32 \
        -flop "$project" \
        -skip_gameinfo \
        -video none \
        -sound none \
        -wavwrite "$result_dir/render-${timer_mode}-${run}.wav" \
        -autoboot_script "$capture_script"
}

render_mode accurate reference
render_mode coalesced a
render_mode coalesced b

if ! cmp -s "$result_dir/render-coalesced-a.wav" "$result_dir/render-coalesced-b.wav"; then
    printf 'FAIL: coalesced panel-timer renders differ; emulator jitter is non-zero\n' >&2
    exit 1
fi
if ! cmp -s "$result_dir/render-accurate-reference.wav" "$result_dir/render-coalesced-a.wav"; then
    printf 'FAIL: coalesced panel timer changed PCM relative to accurate mode\n' >&2
    exit 1
fi
for render in "$result_dir"/render-*.wav; do
    render_sha256=$(sha256sum "$render")
    render_sha256=${render_sha256%% *}
    if [[ "$render_sha256" != "$expected_sha256" ]]; then
        printf 'FAIL: %s differs from the native-tempo reference PCM\n' "$render" >&2
        printf 'expected SHA-256 %s, got %s\n' "$expected_sha256" "$render_sha256" >&2
        exit 1
    fi
done
printf 'PASS: accurate and coalesced panel-timer PCM are byte-identical (integer and fractional jitter 0.00 samples)\n'

runtime_dir=$(mktemp -d "$repo_root/results/runtime/pipewire-regression-XXXXXX")
MAME_RUNTIME_DIR="$runtime_dir" MAME_PIPEWIRE_STATS=1 MPC_PANEL_MODE=event \
    MPC_PANEL_TIMER_MODE=coalesced MPC_MIDI_CLOCK_MODE=event \
    "$repo_root/scripts/run-mpc.sh" mpc2000xl 32 \
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
            x[count] = wall / 1000000
            y[count] = delivered
            sx += x[count]
            sy += y[count]
            count++
        }
    }
    END {
        if (count < 5) exit 1
        mean_x = sx / count
        mean_y = sy / count
        for (i = 0; i < count; i++) {
            dx = x[i] - mean_x
            variance += dx * dx
            covariance += dx * (y[i] - mean_y)
        }
        if (variance == 0) exit 1
        slope = covariance / variance
        intercept = mean_y - slope * mean_x
        duration = x[count - 1] - x[0]
        drift = (slope - 48000) * duration
        if (drift < 0) drift = -drift
        max_residual = 0
        for (i = 0; i < count; i++) {
            residual = y[i] - (intercept + slope * x[i])
            if (residual < 0) residual = -residual
            if (residual > max_residual) max_residual = residual
        }
        printf "fitted_delivery_rate_hz=%.6f\n", slope
        printf "fitted_drift_over_capture_samples=%.6f\n", drift
        printf "wall_clock_fit_max_residual_samples=%.6f\n", max_residual
        exit !((drift <= 48) && (max_residual <= 48))
    }
' "$result_dir/pipewire.log"; then
    printf 'FAIL: fitted live audio clock differs from the 48 kHz timeline by more than one frame period\n' >&2
    grep 'PipeWire: audio clock:' "$result_dir/pipewire.log" >&2
    exit 1
fi
printf 'PASS: fitted live PipeWire delivery tracks 48 kHz within one frame period\n'
printf 'Artifacts: %s\n' "$result_dir"
