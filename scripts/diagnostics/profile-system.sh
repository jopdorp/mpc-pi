#!/bin/sh
# One picture of the whole machine: every thread, every interrupt.
#
# This exists because single-variable guessing ran out. The delivered
# audio carried about ten defects a second, and that rate survived
# changing the channel count (18 -> 6 -> 2), the gadget interrupt's
# core and priority, its URB queue depth, its ALSA headroom, and the
# tone player's own scheduling class. Six levers, no movement. When
# that many educated guesses miss, the missing thing is not another
# guess - it is the map.
#
# So this writes down, for every thread on the box:
#
#   CPU%          how much of a core it burns
#   WAIT/s        milliseconds per second it spent ON the runqueue,
#                 runnable but not running - the direct measure of
#                 being starved by someone else
#   WAIT/switch   mean microseconds of that wait per schedule, which
#                 is the closest thing to a tail available without
#                 tracing (bpftrace gives the real histogram; see
#                 --trace)
#   VOL / INVOL   context switches per second, split. An RT audio
#                 thread should show ~one voluntary switch per callback
#                 and almost no involuntary ones; involuntary switches
#                 are someone preempting it.
#   POL/PRI/CPU   scheduling policy, priority, and the core it was on
#
# and for every interrupt: its rate and its affinity mask.
#
# Output is a table on stdout and a TSV next to it, so a plan can be
# computed from the numbers rather than argued from intuition.
#
#   profile-system.sh [seconds] [out.tsv]      default: 20, /var/log/mpcpi-profile.tsv
set -u
W="${1:-20}"
OUT="${2:-/var/log/mpcpi-profile.tsv}"
HZ=$(getconf CLK_TCK)
NCPU=$(grep -c ^processor /proc/cpuinfo)

snap_threads() {
	for t in /proc/[0-9]*/task/[0-9]*; do
		tid=${t##*/}
		comm=$(cat "$t/comm" 2>/dev/null) || continue
		# stat: 14=utime 15=stime 39=processor  (after the comm field,
		# which is parenthesised and may contain spaces - so cut at the
		# last ')' first, the standard way to parse this file)
		st=$(cat "$t/stat" 2>/dev/null) || continue
		rest=${st#*") "}
		# rest now starts at field 3 (state); utime is field 14 overall
		# = 12th token of rest, stime 13th, processor 37th
		set -- $rest
		[ $# -ge 37 ] || continue
		utime=$12; stime=$13; cpu=$37
		# schedstat: run_ns wait_ns timeslices
		ss=$(cat "$t/schedstat" 2>/dev/null) || ss="0 0 0"
		vol=$(awk '/^voluntary_ctxt/ {print $2}' "$t/status" 2>/dev/null)
		inv=$(awk '/^nonvoluntary_ctxt/ {print $2}' "$t/status" 2>/dev/null)
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$tid" "$comm" "$((utime + stime))" "$cpu" \
			"$(echo "$ss" | cut -d' ' -f2)" \
			"$(echo "$ss" | cut -d' ' -f3)" \
			"${vol:-0}" "${inv:-0}"
	done
}

snap_irqs() {
	awk 'NR > 1 {
		irq = $1; sub(":", "", irq)
		if (irq !~ /^[0-9]+$/) next
		total = 0
		for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) total += $i
		name = $NF
		printf "%s\t%s\t%s\n", irq, total, name
	}' /proc/interrupts
}

snap_threads > /tmp/prof-a.$$
snap_irqs > /tmp/irq-a.$$
sleep "$W"
snap_threads > /tmp/prof-b.$$
snap_irqs > /tmp/irq-b.$$

# Policy and priority come from a single ps pass rather than 3000 chrt
# forks; ps prints them for every thread in one go.
ps -eLo tid=,class=,rtprio= 2>/dev/null | awk '{print $1"\t"$2"\t"$3}' > /tmp/pol.$$

{
	printf 'TID\tCOMM\tCPU_PCT\tWAIT_MS_PER_S\tWAIT_US_PER_SW\tVOL_PER_S\tINVOL_PER_S\tPOLICY\tPRIO\tCPU\n'
	awk -v w="$W" -v hz="$HZ" '
		FILENAME == ARGV[1] { pol[$1] = $2; pri[$1] = $3; next }
		FILENAME == ARGV[2] {
			t[$1] = $3; wait[$1] = $5; sw[$1] = $6; v[$1] = $7; i[$1] = $8
			next
		}
		{
			tid = $1
			if (!(tid in t)) next
			dt = $3 - t[tid]
			dwait = $5 - wait[tid]
			dsw = $6 - sw[tid]
			dv = $7 - v[tid]
			di = $8 - i[tid]
			cpu = dt * 100 / (hz * w)
			waitms = dwait / 1e6 / w
			waitus = (dsw > 0) ? dwait / dsw / 1000 : 0
			# Only print threads that did something: pure sleepers are
			# noise in a table this long.
			if (dt == 0 && dwait == 0 && dv == 0 && di == 0) next
			printf "%s\t%s\t%.2f\t%.3f\t%.1f\t%.1f\t%.1f\t%s\t%s\t%s\n",
				tid, $2, cpu, waitms, waitus, dv / w, di / w,
				(tid in pol) ? pol[tid] : "?",
				(tid in pri) ? pri[tid] : "-", $4
		}
	' /tmp/pol.$$ /tmp/prof-a.$$ /tmp/prof-b.$$ | sort -t"$(printf '\t')" -k4 -rn
} > "$OUT"

{
	printf '\nIRQ\tRATE_PER_S\tAFFINITY\tNAME\n'
	awk -v w="$W" '
		FILENAME == ARGV[1] { c[$1] = $2; next }
		{
			if (!($1 in c)) next
			r = ($2 - c[$1]) / w
			if (r < 1) next
			printf "%s\t%.0f\t%s\t%s\n", $1, r, "AFF", $3
		}
	' /tmp/irq-a.$$ /tmp/irq-b.$$ | while IFS="$(printf '\t')" read -r irq rate _ name; do
		aff=$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || echo "?")
		printf '%s\t%s\t%s\t%s\n' "$irq" "$rate" "$aff" "$name"
	done | sort -t"$(printf '\t')" -k2 -rn
} >> "$OUT"

rm -f /tmp/prof-a.$$ /tmp/prof-b.$$ /tmp/irq-a.$$ /tmp/irq-b.$$ /tmp/pol.$$

# The console view: the threads that actually matter, which are the
# ones that burn CPU or the ones that WAIT. A thread waiting 50ms per
# second is being starved 5% of the time, and that is invisible in top.
echo "=== threads by time spent waiting on a runqueue (${W}s window, ${NCPU} cores) ==="
head -1 "$OUT"
awk -F"$(printf '\t')" 'NR > 1 && NR < 22 && ($4 > 0.5 || $3 > 1.0)' "$OUT" |
	awk -F"$(printf '\t')" '{ printf "%-8s %-18s %6s%% %9s %9s %8s %8s %4s %4s %3s\n",
		$1, substr($2,1,18), $3, $4, $5, $6, $7, $8, $9, $10 }'
echo
echo "=== interrupts by rate ==="
sed -n '/^IRQ/,$p' "$OUT" | head -12 |
	awk -F"$(printf '\t')" '{ printf "%-6s %8s/s  cpu %-8s %s\n", $1, $2, $3, $4 }'
echo
echo "full table: $OUT"
