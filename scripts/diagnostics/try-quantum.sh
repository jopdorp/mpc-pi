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
# Ceiling AND FLOOR: api.alsa.disable-tsched is on, so the graph runs once per
# device period interrupt and the cycle IS the period - 64 frames on the Duo.
# Above it, the graph stops dead with every node reading QUANT 0. Below it,
# nothing happens at all: the metadata changes, the driver keeps its 64, and
# the only thing that really moves is the emulator's block size, which then
# disagrees with the graph. So this script verifies what the driver ADOPTED
# and reverts itself if that is not what was asked for.
#
# 64 is the floor because of the INTERFACE. The Duo is USB 1.1 full speed, one
# packet per 1ms frame, which at 44.1kHz is about 44 frames. A 32-frame period
# asks the codec to interrupt more often than it has packets to deliver.
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
sleep 8

# DID THE DRIVER ACTUALLY TAKE IT? force-quantum is a request, not a result.
#
# With api.alsa.disable-tsched the graph runs once per DEVICE PERIOD interrupt,
# so the cycle is the period size no matter what force-quantum says. Asking for
# 32 against the Duo's 64-frame period set the metadata, left the driver at
# QUANT 64, and moved MPC_PIPEWIRE_FRAMES to 32 - so the emulator wrote
# 32-frame blocks into 64-frame periods with a cushion sized for neither. That
# is not "quantum 32 sounds bad", it is a mismatch this script created, and it
# reported success while doing it.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u mpc 2>/dev/null || echo 1000)}"
GOT=$(timeout 8 pw-top -b -n 3 2>/dev/null |
	awk '$1=="R" && $4=="44100" && $3 != 0 {q=$3} END{print q+0}')
if [ "$GOT" != "$Q" ]; then
	echo "REFUSED: asked for $Q, the driver is running $GOT." >&2
	PS=$(grep -h period_size /proc/asound/card*/pcm0p/sub0/hw_params 2>/dev/null |
		head -1 | tr -dc "0-9")
	echo "The device period is ${PS:-?} frames and tsched is off, so the graph" >&2
	echo "cycle IS the period - force-quantum cannot go below it. Reverting." >&2
	"$0" revert
	exit 1
fi
echo "quantum $Q staged AND adopted by the driver."
echo "PLAY SOMETHING - the counters cannot hear."
echo "revert with: $0 revert"
