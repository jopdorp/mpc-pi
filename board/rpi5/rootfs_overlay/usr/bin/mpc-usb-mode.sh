#!/bin/sh
# Switch the appliance between playing and tracking. Quantum only.
#
#   live  - quantum 32 (725us). The playing mode.
#   track - quantum 48 (1.09ms). The tracking mode: more headroom for a
#           fully armed session with every insert running.
#
# Nothing else changes between them. The interface is always 22 up / 2
# down, so the USB descriptors never change, so the computer never sees
# the interface leave - a recording running on the host survives a mode
# switch. That is only true because the channel count is fixed: it was
# once thought to be a latency lever, and it is not (the gadget
# interrupts per 125us microframe whatever the width; 18 channels down
# to 6 changed nothing measurable).
#
# The quantum itself switches inside the running graph: PipeWire
# renegotiates it on the next cycle. There is a brief transient while
# clients re-adapt, which is why this is a deliberate command rather
# than something the appliance does on its own mid-take.
#
#   mpc-usb-mode.sh live|track|status
set -eu

MODE="${1:-status}"
U=$(id -u mpc)
R="sudo -u mpc env XDG_RUNTIME_DIR=/run/user/$U"

quantum() {
	$R pw-metadata -n settings 0 clock.force-quantum "$1" >/dev/null 2>&1
}

case "$MODE" in
status)
	q=$($R pw-metadata -n settings 0 2>/dev/null |
		grep -o "clock.force-quantum.*value:'[0-9]*'" |
		grep -oE "[0-9]+" | tail -1)
	mask=$(cat /sys/kernel/config/usb_gadget/mpc/functions/uac2.usb0/p_chmask 2>/dev/null || echo none)
	# Count the bits, so the report says channels rather than hex.
	if [ "$mask" != none ]; then
		n=$(printf '%d\n' "$mask" | awk '{c=0; v=$1; while (v) {c += v % 2; v = int(v/2)}; print c}')
	else
		n=none
	fi
	case "${q:-0}" in
		32) name="live" ;;
		48) name="track" ;;
		*)  name="custom" ;;
	esac
	printf 'mode: %s (quantum %s)  interface: %s up / 2 down\n' \
		"$name" "${q:-default}" "$n"
	;;
live)
	quantum 32
	echo "mode: live (quantum 32) - interface unchanged, host uninterrupted"
	;;
track)
	quantum 48
	echo "mode: track (quantum 48) - interface unchanged, host uninterrupted"
	;;
*)
	echo "usage: mpc-usb-mode.sh live|track|status" >&2
	exit 2
	;;
esac
