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
# After running this, REPLUG THE CABLE. Hosts cache descriptors per
# VID/PID, and this gadget's ids never change, so a host that already
# enumerated an older layout may not re-read the new one on its own.
set -eu
N="${1:?usage: $0 <channels-up>   e.g. 2 for a stereo baseline, 26 for the full map}"

[ "$N" -le 27 ] || {
	echo "$N is over the UAC2 ceiling of 27 - the gadget will not bind" >&2
	echo "(f_uac2.c UAC2_CHANNEL_MASK 0x07FFFFFF; asking for more returns -EINVAL)" >&2
	exit 1
}

MPC_USB_CHANNELS_UP="$N" /usr/bin/mpc-usb-gadget.sh stop >/dev/null 2>&1 || true
MPC_USB_CHANNELS_UP="$N" /usr/bin/mpc-usb-gadget.sh start
systemctl restart mpcpi-usb-route >/dev/null 2>&1 || true
echo
echo "now REPLUG the USB-C cable, then on the HOST run:  arecord -l"
