#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame"}
mame_bin=${MAME_BIN:-"$mame_source_dir/mpc"}
rom_dir=${MAME_ROM_DIR:-"$repo_root/roms"}
runtime_dir=${MAME_RUNTIME_DIR:-"$repo_root/results/runtime"}
system_name=${1:-mpc2000xl}
# 48 frames at 44.1kHz is 1088us. 48 divides by both 8 and 16, so the
# host-update cadence can stay at 8-sample updates (6 per quantum) or
# relax to 16 (3 per quantum) without changing the quantum again -
# MPC_SOUND_UPDATES_PER_QUANTUM must divide this exactly.
pipewire_frames=${2:-48}
# 44100: the MPC2000XL is a 44.1kHz machine, and the whole graph now
# runs at its rate so nothing resamples the emulator's own output.
pipewire_rate=${PIPEWIRE_RATE_HZ:-44100}
alsa_headroom=${MPC_ALSA_HEADROOM:-keep}
mame_nice=${MAME_NICE:--10}
mame_rt_priority=${MAME_RT_PRIORITY:-20}
mame_cpuset=${MAME_CPUSET:-0-11}
timing_master=${MAME_TIMING_MASTER:-audio}
video_mode=${MPC_VIDEO_MODE:-opengl}
view_name=${MPC_VIEW_NAME:-Default Layout}
filter_mode=${MPC_FILTER_MODE:-1}
window_resolution=${MPC_WINDOW_RESOLUTION:-auto}
artwork_resolution=${MPC_ARTWORK_RESOLUTION:-auto}
gl_vbo=${MPC_GL_VBO:-1}
output_mode=${MPC_OUTPUT_MODE:-all}
async_present=${MPC_ASYNC_PRESENT:-1}
maximize_window=${MPC_MAXIMIZE:-1}
external_event_loop=${MPC_SDL_EXTERNAL_EVENT_LOOP:-1}
bios_name=${MAME_BIOS:-}
panel_mode=${MPC_PANEL_MODE:-}
panel_timer_mode=${MPC_PANEL_TIMER_MODE:-accurate}
midi_input_mode=${MPC_MIDI_INPUT_MODE:-accurate}
midi_clock_mode=${MPC_MIDI_CLOCK_MODE:-}
v53_status_mode=${MPC_V53_STATUS_MODE:-accurate}
v53_event_service_mode=${MPC_V53_EVENT_SERVICE_MODE:-accurate}
v53_feed_flag_mode=${MPC_V53_FEED_FLAG_MODE:-accurate}
panel_timer_countdown_mode=${MPC_PANEL_TIMER_COUNTDOWN:-accurate}
v53_tick_read_mode=${MPC_V53_TICK_READ_MODE:-accurate}
v53_dispatch_mode=${MPC_V53_DISPATCH_MODE:-accurate}
v53_divide_mode=${MPC_V53_DIVIDE_MODE:-accurate}
lcd_update_mode=${MPC_LCD_UPDATE_MODE:-accurate}
sound_updates_per_quantum=${MPC_SOUND_UPDATES_PER_QUANTUM:-}
v53_fetch_mode=${MPC_V53_FETCH_MODE:-accurate}
v53_data_mode=${MPC_V53_DATA_MODE:-accurate}
v53_idle_mode=${MPC_V53_IDLE_MODE:-accurate}
dsp_read_mode=${MPC_DSP_READ_MODE:-accurate}

if (( $# > 0 )); then shift; fi
if (( $# > 0 )); then shift; fi

case "$system_name" in
    mpc2000xl)
        bios_name=${bios_name:-default}
        panel_mode=${panel_mode:-event}
        midi_clock_mode=${midi_clock_mode:-event}
        ;;
    mpc3000)
        bios_name=${bios_name:-vailixi}
        panel_mode=${panel_mode:-accurate}
        midi_clock_mode=${midi_clock_mode:-accurate}
        ;;
    mpc60)
        bios_name=${bios_name:-v212}
        panel_mode=${panel_mode:-accurate}
        midi_clock_mode=${midi_clock_mode:-accurate}
        ;;
    mpc60scsi)
        bios_name=${bios_name:-v214}
        panel_mode=${panel_mode:-accurate}
        midi_clock_mode=${midi_clock_mode:-accurate}
        ;;
    *)
        printf 'error: unsupported system %s\n' "$system_name" >&2
        exit 2
        ;;
esac

