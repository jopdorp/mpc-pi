#!/bin/sh
# Wire the instrument into the USB gadget - all of it, concurrently.
#
#   mpc-usb-route.sh on       connect the full 22-up / 2-down map
#   mpc-usb-route.sh off      disconnect everything
#   mpc-usb-route.sh show     print what is actually connected
#
# The map, as the computer sees it:
#
#   ch  1-2    MPC stereo mix              (:speaker)
#   ch  3-10   MPC individual outs 1-8     (:outputs, MPC_OUTPUT_MODE=all)
#   ch 11-12   DAW master L/R              (Ardour Master)
#   ch 13-20   DAW channel strips          (MPC GTR1 GTR2 MIC GTR1+ GTR2+ MIC+ AUX)
#   ch 21-22   ADC direct                  (the PCM1808 pair, untouched)
#   stereo IN  computer playback           -> Ardour's AUX strip
#
# One map, not a mode switch: an earlier version made MPC and Ardour take
# turns on ten channels, which quietly reinvented the chained topology the
# design forbids - each source reaches the wire directly or not at all.
#
# ch 21-22 are the converter's own output before Ardour touches it, so a
# take can be re-amped later from the dry signal. ch 13-20 include the
# MPC strip (the MPC *after* Ardour's processing, distinct from the raw
# feed on 1-2) and the AUX strip (the computer's own return, coming back
# to it one trip later - harmless unless the host loops it onward).
#
# Every link is an additional tap, exactly like the recording links: the
# monitor path is never touched, so unplugging the computer changes
# nothing the player can hear.
#
# WHY EXPLICIT ROUTING IS NOT OPTIONAL
#
# With no map in place PipeWire connects every source it sees to the
# first free channels of the default sink. Measured on the running
# board: 44 links from the emulator's :speaker, :outputs and floppy
# nodes piled onto the same two channels a measurement tone was using,
# and the sum read as full-scale clipping. That cost a day of chasing
# defects that were only ever addition. mpcpi-clock exists partly for
# this: it is the default sink, so strays land on a null node instead
# of on the wire to the computer.
set -eu

# The gadget card's nodes; ask PipeWire rather than guessing.
gadget_node() {
	pw-cli ls Node 2>/dev/null |
		awk -F'"' '/node.name/ && /1000480000.usb/ && /output/ { print $2; exit }'
}
gadget_in_node() {
	pw-cli ls Node 2>/dev/null |
		awk -F'"' '/node.name/ && /1000480000.usb/ && /input/ { print $2; exit }'
}
adc_node() {
	pw-cli ls Node 2>/dev/null |
		awk -F'"' '/node.name/ && /107c000000_sound/ && /input/ { print $2; exit }'
}

unlink_all() {
	pw-link -d "$1" 2>/dev/null || true
}

# pw-link succeeding is not the test - the source may not be up yet. Say
# which links exist so bring-up order problems read as what they are.
made=0
absent=0
link() {
	if pw-link "$1" "$2" 2>/dev/null; then
		made=$((made + 1))
	else
		absent=$((absent + 1))
		echo "  (absent) $1 -> $2"
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
	# 1-2: the MPC's own stereo mix.
	link ":speaker:output_FL" "$node:playback_AUX0"
	link ":speaker:output_FR" "$node:playback_AUX1"
	# 3-10: the MPC's eight individual outs.
	i=0
	while [ "$i" -lt 8 ]; do
		link ":outputs:output_$i" "$node:playback_AUX$((i + 2))"
		i=$((i + 1))
	done
	# 11-12: the DAW master.
	link "Ardour:Master/audio_out 1" "$node:playback_AUX10"
	link "Ardour:Master/audio_out 2" "$node:playback_AUX11"
	# 13-20: the eight DAW channel strips, in panel order.
	i=12
	for strip in MPC GTR1 GTR2 MIC GTR1+ GTR2+ MIC+ AUX; do
		link "Ardour:$strip/audio_out 1" "$node:playback_AUX$i"
		i=$((i + 1))
	done
	# 21-22: the converter, dry.
	adc=$(adc_node)
	if [ -n "$adc" ]; then
		# The I2S capture node names its ports capture_1..N, not
		# capture_AUX0 like the gadget does. Port naming follows the
		# channel map the driver advertises, so it differs per device -
		# ask, never assume.
		link "$adc:capture_1" "$node:playback_AUX20"
		link "$adc:capture_2" "$node:playback_AUX21"
	else
		echo "  (absent) ADC input node"
		absent=$((absent + 2))
	fi
	# The stereo return from the computer.
	gin=$(gadget_in_node)
	if [ -n "$gin" ]; then
		link "$gin:capture_FL" "Ardour:AUX/audio_in 1"
		link "$gin:capture_FR" "Ardour:AUX/audio_in 2"
	fi
	echo "mpc-usb-route: $made links up, $absent absent (22 up / 2 down)"
	;;
off)
	unlink_all "$node"
	echo "mpc-usb-route: disconnected"
	;;
show)
	# What is ACTUALLY on the wire, per channel. The map above is the
	# intent; this is the fact, and the two have differed.
	for ch in $(seq 0 21); do
		src=$(pw-link -l 2>/dev/null |
			grep -A4 "playback_AUX$ch\$" |
			sed -n 's/^ *|<- *//p' | tr '\n' ' ')
		printf 'ch %-2d  %s\n' "$((ch + 1))" "${src:-(nothing)}"
	done
	;;
*)
	echo "Usage: $0 {on|off|show}" >&2
	exit 1
	;;
esac
