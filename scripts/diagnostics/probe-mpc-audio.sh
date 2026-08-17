#!/usr/bin/env bash
# Does the emulator actually put audio into the graph? Measured, on the Pi.
#
# This exists because every previous attempt to answer that question was
# wrong. `pw-record --target <node>` does NOT record the node you name: it
# records the default source. On this appliance the default source is the USB
# codec's microphone input, so the tool cheerfully returned peak≈21000 with
# nothing connected and nothing playing, and several conclusions were built on
# that number before it was caught.
#
# The reliable shape is the one mpc-monitor-route.sh already uses for
# playback: create a node with autoconnect DISABLED so session policy cannot
# attach it to anything, then link the ports you want by name and record only
# what you linked. If the link fails, the recording is empty rather than
# quietly full of some other signal - a wrong answer becomes no answer.
#
# Usage: probe-mpc-audio.sh [seconds] [--no-notes]
#   --no-notes  do not inject anything; measure whatever is already playing
#               (use this to check the sequencer, or to listen in while
#               somebody plays the pads by hand)
set -uo pipefail

SECONDS_TO_RECORD=${1:-6}
INJECT=1
[[ "${2:-}" == "--no-notes" ]] && INJECT=0

SOURCE_NODE=${MPC_PROBE_SOURCE:-:speaker}
MIDI_DEV=${MPC_PROBE_MIDI:-/dev/snd/midiC0D0}
OUT=${MPC_PROBE_WAV:-/tmp/mpc-probe.wav}
PROBE=mpcprobe
LOG=${MPC_PROBE_LOG:-/tmp/mpc-probe.log}

# On the appliance the graph belongs to the `mpc` user and this script is run
# by root, so it has to cross into that session. On the development host there
# is no `mpc` user and the graph is simply ours - probing there must not try to
# sudo into a user that does not exist.
if id -u mpc >/dev/null 2>&1 && [[ "$(id -un)" != mpc ]]; then
    mpc_uid=$(id -u mpc)
    run_as_mpc() { sudo -u mpc env XDG_RUNTIME_DIR="/run/user/$mpc_uid" "$@"; }
elif [[ "$(id -un)" == mpc ]]; then
    mpc_uid=$(id -u mpc)
    run_as_mpc() { env XDG_RUNTIME_DIR="/run/user/$mpc_uid" "$@"; }
else
    run_as_mpc() { "$@"; }
fi

probe_owner=$(id -un)
[[ "$(id -un)" == root ]] && id -u mpc >/dev/null 2>&1 && probe_owner=mpc

rm -f "$OUT"

# Stop the recorder with a timeout INSIDE the sudo, not by killing the pid
# from out here. `sudo -u mpc pw-record &` makes $! the sudo process, and
# killing sudo leaves pw-record running as mpc: the wav is never finalised, the
# orphan holds stdout open, and an ssh invocation of this script hangs until it
# is killed from the outside. SIGINT rather than SIGTERM because pw-cat handles
# INT by closing the file cleanly, which is what makes the header valid.
#
# autoconnect=false is the other half of the point: without it WirePlumber
# attaches this capture stream to the default source and we measure a
# microphone again.
run_as_mpc timeout -s INT "$((SECONDS_TO_RECORD + 4))" pw-record \
    --properties "{ node.name = \"$PROBE\", node.autoconnect = false }" \
    --channels 2 --rate 44100 "$OUT" >"$LOG" 2>&1 &
probe_pid=$!
cleanup() {
    pkill -u "$probe_owner" -f "node.name = \"$PROBE\"" 2>/dev/null
}
trap cleanup EXIT

# Wait for the ports to exist rather than sleeping a guessed amount.
for _ in $(seq 1 40); do
    if run_as_mpc pw-link -i 2>/dev/null | grep -q "^$PROBE:"; then break; fi
    sleep 0.25
