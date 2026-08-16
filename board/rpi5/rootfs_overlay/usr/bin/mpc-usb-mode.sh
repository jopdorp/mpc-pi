#!/bin/sh
# Switch the appliance between its two latency modes, in the right order.
#
#   live  - stereo out, stereo return, quantum 32. The playing mode: one
#           mix, nothing to route. Channel count is not what makes it
#           work - the gadget interrupts per 125us microframe whatever
#           the width - it is chosen for simplicity.
#   full  - 20 channels up / 2 down, quantum 48. The tracking mode:
#           every MPC voice and every DAW stem on its own channel, with
#           1.09ms periods - certified clean end-to-end on the armed
#           session.
#
# The quantum switches gaplessly. The channel count cannot: USB
# descriptors are fixed at bind, so the computer sees the interface
# leave and return (a few seconds). Any host-side recording in progress
# stops at that moment - which is why the mode switch is a deliberate
# command and not something the appliance does on its own.
#
# Order matters both directions:
#   going to live: shrink the quantum only AFTER the small gadget is
#     up - a 20-channel gadget at quantum 32 under load is the measured
#     glitch case;
#   going to full: widen the quantum FIRST, for the same reason
#     mirrored.
#
#   mpc-usb-mode.sh live|full|status
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
	ch=$(cut -d, -f1 < /sys/kernel/config/usb_gadget/mpc/functions/uac2.usb0/p_chmask 2>/dev/null || echo none)
	printf 'quantum: %s  gadget p_chmask: %s\n' "${q:-default}" "$ch"
	;;
live)
	MPC_USB_MODE=live /usr/bin/mpc-usb-gadget.sh
	# Let the host re-enumerate before the tighter deadline applies.
	sleep 3
	quantum 32
	echo "mode: live (stereo out / stereo return, quantum 32)"
	;;
full)
	quantum 48
	MPC_USB_MODE=full /usr/bin/mpc-usb-gadget.sh
	echo "mode: full (20 up / 2 down, quantum 48)"
	;;
*)
	echo "usage: mpc-usb-mode.sh live|full|status" >&2
	exit 2
	;;
esac
