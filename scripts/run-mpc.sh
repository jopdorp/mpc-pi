#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame"}
mame_bin=${MAME_BIN:-"$mame_source_dir/mpc"}
rom_dir=${MAME_ROM_DIR:-"$repo_root/roms"}
runtime_dir=${MAME_RUNTIME_DIR:-"$repo_root/results/runtime"}
system_name=${1:-mpc2000xl}
pipewire_frames=${2:-32}
pipewire_rate=${PIPEWIRE_RATE_HZ:-48000}
alsa_headroom=${MPC_ALSA_HEADROOM:-keep}
mame_nice=${MAME_NICE:--10}
mame_rt_priority=${MAME_RT_PRIORITY:-20}
mame_cpuset=${MAME_CPUSET:-0-11}
timing_master=${MAME_TIMING_MASTER:-audio}
video_mode=${MPC_VIDEO_MODE:-opengl}
view_name=${MPC_VIEW_NAME:-Default Layout}
filter_mode=${MPC_FILTER_MODE:-1}
window_resolution=${MPC_WINDOW_RESOLUTION:-auto}
async_present=${MPC_ASYNC_PRESENT:-1}
maximize_window=${MPC_MAXIMIZE:-1}
external_event_loop=${MPC_SDL_EXTERNAL_EVENT_LOOP:-1}
bios_name=${MAME_BIOS:-}
panel_mode=${MPC_PANEL_MODE:-}
midi_input_mode=${MPC_MIDI_INPUT_MODE:-accurate}

if (( $# > 0 )); then shift; fi
if (( $# > 0 )); then shift; fi

case "$system_name" in
    mpc2000xl)
        bios_name=${bios_name:-default}
        panel_mode=${panel_mode:-event}
        ;;
    mpc3000)
        bios_name=${bios_name:-vailixi}
        panel_mode=${panel_mode:-accurate}
        ;;
    mpc60)
        bios_name=${bios_name:-v212}
        panel_mode=${panel_mode:-accurate}
        ;;
    mpc60scsi)
        bios_name=${bios_name:-v214}
        panel_mode=${panel_mode:-accurate}
        ;;
    *)
        printf 'error: unsupported system %s\n' "$system_name" >&2
        exit 2
        ;;
esac

case "$panel_mode" in
    accurate)
        panel_environment=(MAME_MPC_PANEL_EVENT_DRIVEN=0)
        ;;
    event)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_PANEL_MODE=event is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        panel_environment=(MAME_MPC_PANEL_EVENT_DRIVEN=1)
        ;;
    *)
        printf 'error: MPC_PANEL_MODE must be accurate or event, got %s\n' "$panel_mode" >&2
        exit 2
        ;;
esac

case "$midi_input_mode" in
    accurate)
        midi_unset_environment=(-u MAME_MPC_MIDI_FAST_INPUT -u MAME_MPC_MIDI_INTERNAL_PADS)
        midi_environment=()
        ;;
    fast)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_MIDI_INPUT_MODE=fast is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        midi_unset_environment=(-u MAME_MPC_MIDI_INTERNAL_PADS)
        midi_environment=(MAME_MPC_MIDI_FAST_INPUT=1)
        ;;
    internal-pads)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_MIDI_INPUT_MODE=internal-pads is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        midi_unset_environment=()
        midi_environment=(MAME_MPC_MIDI_FAST_INPUT=1 MAME_MPC_MIDI_INTERNAL_PADS=1)
        ;;
    *)
        printf 'error: MPC_MIDI_INPUT_MODE must be accurate, fast, or internal-pads, got %s\n' "$midi_input_mode" >&2
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

if [[ "$alsa_headroom" != keep && ! "$alsa_headroom" =~ ^[0-9]+$ ]]; then
    printf 'error: MPC_ALSA_HEADROOM must be a non-negative frame count or keep, got %s\n' "$alsa_headroom" >&2
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

case "$filter_mode" in
    0) filter_option=-nofilter ;;
    1) filter_option=-filter ;;
    *)
        printf 'error: MPC_FILTER_MODE must be 0 or 1\n' >&2
        exit 2
        ;;
esac

case "$maximize_window" in
    0) maximize_option=-nomaximize ;;
    1) maximize_option=-maximize ;;
    *)
        printf 'error: MPC_MAXIMIZE must be 0 or 1\n' >&2
        exit 2
        ;;
