#!/bin/sh
# Wire the instrument into the USB gadget - all of it, concurrently.
#
#   mpc-usb-route.sh on       connect the full 18-up / 2-down map
#   mpc-usb-route.sh off      disconnect everything
#
# The map, as the computer sees it:
#
#   ch  1-2    MPC stereo mix          (:speaker)
#   ch  3-10   MPC individual outs 1-8 (:outputs, MPC_OUTPUT_MODE=all)
#   ch 11-12   Ardour master L/R
#   ch 13-18   Ardour input strips GTR1 GTR2 MIC GTR1+ GTR2+ MIC+ (mono taps)
#   stereo IN  computer playback -> Ardour's AUX strip
#
# One map, not a mode switch: an earlier version made MPC and Ardour take
# turns on ten channels, which quietly reinvented the chained topology the
# design forbids - each source reaches the wire directly or not at all.
# Ardour's MPC strip is not tapped (the raw MPC is already on 1-10) and
# AUX is not tapped (it is the return carrying the computer's stereo in;
# tapping it would feed the host its own signal back).
#
# Every link is an additional tap, exactly like the recording links: the
# monitor path to the DAC is never touched, so unplugging the computer
# changes nothing the player can hear.
set -eu

# The gadget card's nodes; ask PipeWire rather than guessing.
gadget_node() {
	pw-cli ls Node 2>/dev/null |
		awk -F'"' '/node.name/ && /UAC2|Gadget|usb_gadget/ { print $2; exit }'
}

unlink_all() {
	node=$1
	pw-link -l 2>/dev/null | grep -F "$node" >/dev/null 2>&1 || return 0
	pw-link -d "$node" 2>/dev/null || true
}

# pw-link succeeding is not the test - the source may not be up yet. Say
# which links exist so bring-up order problems read as what they are.
link() {
	if pw-link "$1" "$2" 2>/dev/null; then
		echo "  $1 -> $2"
	else
		echo "  (absent) $1"
	fi
}

node=$(gadget_node)
if [ -z "$node" ]; then
	echo "mpc-usb-route: gadget card not present; is a host connected?" >&2
	exit 1
fi

case "${1:-on}" in
on)
	unlink_all "$node"
	echo "mpc-usb-route: MPC channels 1-10"
	link ":speaker:output_FL" "$node:playback_AUX0"
	link ":speaker:output_FR" "$node:playback_AUX1"
	i=0
	while [ "$i" -lt 8 ]; do
		link ":outputs:output_$i" "$node:playback_AUX$((i + 2))"
		i=$((i + 1))
	done
	echo "mpc-usb-route: Ardour channels 11-18"
	link "Ardour:Master/audio_out 1" "$node:playback_AUX10"
	link "Ardour:Master/audio_out 2" "$node:playback_AUX11"
	i=12
	for strip in GTR1 GTR2 MIC GTR1+ GTR2+ MIC+; do
		link "Ardour:$strip/audio_out 1" "$node:playback_AUX$i"
		i=$((i + 1))
	done
	echo "mpc-usb-route: computer stereo -> Ardour AUX"
	link "$node:capture_AUX0" "Ardour:AUX/audio_in 1"
	link "$node:capture_AUX1" "Ardour:AUX/audio_in 2"
	;;
off)
	unlink_all "$node"
	echo "mpc-usb-route: disconnected"
	;;
*)
	echo "Usage: $0 {on|off}" >&2
	exit 1
	;;
esac
