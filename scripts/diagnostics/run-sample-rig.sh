#!/usr/bin/env bash
# Measure the MPC2000XL's sampling path end to end, on the desktop.
#
# A known stereo probe - 440 Hz LEFT, 660 Hz RIGHT - is played into the
# machine's RECORD IN while :speaker is captured, and sample-rig.lua drives the
# panel from inside the machine. analyze-sample-rig.py then reports how much of
# each tone reached each output during each stage, which is what turns "it
# sounds wrong" into a number. Everything the sampling work found today was
# found this way after hours of listen-and-patch had not.
#
# Two wiring details are not optional, both learned the hard way:
#
#   * pw-record MUST be told --target 0. Left to autoconnect it attaches to the
#     default SOURCE - the machine's physical microphone - and then records the
#     room, which is the speakers playing the very signal under test. That
#     reads as a plausible but wrong result: a hard-right monitor appears in
#     both channels at almost equal level.
#   * the links to :speaker must be made by hand. pw-record --target :speaker
#     produces a file of silence.
#
#   scripts/diagnostics/run-sample-rig.sh [outdir]
#
#   MPCPI_BUNDLE   bundle directory holding bin/mpc and roms (required)
#   MPCPI_IMAGE    floppy image to boot (default results/projects/...)
#   MPCPI_PROBE    probe wav; generated if absent
#   MPCPI_TRACE    if set, journal every DSP register access to <outdir>/dsp.trace
set -u

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
out=${1:-${TMPDIR:-/tmp}/mpc-sample-rig}
bundle=${MPCPI_BUNDLE:-}
image=${MPCPI_IMAGE:-$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img}
probe=${MPCPI_PROBE:-$out/probe.wav}
stages=${MAME_MPC_SAMPLE_STAGE_SECS:-8}

if [[ -z "$bundle" || ! -x "$bundle/bin/mpc" ]]; then
    printf 'error: set MPCPI_BUNDLE to a bundle directory containing bin/mpc\n' >&2
    exit 1
fi

mkdir -p "$out"
rm -f "$out"/rig.log "$out"/rig.wav "$out"/marks "$out"/stages "$out"/dsp.trace

# The probe is deliberately two pure tones, one per channel: a single-bin DFT
# then separates "which input" from "which output" without any alignment.
if [[ ! -f "$probe" ]]; then
    sox -n -r 48000 -b 16 -c 1 "$out/_l.wav" synth 120 sine 440 vol 0.5
    sox -n -r 48000 -b 16 -c 1 "$out/_r.wav" synth 120 sine 660 vol 0.5
    sox -M "$out/_l.wav" "$out/_r.wav" "$probe"
    rm -f "$out/_l.wav" "$out/_r.wav"
fi

pkill -x mpc >/dev/null 2>&1
sleep 3
# The graph lease outlives a killed emulator and blocks the next one.
rm -f "${XDG_RUNTIME_DIR:-/run/user/$UID}"/mpc-pi-pipewire-graph-*.lock

# A null sink at the graph rate stands in for whatever feeds RECORD IN.
pactl list sinks short 2>/dev/null | grep -q mpc_sampler_in || \
    pactl load-module module-null-sink sink_name=mpc_sampler_in \
        sink_properties=device.description=MPC-Sampler-Input rate=48000 >/dev/null 2>&1

trace_env=()
[[ -z "${MPCPI_TRACE:-}" ]] || trace_env=(MAME_MPC_DSP_TRACE="$out/dsp.trace")

cd "$bundle"
env MAME_MPC_SAMPLE_DEBUG=1 MAME_MPC_SAMPLE_STAGE_SECS="$stages" \
    MAME_MPC_SAMPLE_MARKS="$out/stages" "${trace_env[@]}" \
    setsid nohup ./bin/mpc mpc2000xl \
    -rompath ./roms -bios default -sound pipewire -samplerate 48000 \
    -flop "$image" \
    -skip_gameinfo -autoboot_script "$repo_root/scripts/diagnostics/sample-rig.lua" \
    -video opengl -window -resolution 800x400 \
    -pluginspath ./plugins -plugin layout \
    > "$out/rig.log" 2>&1 < /dev/null &

for _ in $(seq 40); do
    pw-link -i 2>/dev/null | grep -q '^:mic:input_FL$' && break
    sleep 1
done
for ch in FL FR; do
    pw-link "mpc_sampler_in:monitor_$ch" ":mic:input_$ch" 2>/dev/null
done

pw-play --target mpc_sampler_in "$probe" >/dev/null 2>&1 &
play_pid=$!
pw-record --target 0 --rate 48000 "$out/rig.wav" >/dev/null 2>&1 &
rec_pid=$!
sleep 2
for ch in FL FR; do pw-link ":speaker:output_$ch" "pw-record:input_$ch" 2>/dev/null; done
start=$(date +%s.%N)

# Stage boundaries as wall-clock offsets into the capture. Polled rather than
# derived from the script's own waits because the boot is not reproducible to
# the second and the capture starts whenever PipeWire is ready.
touch "$out/stages"
seen=""
for _ in $(seq 20000); do
    while read -r stage; do
        case " $seen " in
            *" $stage "*) ;;
            *) seen="$seen $stage"
               printf '%s %s\n' "$stage" \
                   "$(echo "$(date +%s.%N) - $start" | bc)" >> "$out/marks" ;;
        esac
    done < "$out/stages"
    case " $seen " in *" DONE "*) break ;; esac
    sleep 0.05
done

sleep 1
kill -INT "$rec_pid" 2>/dev/null; sleep 2
kill -9 "$rec_pid" "$play_pid" 2>/dev/null

printf 'capture %s\nmarks %s\n' "$out/rig.wav" "$out/marks"
python3 "$repo_root/scripts/diagnostics/analyze-sample-rig.py" "$out/rig.wav" "$out/marks"
