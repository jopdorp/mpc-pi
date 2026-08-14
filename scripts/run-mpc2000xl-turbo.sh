#!/usr/bin/env bash
set -euo pipefail

# Maximum-throughput MPC2000XL preset: every measured speed option is on,
# including the ones that are NOT accuracy-preserving. This is the deployment
# shape for an external panel (Maschine MK1) rather than a reference
# configuration.
#
# Neither this preset nor the fast preset reproduces the frozen PCM render:
# both inherit MPC_OUTPUT_MODE=stereo (patch 0031), which intentionally drops
# assignable-output voices. The reference render is its own configuration
# (MPC_OUTPUT_MODE=all with accurate input paths), and individual patches are
# gated against it there. What this preset adds beyond fast is a
# latency-changing input path: MPC_MIDI_INPUT_MODE=internal-pads (patch 0020)
# injects pad bytes straight into the V53 serial receiver, bypassing panel scan
# and debounce, so pad timing and debounce behaviour intentionally differ.
#
# Acceptance evidence for this preset is the live-timing harness plus
# functional checks. Use scripts/run-mpc2000xl-fast.sh when the emulated
# timing has to stay as close to the reference as the project can measure.
#
# Everything else enabled here is exact (PCM-identical) but ships default-off
# because its measured benefit on desktop x86 is retired instructions rather
# than wall clock; on an in-order Cortex-A53 that work is not hidden.

# Latency-changing: the deployment input path.
export MPC_MIDI_INPUT_MODE=${MPC_MIDI_INPUT_MODE:-internal-pads}
# Latency-changing: suspend the front-panel CPU and synthesize its serial
# stream. Measured +14.8% throughput, and it removes panel scan, debounce and
# serial shift from the input path.
export MPC_PANEL_MODE=${MPC_PANEL_MODE:-hle}

# Exact fast paths held back from the reference preset as A53 candidates.
export MPC_V53_DATA_MODE=${MPC_V53_DATA_MODE:-window}
export MPC_DSP_READ_MODE=${MPC_DSP_READ_MODE:-window}
export MPC_PANEL_TIMER_COUNTDOWN=${MPC_PANEL_TIMER_COUNTDOWN:-countdown}

# Headless: the panel LCD is delivered to external hardware through the
# patch 0039 export, so no window, renderer or artwork work is needed. Set
# MPC_LCD_EXPORT_PATH= (empty) to disable the export, or MPC_VIDEO_MODE to
# put a window back for debugging.
export MPC_VIDEO_MODE=${MPC_VIDEO_MODE:-none}
lcd_export_path=${MPC_LCD_EXPORT_PATH-/dev/shm/mpc-lcd}
if [[ -n "$lcd_export_path" ]]; then
    export MAME_MPC_LCD_EXPORT="$lcd_export_path"
fi

# Input latency: poll MIDI far more often than the stock 1500 Hz (0.67 ms of
# pure queueing before a note reaches the emulator) and stop the DSP DMA from
# pacing transfers at one word per 64 clocks.
export MAME_MPC_MIDI_POLL_HZ=${MAME_MPC_MIDI_POLL_HZ:-8000}
export MAME_MPC_DSP_DMA_TURBO=${MAME_MPC_DSP_DMA_TURBO:-8}

# Deep CPU idle states cost more wake-up latency than anything left in the
# emulator: C6 exits in ~140 us and C10 in ~310 us on a Core Ultra. Holding
# /dev/cpu_dma_latency at 0 keeps the cores out of them for this session.
if [[ -w /dev/cpu_dma_latency ]]; then
    exec 9<>/dev/cpu_dma_latency
    printf '\x00\x00\x00\x00' >&9
    printf 'CPU deep idle: held off through /dev/cpu_dma_latency\n'
else
    printf 'CPU deep idle: NOT held off (/dev/cpu_dma_latency needs root).\n'
    printf '  C-state exit latency stays in the input path. To enable:\n'
    printf '    sudo setfacl -m u:$USER:rw /dev/cpu_dma_latency\n'
    printf '  or install a udev rule granting your user access.\n'
fi
if [[ "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)" == powersave ]]; then
    printf 'CPU governor: powersave (consider performance for a faster ramp out of idle)\n'
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec "$repo_root/scripts/run-mpc2000xl-fast.sh" "$@"
