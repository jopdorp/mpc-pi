#!/bin/sh
# Wire the emulator and Ardour into the USB gadget's 22 channels, all
# concurrently.
#
# REBUILT FROM AN EARLIER, MEASURED VERSION (git show de9326e^:...), with
# two things updated and everything else kept: the desk is LOOP1-5 now,
# not GTR1/GTR2/MIC/AUX, so channels 13-22 changed; and the port naming
# below - playback_AUX0..21 with no FL/FR even for the first pair, but
# capture_FL/FR for the 2-channel return - is copied from what that
# version measured on THIS gadget, not re-derived. Discovering and
# sorting the ports instead (an intermediate draft of this file did that)
# is a real bug: "AUX10" sorts before "AUX2" as text, so anything past
# channel 9 would have landed on the wrong wire.
#
#   mpc-usb-route.sh on      connect the full 22-up / 2-down map
#   mpc-usb-route.sh off     disconnect everything this script added
#   mpc-usb-route.sh status  print what is actually connected, per channel
#
# The map, as the computer sees it:
#
#   ch  1-2    MPC stereo mix              (:speaker)
#   ch  3-10   MPC individual outs 1-8     (:outputs, needs MPC_OUTPUT_MODE=all)
#   ch 11-12   DAW master L/R              (:Master)
#   ch 13-22   DAW loop stems, stereo      (:LOOP1 .. :LOOP5)
#   stereo IN  computer playback           -> :Master, mixed straight in
#
# Twenty-two up costs the ADC-direct tap the earlier version carried on
# 21-22 (the PCM1808 pair, dry, for later re-amping) - dropped rather
# than dropping a loop track, because reaching every loop stem from the
# computer is closer to what this appliance is FOR now than a dry
# capture feed is. There is also no dedicated AUX strip to land the
# computer's playback on any more - it predates the LOOP1-5 rename -
# so it goes straight to the master input as a backing-track mix-in.
#
# EVERY LINK HERE IS A TAP. Nothing already routed to the local monitor
# output is unrouted first - the gadget receives a parallel copy, same
# as mpc-monitor-route.sh's sink does. Unplugging the computer changes
# nothing the player can hear.
#
# WHY EXPLICIT ROUTING IS NOT OPTIONAL: with no map in place PipeWire
# connects every source it sees to the first free channels of the
# default sink. Measured once already: 44 links from the emulator's
# :speaker, :outputs and floppy nodes piled onto the same two channels a
# measurement tone was using, and the sum read as full-scale clipping -
# a day of chasing defects that were only ever addition. mpcpi-clock
# exists partly for this: it is the default sink, so strays land on a
# null node instead of on the wire to the computer.
set -eu
MODE="${1:?usage: $0 (on|off|status)}"

U=$(id -u mpc)
R="sudo -u mpc env XDG_RUNTIME_DIR=/run/user/$U"
GADGET_MATCH="platform-1000480000.usb"

log() { echo "mpc-usb-route: $*"; }

gadget_node() {
	# The alsa_output side: where WE write, and the host RECORDS it.
	$R pw-link -i 2>/dev/null | grep "^alsa_output.*$GADGET_MATCH" |
		cut -d: -f1 | sort -u | head -1
}
gadget_in_node() {
	# The alsa_input side: where WE read what the host PLAYS.
	$R pw-link -o 2>/dev/null | grep "^alsa_input.*$GADGET_MATCH" |
		cut -d: -f1 | sort -u | head -1
}

made=0
absent=0
link() {
	# pw-link returns NONZERO for a link that already exists ("File
	# exists" on stderr) - not a failure, the strongest possible evidence
	# the two ports ARE connected. Counting that as absent is what made a
	# SECOND run of this script look worse than the first: every link the
	# previous run had already made came back as a failure on retry,
	# undercounting $made and (with the >=4 floor below) potentially
	# failing a route that was actually complete.
	#
	# The assignment MUST be the condition of the if itself, not a
	# separate statement checked via $? afterward - this script runs
	# under `set -e`, and set -e aborts on ANY unprotected command's
	# nonzero status, including a plain `x=$(...)` on its own line. That
	# killed the script mid-link on the very first "already exists" hit,
	# which looked like the whole script had crashed rather than like one
	# already-satisfied link.
	if err=$($R pw-link "$1" "$2" 2>&1 >/dev/null); then
		made=$((made + 1))
	elif printf '%s' "$err" | grep -q 'File exists'; then
		made=$((made + 1))
	else
		absent=$((absent + 1))
		[ "$MODE" = "status" ] && echo "  (absent) $1 -> $2: $err"
	fi
	# link()'s own exit status is its last command's - here, that guarded
	# echo, which is false whenever MODE != status. Every call site below
	# is a bare statement in a loop, unprotected by set -e, so THAT
	# false status - not the pw-link result the whole function exists to
	# report - is what killed the script the third time this exact class
	# of bug shipped. The counting already happened via made/absent; the
	# function itself must always report success.
	return 0
}
unlink() { $R pw-link -d "$1" "$2" 2>/dev/null || true; }

