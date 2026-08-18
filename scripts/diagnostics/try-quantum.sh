#!/bin/sh
# Change the graph quantum, reversibly, for a listening test.
#
#   try-quantum.sh 48      set it
#   try-quantum.sh revert  put it back
#
# ONLY THE PLAYER CAN PASS THIS TEST. Every counter on this appliance has
# reported zero while the player heard clicking - see the note in
# 98-mpcpi-external-usb-audio.conf: what breaks is below the layer that counts.
# So xruns being 0 after this is NECESSARY and not SUFFICIENT, and a quantum
# must never be left changed on the strength of a counter alone.
#
# Two things have to move together or the emulator and the graph disagree
# about how much audio a period is:
#   * default.clock.* in PipeWire
#   * MPC_PIPEWIRE_FRAMES in the emulator unit
# Done as DROP-INS so reverting is deleting two files, not editing two configs.
#
# Ceiling: api.alsa.disable-tsched is on, so quantum must be <= the device
# period-size, which is 64. 48 and 32 are in range; 128 is not, and asking for
# it does not degrade - it stops the graph dead with every node reading QUANT 0.
set -eu
PWDIR=/etc/pipewire/pipewire.conf.d
UNITDIR=/etc/systemd/system/mpcpi-emulator.service.d
PWDROP=$PWDIR/99-mpcpi-quantum-test.conf
UNITDROP=$UNITDIR/99-quantum-test.conf

if [ "${1:-}" = "revert" ]; then
	rm -f "$PWDROP" "$UNITDROP"
	systemctl daemon-reload
	systemctl restart pipewire.service 2>/dev/null || true
	systemctl restart mpcpi-emulator
	echo "reverted to the configured quantum"
	exit 0
fi

Q="${1:?usage: try-quantum.sh <frames|revert>}"
[ "$Q" -le 64 ] || { echo "quantum $Q > period-size 64; the graph will stop" >&2; exit 1; }

mkdir -p "$PWDIR" "$UNITDIR"
cat > "$PWDROP" <<EOF
context.properties = {
    default.clock.quantum     = $Q
    default.clock.min-quantum = $Q
    default.clock.max-quantum = $Q
    default.clock.force-quantum = $Q
}
EOF
cat > "$UNITDROP" <<EOF
[Service]
Environment=MPC_PIPEWIRE_FRAMES=$Q
EOF
systemctl daemon-reload
systemctl restart pipewire.service 2>/dev/null || true
sleep 3
systemctl restart mpcpi-emulator
echo "quantum $Q staged. PLAY SOMETHING - the counters cannot hear."
echo "revert with: $0 revert"
