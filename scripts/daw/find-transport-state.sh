#!/usr/bin/env bash
# One-shot discovery: find the sequencer's running position in emulated RAM
# so daw-ctl can track the MPC's bar grid without a MIDI link.
# See docs/maschine-daw-design.md, "MIDI sync out does not work".
set -uo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
base=$(mktemp -d /tmp/daw-transport-XXXXXX)
runtime=$base/runtime; mkdir -p "$runtime"

env MAME_BIN=$repo_root/.cache/mame/mpc MAME_RUNTIME_DIR=$runtime \
	MAME_CPUSET=0-11 MPC_VIDEO_MODE=none MPC_OUTPUT_MODE=stereo \
	MPC_PANEL_MODE=hle MPC_PANEL_TIMER_MODE=coalesced \
	MPC_V53_DISPATCH_MODE=direct MPC_V53_FETCH_MODE=window \
	MPC_V53_IDLE_MODE=skip MPC_V53_STATUS_MODE=hle \
	MPC_V53_EVENT_SERVICE_MODE=hle MPC_V53_FEED_FLAG_MODE=hle \
	MPC_V53_TICK_READ_MODE=hle MPC_V53_DIVIDE_MODE=superblock \
	MAME_BIOS=default \
	SCAN_BEGIN=${SCAN_BEGIN:-0} SCAN_END=${SCAN_END:-131072} \
	setsid "$repo_root/scripts/run-mpc.sh" mpc2000xl 256 \
	-flop "$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img" \
	-skip_gameinfo -video none \
	-autoboot_script "$repo_root/scripts/daw/find-transport-state.lua" \
	> "$base/mame.log" 2>&1 &
mame_pid=$!

n=0
until grep -q "TRANSPORT_SCAN_END" "$base/mame.log" 2>/dev/null; do
	sleep 3; n=$((n+1))
	if [ $n -gt 120 ] || ! kill -0 $mame_pid 2>/dev/null; then
		break
	fi
done
kill -9 -- -$mame_pid 2>/dev/null
grep -E "TRANSPORT_" "$base/mame.log" | head -50
echo "log: $base/mame.log"