esac

case "$external_event_loop" in
    0|1) ;;
    *)
        printf 'error: MPC_SDL_EXTERNAL_EVENT_LOOP must be 0 or 1\n' >&2
        exit 2
        ;;
esac

case "$timing_master" in
    video)
        clock_environment=(-u MAME_PIPEWIRE_AUDIO_CLOCK)
        throttle_option=-throttle
        ;;
    audio)
        clock_environment=(MAME_PIPEWIRE_AUDIO_CLOCK=1)
        throttle_option=-nothrottle
        ;;
    *)
        printf 'error: MAME_TIMING_MASTER must be video or audio, got %s\n' "$timing_master" >&2
        exit 2
        ;;
esac

if [[ ! -x "$mame_bin" ]]; then
    printf 'error: release MAME binary not found at %s; run scripts/build-mame.sh first\n' "$mame_bin" >&2
    exit 1
fi

if [[ "$alsa_headroom" != keep ]]; then
    if command -v wpctl >/dev/null && command -v pw-cli >/dev/null; then
        default_sink_info=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)
        default_sink_id=$(sed -n '1s/^id \([0-9][0-9]*\),.*/\1/p' <<<"$default_sink_info")
        if [[ -n "$default_sink_id" ]] && grep -q '^[[:space:]]*alsa\.card = ' <<<"$default_sink_info"; then
            pw-cli set-param "$default_sink_id" Props \
                "{ params = [ \"api.alsa.headroom\" $alsa_headroom ] }" >/dev/null
            printf 'Default ALSA sink %s headroom: %s frames\n' "$default_sink_id" "$alsa_headroom"
        else
            printf 'warning: default PipeWire sink is not an ALSA node; headroom was not changed\n' >&2
        fi
    else
        printf 'warning: wpctl/pw-cli unavailable; ALSA headroom was not changed\n' >&2
    fi
else
    printf 'Default ALSA sink headroom: unchanged\n'
fi

mkdir -p -- "$rom_dir" "$runtime_dir/cfg" "$runtime_dir/diff" "$runtime_dir/nvram" "$runtime_dir/snap" "$runtime_dir/sta"
pipewire_latency=${PIPEWIRE_LATENCY:-"$pipewire_frames/$pipewire_rate"}
pipewire_quantum=${PIPEWIRE_QUANTUM:-"$pipewire_frames/$pipewire_rate"}
latency_ms=$(LC_NUMERIC=C awk -v frames="$pipewire_frames" -v rate="$pipewire_rate" \
    'BEGIN { printf "%.2f", frames * 1000 / rate }')
printf 'Starting %s BIOS %s with native PipeWire; quantum=%s, latency=%s (~%s ms requested)\n' \
    "$system_name" "$bios_name" "$pipewire_quantum" "$pipewire_latency" "$latency_ms"
printf 'Scheduling MAME on CPU(s) %s as nice %s, SCHED_RR priority %s (PipeWire runs above it at RR 90)\n' \
    "$mame_cpuset" "$mame_nice" "$mame_rt_priority"
printf 'Timing master: %s\n' "$timing_master"
if [[ "$system_name" == mpc2000xl ]]; then
    printf 'Panel UART: %s mode\n' "$panel_mode"
    printf 'MIDI input: %s mode\n' "$midi_input_mode"
fi
printf 'Video: %s, async=%s, event-loop-isolation=%s, view=%s, resolution=%s, bilinear=%s\n' \
    "$video_mode" "$async_present" "$external_event_loop" "$view_name" "$window_resolution" "$filter_mode"

exec taskset --cpu-list "$mame_cpuset" nice -n "$mame_nice" chrt --rr "$mame_rt_priority" \
    env "${midi_unset_environment[@]}" "${clock_environment[@]}" "${panel_environment[@]}" "${midi_environment[@]}" \
    MAME_ASYNC_PRESENT="$async_present" \
    MAME_SDL_EXTERNAL_EVENT_LOOP="$external_event_loop" \
    PIPEWIRE_QUANTUM="$pipewire_quantum" PIPEWIRE_LATENCY="$pipewire_latency" \
    "$mame_bin" "$system_name" \
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
	-video "$video_mode" \
	-view "$view_name" \
	"$filter_option" \
	"$maximize_option" \
	-resolution "$window_resolution" \
    "$throttle_option" \
    "$@"
