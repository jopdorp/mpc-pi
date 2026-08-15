#!/usr/bin/env bash
# Phase 3: one loop lane on the linear timeline — record, loop by region
# duplication, overdub on the layer pair, undo. MAME provides the audio,
# mclk the MIDI clock. See docs/maschine-daw-design.md.
set -uo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
lua=${LUASESSION:-/usr/lib/ardour9/luasession}
base=$(mktemp -d /tmp/daw-phase3-XXXXXX)
export PHASE3_DIR=$base
runtime=$base/runtime; mkdir -p "$runtime"

ardour_prefix=$(dirname "$lua")
export ARDOUR_DATA_PATH=${ARDOUR_DATA_PATH:-/usr/share/$(basename "$ardour_prefix")}
export ARDOUR_CONFIG_PATH=${ARDOUR_CONFIG_PATH:-/etc/$(basename "$ardour_prefix")}
export ARDOUR_DLL_PATH=$ardour_prefix
export LD_LIBRARY_PATH=$ardour_prefix${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

mclk=$base/mclk
gcc -O2 -o "$mclk" "$repo_root/scripts/daw/mclk.c" -lasound || exit 1

echo "=== starting emulator"
# MAME stays off cores 8-11: it runs SCHED_RR and a free-running emulator
# starves the SCHED_OTHER clock sender and luasession, which stalls the
# slaved transport (measured: position froze at 0.7 s).
env MAME_BIN=$repo_root/.cache/mame/mpc MAME_RUNTIME_DIR=$runtime \
	MAME_CPUSET=0-7 MAME_TIMING_MASTER=audio PIPEWIRE_RATE_HZ=48000 \
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

n=0
until grep -q "PHASE2_PLAYBACK_READY" "$base/mame.log" 2>/dev/null; do
	sleep 2; n=$((n+1))
	if [ $n -gt 60 ] || ! kill -0 $mame_pid 2>/dev/null; then
		echo "FAIL: emulator never reached playback"; tail -5 "$base/mame.log"
		kill -9 -- -$mame_pid 2>/dev/null; exit 1
	fi
done
echo "=== emulator playing"

# Straight to a file: a grep in the pipeline buffers the live output and
# hides where a hang happens.
# Pinned opposite MAME: Ardour's butler/disk threads are SCHED_OTHER, and on
# MAME's SCHED_RR cores they starve — the slaved transport then freezes the
# moment recording engages (proven by the no-MAME isolation probe, which
# records fine).
taskset -c 8-11 "$lua" "$repo_root/scripts/daw/phase3-poc.lua" > "$base/lua.log" 2>&1 &
lua_pid=$!
tail -f "$base/lua.log" --pid=$lua_pid 2>/dev/null | \
	grep -vE "WARNING|Falling|buffer of size" &

n=0
until [ -f "$base/ready" ]; do
	sleep 1; n=$((n+1))
	if [ $n -gt 90 ] || ! kill -0 $lua_pid 2>/dev/null; then
		echo "FAIL: luasession never became ready"
		kill $lua_pid 2>/dev/null; kill -9 -- -$mame_pid 2>/dev/null; exit 1
	fi
done

taskset -c 8-11 "$mclk" "${SYNC_BPM:-120}" 8 &
clk_pid=$!
sleep 2
out_port=$(pw-link -o 2>/dev/null | grep -i "mclk" | head -1)
in_port=$(pw-link -i 2>/dev/null | grep -i "MIDI Clock in" | head -1)
echo "=== linking clock: ${out_port:-NONE} -> ${in_port:-NONE}"
if [ -z "$out_port" ] || [ -z "$in_port" ]; then
	echo "FAIL: clock or sync port missing"
	kill $clk_pid $lua_pid 2>/dev/null; kill -9 -- -$mame_pid 2>/dev/null
	exit 1
fi
pw-link "$out_port" "$in_port" || echo "WARN: pw-link rc=$?"

wait $lua_pid
rc=$?

kill $clk_pid 2>/dev/null
kill -- -$mame_pid 2>/dev/null
for _ in $(seq 10); do
	kill -0 $mame_pid 2>/dev/null || break
	sleep 1
done
kill -9 -- -$mame_pid 2>/dev/null
wait $mame_pid 2>/dev/null

echo "=== capture files:"
find "$PHASE3_DIR/session" -name "*.wav" -exec ls -la {} \; 2>/dev/null | head -6
exit $rc
