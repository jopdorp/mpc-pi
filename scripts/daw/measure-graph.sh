#!/bin/sh
# Measure the running graph with PipeWire's own accounting.
#
# Three metrics were tried before this one and each lied in its own way.
# Ardour's AudioEngine:get_dsp_load() reports 0.00% when PipeWire drives
# the graph rather than Ardour. Reading /proc/self/stat from inside
# luasession measures a process whose audio callback may not be being
# called at all. Both produce confident zeros.
#
# pw-top counts what the driver actually did: QUANT is the period in
# samples, BUSY is how long the node's callback took, and ERR is xruns.
# BUSY/period is the only ratio that decides whether the instrument
# crackles, and it is measured by the thing doing the scheduling.
#
#   measure-graph.sh <quantum> [seconds]
set -u
Q="${1:-64}"
SECS="${2:-20}"
U=$(id -u mpc)
R="sudo -u mpc env XDG_RUNTIME_DIR=/run/user/$U"

$R pw-metadata -n settings 0 clock.force-quantum "$Q" >/dev/null 2>&1
sleep 2

# -b is batch mode; each -n iteration prints the whole node table once.
out=$($R timeout $((SECS + 5)) pw-top -b -n "$SECS" 2>/dev/null)

printf 'quantum requested: %s\n' "$Q"
printf '%s\n' "$out" | awk -v q="$Q" '
  # Columns: S ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME...
  $1 ~ /^[ICRS]$/ && $3 ~ /^[0-9]+$/ && $3 > 0 {
    name = ""
    for (i = 10; i <= NF; i++) name = name $i " "
    busy = $6; sub(/us$/, "", busy)
    err = $9
    if (busy + 0 > max[name]) max[name] = busy + 0
    sum[name] += busy + 0; n[name]++
    if (err + 0 > maxerr[name]) maxerr[name] = err + 0
    quant[name] = $3
  }
  END {
    printf "%-46s %7s %9s %9s %7s\n", "NODE", "QUANT", "BUSY-avg", "BUSY-max", "XRUNS"
    for (k in sum)
      printf "%-46s %7s %8.1fus %8.1fus %7d\n",
             substr(k, 1, 46), quant[k], sum[k]/n[k], max[k], maxerr[k]
  }'

# The period in microseconds, so the reader can do the division that
# matters without looking it up: 32 samples at 44.1k is 725us.
printf 'period at %s samples / 44.1kHz: %.0fus\n' "$Q" \
	"$(awk -v q="$Q" 'BEGIN{print q/44100*1e6}')"
$R pw-metadata -n settings 0 clock.force-quantum 0 >/dev/null 2>&1
