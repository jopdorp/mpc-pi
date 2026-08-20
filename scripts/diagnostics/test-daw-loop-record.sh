#!/bin/sh
# Record two loops of DIFFERENT lengths from the panel's own path, on the
# appliance, with the MPC's transport running. Runs ON the board.
#
# This is the end-to-end proof for loop recording, and it is deliberately
# made of nothing but the wires the panel uses:
#
#   the MPC's transport   PLAY START as a MIDI note on VirMIDI 0-0, which is
#                         exactly what maschine-hub sends for the PLAY key
#   the DAW verbs         lines on /run/daw-ctl.fifo, which is exactly what
#                         maschine-hub writes for REC and D1-D7
#
# so a pass here is a pass for the buttons. Nothing in it talks to Ardour
# directly: the takes have to come out of daw-ctl's bar quantiser, its OSC
# punches and the governor's queue, or they do not come out.
#
#   scripts/diagnostics/test-daw-loop-record.sh [bpm] [bars1] [bars2]
set -u
BPM=${1:-86}
BARS1=${2:-3}
BARS2=${3:-2}
FIFO=${DAW_FIFO:-/run/daw-ctl.fifo}
MIDI=${MPC_MIDI:-/dev/snd/midiC0D0}
TRANSPORT=${MPC_TRANSPORT_PATH:-/dev/shm/mpc-transport}
REGIONS=${DAW_REGIONS:-/dev/shm/daw-regions}
LANE1=${LANE1:-LOOP1}
LANE2=${LANE2:-LOOP2}

# One bar in seconds, and a little slack. The punch is quantised to the NEXT
# bar line, so asking for n bars means holding for n bars plus however much
# of the current one is left.
bar_s=$(awk -v b="$BPM" 'BEGIN { printf "%.4f", 240.0 / b }')
say() { echo "[$(date +%H:%M:%S)] $*"; }
verb() { echo "$*" > "$FIFO"; }

# The MPC's own keys, as notes. Panel keys ride notes 52..97 (see
# maschine-hub.py's encode_midi): PLAY START is keycode 0x29, STOP 0x1e.
# OCTAL, not \x. This is /bin/sh: dash's printf has no \x escape and writes
# the four literal characters, so the emulator saw no MIDI at all and the
# machine sat there - which reads exactly like "PLAY does nothing".
key() { printf "$1" > "$MIDI"; sleep 0.15; printf "$2" > "$MIDI"; }
play_start() { key '\220\134\144' '\200\134\000'; }
stop_mpc()   { key '\220\121\144' '\200\121\000'; }

[ -p "$FIFO" ] || { echo "FAIL: no $FIFO"; exit 1; }
[ -s "$TRANSPORT" ] || { echo "FAIL: nothing exports $TRANSPORT"; exit 1; }

say "transport export: $(cat "$TRANSPORT")"
verb "tempo $BPM"
say "bar = ${bar_s}s at $BPM BPM"

play_start
sleep 2
say "playing: $(cat "$TRANSPORT")"
case "$(cut -d' ' -f1 "$TRANSPORT")" in
1) ;;
*) echo "FAIL: the MPC did not start"; exit 1 ;;
esac

verb "arm 1"
sleep 0.5

hold() { awk -v b="$1" -v s="$2" 'BEGIN { printf "%.3f", b * s + 0.6 }'; }

say "punch in $LANE1"
verb "punch_in $LANE1"
sleep "$(hold "$BARS1" "$bar_s")"
say "punch out $LANE1"
verb "punch_out $LANE1"
sleep 3

say "punch in $LANE2"
verb "punch_in $LANE2"
sleep "$(hold "$BARS2" "$bar_s")"
say "punch out $LANE2"
verb "punch_out $LANE2"
sleep 3

verb "arm 0"
sleep 0.5
stop_mpc
sleep 1
say "stopped: $(cat "$TRANSPORT")"

echo
echo "=== published regions ==="
cat "$REGIONS"
echo
echo "=== what a bar is worth ==="
rate=$(head -1 "$REGIONS" | awk '{ print $3 }')
awk -v r="$rate" -v b="$BPM" 'BEGIN {
	printf "rate=%d bpm=%s one bar=%d samples\n", r, b, int(r * 240.0 / b + 0.5) }'
