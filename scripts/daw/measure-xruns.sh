#!/bin/sh
# Measure the xrun RATE reproducibly: many windows per quantum, median.
#
# soak.sh answers "is it broken" in one 20-second window. That was enough
# while the effects were tens of xruns per second apart. It stopped being
# enough once the remaining differences got down to the size of the noise:
# three runs of the SAME configuration produced 374, 734 and 1007 xruns
# per 20 seconds, so every A/B comparison drawn from single windows -
# including the thread-count one - was measuring the weather.
#
# What changes here:
#
#   * The session is started ONCE for the whole matrix. Restarting it per
#     quantum meant every measurement carried a different load transient,
#     a different plugin instantiation order, and a different set of
#     first-touch page faults.
#   * Each quantum gets REPEATS back-to-back windows, and the FIRST is
#     discarded. The quantum change itself xruns; so does the first
#     window after it, while the driver renegotiates and the workers
#     settle onto their cores.
#   * Window boundaries share a sample. Reading a counter at the end of
#     one window and again at the start of the next leaves a gap of two
#     pw-top batches - about two seconds - in which xruns happen and are
#     billed to nothing.
#   * The result is a MEDIAN with the spread beside it. A mean over a
#     bursty signal is dragged around by whichever window caught a burst,
#     which is exactly how the numbers above happened.
#
#   measure-xruns.sh [quantum ...]      default: 48 32
#
# env: MPCPI_WINDOW (seconds per window, default 10)
#      MPCPI_REPEATS (windows per quantum incl. the discarded one, def 5)
#      MPCPI_SESSION, MPCPI_SESSION_NAME
set -u
QUANTA="${*:-48 32}"
U=$(id -u mpc)
R="sudo -u mpc env XDG_RUNTIME_DIR=/run/user/$U"
SRC=/opt/mpc-pi-src
SESSION="${MPCPI_SESSION:-/home/mpc/lp}"
NAME="${MPCPI_SESSION_NAME:-t}"
WINDOW="${MPCPI_WINDOW:-10}"
REPEATS="${MPCPI_REPEATS:-5}"
LOG=/var/log/mpcpi-xruns.log

. "$SRC/scripts/daw/ardour-env.sh"
ardour_env || { echo "no Ardour"; exit 1; }

# The client node is the one with no name and no format of its own: it is
# Ardour attached to the driver. Identified by shape, not by name, so a
# rename cannot silently redirect the measurement at the driver node -
# whose ERR column counts something else entirely.
sample() {
	$R timeout 8 pw-top -b -n 2 2>/dev/null > /tmp/pwtop.$$
	# Ardour is the follower with no format and NO NAME - the row ends
	# at the bare "+" of the tree drawing. The earlier "0 0 follower,
	# tail -1" matched pw-play and the emulator nodes as well, and which
	# one tail picked depended on listing order: one run read a MAME
	# node (xruns=0, BUSY 0.0us), the next read something else entirely,
	# and one window even produced a negative driver delta. Every row a
	# measurement depends on must be selected by a property only the
	# intended node has.
	grep -E "^R +[0-9]+ +0 +0" /tmp/pwtop.$$ | grep -E "\+ *$" | tail -1
}

# The DRIVER row, from the same capture. Without it a rising client ERR
# is unattributable: a follower that is late every time the sink is late
# is not a slow follower, it is a slow sink, and the two want opposite
# fixes. The driver is the row that owns the quantum and rate - the
# followers report 0 0 because they inherit them.
driver_line() {
	grep -E "^R +[0-9]+ +[1-9][0-9]* +[1-9][0-9]*" /tmp/pwtop.$$ | head -1
}

median() {
	# shellcheck disable=SC2046
	set -- $(printf '%s\n' "$@" | sort -n)
	eval echo "\${$((($# + 1) / 2))}"
}

pkill -x luasession 2>/dev/null
sleep 2

# Wake the sink: an idle ALSA node is not a driver, and a graph with no
# driver runs nothing at all - which reports as a confident zero.
ID=$($R wpctl status 2>/dev/null | grep "1f000a0000" |
	grep -oE "^[^0-9]*[0-9]+\." | grep -oE "[0-9]+" | head -1)
[ -n "$ID" ] && $R wpctl set-default "$ID" >/dev/null 2>&1
[ -n "$ID" ] && timeout 6 $R pw-play --target "$ID" \
	/usr/share/sounds/alsa/Front_Center.wav >/dev/null 2>&1

# Long enough to outlive the whole matrix: quanta x repeats x window,
# plus settling. A session that exits mid-matrix leaves every later
# quantum measuring an empty graph.
total=$(( $(echo "$QUANTA" | wc -w) * (REPEATS + 2) * WINDOW + 120 ))

