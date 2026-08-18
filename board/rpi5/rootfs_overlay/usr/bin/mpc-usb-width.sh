#!/bin/sh
# Rebind the gadget at a given channel width, for bisecting a host that
# will not show the capture side.
#
#   mpc-usb-width.sh 2     dead-simple stereo - if the host does not show
#                          THIS as an input, the problem is not the width
#   mpc-usb-width.sh 26    the full desk map (the configured default)
#
# Why this exists: the appliance can prove the gadget binds, enumerates at
# high speed, and exposes both PCM directions locally - and none of that
# says whether the HOST parsed the descriptors. Only the host can answer
# that, so the fastest path is to let whoever is at the host change one
# variable and look, rather than describe the symptom over a wire.
#
# DO NOT REPLUG THE CABLE TO APPLY THIS. Two reasons:
#
#   1. It is unnecessary. Unbinding and rebinding the UDC is a full USB
#      disconnect/reconnect as far as the host is concerned - measured, the
#      device comes back with a NEW USB address every time (21 -> 22 across
#      one rebind). The host re-reads the descriptors on its own.
#   2. It power-cycles the board. The USB-C port is the Pi 5's power input,
#      so pulling it reboots the appliance - and a reboot resets the gadget
#      to the configured default width, silently undoing whatever this
#      script was asked to set.
#
# An earlier version of this file told the user to replug, which was wrong
# on both counts.
set -eu
N="${1:?usage: $0 <channels-up>   e.g. 2 for a stereo baseline, 26 for the full map}"

[ "$N" -le 27 ] || {
	echo "$N is over the UAC2 ceiling of 27 - the gadget will not bind" >&2
	echo "(f_uac2.c UAC2_CHANNEL_MASK 0x07FFFFFF; asking for more returns -EINVAL)" >&2
	exit 1
}

# PERSIST FIRST, then apply. The width has to survive a reboot - this port
# is the Pi's power input, so the board WILL be power-cycled routinely, and
# a width that only lived in an environment variable meant every reboot
# silently reverted whatever was being tested.
CONF=${MPCPI_GADGET_CONF:-/etc/default/mpcpi-usb-gadget}
mkdir -p "$(dirname "$CONF")"
if [ -f "$CONF" ] && grep -q '^MPC_USB_CHANNELS_UP=' "$CONF"; then
	sed -i "s/^MPC_USB_CHANNELS_UP=.*/MPC_USB_CHANNELS_UP=$N/" "$CONF"
else
	printf '# Written by mpc-usb-width.sh. Read by mpc-usb-gadget.sh at every\n' >> "$CONF"
	printf '# start, including at boot, so the gadget comes back as it was left.\n' >> "$CONF"
	printf 'MPC_USB_CHANNELS_UP=%s\n' "$N" >> "$CONF"
fi

/usr/bin/mpc-usb-gadget.sh stop >/dev/null 2>&1 || true
/usr/bin/mpc-usb-gadget.sh start
systemctl restart mpcpi-usb-route >/dev/null 2>&1 || true
echo "persisted to $CONF - this width now survives a reboot"
echo
echo "the host has already re-enumerated - no replug needed (and replugging"
echo "would reboot the Pi, since USB-C is its power input)."
echo "on the HOST now run:  arecord -l"
