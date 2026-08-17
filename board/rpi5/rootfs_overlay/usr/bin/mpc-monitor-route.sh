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

link_pair() {
	src="$1"
	for ch in FL FR; do
		# -o is idempotent in effect: a duplicate link is refused, and that
		# refusal is not an error worth stopping for.
		$R pw-link "$src:output_$ch" "$sink:playback_$ch" 2>/dev/null || true
	done
}

case "${1:-link}" in
link)
	# The emulator's own outputs. :outputs is the main pair; :speaker is the
	# MPC's internal speaker; :fdc is the floppy drive, which is a genuine
	# part of the instrument's sound and deliberately included.
	for src in ":outputs" ":speaker"; do
		$R pw-link -o 2>/dev/null | grep -q "^$src:" && link_pair "$src"
	done
	# Ardour's master, when the session is up.
	master=$($R pw-link -o 2>/dev/null | grep -iE "^(Ardour|ardour).*master" |
		head -1 | cut -d: -f1)
	[ -n "$master" ] && link_pair "$master"
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
