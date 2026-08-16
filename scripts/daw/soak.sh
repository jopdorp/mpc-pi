#!/bin/sh
# Hold the session open and report the xrun RATE at each quantum.
#
# Lives in the repo, not in /tmp. Every measurement harness before this
# one was written into /tmp on the board, which is tmpfs: a reboot -
# and this work reboots constantly - erased them, and the next run
# then measured an empty graph and reported a confident zero xruns.
# A measurement tool that disappears is worse than none, because its
# absence looks like a result.
#
# Rate, not total: xruns accumulate from session load and from every
# quantum change, so a total says only that something once went wrong.
# The delta over a fixed window says whether it is still going wrong.
#
#   soak.sh [quantum ...]        default: 64 48 32
set -u
QUANTA="${*:-64 48 32}"
U=$(id -u mpc)
R="sudo -u mpc env XDG_RUNTIME_DIR=/run/user/$U"
SRC=/opt/mpc-pi-src
SESSION="${MPCPI_SESSION:-/home/mpc/lp}"
NAME="${MPCPI_SESSION_NAME:-t}"
WINDOW="${MPCPI_WINDOW:-20}"

. "$SRC/scripts/daw/ardour-env.sh"
ardour_env || { echo "no Ardour"; exit 1; }

# The client node is the one with no name and no format of its own: it
# is Ardour, attached to the driver. Identify it by ID so a rename or a
# reordering cannot silently point the measurement at the wrong node.
client_line() {
	$R timeout 6 pw-top -b -n 2 2>/dev/null |
		grep -E "^R +[0-9]+ +0 +0" | tail -1
}

pkill -x luasession 2>/dev/null
sleep 2

# Wake the sink first: an idle ALSA node is not a driver, and a graph
# with no driver runs nothing at all.
ID=$($R wpctl status 2>/dev/null | grep "1f000a0000" |
	grep -oE "^[^0-9]*[0-9]+\." | grep -oE "[0-9]+" | head -1)
[ -n "$ID" ] && $R wpctl set-default "$ID" >/dev/null 2>&1
[ -n "$ID" ] && timeout 6 $R pw-play --target "$ID" \
	/usr/share/sounds/alsa/Front_Center.wav >/dev/null 2>&1

setsid nohup taskset -c 2-3 sudo -u mpc env \
	XDG_RUNTIME_DIR="/run/user/$U" \
	LD_LIBRARY_PATH="$ARDOUR_DLL_PATH" ARDOUR_DLL_PATH="$ARDOUR_DLL_PATH" \
	ARDOUR_DATA_PATH="$ARDOUR_DATA_PATH" \
	ARDOUR_CONFIG_PATH="$ARDOUR_CONFIG_PATH" \
	SESSION_DIR="$SESSION" SESSION_NAME="$NAME" \
	MPCPI_COMPAT="$SRC/scripts/daw/ardour-compat.lua" \
	SECONDS=600 \
	pw-jack "$LUASESSION" "$SRC/scripts/daw/measure-dsp.lua" \
	> /var/log/mpcpi-soak.log 2>&1 < /dev/null &

n=0
while [ $n -lt 60 ]; do
	grep -q "master connected" /var/log/mpcpi-soak.log 2>/dev/null && break
	sleep 3
	n=$((n + 1))
done
if ! pgrep -x luasession >/dev/null; then
	echo "session failed to start - see /var/log/mpcpi-soak.log" >&2
	tail -3 /var/log/mpcpi-soak.log >&2
	exit 1
fi
echo "session up: $(grep -c . /var/log/mpcpi-soak.log) lines"

for q in $QUANTA; do
	$R pw-metadata -n settings 0 clock.force-quantum "$q" >/dev/null 2>&1
	sleep 8
	first=$(client_line)
	a=$(printf '%s' "$first" | awk '{print $9}')
	if [ -z "$a" ]; then
		echo "q=$q: NO CLIENT NODE - the session is not in the graph" >&2
		continue
	fi
	sleep "$WINDOW"
	last=$(client_line)
	b=$(printf '%s' "$last" | awk '{print $9}')
	printf 'q=%-3s xruns/%ss=%-7s B/Q=%-6s BUSY=%s\n' \
		"$q" "$WINDOW" "$((b - a))" \
		"$(printf '%s' "$last" | awk '{print $8}')" \
		"$(printf '%s' "$last" | awk '{print $6}')"
done

$R pw-metadata -n settings 0 clock.force-quantum 0 >/dev/null 2>&1
pkill -x luasession 2>/dev/null
echo SOAK-DONE
