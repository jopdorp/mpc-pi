#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pipewire_frames=${MPC_PIPEWIRE_FRAMES:-32}
force_pipewire_graph=${MPC_FORCE_PIPEWIRE_GRAPH:-1}

# Fastest accepted MPC2000XL deployment preset. Every value remains
# independently overrideable for A/B tests and multichannel hardware.
export PIPEWIRE_RATE_HZ=${PIPEWIRE_RATE_HZ:-44100}
if [[ ! "$pipewire_frames" =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: MPC_PIPEWIRE_FRAMES must be a positive frame count\n' >&2
    exit 2
fi
if [[ ! "$PIPEWIRE_RATE_HZ" =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: PIPEWIRE_RATE_HZ must be a positive integer\n' >&2
    exit 2
fi
export PIPEWIRE_QUANTUM="$pipewire_frames/$PIPEWIRE_RATE_HZ"
export PIPEWIRE_LATENCY="$pipewire_frames/$PIPEWIRE_RATE_HZ"
export MAME_TIMING_MASTER=${MAME_TIMING_MASTER:-audio}
export MPC_VIDEO_MODE=${MPC_VIDEO_MODE:-opengl}
export MPC_VIEW_NAME=${MPC_VIEW_NAME:-Screen 0}
export MPC_WINDOW_RESOLUTION=${MPC_WINDOW_RESOLUTION:-1240x300}
export MPC_ARTWORK_RESOLUTION=${MPC_ARTWORK_RESOLUTION:-auto}
export MPC_GL_VBO=${MPC_GL_VBO:-1}
export MPC_OUTPUT_MODE=${MPC_OUTPUT_MODE:-stereo}
export MPC_ASYNC_PRESENT=${MPC_ASYNC_PRESENT:-1}
export MPC_SDL_EXTERNAL_EVENT_LOOP=${MPC_SDL_EXTERNAL_EVENT_LOOP:-1}
export MPC_PANEL_MODE=${MPC_PANEL_MODE:-event}
export MPC_PANEL_TIMER_MODE=${MPC_PANEL_TIMER_MODE:-coalesced}
export MPC_MIDI_INPUT_MODE=${MPC_MIDI_INPUT_MODE:-accurate}
export MPC_MIDI_CLOCK_MODE=${MPC_MIDI_CLOCK_MODE:-event}
export MPC_V53_STATUS_MODE=${MPC_V53_STATUS_MODE:-hle}
export MPC_V53_EVENT_SERVICE_MODE=${MPC_V53_EVENT_SERVICE_MODE:-hle}
export MPC_V53_DISPATCH_MODE=${MPC_V53_DISPATCH_MODE:-direct}
export MPC_V53_DIVIDE_MODE=${MPC_V53_DIVIDE_MODE:-superblock}
export MPC_LCD_UPDATE_MODE=${MPC_LCD_UPDATE_MODE:-changed}
# Direct-pointer V33 opcode fetch window: PCM-exact, measured +10.2% throughput.
# Safe here because the MPC2000XL V53 program map is static .ram()/.rom().
export MPC_V53_FETCH_MODE=${MPC_V53_FETCH_MODE:-window}
# Exact idle-iteration skip of the OS main scheduler loop: PCM-exact with
# hundreds of thousands of skips, zero live underruns, +26.4% average speed.
export MPC_V53_IDLE_MODE=${MPC_V53_IDLE_MODE:-skip}
# One host sound update per half quantum: exactly 16 frames at 44.1 kHz/q32, so
# a PipeWire callback consumes exactly two producer updates instead of a
# drifting 2.177. On a marginal deadline (LP-E cores at RR1) this halved
# playback underruns, 4.00 -> 2.00 across a matched ABBA. It moves stream chunk
# boundaries, so it is timing-preserving and this preset is not the canonical
# PCM control.
export MPC_SOUND_UPDATES_PER_QUANTUM=${MPC_SOUND_UPDATES_PER_QUANTUM:-2}

# Experimental sound-tail flags are intentionally not enabled here until the
# 44.1 kHz/q32 delivered-audio gate passes without corrections.

case "$force_pipewire_graph" in
    0|1) ;;
    *)
        printf 'error: MPC_FORCE_PIPEWIRE_GRAPH must be 0 or 1\n' >&2
        exit 2
        ;;
esac

mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame"}
mame_bin=${MAME_BIN:-"$mame_source_dir/mpc"}
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

[[ "$MPC_OUTPUT_MODE" != stereo ]] || \
    require_binary_capability MAME_MPC_STEREO_ONLY MPC_OUTPUT_MODE=stereo
[[ "$MPC_V53_DIVIDE_MODE" != superblock ]] || \
    require_binary_capability MAME_MPC_V53_DIVIDE_SUPERBLOCK MPC_V53_DIVIDE_MODE=superblock
[[ "$MPC_LCD_UPDATE_MODE" != changed ]] || \
    require_binary_capability MAME_MPC_LCD_SKIP_UNCHANGED MPC_LCD_UPDATE_MODE=changed
[[ -z "$MPC_SOUND_UPDATES_PER_QUANTUM" ]] || \
    require_binary_capability MAME_SOUND_UPDATE_FRAMES MPC_SOUND_UPDATES_PER_QUANTUM
[[ "$MPC_V53_FETCH_MODE" != window ]] || \
    require_binary_capability MAME_MPC_V53_FETCH_WINDOW MPC_V53_FETCH_MODE=window
[[ "$MPC_V53_IDLE_MODE" != skip ]] || \
    require_binary_capability MAME_MPC_V53_IDLE_SKIP MPC_V53_IDLE_MODE=skip

setting_value()
{
    pw-metadata -n settings 0 | sed -n "s/.*key:'$1' value:'\([^']*\)'.*/\1/p" | tail -1
}

child_pid=
child_pgid=
child_reaped=0
launch_in_progress=0
pending_signal=0
pipewire_forced=0
pipewire_lock_fd=
original_force_rate=
original_force_quantum=

restore_pipewire()
{
    local failed=0 actual_force_rate actual_force_quantum
    if (( !pipewire_forced )); then
        return 0
    fi

    if ! pw-metadata -n settings 0 clock.force-quantum "$original_force_quantum" >/dev/null; then
        printf 'error: failed to restore PipeWire clock.force-quantum=%s\n' \
            "$original_force_quantum" >&2
        failed=1
    fi
    if ! pw-metadata -n settings 0 clock.force-rate "$original_force_rate" >/dev/null; then
        printf 'error: failed to restore PipeWire clock.force-rate=%s\n' \
            "$original_force_rate" >&2
        failed=1
    fi
    actual_force_rate=$(setting_value clock.force-rate)
    actual_force_quantum=$(setting_value clock.force-quantum)
    if [[ "$actual_force_rate" != "$original_force_rate" || \
          "$actual_force_quantum" != "$original_force_quantum" ]]; then
        printf 'error: PipeWire graph restore mismatch: expected rate=%s quantum=%s, got rate=%s quantum=%s\n' \
            "$original_force_rate" "$original_force_quantum" \
            "${actual_force_rate:-missing}" "${actual_force_quantum:-missing}" >&2
        failed=1
    fi
    pipewire_forced=0
    return "$failed"
}

release_pipewire_lock()
{
    if [[ "$pipewire_lock_fd" =~ ^[0-9]+$ ]]; then
        flock -u "$pipewire_lock_fd" || true
        exec {pipewire_lock_fd}>&-
        pipewire_lock_fd=
    fi
}

cleanup()
{
    local status=$? restore_status=0
    trap - EXIT
    trap '' INT TERM HUP
    if [[ "$child_pgid" =~ ^[1-9][0-9]*$ ]] && kill -0 -- "-$child_pgid" 2>/dev/null; then
        kill -TERM -- "-$child_pgid" 2>/dev/null || true
    fi
    restore_pipewire || restore_status=$?
    if [[ "$child_pgid" =~ ^[1-9][0-9]*$ ]]; then
        for _ in {1..50}; do
            kill -0 -- "-$child_pgid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 -- "-$child_pgid" 2>/dev/null; then
            printf 'warning: MAME did not stop within 5 seconds; sending SIGKILL\n' >&2
            kill -KILL -- "-$child_pgid" 2>/dev/null || true
        fi
    fi
    if [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] && (( !child_reaped )); then
        wait "$child_pid" 2>/dev/null || true
    fi
    release_pipewire_lock
    if (( status == 0 && restore_status != 0 )); then
        status=$restore_status
    fi
    exit "$status"
}

handle_signal()
{
    local status=$1
    if (( launch_in_progress )); then
        pending_signal=$status
        return
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
trap 'handle_signal 129' HUP

if (( force_pipewire_graph )); then
    if ! command -v pw-metadata >/dev/null || ! command -v flock >/dev/null; then
        printf 'error: native 44.1 kHz fast mode requires pw-metadata and flock\n' >&2
        exit 1
    fi
    pipewire_lock_path=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/mpc-pi-pipewire-graph-${UID}.lock
    exec {pipewire_lock_fd}>"$pipewire_lock_path"
    if ! flock -n "$pipewire_lock_fd"; then
        printf 'error: another MPC fast launch owns the PipeWire graph settings\n' >&2
        exit 1
    fi
    original_force_rate=$(setting_value clock.force-rate)
    original_force_quantum=$(setting_value clock.force-quantum)
    if [[ -z "$original_force_rate" || -z "$original_force_quantum" ]]; then
        printf 'error: could not read PipeWire force-rate/force-quantum settings\n' >&2
        exit 1
    fi
    pipewire_forced=1
    pw-metadata -n settings 0 clock.force-rate "$PIPEWIRE_RATE_HZ" >/dev/null
    pw-metadata -n settings 0 clock.force-quantum "$pipewire_frames" >/dev/null
    if [[ $(setting_value clock.force-rate) != "$PIPEWIRE_RATE_HZ" || \
          $(setting_value clock.force-quantum) != "$pipewire_frames" ]]; then
        printf 'error: PipeWire rejected the requested %s Hz/q%s graph\n' \
            "$PIPEWIRE_RATE_HZ" "$pipewire_frames" >&2
        exit 1
    fi
    printf 'PipeWire graph forced to %s Hz/q%s for this launch; previous settings will be restored\n' \
        "$PIPEWIRE_RATE_HZ" "$pipewire_frames"
fi

set +m
launch_in_progress=1
setsid env \
    -u MAME_MPC_V53_REPLAY \
    -u MAME_MPC_V53_HOTBLOCKS \
    -u MAME_SOUND_EFFECTS_HANDSHAKE \
    -u MAME_SOUND_EFFECTS_PRIORITY_BOOST \
    -u MAME_SOUND_EFFECTS_INLINE \
    -u MAME_SOUND_EFFECTS_PHASE_STATS \
    -u MAME_SOUND_EFFECTS_PENDING_STATS \
    -u MAME_SOUND_EFFECTS_PENDING_WAKE \
    "$repo_root/scripts/run-mpc.sh" mpc2000xl "$pipewire_frames" "$@" &
child_pid=$!
launch_in_progress=0
if (( pending_signal )); then
    exit "$pending_signal"
fi
if kill -0 "$child_pid" 2>/dev/null; then
    child_pgid=$(ps -o pgid= -p "$child_pid" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -z "$child_pgid" ]]; then
        set +e
        wait "$child_pid"
        status=$?
        set -e
        child_reaped=1
        exit "$status"
    fi
    if [[ "$child_pgid" != "$child_pid" ]]; then
        printf 'error: could not establish an owned MAME process group (pid=%s pgid=%s)\n' \
            "$child_pid" "${child_pgid:-missing}" >&2
        child_pgid=
        kill -TERM "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
        child_reaped=1
        exit 1
    fi
fi
set +e
wait "$child_pid"
status=$?
set -e
child_reaped=1
exit "$status"