case "$output_mode" in
    all)
        output_environment=(MAME_MPC_STEREO_ONLY=0)
        cfg_directory="$runtime_dir/cfg"
        ;;
    stereo)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_OUTPUT_MODE=stereo is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        output_environment=(MAME_MPC_STEREO_ONLY=1)
        cfg_directory="$runtime_dir/cfg-stereo;$runtime_dir/cfg"
        ;;
    *)
        printf 'error: MPC_OUTPUT_MODE must be all or stereo, got %s\n' "$output_mode" >&2
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
    hle)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_PANEL_MODE=hle is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        # The panel CPU is suspended and its serial stream is synthesized.
        panel_environment=(MAME_MPC_PANEL_EVENT_DRIVEN=1 MAME_MPC_PANEL_HLE=1)
        ;;
    *)
        printf 'error: MPC_PANEL_MODE must be accurate, event, or hle, got %s\n' "$panel_mode" >&2
        exit 2
        ;;
esac

case "$panel_timer_mode" in
    accurate)
        panel_timer_environment=(MAME_MPC_PANEL_TIMER_COALESCED=0)
        ;;
    coalesced)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_PANEL_TIMER_MODE=coalesced is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        panel_timer_environment=(MAME_MPC_PANEL_TIMER_COALESCED=1)
        ;;
    *)
        printf 'error: MPC_PANEL_TIMER_MODE must be accurate or coalesced, got %s\n' "$panel_timer_mode" >&2
        exit 2
        ;;
esac

case "$midi_clock_mode" in
    accurate)
        midi_clock_environment=(MAME_MPC_MIDI_EVENT_DRIVEN=0)
        ;;
    event)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_MIDI_CLOCK_MODE=event is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        midi_clock_environment=(MAME_MPC_MIDI_EVENT_DRIVEN=1)
        ;;
    *)
        printf 'error: MPC_MIDI_CLOCK_MODE must be accurate or event, got %s\n' "$midi_clock_mode" >&2
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

case "$v53_status_mode" in
    accurate)
        v53_status_environment=(MAME_MPC_V53_BRK88_HLE=0)
        ;;
    hle)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_V53_STATUS_MODE=hle is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        v53_status_environment=(MAME_MPC_V53_BRK88_HLE=1)
        ;;
    *)
        printf 'error: MPC_V53_STATUS_MODE must be accurate or hle, got %s\n' "$v53_status_mode" >&2
        exit 2
        ;;
esac

case "$v53_event_service_mode" in
    accurate)
        v53_event_service_environment=(MAME_MPC_V53_BRKFD_HLE=0)
        ;;
    hle)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_V53_EVENT_SERVICE_MODE=hle is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        v53_event_service_environment=(MAME_MPC_V53_BRKFD_HLE=1)
        ;;
    *)
        printf 'error: MPC_V53_EVENT_SERVICE_MODE must be accurate or hle, got %s\n' "$v53_event_service_mode" >&2
        exit 2
        ;;
esac

case "$v53_feed_flag_mode" in
    accurate)
        v53_feed_flag_environment=(MAME_MPC_V53_BRK92_HLE=0)
        ;;
    hle)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_V53_FEED_FLAG_MODE=hle is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        v53_feed_flag_environment=(MAME_MPC_V53_BRK92_HLE=1)
        ;;
    *)
        printf 'error: MPC_V53_FEED_FLAG_MODE must be accurate or hle, got %s\n' "$v53_feed_flag_mode" >&2
        exit 2
        ;;
esac

case "$v53_tick_read_mode" in
    accurate)
        v53_tick_read_environment=(MAME_MPC_V53_BRK77_HLE=0)
        ;;
    hle)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_V53_TICK_READ_MODE=hle is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        v53_tick_read_environment=(MAME_MPC_V53_BRK77_HLE=1)
        ;;
    *)
        printf 'error: MPC_V53_TICK_READ_MODE must be accurate or hle, got %s\n' "$v53_tick_read_mode" >&2
        exit 2
        ;;
esac

panel_timer_countdown_unset=()
panel_timer_countdown_environment=()
case "$panel_timer_countdown_mode" in
    accurate)
        panel_timer_countdown_unset=(-u MAME_MPC_PANEL_TIMER_FAST)
        ;;
    countdown)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_PANEL_TIMER_COUNTDOWN=countdown is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        panel_timer_countdown_environment=(MAME_MPC_PANEL_TIMER_FAST=1)
        ;;
    *)
        printf 'error: MPC_PANEL_TIMER_COUNTDOWN must be accurate or countdown, got %s\n' "$panel_timer_countdown_mode" >&2
        exit 2
        ;;
