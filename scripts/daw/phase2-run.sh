#!/usr/bin/env bash
# Phase 2: MAME and headless Ardour sharing one PipeWire graph, Ardour
# recording the emulator's live output. See docs/maschine-daw-design.md.
set -uo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
lua=${LUASESSION:-/usr/lib/ardour9/luasession}
base=$(mktemp -d /tmp/daw-phase2-XXXXXX)
export PHASE2_DIR=$base/session
runtime=$base/runtime; mkdir -p "$runtime"

ardour_prefix=$(dirname "$lua")
export ARDOUR_DATA_PATH=${ARDOUR_DATA_PATH:-/usr/share/$(basename "$ardour_prefix")}
export ARDOUR_CONFIG_PATH=${ARDOUR_CONFIG_PATH:-/etc/$(basename "$ardour_prefix")}
export ARDOUR_DLL_PATH=${ARDOUR_DLL_PATH:-$ardour_prefix}
export LD_LIBRARY_PATH=$ardour_prefix${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

# The emulator is its own timing master and asks PipeWire for the graph
# driver role (node.want-driver). With Ardour slaved to MIDI clock the
# driver role then flaps and the chase collapses (proven by run 8 of the
# phase 3 debug). In DAW mode the ALSA device stays the only driver.
export PIPEWIRE_PROPS='{ node.want-driver = false }'

echo "=== starting emulator (playing demo project, pipewire out)"
env MAME_BIN=$repo_root/.cache/mame/mpc MAME_RUNTIME_DIR=$runtime \
	MAME_CPUSET=0-11 MAME_TIMING_MASTER=audio PIPEWIRE_RATE_HZ=48000 \
	MPC_VIDEO_MODE=none MPC_OUTPUT_MODE=stereo \
	MPC_PANEL_MODE=hle MPC_PANEL_TIMER_MODE=coalesced \
	MPC_V53_DISPATCH_MODE=direct MPC_V53_FETCH_MODE=window \
	MPC_V53_IDLE_MODE=skip MPC_V53_STATUS_MODE=hle \
	MPC_V53_EVENT_SERVICE_MODE=hle MPC_V53_FEED_FLAG_MODE=hle \
	MPC_V53_TICK_READ_MODE=hle MPC_V53_DIVIDE_MODE=superblock \
	MAME_BIOS=default \
	setsid "$repo_root/scripts/run-mpc.sh" mpc2000xl "${DAW_QUANTUM:-256}" \
	-flop "$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img" \
	-skip_gameinfo -video none \
	-autoboot_script "$repo_root/scripts/daw/phase2-autoboot.lua" \
	> "$base/mame.log" 2>&1 &
mame_pid=$!

# The autoboot prints this once boot is done and the demo song is playing.
n=0
until grep -q "PHASE2_PLAYBACK_READY" "$base/mame.log" 2>/dev/null; do
	sleep 2; n=$((n+1))
	if [ $n -gt 60 ] || ! kill -0 $mame_pid 2>/dev/null; then
		echo "FAIL: emulator never reached playback"; tail -5 "$base/mame.log"
		kill $mame_pid 2>/dev/null; exit 1
	fi
done
# MAME's native pipewire module names its nodes after the sound device tag:
# ":speaker" for the stereo output, ":fdc:..." for the floppy noise.
echo "=== emulator output ports:"
pw-link -o 2>/dev/null | grep "^:speaker" | head -4

"$lua" "$repo_root/scripts/daw/phase2-poc.lua" 2>&1 | \
	grep -vE "WARNING|Falling|buffer of size"
poc_rc=$?

# run-mpc.sh wraps the real emulator; kill the whole setsid group or MAME
# survives and keeps looping the demo song forever. The autoboot loop can
# swallow SIGTERM, so escalate to SIGKILL rather than hang in wait.
kill -- -$mame_pid 2>/dev/null || kill $mame_pid 2>/dev/null
for _ in $(seq 10); do
	kill -0 $mame_pid 2>/dev/null || break
	sleep 1
done
kill -9 -- -$mame_pid 2>/dev/null
wait $mame_pid 2>/dev/null
echo "=== capture files:"
find "$PHASE2_DIR" -name "*.wav" -exec ls -la {} \; | head -4
# Assert the capture is not silence.
python3 - "$PHASE2_DIR" <<'PY'
import sys, glob, struct, math
files = glob.glob(sys.argv[1] + "/interchange/**/*.wav", recursive=True)
if not files:
    print("VERDICT: no capture files"); sys.exit(1)
worst = 0.0
for f in files:
    data = open(f, 'rb').read()
    idx = data.find(b'data')
    body = data[idx+8: idx+8+2*48000*4]
    if len(body) < 4:
        continue
    n = len(body)//2
    s = struct.unpack(f'<{n}h', body[:n*2])
    rms = math.sqrt(sum(x*x for x in s)/max(1,len(s)))
    print(f"  {f.split('/')[-1]}: rms={rms:.1f}")
    worst = max(worst, rms)
print("VERDICT:", "SIGNAL CAPTURED" if worst > 50 else "SILENCE - routing failed")
sys.exit(0 if worst > 50 else 1)
PY