node=$(gadget_node)
if [ -z "$node" ] && [ "$MODE" != "status" ]; then
	log "gadget card not present - is it bound? (mpc-usb-gadget.sh status)"
	exit 1
fi

route() {
	op=$1     # "link" or "unlink"
	# MAME's own node - :speaker - uses a COLON before the port name
	# (":speaker:output_FL"), proven by phase3-run.sh long before this
	# script existed. Ardour's ports use a SLASH instead
	# (":Master/audio_out 1"), confirmed live against the running graph -
	# every colon-separated attempt at an Ardour port failed with "No such
	# file or directory" while pw-link's OWN -o/-i listing showed the
	# identical port existing under the slash form. Likely because Ardour
	# reaches PipeWire through pw-jack, and a JACK port name is itself
	# "Client:Port" - colon-INSIDE-the-name - so pw-link needs a different
	# separator to tell node from port without colliding with that.
	# MAME's node is a native PipeWire client with no such embedded colon,
	# so it keeps the ordinary separator.
	$op ":speaker:output_FL" "$node:playback_AUX0"
	$op ":speaker:output_FR" "$node:playback_AUX1"

	# Silent today: MPC_OUTPUT_MODE=stereo compiles :outputs out entirely.
	# Switching to "all" is a separate, measured decision (see
	# docs/maschine-daw-design.md), not bundled into bringing the gadget up.
	# :outputs is MAME's own node too, so it keeps the colon form.
	i=0
	while [ "$i" -lt 8 ]; do
		$op ":outputs:output_$i" "$node:playback_AUX$((i + 2))"
		i=$((i + 1))
	done

	$op ":Master/audio_out 1" "$node:playback_AUX10"
	$op ":Master/audio_out 2" "$node:playback_AUX11"

	i=0
	for strip in LOOP1 LOOP2 LOOP3 LOOP4 LOOP5; do
		base=$((12 + i * 2))
		$op ":$strip/audio_out 1" "$node:playback_AUX$base"
		$op ":$strip/audio_out 2" "$node:playback_AUX$((base + 1))"
		i=$((i + 1))
	done

	gin=$(gadget_in_node)
	if [ -n "$gin" ]; then
		$op "$gin:capture_FL" ":Master/audio_in 1"
		$op "$gin:capture_FR" ":Master/audio_in 2"
	fi
}

case "$MODE" in
on)
	route link
	log "$made links up, $absent absent (target: 22 up / 2 down)"
	# EXIT NONZERO WHEN NOTHING WORTH HAVING GOT LINKED.
	#
	# An earlier version of the sibling script for the local monitor sink
	# returned 0 unconditionally here, and success arrived on the FIRST
	# retry attempt - before the emulator had published its node - so the
	# retry loop in the systemd unit stopped and the instrument came up
	# with no links at all. Four is the floor: MPC master (2) plus Ardour
	# master (2), the two sources that are always present once their
	# units are up. Everything past that (individual outs, loop stems) is
	# a bonus this attempt may not have caught yet.
	[ "$made" -ge 4 ] || { log "only $made links - not enough yet"; exit 1; }
	;;
off)
	route unlink
	log "disconnected"
	;;
status)
	if [ -z "$node" ]; then
		echo "gadget not present"
		exit 1
	fi
	for ch in $(seq 0 21); do
		# For an INPUT port (our sink's playback_AUXn), pw-link -l prints
		# the port's own name first and its source(s) on the "|<-" line(s)
		# immediately AFTER it - not before. This read -B1 originally,
		# which is backwards, and printed whatever unrelated line happened
		# to precede the match instead of the actual source.
		src=$($R pw-link -l 2>/dev/null |
			grep -A1 "playback_AUX$ch\$" | sed -n '2p' | sed 's/^ *|<- *//')
		printf 'ch %-2d  %s\n' "$((ch + 1))" "${src:-(nothing)}"
	done
	gin=$(gadget_in_node)
	[ -n "$gin" ] && echo "down    $gin (capture_FL/FR)"
	true    # status is a report, not a pass/fail check - always exit 0,
	        # regardless of whether the line above found anything.
	;;
*)
	echo "usage: $0 {on|off|status}" >&2
	exit 2
	;;
esac