esac

case "$v53_dispatch_mode" in
    accurate)
        v53_dispatch_environment=(MAME_MPC_V53_DIRECT_DISPATCH=0)
        ;;
    direct)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_V53_DISPATCH_MODE=direct is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        v53_dispatch_environment=(MAME_MPC_V53_DIRECT_DISPATCH=1)
        ;;
    *)
        printf 'error: MPC_V53_DISPATCH_MODE must be accurate or direct, got %s\n' "$v53_dispatch_mode" >&2
        exit 2
        ;;
esac

case "$v53_divide_mode" in
    accurate)
        v53_divide_environment=(MAME_MPC_V53_DIVIDE_SUPERBLOCK=0)
        ;;
    superblock)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_V53_DIVIDE_MODE=superblock is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        v53_divide_environment=(MAME_MPC_V53_DIVIDE_SUPERBLOCK=1)
        ;;
    *)
        printf 'error: MPC_V53_DIVIDE_MODE must be accurate or superblock, got %s\n' "$v53_divide_mode" >&2
        exit 2
        ;;
esac

case "$lcd_update_mode" in
    accurate)
        lcd_update_environment=(MAME_MPC_LCD_SKIP_UNCHANGED=0)
        ;;
    changed)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_LCD_UPDATE_MODE=changed is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        lcd_update_environment=(MAME_MPC_LCD_SKIP_UNCHANGED=1)
        ;;
    *)
        printf 'error: MPC_LCD_UPDATE_MODE must be accurate or changed, got %s\n' "$lcd_update_mode" >&2
        exit 2
        ;;
esac

v53_fetch_unset=()
v53_fetch_environment=()
case "$v53_fetch_mode" in
    accurate)
        # GNU env only accepts -u before the first NAME=VALUE operand.
        v53_fetch_unset=(-u MAME_MPC_V53_FETCH_WINDOW)
        ;;
    window)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_V53_FETCH_MODE=window is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        v53_fetch_environment=(MAME_MPC_V53_FETCH_WINDOW=1)
        ;;
    *)
        printf 'error: MPC_V53_FETCH_MODE must be accurate or window, got %s\n' "$v53_fetch_mode" >&2
        exit 2
        ;;
esac

v53_data_unset=()
v53_data_environment=()
case "$v53_data_mode" in
    accurate)
        v53_data_unset=(-u MAME_MPC_V53_DATA_WINDOW)
        ;;
    window)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_V53_DATA_MODE=window is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        v53_data_environment=(MAME_MPC_V53_DATA_WINDOW=1)
        ;;
    *)
        printf 'error: MPC_V53_DATA_MODE must be accurate or window, got %s\n' "$v53_data_mode" >&2
        exit 2
        ;;
esac

v53_idle_unset=()
v53_idle_environment=()
case "$v53_idle_mode" in
    accurate)
        v53_idle_unset=(-u MAME_MPC_V53_IDLE_SKIP)
        ;;
    skip)
        if [[ "$system_name" != mpc2000xl ]]; then
            printf 'error: MPC_V53_IDLE_MODE=skip is only supported by mpc2000xl\n' >&2
            exit 2
        fi
        v53_idle_environment=(MAME_MPC_V53_IDLE_SKIP=1)
        ;;
    *)
        printf 'error: MPC_V53_IDLE_MODE must be accurate or skip, got %s\n' "$v53_idle_mode" >&2
        exit 2
        ;;
esac

dsp_read_unset=()
dsp_read_environment=()
case "$dsp_read_mode" in
    accurate)
        dsp_read_unset=(-u MAME_MPC_DSP_WINDOW)
        ;;
    window)
        dsp_read_environment=(MAME_MPC_DSP_WINDOW=1)
        ;;
    *)
        printf 'error: MPC_DSP_READ_MODE must be accurate or window, got %s\n' "$dsp_read_mode" >&2
        exit 2
        ;;
esac

# Derive the host sound-update cadence from the graph quantum instead of the
# fixed STREAMS_UPDATE_FREQUENCY constant.  One update then carries
# quantum/updates-per-quantum frames, so a PipeWire callback consumes a whole
# number of producer updates and the internal margin is exactly one quantum
# plus one update.  Unset keeps the historical fixed cadence, which is the
# only setting that reproduces the canonical PCM.
sound_cadence_unset=()
sound_cadence_environment=()
if [[ -z "$sound_updates_per_quantum" ]]; then
    # GNU env only accepts -u before the first NAME=VALUE operand, so the unset
    # flags are emitted in a separate leading group.
    sound_cadence_unset=(-u MAME_SOUND_UPDATE_FRAMES -u MAME_SOUND_UPDATE_RATE)
