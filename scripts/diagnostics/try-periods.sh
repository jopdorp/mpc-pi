#!/bin/sh
# Change the Duo's period COUNT, reversibly, for a listening test.
#
#   try-periods.sh 2       set it
#   try-periods.sh revert  put it back
#
# period-size is the graph cycle and is pinned at 64 by the interface: USB 1.1
# full speed delivers one packet per 1ms frame, about 44 frames at 44.1kHz, so
# a smaller period asks the codec to interrupt more often than it has packets.
# period-NUM is a different knob - it is how many of those periods the device
# buffers, and it is pure output latency:
#
#   64 x 4 = 256 frames = 5.8ms
#   64 x 2 = 128 frames = 2.9ms
#
# 2 was rejected on 17 Aug as "a full-speed codec cannot hold a buffer that
# small", on crackle measured then. The crackle was SCHED_RR, fixed on 18 Aug -
# a scheduling bug that produced crackle at EVERY buffer size and was read as a
# hardware limit at each one. So the rejection is untested against the fix.
#
# THE DEVICE TAKES ITS OWN VIEW. Asked for 256/3 it once negotiated 128/384, so
# what was requested is not what is running. This script reads hw_params back
# and refuses if the device did not take it.
set -eu
DROP=/etc/wireplumber/wireplumber.conf.d/99-mpcpi-period-test.conf
HW=$(ls /proc/asound/card*/pcm0p/sub0/hw_params 2>/dev/null | head -1)

restart_audio() {
	systemctl restart wireplumber.service 2>/dev/null ||
		systemctl --machine=mpc@ --user restart wireplumber 2>/dev/null || true
	sleep 4
	systemctl restart mpcpi-emulator
	sleep 8
}

if [ "${1:-}" = "revert" ]; then
	rm -f "$DROP"
	restart_audio
	echo "reverted; device now $(tr -s ' ' < "$HW" | grep -E 'period_size|buffer_size' | tr '\n' ' ')"
	exit 0
fi

N="${1:?usage: try-periods.sh <count|revert>}"
mkdir -p "$(dirname "$DROP")"
cat > "$DROP" <<EOF
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_output\\\\.usb-.*" } ]
    actions = { update-props = { api.alsa.period-num = $N } }
  }
]
EOF
restart_audio

WANT=$((64 * N))
GOT=$(grep -E "^buffer_size" "$HW" 2>/dev/null | tr -dc "0-9")
echo "asked for $N periods (${WANT} frames); device reports buffer_size=${GOT:-?}"
if [ "${GOT:-0}" != "$WANT" ]; then
	echo "REFUSED: the device did not take it. Reverting." >&2
	"$0" revert
	exit 1
fi
echo "$N periods adopted - $(awk "BEGIN{printf \"%.1f\", $WANT/44.1}")ms of device buffer."
echo "PLAY SOMETHING - the counters cannot hear. Revert: $0 revert"
