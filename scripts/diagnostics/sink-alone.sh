#!/bin/sh
# Does the SINK miss deadlines with no graph on top of it?
#
# Every measurement so far has been of Ardour attached to the sink, and
# every explanation offered for the xruns has therefore been about
# Ardour: its thread count, its plugin load, its core placement. None of
# them moved the number. Removing all 27 plugins halved the busy time
# and left the xrun rate alone; isolating the audio interrupt on its own
# core at priority 95 changed nothing measurable.
#
# The measurement that has never been taken is the one below: the ALSA
# sink, running at the same quantum, with nothing connected to it but a
# file player. If the driver still logs errors here, then no arrangement
# of the graph above it can help, and the fault is in the I2S path -
# clock, DMA turnaround, or period count.
#
# Reports the DRIVER row's error count, because that is the row that
# answers the question. A client row would only say that some client was
# late.
#
#   sink-alone.sh [quantum ...]      default: 48 32
set -u
QUANTA="${*:-48 32}"
U=$(id -u mpc)
R="sudo -u mpc env XDG_RUNTIME_DIR=/run/user/$U"
WINDOW="${MPCPI_WINDOW:-10}"
REPEATS="${MPCPI_REPEATS:-4}"
TONE=/tmp/mpcpi-tone.wav

# Nothing else in the graph. A leftover session would make this the same
# measurement as all the others.
pkill -x luasession 2>/dev/null
sleep 2

# A long file, not a short one on repeat: every restart is a node
# creation and a fresh set of allocations, which is a disturbance of
# exactly the kind being measured.
if [ ! -f "$TONE" ]; then
	python3 - "$TONE" <<'PY'
import math, struct, sys, wave

RATE, SECONDS = 44100, 180
# One second of samples, written SECONDS times. The first version built
# every frame in a Python loop - 26 million of them for a ten-minute
# file - and spent several minutes at 100% of a core before the
# measurement could even start. On a box being measured for scheduling
# latency, the test fixture is not allowed to be the load.
#
# 440Hz divides 44100 badly, so the block does not loop seamlessly; that
# is fine. A click once a second is not silence, and silence is what has
# to be avoided here - some paths short-circuit an all-zero buffer, and
# the point is to keep the sink genuinely fed.
block = b"".join(
    struct.pack("<hh", v, v)
    for v in (int(3000 * math.sin(2 * math.pi * 441 * n / RATE))
              for n in range(RATE))
)
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(RATE)
    for _ in range(SECONDS):
        w.writeframes(block)
PY
fi

ID=$($R wpctl status 2>/dev/null | grep "1f000a0000" |
	grep -oE "^[^0-9]*[0-9]+\." | grep -oE "[0-9]+" | head -1)
[ -n "$ID" ] && $R wpctl set-default "$ID" >/dev/null 2>&1

driver_err() {
	$R timeout 8 pw-top -b -n 2 2>/dev/null |
		grep -E "^R +[0-9]+ +[1-9][0-9]* +[1-9][0-9]*" | tail -1
}

for q in $QUANTA; do
	$R pw-metadata -n settings 0 clock.force-quantum "$q" >/dev/null 2>&1
	setsid $R pw-play "$TONE" >/dev/null 2>&1 &
	player=$!
	sleep 8
	line=$(driver_err)
	a=$(printf '%s' "$line" | awk '{print $9}')
	if [ -z "$a" ]; then
		echo "q=$q: no driver row - the sink is not running" >&2
		kill "$player" 2>/dev/null
		continue
	fi
	i=0
	while [ $i -lt "$REPEATS" ]; do
		sleep "$WINDOW"
		line=$(driver_err)
		b=$(printf '%s' "$line" | awk '{print $9}')
		printf '  q=%-3s window%-2d driver-err=%-6s WAIT=%-9s BUSY=%s\n' \
			"$q" "$i" "$((b - a))" \
			"$(printf '%s' "$line" | awk '{print $5}')" \
			"$(printf '%s' "$line" | awk '{print $6}')"
		a=$b
		i=$((i + 1))
	done
	kill "$player" 2>/dev/null
	sleep 2
done

$R pw-metadata -n settings 0 clock.force-quantum 0 >/dev/null 2>&1
echo SINK-ALONE-DONE