elif [[ ! "$sound_updates_per_quantum" =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: MPC_SOUND_UPDATES_PER_QUANTUM must be a positive integer, got %s\n' \
        "$sound_updates_per_quantum" >&2
    exit 2
fi

if [[ ! "$pipewire_frames" =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: PipeWire period must be a positive frame count, got %s\n' "$pipewire_frames" >&2
    exit 2
fi

if [[ ! "$pipewire_rate" =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: PipeWire graph rate must be a positive integer, got %s\n' "$pipewire_rate" >&2
    exit 2
fi

if [[ -n "$sound_updates_per_quantum" ]]; then
    if (( pipewire_frames % sound_updates_per_quantum )); then
        printf 'error: MPC_SOUND_UPDATES_PER_QUANTUM=%s must divide the %s-frame quantum exactly\n' \
            "$sound_updates_per_quantum" "$pipewire_frames" >&2
        exit 2
    fi
    sound_update_frames=$(( pipewire_frames / sound_updates_per_quantum ))
    sound_cadence_environment=(
        MAME_SOUND_UPDATE_FRAMES="$sound_update_frames"
        MAME_SOUND_UPDATE_RATE="$pipewire_rate"
    )
fi

case "$artwork_resolution" in
    auto)
        ;;
    *)
        if [[ ! "$artwork_resolution" =~ ^([1-9][0-9]{0,5})x([1-9][0-9]{0,5})$ ]]; then
            printf 'error: MPC_ARTWORK_RESOLUTION must be auto or WIDTHxHEIGHT, got %s\n' \
                "$artwork_resolution" >&2
            exit 2
        fi
        artwork_width=${BASH_REMATCH[1]}
        artwork_height=${BASH_REMATCH[2]}
        if (( artwork_width > 65536 || artwork_height > 65536 )); then
            printf 'error: MPC_ARTWORK_RESOLUTION dimensions must be from 1 through 65536, got %s\n' \
                "$artwork_resolution" >&2
            exit 2
        fi
        ;;
esac

if [[ "$alsa_headroom" != keep && ! "$alsa_headroom" =~ ^[0-9]+$ ]]; then
    printf 'error: MPC_ALSA_HEADROOM must be a non-negative frame count or keep, got %s\n' "$alsa_headroom" >&2
    exit 2
fi

if [[ ! "$mame_nice" =~ ^-?([0-9]|1[0-9]|20)$ ]]; then
    printf 'error: MAME_NICE must be an integer from -20 through 20, got %s\n' "$mame_nice" >&2
    exit 2
fi

# 0 disables SCHED_RR for hosts whose users hold no realtime rlimit; every
# other value is passed to chrt unchanged.
if [[ ! "$mame_rt_priority" =~ ^(0|[1-9]|[1-8][0-9]|9[0-5])$ ]]; then
    printf 'error: MAME_RT_PRIORITY must be 0 or an integer from 1 through 95, got %s\n' \
        "$mame_rt_priority" >&2
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

case "$gl_vbo" in
    0) gl_vbo_option=-nogl_vbo ;;
    1) gl_vbo_option=-gl_vbo ;;
    *)
        printf 'error: MPC_GL_VBO must be 0 or 1\n' >&2
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

# MPC_THROTTLE_MODE overrides what the timing master implies.
#
# timing_master=audio pairs MAME_PIPEWIRE_AUDIO_CLOCK=1 with -nothrottle,
# because the audio backend is then supposed to pace the emulator: it blocks
# when the buffer is full and MAME needs no throttle of its own. That holds on
# the development host.
#
# It does not hold on the Raspberry Pi appliance. There, unthrottled MAME
# free-runs at 100% of its core and floods its own stream - three consecutive
# 6-second samples of PipeWire's error counter on the emulator's node:
#
#     -nothrottle:  9556, 9550, 9617
#     -throttle:     259 per 8s
#
# So the pairing is a default and not a law, and the appliance needs to say so
# rather than either giving up the audio clock or accepting the flood. Why the
# backpressure does not arrive there is still open.
throttle_mode=${MPC_THROTTLE_MODE:-auto}
case "$throttle_mode" in
    auto)       ;;
    throttle)   throttle_option=-throttle ;;
    nothrottle) throttle_option=-nothrottle ;;
    *)
        printf 'error: MPC_THROTTLE_MODE must be auto, throttle, or nothrottle, got %s\n' \
            "$throttle_mode" >&2
        exit 2
        ;;