# taskset is not optional and not a tuning knob here. isolcpus=1-3 takes
# those cores out of every process's default affinity mask, so a session
# launched without it runs entirely on core 0 - alongside every IRQ and
# all of userspace - while the three cores isolated for audio sit idle.
# Omitting it does not measure "the default placement"; it measures the
# worst one, and it is not comparable with any earlier number.
setsid nohup taskset -c "${MPCPI_AUDIO_CORES:-2-3}" sudo -u mpc env \
	XDG_RUNTIME_DIR="/run/user/$U" \
	LD_LIBRARY_PATH="$ARDOUR_DLL_PATH" ARDOUR_DLL_PATH="$ARDOUR_DLL_PATH" \
	ARDOUR_DATA_PATH="$ARDOUR_DATA_PATH" \
	ARDOUR_CONFIG_PATH="$ARDOUR_CONFIG_PATH" \
	SESSION_DIR="$SESSION" SESSION_NAME="$NAME" \
	ACTIVE="${ACTIVE:-}" STRESS="${STRESS:-}" \
	NO_INPUTS="${NO_INPUTS:-}" REC_ARM="${REC_ARM:-}" \
	MPCPI_COMPAT="$SRC/scripts/daw/ardour-compat.lua" \
	SECONDS="$total" \
	pw-jack "$LUASESSION" "$SRC/scripts/daw/measure-dsp.lua" \
	> "$LOG" 2>&1 < /dev/null &

n=0
while [ $n -lt 60 ]; do
	grep -q "master connected" "$LOG" 2>/dev/null && break
	sleep 3
	n=$((n + 1))
done
if ! pgrep -x luasession >/dev/null; then
	echo "session failed to start - see $LOG" >&2
	tail -5 "$LOG" >&2
	exit 1
fi
echo "session up (budget ${total}s, ${REPEATS} windows of ${WINDOW}s per quantum)"

# NO_INPUTS=1 cuts every link feeding Ardour from a capture device.
#
# A bisection, not a tuning option. Ardour's lateness survived switching
# off all 27 plugins and survived fixing the sink's scheduling, so it is
# neither DSP cost nor the driver underneath. What remains wired into
# the graph are the capture nodes the tracks are connected to: an
# 8-channel 44.1k ADC and the USB gadget's input, which was found
# running at 48000 inside a 44100 graph. Both carry error counts of
# their own.
#
# Cut from here rather than from Lua: IO:disconnect(nil) segfaults
# luasession, and a segfault takes the whole measurement with it.
if [ "${NO_INPUTS:-}" = "1" ]; then
	cut=0
	for id in $($R pw-link -I -l 2>/dev/null |
			awk '/alsa_input|capture|stereo-fallback/ {print $1}' |
			grep -E '^[0-9]+$' | sort -u); do
		$R pw-link -d "$id" >/dev/null 2>&1 && cut=$((cut + 1))
	done
	echo "NO_INPUTS: cut $cut links from capture devices"
fi

for q in $QUANTA; do
	$R pw-metadata -n settings 0 clock.force-quantum "$q" >/dev/null 2>&1
	sleep 6
	prev=$(sample)
	a=$(printf '%s' "$prev" | awk '{print $9}')
	da=$(driver_line | awk '{print $9}')
	if [ -z "$a" ]; then
		echo "q=$q: NO CLIENT NODE - the session is not in the graph" >&2
		continue
	fi
	vals=""
	busies=""
	i=0
	while [ $i -lt "$REPEATS" ]; do
		sleep "$WINDOW"
		cur=$(sample)
		b=$(printf '%s' "$cur" | awk '{print $9}')
		[ -n "$b" ] || { echo "q=$q: client vanished mid-run" >&2; break; }
		d=$((b - a))
		bq=$(printf '%s' "$cur" | awk '{print $8}')
		# BUSY in nanoseconds, not just the ratio. The ratio alone cannot
		# separate "the work is too big" from "the period is too small":
		# busy time across two quanta gives both the per-sample cost and
		# the fixed per-callback cost, and only the second one is
		# addressable by removing nodes from the graph.
		busy=$(printf '%s' "$cur" | awk '{print $6}')
		db=$(driver_line | awk '{print $9}')
		dd=$((${db:-0} - ${da:-0}))
		da=${db:-0}
		# The first window is warm-up: the quantum change itself xruns and
		# the graph has not settled onto its cores yet.
		if [ $i -eq 0 ]; then
			printf '  q=%-3s warmup   xruns=%-6s drv=%-6s B/Q=%-6s BUSY=%s\n' \
				"$q" "$d" "$dd" "$bq" "$busy"
		else
			printf '  q=%-3s window%-2d xruns=%-6s drv=%-6s B/Q=%-6s BUSY=%s\n' \
				"$q" "$i" "$d" "$dd" "$bq" "$busy"
			vals="$vals $d"
			busies="$busies $busy"
		fi
		a=$b
		i=$((i + 1))
	done
	[ -n "$vals" ] || continue
	# shellcheck disable=SC2086
	lo=$(printf '%s\n' $vals | sort -n | head -1)
	# shellcheck disable=SC2086
	hi=$(printf '%s\n' $vals | sort -n | tail -1)
	# shellcheck disable=SC2086
	med=$(median $vals)
	# shellcheck disable=SC2086
	mbusy=$(median $busies)
	printf 'Q=%-3s MEDIAN=%-6s per-%ss  range=%s..%s  n=%s  BUSY=%s\n' \
		"$q" "$med" "$WINDOW" "$lo" "$hi" "$(echo $vals | wc -w)" "$mbusy"
done

rm -f /tmp/pwtop.$$
$R pw-metadata -n settings 0 clock.force-quantum 0 >/dev/null 2>&1
pkill -x luasession 2>/dev/null
echo XRUNS-DONE
