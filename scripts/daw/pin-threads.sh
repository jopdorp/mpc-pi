#!/bin/sh
# Put each of Ardour's threads where it belongs.
#
# Process-wide affinity is too blunt. Ardour runs a dozen threads and
# only three of them are realtime: the callback thread and its DSP
# workers. The rest - butler, peak-file builders, the analyzer, the
# trigger-box worker, IO - are ordinary threads doing disk and
# housekeeping work, and pinning the whole process to the audio cores
# drags all of them onto exactly the cores that must stay quiet.
#
# Two reasons that hurts even though they cannot preempt an RT thread:
# they take locks the RT threads then wait on, and they keep more than
# one task runnable per core, which is precisely the condition
# nohz_full needs absent in order to stop the tick.
#
# So: one RT worker per isolated core, everything else on core 0.
#
#   pin-threads.sh [pid]
set -u
PID="${1:-$(pgrep -x luasession | head -1)}"
[ -n "$PID" ] || { echo "no luasession running" >&2; exit 1; }

HOUSEKEEPING="${MPCPI_HOUSEKEEPING:-0}"
AUDIO_CORES="${MPCPI_AUDIO_CORES:-2 3}"

# Move by NAME, never by "everything that is not realtime".
#
# The first version moved all 34 non-RT threads to core 0 and killed the
# session outright: PipeWire's own client-side threads live in this
# process, they are not SCHED_FIFO, and exiling them from the audio
# cores is exiling the thing that delivers the callback. The client
# dropped out of the graph mid-measurement.
#
# These are the threads that do disk and analysis work and have no part
# in a callback. Anything not named here is left exactly where the
# engine put it, which is the conservative default: a thread whose role
# is not understood is not a thread to relocate.
HOUSEKEEPERS="butler PeakFileBuilder Analyzer TriggerBox DeviceList
              EngineWatchdog IO- FileSource AutoLoop"

moved=0
for tid in $(ls "/proc/$PID/task" 2>/dev/null); do
	comm=$(cat "/proc/$PID/task/$tid/comm" 2>/dev/null) || continue
	for want in $HOUSEKEEPERS; do
		case "$comm" in
			*"$want"*)
				taskset -pc "$HOUSEKEEPING" "$tid" >/dev/null 2>&1 &&
					moved=$((moved + 1))
				printf '  %-18s tid=%-7s -> cpu %s\n' \
					"$comm" "$tid" "$HOUSEKEEPING"
				break
				;;
		esac
	done
done

echo "moved $moved housekeeping threads to core $HOUSEKEEPING;"
echo "realtime and transport threads left where the engine placed them"
