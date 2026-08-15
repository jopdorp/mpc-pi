#!/usr/bin/env bash
# Verify the emulator transport export: boot the demo project, play, and
# check that /dev/shm/mpc-transport advances at 1000 ms/s while playing.
# See docs/maschine-daw-design.md, "Synchronization".
set -uo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
base=$(mktemp -d /tmp/daw-tex-XXXXXX)
runtime=$base/runtime; mkdir -p "$runtime"
export MPC_TRANSPORT_PATH=${MPC_TRANSPORT_PATH:-$base/mpc-transport}

env MAME_BIN=$repo_root/.cache/mame/mpc MAME_RUNTIME_DIR=$runtime \
	MAME_CPUSET=0-7 MPC_VIDEO_MODE=none MPC_OUTPUT_MODE=stereo \
	MPC_PANEL_MODE=hle MPC_PANEL_TIMER_MODE=coalesced \
	MPC_V53_DISPATCH_MODE=direct MPC_V53_FETCH_MODE=window \
	MPC_V53_IDLE_MODE=skip MPC_V53_STATUS_MODE=hle \
	MPC_V53_EVENT_SERVICE_MODE=hle MPC_V53_FEED_FLAG_MODE=hle \
	MPC_V53_TICK_READ_MODE=hle MPC_V53_DIVIDE_MODE=superblock \
	MAME_BIOS=default MPC_TRANSPORT_PATH="$MPC_TRANSPORT_PATH" \
	MPC_TRANSPORT_EXPORT_LUA="$repo_root/scripts/daw/transport-export.lua" \
	setsid "$repo_root/scripts/run-mpc.sh" mpc2000xl "${DAW_QUANTUM:-256}" \
	-flop "$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img" \
	-skip_gameinfo -video none \
	-autoboot_script "$repo_root/scripts/daw/transport-export-probe.lua" \
	> "$base/mame.log" 2>&1 &
mame_pid=$!

n=0
until [ -s "$MPC_TRANSPORT_PATH" ]; do
	sleep 2; n=$((n+1))
	if [ $n -gt 60 ] || ! kill -0 $mame_pid 2>/dev/null; then
		echo "FAIL: export file never appeared"; tail -5 "$base/mame.log"
		kill -9 -- -$mame_pid 2>/dev/null; exit 1
	fi
done
echo "=== export live: $(cat "$MPC_TRANSPORT_PATH")"

# Compare the counter against EMULATED time, not wall time: these
# harnesses run -nothrottle, so the emulator is faster than realtime. The
# counter must advance 1000 units per emulated second.
read -r p0 ms0 t0 < "$MPC_TRANSPORT_PATH"
sleep 4
read -r p1 ms1 t1 < "$MPC_TRANSPORT_PATH"
kill -9 -- -$mame_pid 2>/dev/null

rate=$(python3 -c "print(f'{($ms1-$ms0)/max(1e-6,$t1-$t0):.1f}')")
echo "playing: $p0 -> $p1   elapsed_ms: $ms0 -> $ms1   emu_s: $t0 -> $t1"
echo "counter rate: $rate units per emulated second (expect ~1000)"
ok=$(python3 -c "print(1 if 950 <= $rate <= 1050 else 0)")
if [ "$p1" = "1" ] && [ "$ok" = "1" ]; then
	echo "VERDICT: TRANSPORT EXPORT OK"
	exit 0
fi
echo "VERDICT: export not tracking playback"
exit 1
