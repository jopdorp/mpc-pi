#!/usr/bin/env bash
# Discover/verify the MPC2000XL sync-out enable sequence: run MAME with its
# MIDI out wired to "Midi Through Port-0", drive the panel via
# sync-out-autoboot.lua, then count MIDI clock (0xF8) events on the port.
# Iterate SYNCOUT_DOWNS / SYNCOUT_RIGHTS / SYNCOUT_DETENTS until CLOCK
# PRESENT.
set -uo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
base=$(mktemp -d /tmp/daw-syncout-XXXXXX)
runtime=$base/runtime; mkdir -p "$runtime"

aseqdump -p "Midi Through" > "$base/midi.log" 2>&1 &
dump_pid=$!

# The emulator is its own timing master and asks PipeWire for the graph
# driver role (node.want-driver). With Ardour slaved to MIDI clock the
# driver role then flaps and the chase collapses (proven by run 8 of the
# phase 3 debug). In DAW mode the ALSA device stays the only driver.
export PIPEWIRE_PROPS='{ node.want-driver = false }'

echo "=== starting emulator (midiout1 -> Midi Through Port-0)"
env MAME_BIN=$repo_root/.cache/mame/mpc MAME_RUNTIME_DIR=$runtime \
	MAME_CPUSET=0-11 MAME_TIMING_MASTER=audio PIPEWIRE_RATE_HZ=48000 \
	MPC_VIDEO_MODE=none MPC_OUTPUT_MODE=stereo \
	MPC_PANEL_MODE=${MPC_PANEL_MODE:-hle} \
	MPC_PANEL_TIMER_MODE=${MPC_PANEL_TIMER_MODE:-coalesced} \
	MPC_V53_DISPATCH_MODE=${MPC_V53_DISPATCH_MODE:-direct} \
	MPC_V53_FETCH_MODE=${MPC_V53_FETCH_MODE:-window} \
	MPC_V53_IDLE_MODE=${MPC_V53_IDLE_MODE:-skip} \
	MPC_V53_STATUS_MODE=${MPC_V53_STATUS_MODE:-hle} \
	MPC_V53_EVENT_SERVICE_MODE=${MPC_V53_EVENT_SERVICE_MODE:-hle} \
	MPC_V53_FEED_FLAG_MODE=${MPC_V53_FEED_FLAG_MODE:-hle} \
	MPC_V53_TICK_READ_MODE=${MPC_V53_TICK_READ_MODE:-hle} \
	MPC_V53_DIVIDE_MODE=${MPC_V53_DIVIDE_MODE:-superblock} \
	MAME_BIOS=default \
	SYNCOUT_DOWNS=${SYNCOUT_DOWNS:-1} SYNCOUT_RIGHTS=${SYNCOUT_RIGHTS:-0} \
	SYNCOUT_UPS=${SYNCOUT_UPS:-0} \
	SYNCOUT_DETENTS=${SYNCOUT_DETENTS:-1} \
	setsid "$repo_root/scripts/run-mpc.sh" mpc2000xl "${DAW_QUANTUM:-256}" \
	-flop "$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img" \
	-skip_gameinfo -video none \
	-midiout1 "Midi Through Port-0" \
	-autoboot_script "$repo_root/scripts/daw/sync-out-autoboot.lua" \
	> "$base/mame.log" 2>&1 &
mame_pid=$!

n=0
until grep -q "SYNCOUT_PLAYBACK_BEGIN" "$base/mame.log" 2>/dev/null; do
	sleep 2; n=$((n+1))
	if [ $n -gt 60 ] || ! kill -0 $mame_pid 2>/dev/null; then
		echo "FAIL: emulator never reached playback"; tail -8 "$base/mame.log"
		kill $dump_pid 2>/dev/null; kill -9 -- -$mame_pid 2>/dev/null; exit 1
	fi
done
grep "SYNCOUT_" "$base/mame.log"
echo "=== playing; sampling MIDI out for 8 s"
sleep 8

clocks=$(grep -c "Clock" "$base/midi.log" || true)
starts=$(grep -c "Start" "$base/midi.log" || true)
others=$(grep -vE "Clock|Start|Port|Source|Waiting" "$base/midi.log" | head -4)
echo "clock events: $clocks, start events: $starts"
[ -n "$others" ] && { echo "other events:"; echo "$others"; }

kill $dump_pid 2>/dev/null
kill -- -$mame_pid 2>/dev/null
for _ in $(seq 10); do kill -0 $mame_pid 2>/dev/null || break; sleep 1; done
kill -9 -- -$mame_pid 2>/dev/null

if [ "${clocks:-0}" -gt 50 ]; then
	echo "VERDICT: CLOCK PRESENT"
	exit 0
fi
echo "VERDICT: no clock (downs=${SYNCOUT_DOWNS:-1} rights=${SYNCOUT_RIGHTS:-0} detents=${SYNCOUT_DETENTS:-1})"
exit 1
