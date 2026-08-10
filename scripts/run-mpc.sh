#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame"}
mame_bin=${MAME_BIN:-"$mame_source_dir/mpc"}
rom_dir=${MAME_ROM_DIR:-"$repo_root/roms"}
runtime_dir=${MAME_RUNTIME_DIR:-"$repo_root/results/runtime"}
system_name=${1:-mpc2000xl}
pipewire_frames=${2:-128}
pipewire_rate=${PIPEWIRE_RATE_HZ:-48000}
mame_nice=${MAME_NICE:--10}
mame_rt_priority=${MAME_RT_PRIORITY:-20}
mame_cpuset=${MAME_CPUSET:-0-11}
bios_name=${MAME_BIOS:-}

if (( $# > 0 )); then shift; fi
if (( $# > 0 )); then shift; fi

case "$system_name" in
    mpc2000xl)
        bios_name=${bios_name:-default}
        ;;
    mpc3000)
        bios_name=${bios_name:-vailixi}
        ;;
    mpc60)
        bios_name=${bios_name:-v212}
        ;;
    mpc60scsi)
        bios_name=${bios_name:-v214}
        ;;
    *)
        printf 'error: unsupported system %s\n' "$system_name" >&2
        exit 2
        ;;
esac

if [[ ! "$pipewire_frames" =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: PipeWire period must be a positive frame count, got %s\n' "$pipewire_frames" >&2
    exit 2
fi

if [[ ! "$pipewire_rate" =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: PipeWire graph rate must be a positive integer, got %s\n' "$pipewire_rate" >&2
    exit 2
fi

if [[ ! "$mame_nice" =~ ^-?([0-9]|1[0-9]|20)$ ]]; then
    printf 'error: MAME_NICE must be an integer from -20 through 20, got %s\n' "$mame_nice" >&2
    exit 2
fi

if [[ ! "$mame_rt_priority" =~ ^([1-9]|[1-8][0-9]|9[0-5])$ ]]; then
    printf 'error: MAME_RT_PRIORITY must be an integer from 1 through 95, got %s\n' "$mame_rt_priority" >&2
    exit 2
fi

if ! taskset --cpu-list "$mame_cpuset" true 2>/dev/null; then
    printf 'error: MAME_CPUSET is not a valid, available CPU list: %s\n' "$mame_cpuset" >&2
    exit 2
fi

if [[ ! -x "$mame_bin" ]]; then
    printf 'error: release MAME binary not found at %s; run scripts/build-mame.sh first\n' "$mame_bin" >&2
    exit 1
fi

mkdir -p -- "$rom_dir" "$runtime_dir/cfg" "$runtime_dir/diff" "$runtime_dir/nvram" "$runtime_dir/snap" "$runtime_dir/sta"
pipewire_latency=${PIPEWIRE_LATENCY:-"$pipewire_frames/$pipewire_rate"}
latency_ms=$(LC_NUMERIC=C awk -v frames="$pipewire_frames" -v rate="$pipewire_rate" \
    'BEGIN { printf "%.2f", frames * 1000 / rate }')
printf 'Starting %s BIOS %s with native PipeWire; PIPEWIRE_LATENCY=%s (~%s ms per period)\n' \
    "$system_name" "$bios_name" "$pipewire_latency" "$latency_ms"
printf 'Scheduling MAME on CPU(s) %s as nice %s, SCHED_RR priority %s (PipeWire runs above it at RR 90)\n' \
    "$mame_cpuset" "$mame_nice" "$mame_rt_priority"

exec taskset --cpu-list "$mame_cpuset" nice -n "$mame_nice" chrt --rr "$mame_rt_priority" \
    env -u MAME_PIPEWIRE_AUDIO_CLOCK PIPEWIRE_LATENCY="$pipewire_latency" "$mame_bin" "$system_name" \
    -rompath "$rom_dir" \
    -bios "$bios_name" \
    -sound pipewire \
    -samplerate "$pipewire_rate" \
    -cfg_directory "$runtime_dir/cfg" \
    -diff_directory "$runtime_dir/diff" \
    -nvram_directory "$runtime_dir/nvram" \
    -snapshot_directory "$runtime_dir/snap" \
    -state_directory "$runtime_dir/sta" \
    -window \
    -throttle \
    "$@"
