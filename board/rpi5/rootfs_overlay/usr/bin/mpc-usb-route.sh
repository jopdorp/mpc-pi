#!/bin/sh
# Choose what the computer records from the USB audio gadget.
#
#   mpc-usb-route.sh mpc      MPC stereo + the eight individual outs (10 ch)
#   mpc-usb-route.sh ardour   Ardour's master/stems into the same 10 ch
#   mpc-usb-route.sh off      disconnect everything
#
# Both sources are ten channels, so only one occupies the gadget at a time
# (see docs/maschine-daw-design.md for why we do not ship 20 channels by
# default). The MPC's own monitor path to the DAC is never touched: these
# are additional taps, exactly like the Ardour recording links.
set -eu

SINK=${MPC_USB_SINK:-alsa_output.platform-fe980000.usb.stereo-fallback}
# The gadget card's playback device is what the host records from; ask
# PipeWire for its real node name rather than guessing.
gadget_node() {
	pw-cli ls Node 2>/dev/null |
		awk -F'"' '/node.name/ && /UAC2|Gadget|usb_gadget/ { print $2; exit }'
}

unlink_all() {
	node=$1
	pw-link -l 2>/dev/null | grep -F "$node" >/dev/null 2>&1 || return 0
	pw-link -d "$node" 2>/dev/null || true
}

node=$(gadget_node)
if [ -z "$node" ]; then
	echo "mpc-usb-route: gadget card not present; is a host connected?" >&2
	exit 1
fi

case "${1:-mpc}" in
mpc)
	unlink_all "$node"
	# Stereo pair first, then the eight individual outs, so channel 1/2 on
	# the computer is always the main mix.
	pw-link ":speaker:output_FL" "$node:playback_AUX0" || true
	pw-link ":speaker:output_FR" "$node:playback_AUX1" || true
	i=0
	while [ "$i" -lt 8 ]; do
		pw-link ":outputs:output_$i" "$node:playback_AUX$((i + 2))" || true
		i=$((i + 1))
	done
	echo "mpc-usb-route: MPC stereo + 8 individual outs -> $node"
	;;
ardour)
	unlink_all "$node"
	pw-link "Ardour:Master/audio_out 1" "$node:playback_AUX0" || true
	pw-link "Ardour:Master/audio_out 2" "$node:playback_AUX1" || true
	echo "mpc-usb-route: Ardour master -> $node"
	;;
off)
	unlink_all "$node"
	echo "mpc-usb-route: disconnected"
	;;
*)
	echo "Usage: $0 {mpc|ardour|off}" >&2
	exit 1
	;;
esac