done
if ! run_as_mpc pw-link -i 2>/dev/null | grep -q "^$PROBE:"; then
    # Say WHY. This failed intermittently and reported only "never appeared",
    # because pw-record's own stderr was going to /dev/null - the one place
    # the reason was written.
    printf 'probe: capture node never appeared. pw-record said:\n' >&2
    sed 's/^/  /' "$LOG" >&2 2>/dev/null || printf '  (nothing)\n' >&2
    exit 1
fi

linked=0
for pair in FL FR; do
    if run_as_mpc pw-link "$SOURCE_NODE:output_$pair" "$PROBE:input_$pair" \
            2>/dev/null; then
        linked=$((linked + 1))
    else
        printf 'probe: could not link %s:output_%s -> %s:input_%s\n' \
            "$SOURCE_NODE" "$pair" "$PROBE" "$pair" >&2
    fi
done
if (( linked == 0 )); then
    printf 'probe: nothing linked; refusing to report a number\n' >&2
    exit 1
fi
printf 'probe: %d/2 channels linked from %s\n' "$linked" "$SOURCE_NODE"

if (( INJECT )); then
    # The same bytes the Maschine hub writes: notes 36..51 on channel 1, which
    # is the range the internal-pads path maps to pads A01..A16.
    printf 'probe: injecting pads 36..51 into %s\n' "$MIDI_DEV"
    # Output redirected: a background child that inherits stdout keeps an ssh
    # channel open after the script itself has finished.
    python3 - "$MIDI_DEV" >/dev/null 2>&1 <<'PYEOF' &
import sys, time
with open(sys.argv[1], "wb", buffering=0) as f:
    for note in range(36, 52):
        f.write(bytes([0x90, note, 100]))
        time.sleep(0.18)
        f.write(bytes([0x80, note, 0]))
        time.sleep(0.06)
PYEOF
fi

# The recorder ends itself; just wait for it so the wav is complete.
wait "$probe_pid" 2>/dev/null
cleanup
trap - EXIT

python3 - "$OUT" <<'PYEOF'
import struct, sys, wave
try:
    w = wave.open(sys.argv[1])
except Exception as exc:
    print("probe: unreadable recording: %s" % exc)
    raise SystemExit(1)
n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
if n == 0:
    print("probe: recording is empty - the link carried nothing")
    raise SystemExit(1)
raw = w.readframes(n)
s = struct.unpack("<%dh" % (len(raw) // 2), raw)
print("probe: %.2fs at %dHz, %d channels" % (n / float(sr), sr, ch))
verdict = 0
for c in range(ch):
    d = s[c::ch]
    peak = max(abs(x) for x in d)
    nz = sum(1 for x in d if x) / float(len(d)) * 100
    print("  ch%d peak=%6d  non-zero=%5.2f%%  %s"
          % (c, peak, nz, "AUDIO" if peak > 200 else "SILENT"))
    verdict = max(verdict, peak)
print("probe: %s" % ("AUDIO PRESENT" if verdict > 200 else "SILENT"))

# Crackle has to be located, not just heard. PipeWire's own error counters can
# read zero on every node while the player still hears crackling, because a
# dropout below PipeWire - in the USB frame schedule or the ALSA period - is
# invisible to them. So characterise the CONTENT here: if what the graph
# carries is smooth, the crackle is downstream of this measurement.
L = s[0::ch]
if len(L) > 2:
    jumps = sum(1 for i in range(1, len(L)) if abs(L[i] - L[i - 1]) > 12000)
    runs, run = 0, 0
    for x in L:
        if x == 0:
            run += 1
        else:
            if run > 64:
                runs += 1
            run = 0
    mean_delta = sum(abs(L[i] - L[i - 1]) for i in range(1, len(L))) / (len(L) - 1)
    print("  content: %d one-sample jumps >12000, %d silent gaps >64 samples,"
          " mean |delta|=%.0f" % (jumps, runs, mean_delta))
    if jumps == 0 and runs == 0:
        print("  content is smooth - any crackle is BELOW this point"
              " (USB/ALSA), not in the graph")
raise SystemExit(0 if verdict > 200 else 2)
PYEOF
