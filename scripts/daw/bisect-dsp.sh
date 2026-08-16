#!/bin/sh
# Find the expensive inserts by halving, not by hunch.
#
# The first guess was the seven 16-band EQs. Deactivating every one of
# them bought about 10% of a budget that needs 40%, which is the kind of
# confident wrong answer a search does not let you keep.
#
# So: measure the floor with everything off, measure the ceiling with
# everything on, then halve. Each step reports B/Q from pw-top - the
# ratio of callback time to period, measured by the scheduler - so the
# answer is always in the unit that decides whether the instrument
# crackles.
#
#   bisect-dsp.sh [quantum]
#
# Reads /tmp/hold.sh, which starts a held session; ACTIVE is injected.
set -u
Q="${1:-32}"
U=$(id -u mpc)
R="sudo -u mpc env XDG_RUNTIME_DIR=/run/user/$U"
HOLD=/tmp/hold.sh

# One measurement: start a session with the given ACTIVE set, wait for it
# to be connected, force the quantum, and read the Ardour client's B/Q.
measure() {
	set_spec="$1"
	pkill -x luasession 2>/dev/null
	sleep 2
	sed "s|SECONDS=|ACTIVE=$set_spec SECONDS=|" "$HOLD" > /tmp/bisect-run.sh
	chmod +x /tmp/bisect-run.sh
	setsid nohup /tmp/bisect-run.sh > /tmp/bisect-run.log 2>&1 < /dev/null &
	n=0
	while [ $n -lt 50 ]; do
		grep -q "master connected" /tmp/bisect-run.log 2>/dev/null && break
		sleep 3
		n=$((n + 1))
	done
	sleep 6
	$R pw-metadata -n settings 0 clock.force-quantum "$Q" >/dev/null 2>&1
	sleep 3
	# The Ardour client is the follower node with no name of its own.
	line=$($R timeout 6 pw-top -b -n 2 2>/dev/null |
		grep -E "^R +1?[0-9]+ +0 +0" | tail -1)
	busy=$(printf '%s' "$line" | awk '{print $6}')
	bq=$(printf '%s' "$line" | awk '{print $8}')
	on=$(grep -oE "ACTIVE .* -> [0-9]+ of [0-9]+" /tmp/bisect-run.log | tail -1)
	printf '%-10s %-28s BUSY=%-8s B/Q=%s\n' "$set_spec" "${on:-?}" \
		"${busy:-?}" "${bq:-?}"
}

echo "== floor and ceiling (quantum $Q, period $(awk -v q="$Q" \
	'BEGIN{printf "%.0fus", q/44100*1e6}'))"
measure none
measure all

echo
echo "== halves"
# 29 inserts; the exact count is printed by each run, so the ranges below
# cover any session at least that large without needing to know it here.
measure 1-15
measure 16-29

echo
echo "== quarters"
measure 1-8
measure 9-15
measure 16-22
measure 23-29

pkill -x luasession 2>/dev/null
echo BISECT-DONE
