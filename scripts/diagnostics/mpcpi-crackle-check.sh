#!/bin/sh
# One block of numbers that says whether the audio path is healthy.
#
# Run it before and after every change that adds load - Ardour, the USB gadget,
# a smaller quantum. Everything here is a metric that survived being wrong:
#
#   realtime %      what fraction of the audio the machine generated actually
#                   reached PipeWire. Below ~99% means audio is being DROPPED
#                   before the graph ever sees it, and no buffer tuning helps.
#                   This is the number that was 9.7% while every other counter
#                   looked fine. Needs MAME_PIPEWIRE_STATS=1.
#   underruns/s     MAME's own ring running short. Padded with a repeated
#                   sample, so it is a buzz, not a gap, and no zero-hunting
#                   detector can see it.
#   codec xruns     the device missing a deadline. Real, and separate from the
#                   two above.
#   RUNQ_WAIT       per thread, milliseconds spent runnable-but-not-running.
#                   The audio threads must be ~0. If they are not, they are
#                   being preempted or starved and the rest is noise.
#
# NOT used, deliberately: pw-top's ERR column. It is not a dropout counter, it
# has cost this project days twice, and every conclusion ever drawn from it has
# had to be retracted. See docs/audio-chain.md.
set -eu

secs="${1:-20}"
label="${2:-check}"
export XDG_RUNTIME_DIR=/run/user/1001
as_mpc() { sudo -u mpc env XDG_RUNTIME_DIR=/run/user/1001 "$@"; }

pid=$(pgrep -x mpc | head -1) || { echo "emulator not running"; exit 1; }

printf '=== %s (%ss) ===\n' "$label" "$secs"
quantum=$(as_mpc timeout 8 pw-top -b -n 3 2>/dev/null |
    awk '$1 == "R" && $3 ~ /^[0-9]+$/ && $3 > 0 { q = $3; r = $4 }
         END { if (q) printf "%s frames at %s Hz", q, r; else print "UNKNOWN" }')
printf 'quantum : %s\n' "$quantum"

# The ERR column on the ALSA DRIVER row is the device's xrun count, which is
# real. The same column on a CLIENT row is not a dropout counter - that is the
# one that has repeatedly misled this project. Only the driver row is read here.
codec_xruns() {
    as_mpc timeout 6 pw-top -b -n 2 2>/dev/null |
        awk '/alsa_output/ { e = $9 } END { print e + 0 }'
}
xrun_before=$(codec_xruns)

snap() { for t in "/proc/$pid/task/"*; do
             printf '%s %s %s\n' "${t##*/}" "$(cat "$t/comm")" "$(cat "$t/schedstat")"
         done; }
snap > /tmp/cc-a
sleep "$secs"
snap > /tmp/cc-b

xrun_after=$(codec_xruns)

journalctl -u mpcpi-emulator --since "-${secs}s" --no-pager -o cat > /tmp/cc-log || true

corrections=$(grep -c "audio buffer correction on stream 1" /tmp/cc-log || true)
if [ "${corrections:-0}" -gt 0 ]; then
    awk -v c="$corrections" -v s="$secs" \
        'BEGIN { f = c * 500 * 64; printf "realtime: %.1f%% (%d frames delivered)\n", 100*f/(44100*s), f }'
else
    printf 'realtime: UNKNOWN - set MAME_PIPEWIRE_STATS=1 to measure it\n'
fi

grep "audio buffer event" /tmp/cc-log 2>/dev/null |
  sed 's/.*on stream \([0-9]*\): underruns=[0-9]* (+\([0-9]*\)).*/\1 \2/' |
  awk -v s="$secs" '{ u[$1] += $2 }
       END { if (!length(u)) print "underruns: 0 reported"
             for (k in u) printf "underruns: stream %s = %d (%.1f/s)\n", k, u[k], u[k]/s }'

printf 'codec xruns: %s -> %s\n' "${xrun_before:-?}" "${xrun_after:-?}"

# No process substitution: /bin/sh here is dash.
sort -k1,1 /tmp/cc-a > /tmp/cc-a.s
sort -k1,1 /tmp/cc-b > /tmp/cc-b.s
join -j1 /tmp/cc-a.s /tmp/cc-b.s |
  awk '{ printf "  %-7s %-13s ran=%7.1fms RUNQ_WAIT=%8.1fms\n",
         $1, $2, ($7-$3)/1e6, ($8-$4)/1e6 }'