esac

if [[ ! -x "$mame_bin" ]]; then
    printf 'error: release MAME binary not found at %s; run scripts/build-mame.sh first\n' "$mame_bin" >&2
    exit 1
fi

require_binary_capability()
{
    local marker=$1 setting=$2
    if ! LC_ALL=C grep -aFq -- "$marker" "$mame_bin"; then
        printf 'error: %s requires a newer MAME binary with %s support; run scripts/build-mame.sh\n' \
            "$setting" "$marker" >&2
        exit 1
    fi
}

[[ "$output_mode" != stereo ]] || require_binary_capability MAME_MPC_STEREO_ONLY MPC_OUTPUT_MODE=stereo
[[ "$v53_divide_mode" != superblock ]] || \
    require_binary_capability MAME_MPC_V53_DIVIDE_SUPERBLOCK MPC_V53_DIVIDE_MODE=superblock
[[ "$lcd_update_mode" != changed ]] || \
    require_binary_capability MAME_MPC_LCD_SKIP_UNCHANGED MPC_LCD_UPDATE_MODE=changed

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

mkdir -p -- "$rom_dir" "$runtime_dir/cfg" "$runtime_dir/cfg-stereo" "$runtime_dir/diff" \
    "$runtime_dir/nvram" "$runtime_dir/snap" "$runtime_dir/sta"
pipewire_latency=${PIPEWIRE_LATENCY:-"$pipewire_frames/$pipewire_rate"}
pipewire_quantum=${PIPEWIRE_QUANTUM:-"$pipewire_frames/$pipewire_rate"}
latency_ms=$(LC_NUMERIC=C awk -v frames="$pipewire_frames" -v rate="$pipewire_rate" \
    'BEGIN { printf "%.2f", frames * 1000 / rate }')
printf 'Starting %s BIOS %s with native PipeWire; quantum=%s, latency=%s (~%s ms requested)\n' \
    "$system_name" "$bios_name" "$pipewire_quantum" "$pipewire_latency" "$latency_ms"
# chrt below applies to the PROCESS, so every thread MAME creates inherits this
# priority - including its sound effects thread, which is the audio producer,
# and PipeWire's client thread-loop, which fills the buffers. SCHED_RR does not
# preempt at equal priority, so on a single pinned core those two only run when
# the emulation thread blocks, and the audio producer delivered 9.7% of realtime.
# Raise them afterwards with mpc-audio-thread-priority.sh; see docs/audio-chain.md.
if (( mame_rt_priority > 0 )); then
    scheduler_prefix=(chrt --rr "$mame_rt_priority")
    printf 'Scheduling MAME on CPU(s) %s as nice %s, SCHED_RR priority %s\n' \
        "$mame_cpuset" "$mame_nice" "$mame_rt_priority"
    printf '  NOTE: MAME'\''s audio threads inherit this priority. Run\n'
    printf '        mpc-audio-thread-priority.sh after start or they will be starved.\n'
else
    scheduler_prefix=()
    printf 'Scheduling MAME on CPU(s) %s as nice %s, no realtime priority\n' \
        "$mame_cpuset" "$mame_nice"
fi
printf 'Timing master: %s (%s)\n' "$timing_master" "${throttle_option#-}"
if [[ -n "$sound_updates_per_quantum" ]]; then
    printf 'Sound update cadence: %s frames (%s per %s-frame quantum at %s Hz)\n' \
        "$sound_update_frames" "$sound_updates_per_quantum" "$pipewire_frames" "$pipewire_rate"
else
    printf 'Sound update cadence: fixed 3 kHz\n'
