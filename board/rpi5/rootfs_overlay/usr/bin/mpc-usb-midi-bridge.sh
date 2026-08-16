#!/bin/sh
# Wire the gadget's MIDI cables to what they represent.
#
#   cable 1 <-> the MPC: emulator virmidi, both directions, so the
#               computer's DAW can slave to the MPC's clock or drive the
#               MPC with its own. Mastership is not a mode here - it is
#               whichever machine you configure to send clock.
#   cable 2 <-  the Maschine: the hub mirrors decoded pads, knobs and
#               buttons as notes and CCs (see maschine-hub --pc-midi).
#
# aconnect by client name, not number: numbers are assignment order and
# assignment order is boot order, which is exactly the kind of thing
# that changes the week you stop checking.
set -eu

seq_client() {
	aconnect -l 2>/dev/null | awk -v pat="$1" \
		'/^client/ && $0 ~ pat { gsub(":", "", $2); print $2; exit }'
}

gadget=$(seq_client "f_midi")
virmidi=$(seq_client "Virtual Raw MIDI|VirMIDI")

if [ -z "$gadget" ]; then
	echo "mpc-usb-midi-bridge: no f_midi client; is the gadget bound?" >&2
	exit 1
fi
if [ -z "$virmidi" ]; then
	echo "mpc-usb-midi-bridge: no virmidi client; is the emulator stack up?" >&2
	exit 1
fi

case "${1:-on}" in
on)
	# Port 0 of each side is cable 1. Both directions, idempotent.
	aconnect "$virmidi:0" "$gadget:0" 2>/dev/null || true
	aconnect "$gadget:0" "$virmidi:0" 2>/dev/null || true
	echo "mpc-usb-midi-bridge: MPC <-> computer on cable 1"
	;;
off)
	aconnect -d "$virmidi:0" "$gadget:0" 2>/dev/null || true
	aconnect -d "$gadget:0" "$virmidi:0" 2>/dev/null || true
	echo "mpc-usb-midi-bridge: disconnected"
	;;
*)
	echo "Usage: $0 {on|off}" >&2
	exit 1
	;;
esac
