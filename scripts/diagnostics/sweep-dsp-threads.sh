#!/bin/sh
# Sweep Ardour's DSP thread count against the xrun rate, reproducibly.
#
# The earlier sweep concluded "2 is best, 3 and 4 regress" from single
# 20-second windows, at a time when repeat runs of one configuration
# spanned 374 to 1007 xruns. That conclusion was not supported by the
# data it was drawn from.
#
# It also matters more than it looked, because the graph turns out to
# carry three realtime threads, not two: the pipewire-jack client's data
# loop (prio 85, where the callback lands) plus one Ardour graph worker
# per configured processor. With processor-usage=2 on two isolated
# cores, that is three RT threads on two cores, and the dispatcher sits
# at a HIGHER priority than the workers it then waits for - so on the
# core they share, the worker cannot run while the dispatcher spins.
#
# Runs the floor (ACTIVE=none) rather than the shipped chains, because
# xruns were measured to be almost independent of DSP load - removing
# all 27 plugins halved busy time and did not reduce the xrun rate at
# quantum 48 at all. The floor is the same scheduling question with less
# noise and a third of the runtime.
#
#   sweep-dsp-threads.sh [n ...]     default: 1 2 3
set -u
NS="${*:-1 2 3}"
CFG=/home/mpc/.config/ardour8/config
OUT=/var/log/mpcpi-threadsweep.txt

[ -f "$CFG" ] || { echo "no ardour config at $CFG" >&2; exit 1; }
cp "$CFG" "$CFG.sweep-backup"
restore() {
	mv "$CFG.sweep-backup" "$CFG" 2>/dev/null
	chown mpc:mpc "$CFG" 2>/dev/null
}
trap restore EXIT INT TERM

: > "$OUT"
for n in $NS; do
	sed -i "s/\(name=\"processor-usage\" value=\"\)[0-9]*\"/\1$n\"/" "$CFG"
	chown mpc:mpc "$CFG"
	got=$(grep -o 'processor-usage" value="[0-9]*"' "$CFG")
	echo "=== processor-usage=$n ($got) ===" | tee -a "$OUT"
	# --line-buffered or nothing appears until the config finishes: grep
	# block-buffers when its stdout is a pipe, so a sweep that takes
	# twelve minutes shows an empty log for four of them and reads as a
	# hang. The run is long enough that watching it matters.
	ACTIVE=none sh /opt/mpc-pi-src/scripts/daw/measure-xruns.sh 48 32 |
		grep --line-buffered -E "^(Q=|  q=)" | tee -a "$OUT"
done
echo SWEEP-DONE | tee -a "$OUT"