fi
printf 'Audio outputs: %s mode\n' "$output_mode"
if [[ "$system_name" == mpc2000xl ]]; then
    printf 'Panel UART: %s mode\n' "$panel_mode"
    printf 'Panel timer output: %s mode\n' "$panel_timer_mode"
    printf 'MIDI input: %s mode\n' "$midi_input_mode"
    printf 'MIDI baud clocks: %s mode\n' "$midi_clock_mode"
    printf 'V53 status service: %s mode\n' "$v53_status_mode"
    printf 'V53 event service: %s mode\n' "$v53_event_service_mode"
    printf 'V53 opcode dispatch: %s mode\n' "$v53_dispatch_mode"
    printf 'V53 divide loop: %s mode\n' "$v53_divide_mode"
    printf 'V53 opcode fetch: %s mode\n' "$v53_fetch_mode"
    printf 'V53 data access: %s mode\n' "$v53_data_mode"
    printf 'V53 idle loop: %s mode\n' "$v53_idle_mode"
    if [[ "$lcd_update_mode" == changed ]]; then
        printf 'LCD frame updates: changed-only\n'
    else
        printf 'LCD frame updates: every-frame\n'
    fi
fi
# Renderer flags only when there IS a renderer.
#
# -window, -view, -filter, -maximize, -resolution, -artwork_resolution and
# -gl_vbo were passed unconditionally, including with -video none. On a desktop
# build MAME accepts and ignores them; the appliance's binary is built headless
# and has no OpenGL at all, so it exited with
#
#     Error: unknown option: -gl_vbo
#
# status 6/NOTCONFIGURED, 64 restarts deep. The flags were harmless only because
# every machine that had run this script so far happened to have a renderer
# compiled in - which is exactly the kind of assumption that breaks the moment
# the script is used somewhere new, and the appliance is somewhere new.
window_options=()
if [[ "$video_mode" != none ]]; then
    window_options=(
        -window
        -view "$view_name"
        "$filter_option"
        "$maximize_option"
        -resolution "$window_resolution"
        -artwork_resolution "$artwork_resolution"
        "$gl_vbo_option"
    )
fi

# DATAENTRY is an IPT_DIAL_V on the MPC2000XL.  Enable its mouse axis without
# global -mouse, which would hide and capture the pointer needed by the panel
# and Device Settings menu.
dial_options=()
if [[ "$system_name" == mpc2000xl ]]; then
    dial_options=(-dial_device mouse)
fi

printf 'Video: %s, async=%s, event-loop-isolation=%s, view=%s, window-resolution=%s, artwork-resolution=%s, screen-filter=%s, ogl-vbo=%s\n' \
    "$video_mode" "$async_present" "$external_event_loop" "$view_name" \
    "$window_resolution" "$artwork_resolution" "$filter_mode" "$gl_vbo"

exec taskset --cpu-list "$mame_cpuset" nice -n "$mame_nice" "${scheduler_prefix[@]}" \
    env "${panel_timer_countdown_unset[@]}" "${sound_cadence_unset[@]}" "${v53_fetch_unset[@]}" "${v53_data_unset[@]}" "${v53_idle_unset[@]}" "${dsp_read_unset[@]}" "${midi_unset_environment[@]}" \
    "${clock_environment[@]}" "${panel_environment[@]}" \
    "${panel_timer_environment[@]}" "${midi_clock_environment[@]}" "${midi_environment[@]}" \
    "${v53_status_environment[@]}" "${v53_event_service_environment[@]}" \
    "${v53_feed_flag_environment[@]}" "${v53_tick_read_environment[@]}" \
    "${panel_timer_countdown_environment[@]}" \
    "${v53_dispatch_environment[@]}" "${v53_divide_environment[@]}" \
    "${lcd_update_environment[@]}" \
    "${sound_cadence_environment[@]}" \
    "${v53_fetch_environment[@]}" \
    "${v53_data_environment[@]}" \
    "${v53_idle_environment[@]}" \
    "${dsp_read_environment[@]}" \
    "${output_environment[@]}" \
    MAME_ASYNC_PRESENT="$async_present" \
    MAME_SDL_EXTERNAL_EVENT_LOOP="$external_event_loop" \
    PIPEWIRE_QUANTUM="$pipewire_quantum" PIPEWIRE_LATENCY="$pipewire_latency" \
    "$mame_bin" "$system_name" \
    -rompath "$rom_dir" \
    -bios "$bios_name" \
    -sound pipewire \
    -samplerate "$pipewire_rate" \
    -cfg_directory "$cfg_directory" \
    -diff_directory "$runtime_dir/diff" \
    -nvram_directory "$runtime_dir/nvram" \
    -snapshot_directory "$runtime_dir/snap" \
    -state_directory "$runtime_dir/sta" \
    -video "$video_mode" \
    "${window_options[@]}" \
    "${dial_options[@]}" \
    "$throttle_option" \
    "$@"
