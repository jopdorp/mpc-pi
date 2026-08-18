#!/bin/sh
# capture-monitor.sh <label> <seconds>
# Records what the DAC actually receives while pads are being hit, so the
# capture contains sounding audio rather than the silence between hits.
set -eu
lbl="$1"; secs="${2:-10}"
export XDG_RUNTIME_DIR=/run/user/1001
as_mpc() { sudo -u mpc env XDG_RUNTIME_DIR=/run/user/1001 "$@"; }
S=$(as_mpc pw-cli ls Node 2>/dev/null | grep -o 'alsa_output[^"]*analog-stereo' | head -1)
out=/tmp/mon-$lbl.wav
rm -f "$out"
python3 /usr/local/bin/mpcpi-pad-blast.py $((secs + 8)) &
blast=$!
sleep 3
as_mpc pw-record --properties '{ node.name = monprobe, node.autoconnect = false }' \
    --channels 2 --rate 44100 --format s16 "$out" &
sleep 2
as_mpc pw-link "$S:monitor_FL" monprobe:input_FL 2>/dev/null || true
as_mpc pw-link "$S:monitor_FR" monprobe:input_FR 2>/dev/null || true
links=$(as_mpc pw-link -l 2>/dev/null | grep -c monprobe || true)
sleep "$secs"
pkill -INT -f pw-record 2>/dev/null || true
wait $blast 2>/dev/null || true
sleep 1
printf '%s: links=%s bytes=%s\n' "$lbl" "$links" "$(stat -c %s "$out" 2>/dev/null || echo 0)"
[ "$links" -ge 2 ] || { echo "REFUSING: nothing linked"; exit 1; }
