#!/bin/sh
# Link what the instrument produces to the LOCAL monitoring output.
#
# The gadget's 22 channels are mapped by mpc-usb-route.sh; this is the other
# destination - the USB codec standing in for the ADC/DAC that will eventually
# hang off the I2S header. It is what the player actually hears when the
# appliance is not plugged into a computer.
#
# Explicit links rather than relying on WirePlumber's default-sink
# auto-linking, which did not happen: the emulator ran with nowhere to send
# audio and logged 133,780 errors while the codec sat suspended. Auto-linking
# depends on default-node selection, remembered state, and start order - three
# things that all have to be right at once. A link either exists or it does
# not.
#
#   mpc-monitor-route.sh [link|show]
set -eu

U=$(id -u mpc)
R="sudo -u mpc env XDG_RUNTIME_DIR=/run/user/$U"
SINK_MATCH="${MPCPI_MONITOR_SINK:-BurrBrown}"

sink=$($R pw-link -o 2>/dev/null | grep -i "$SINK_MATCH" | head -1 | cut -d: -f1)
[ -n "$sink" ] || sink=$($R pw-link -i 2>/dev/null | grep -i "$SINK_MATCH" |
	head -1 | sed 's/:playback.*//')
if [ -z "$sink" ]; then
	echo "no monitoring sink matching '$SINK_MATCH'" >&2
	exit 1
fi

# Take the source OFF anything else first.
#
# The emulator drifted onto mpcpi-clock - the null-sink graph clock - so its
# audio was being delivered nowhere audible while Ardour's click was the only
# thing reaching the codec. WirePlumber's default-node logic and Ardour's
# "connect the emulator" stage both re-link it, so this has to be asserted
# rather than assumed: a link to the clock is a link to silence.
unlink_from_clock() {
	for ch in FL FR; do
		$R pw-link -d "$1:output_$ch" "mpcpi-clock:playback_$ch" 2>/dev/null || true
	done
}

link_pair() {
	src="$1"
	unlink_from_clock "$src"
	for ch in FL FR; do
		# -o is idempotent in effect: a duplicate link is refused, and that
		# refusal is not an error worth stopping for.
		$R pw-link "$src:output_$ch" "$sink:playback_$ch" 2>/dev/null || true
	done
}

case "${1:-link}" in
link)
	# ONLY the main stereo pair.
	#
	# The emulator exposes several sources - :speaker, :outputs, and :fdc (the
	# floppy drive). Linking more than one SUMS them into the same two
	# channels, which is not monitoring, it is a mix nobody asked for.
	#
	# This project has been burnt by exactly that before - 44 emulator links
	# summed onto a measurement tone's channels and produced thousands of
	# apparent defects that were entirely the routing.
	#
	# :speaker, NOT :outputs. This defaulted to :outputs on the strength of a
	# comment right here claiming :outputs was the main L/R pair and that the
	# two nodes were "the SAME audio twice". Both halves were wrong, and it cost
	# a long hunt for silent audio: the appliance was correctly linked, at the
	# right quantum, to a node that carries nothing.
	#
	# Measured, with a capture node that had autoconnect disabled and was
	# explicitly linked (scripts/diagnostics/probe-mpc-audio.sh), while pad
	# notes 36..51 were injected into VirMIDI:
	#
	#     :outputs   ch0 peak=0     ch1 peak=0        SILENT
	#     :speaker   ch0 peak=9678  ch1 peak=9799     AUDIO
	#
	# A -wavwrite render of the same machine writes ELEVEN channels, with the
	# music on channels 1 and 2 and the rest silent - the mpc2000xl has several
	# speaker devices and MAME publishes one PipeWire node per device, so
	# "outputs" is a plausible-sounding name for a device that is not the one
	# the program plays through. The development host, which has always been
	# audible, uses :speaker too.
	#
	# Set MPCPI_MONITOR_SOURCES to override, e.g. ":speaker :outputs".
	for src in ${MPCPI_MONITOR_SOURCES:-":speaker"}; do
		$R pw-link -o 2>/dev/null | grep -q "^$src:" && link_pair "$src"
	done
	# Ardour's master, alongside the MPC. Both instruments into the one stereo
	# pair is deliberate here: it is the monitor mix - the MPC and the DAW are
	# the two things being played, and hearing both is the point.
	#
	# That is a different thing from what the source filter above prevents.
	# There, the alternative sources are other speaker devices of the same
	# machine plus floppy noise. Here :speaker and Ardour's master are two
	# separate instruments.
	#
	# Set MPCPI_MONITOR_ARDOUR=0 to hear only the MPC.
	if [ "${MPCPI_MONITOR_ARDOUR:-1}" != "0" ]; then
		master=$($R pw-link -o 2>/dev/null |
			grep -iE "ardour.*(master|Master)" | head -1 | cut -d: -f1)
		if [ -n "$master" ]; then
			link_pair "$master"
			printf '  + ardour master: %s\n' "$master"
		else
			printf '  (no ardour master port yet)\n'
		fi
	fi
	printf 'monitoring on %s\n' "$sink"
	$R pw-link -l 2>/dev/null | grep -c "$SINK_MATCH" |
		sed 's/^/  links: /'
	;;
show)
	printf 'sink : %s\n' "$sink"
	$R pw-link -l 2>/dev/null | grep -B1 -A1 "$SINK_MATCH" | head -20
	;;
*)
	echo "usage: mpc-monitor-route.sh [link|show]" >&2
	exit 1
	;;
esac
