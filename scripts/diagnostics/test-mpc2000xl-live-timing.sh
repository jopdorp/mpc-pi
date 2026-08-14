#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
pipewire_frames=${MPC_PIPEWIRE_FRAMES:-48}
pipewire_rate=${PIPEWIRE_RATE_HZ:-48000}
timing_master=${MAME_TIMING_MASTER:-video}
video_mode=${MPC_VIDEO_MODE:-auto}
bgfx_backend=${MPC_BGFX_BACKEND:-opengl}
scale_mode=${MPC_SCALE_MODE:-none}
view_name=${MPC_VIEW_NAME:-auto}
filter_mode=${MPC_FILTER_MODE:-1}
window_resolution=${MPC_WINDOW_RESOLUTION:-1240x300}
async_present=${MPC_ASYNC_PRESENT:-0}
external_capture=${MPC_EXTERNAL_CAPTURE:-0}
project="$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img"
lua_script="$repo_root/scripts/diagnostics/live-logic-mpc2000xl.lua"
result_dir=$(mktemp -d "$repo_root/results/diagnostics/live-timing-XXXXXX")
runtime_dir=$(mktemp -d "$repo_root/results/runtime/live-timing-XXXXXX")
scratch_dir=$(mktemp -d "${MPC_TIMING_SCRATCH_ROOT:-/dev/shm}/mpc-live-timing-XXXXXX")
live_capture="$scratch_dir/live.wav"
emulated_capture="$scratch_dir/emulated.wav"
delivered_capture="$scratch_dir/delivered.wav"
mame_log="$scratch_dir/mame.log"
record_log="$scratch_dir/pw-record.log"
mame_pid=
record_pid=

case "$filter_mode" in
    0) filter_option=-nofilter ;;
    1) filter_option=-filter ;;
    *)
        printf 'error: MPC_FILTER_MODE must be 0 or 1\n' >&2
        exit 2
        ;;
esac

stop_child() {
    local pid=$1
    local signal=$2
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "-$signal" "$pid" 2>/dev/null || true
    fi
}

cleanup() {
    stop_child "$record_pid" INT
    stop_child "$mame_pid" KILL
    for name in live.wav emulated.wav delivered.wav mame.log pw-record.log; do
        if [[ -f "$scratch_dir/$name" ]]; then
            cp -- "$scratch_dir/$name" "$result_dir/$name"
            rm -- "$scratch_dir/$name"
        fi
    done
    rmdir -- "$scratch_dir" 2>/dev/null || true
}
trap cleanup EXIT

MAME_RUNTIME_DIR="$runtime_dir" MAME_PIPEWIRE_STATS=1 MAME_TIMING_MASTER="$timing_master" \
PIPEWIRE_RATE_HZ="$pipewire_rate" \
MAME_ASYNC_PRESENT="$async_present" \
MAME_PIPEWIRE_CAPTURE_WAV="$delivered_capture" \
    "$repo_root/scripts/run-mpc.sh" mpc2000xl "$pipewire_frames" \
    -flop "$project" \
    -skip_gameinfo \
    -seconds_to_run 45 \
    -video "$video_mode" \
    "$filter_option" \
    -bgfx_path "$repo_root/.cache/mame/bgfx" \
    -bgfx_backend "$bgfx_backend" \
    -scalemode "$scale_mode" \
    -view "$view_name" \
    -nomaximize \
    -resolution "$window_resolution" \
    -wavwrite "$emulated_capture" \
    -autoboot_script "$lua_script" \
    >"$mame_log" 2>&1 &
mame_pid=$!

speaker_ready=false
for _ in $(seq 1 300); do
    if pw-dump | jq -e '.[] | select(.type == "PipeWire:Interface:Node" and .info.props["node.name"] == ":speaker")' >/dev/null; then
        speaker_ready=true
        break
    fi
    if ! kill -0 "$mame_pid" 2>/dev/null; then
        printf 'FAIL: MAME exited before its PipeWire speaker node appeared\n' >&2
        cat "$mame_log" >&2
        exit 1
    fi
    sleep 0.1
done
if [[ "$speaker_ready" != true ]]; then
    printf 'FAIL: PipeWire speaker node did not appear within 30 seconds\n' >&2
    exit 1
fi

if [[ "$external_capture" == 1 ]]; then
    pw-record --target ':speaker' --rate "$pipewire_rate" --channels 2 --format s16 "$live_capture" \
        >"$record_log" 2>&1 &
    record_pid=$!
elif [[ "$external_capture" != 0 ]]; then
    printf 'error: MPC_EXTERNAL_CAPTURE must be 0 or 1\n' >&2
    exit 2
fi

set +e
wait "$mame_pid"
mame_status=$?
set -e
mame_pid=
stop_child "$record_pid" INT
if [[ -n "$record_pid" ]]; then
    set +e
    wait "$record_pid"
    set -e
fi
record_pid=

if [[ "$mame_status" -ne 0 ]]; then
    printf 'FAIL: MAME exited with status %s\n' "$mame_status" >&2
    tail -100 "$mame_log" >&2
    exit 1
fi
if ! grep -q 'MPC_TIMING_PLAYBACK_BEGIN' "$mame_log" || ! grep -q 'MPC_TIMING_PLAYBACK_END' "$mame_log"; then
    printf 'FAIL: playback interval markers are missing\n' >&2
    tail -100 "$mame_log" >&2
    exit 1
fi

if ! awk '
    /MPC_TIMING_PLAYBACK_BEGIN/ { active = 1; next }
    /MPC_TIMING_PLAYBACK_END/ { active = 0 }
    active && /PipeWire: MAME audio buffer correction/ {
        stream = underruns = overruns = ""
        for (i = 1; i <= NF; i++) {
            if ($i == "stream") stream = $(i + 1)
            if ($i ~ /^underruns=/) { split($i, a, "="); underruns = a[2] + 0 }
            if ($i ~ /^overruns=/) { split($i, a, "="); overruns = a[2] + 0 }
        }
        sub(/:$/, "", stream)
        if (!(stream in seen)) {
            seen[stream] = 1
            first_underruns[stream] = underruns
            first_overruns[stream] = overruns
        } else if (underruns != first_underruns[stream] || overruns != first_overruns[stream]) {
            bad = 1
        }
        reports++
    }
    END { exit !(reports >= 30 && !bad) }
' "$mame_log"; then
    printf 'FAIL: PipeWire buffer corrections changed during playback\n' >&2
    sed -n '/MPC_TIMING_PLAYBACK_BEGIN/,/MPC_TIMING_PLAYBACK_END/p' "$mame_log" >&2
    exit 1
fi

if sed -n '/MPC_TIMING_PLAYBACK_BEGIN/,/MPC_TIMING_PLAYBACK_END/p' "$mame_log" | grep -q 'PipeWire: MAME audio buffer event'; then
    printf 'FAIL: PipeWire reported an immediate buffer correction during playback\n' >&2
    sed -n '/MPC_TIMING_PLAYBACK_BEGIN/,/MPC_TIMING_PLAYBACK_END/p' "$mame_log" >&2
    exit 1
fi

"$repo_root/scripts/diagnostics/compare-live-audio-timing.py" \
    "$emulated_capture" "$delivered_capture"
printf 'PASS: full windowed video and PipeWire timing regression\n'
printf 'Artifacts: %s\n' "$result_dir"
