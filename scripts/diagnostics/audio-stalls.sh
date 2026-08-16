#!/bin/sh
# Ask what the audio process is doing when it misses a deadline.
#
# The reason this exists: at quantum 64 the graph runs at B/Q 0.55 - it
# uses just over half its period - and still xruns six times a second.
# A load problem cannot do that. Something stalls a callback for longer
# than the whole period, several times a second, while the average
# callback has 650us to spare.
#
# The candidates that produce exactly that shape, in the order they are
# worth checking on THIS board:
#
#   1. Page faults. The appliance netboots with its root on NFS, so a
#      major fault in the audio thread is a network round trip - and
#      Ardour mmaps its own text, every plugin .so, and the session's
#      audio files. mlockall is what a JACK client is supposed to do
#      about this, and pipewire-jack's module-rt grants rt.prio without
#      granting memlock.
#   2. Voluntary context switches inside the callback: a lock the RT
#      thread waits on, held by something that is not RT.
#   3. Involuntary ones: preemption on a core that is supposed to be
#      isolated.
#
# All three are counters that already exist. Sample them across a window
# and print the RATE, because the totals since process start say only
# that a thing once happened - most of it during session load.
#
#   audio-stalls.sh [seconds]        default 20
set -u
W="${1:-20}"

PID=$(pgrep -x luasession | head -1)
[ -n "$PID" ] || { echo "no luasession running - start a measurement first" >&2; exit 1; }

echo "pid $PID  window ${W}s"

lim=$(tr '\0' '\n' < "/proc/$PID/limits" 2>/dev/null |
	grep -i "max locked memory")
echo "  $lim"
lck=$(grep VmLck "/proc/$PID/status" | awk '{print $2, $3}')
rss=$(grep VmRSS "/proc/$PID/status" | awk '{print $2, $3}')
echo "  VmLck $lck   of VmRSS $rss"
case "$lck" in
	"0 kB")
		echo "  -> nothing is locked: every page of Ardour, of its plugins"
		echo "     and of this session is reclaimable, and this root is NFS"
		;;
esac

# Per-thread, because a process-wide number hides which thread stalls,
# and only the RT ones matter. Threads are named: the callback lives in
# a pw-data-loop, the workers in Ardour's own DSP threads.
snap() {
	for t in /proc/"$PID"/task/*; do
		tid=${t##*/}
		comm=$(cat "$t/comm" 2>/dev/null) || continue
		# utime/stime are fields 14/15, minflt 10, majflt 12
		set -- $(cut -d' ' -f10,12 "$t/stat" 2>/dev/null)
		vol=$(awk '/voluntary_ctxt_switches/ {print $2}' "$t/status" 2>/dev/null |
			head -1)
		nonvol=$(awk '/nonvoluntary_ctxt_switches/ {print $2}' "$t/status" \
			2>/dev/null | head -1)
		printf '%s %s %s %s %s %s\n' "$tid" "$comm" "${1:-0}" "${2:-0}" \
			"${vol:-0}" "${nonvol:-0}"
	done
}

snap > /tmp/stalls-a
sleep "$W"
snap > /tmp/stalls-b

printf '\n%-8s %-18s %8s %8s %9s %9s\n' \
	TID THREAD MINFLT MAJFLT VOL-CSW INVOL-CSW
awk -v w="$W" '
	NR == FNR { min[$1]=$3; maj[$1]=$4; vol[$1]=$5; inv[$1]=$6; name[$1]=$2; next }
	{
		dmin = $3 - min[$1]; dmaj = $4 - maj[$1]
		dvol = $5 - vol[$1]; dinv = $6 - inv[$1]
		if (dmin || dmaj || dvol || dinv)
			printf "%-8s %-18s %8d %8d %9d %9d\n", $1, $2, dmin, dmaj, dvol, dinv
	}
' /tmp/stalls-a /tmp/stalls-b | sort -k5 -rn

echo
echo "rates are per ${W}s. A realtime thread should show ~0 major faults"
echo "and one voluntary switch per callback (the wait for the next period)."
