#!/usr/bin/env bash
# Find the sequencer tempo in emulated RAM, for one project image.
#
#   scripts/diagnostics/find-mpc-tempo.sh <image.img> [expected tenths]
#
# The expected value is the number on the MPC's own main screen times ten:
# "J:  86.0" is 860. Run it for two projects at different tempos and the
# address that answers correctly in both is the one daw-ctl wants; see
# scripts/daw/transport-export.lua, MPC_TEMPO_ADDR.
set -uo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=${1:?usage: find-mpc-tempo.sh <image.img> [tenths of a BPM]}
expect=${2:-860}
base=$(mktemp -d /tmp/mpc-tempo-XXXXXX)
runtime=$base/runtime; mkdir -p "$runtime"

env MAME_BIN="${MAME_BIN:-$repo_root/.cache/mame/mpc}" \
	MAME_RUNTIME_DIR="$runtime" \
	MAME_CPUSET="${MAME_CPUSET:-0-11}" MPC_VIDEO_MODE=none \
	MPC_OUTPUT_MODE="${MPC_OUTPUT_MODE:-stereo}" \
	MPC_PANEL_MODE=hle MPC_PANEL_TIMER_MODE=coalesced \
	MAME_BIOS=default MPC_TEMPO_EXPECT="$expect" \
	SCAN_BEGIN="${SCAN_BEGIN:-0}" SCAN_END="${SCAN_END:-524288}" \
	setsid "$repo_root/scripts/run-mpc.sh" mpc2000xl 256 \
	-flop "$image" -skip_gameinfo -video none \
	-autoboot_script "$repo_root/scripts/diagnostics/find-mpc-tempo.lua" \
	> "$base/mame.log" 2>&1 &
mame_pid=$!

n=0
until grep -q "TEMPO_SCAN_END" "$base/mame.log" 2>/dev/null; do
	sleep 3; n=$((n + 1))
	if [ $n -gt 100 ] || ! kill -0 $mame_pid 2>/dev/null; then break; fi
done
kill -9 -- -$mame_pid 2>/dev/null
grep -E "TEMPO_" "$base/mame.log"
echo "log: $base/mame.log"
