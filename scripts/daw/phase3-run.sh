#!/usr/bin/env bash
# Phase 3: one loop lane on the linear timeline — record, loop by region
# duplication, overdub on the layer pair, undo. MAME provides the audio.
# The Ardour transport free-runs internally: the emulator and Ardour share
# one hardware clock so there is nothing to chase; tempo/bar phase reaches
# daw-ctl straight from the MPC's MIDI clock, outside Ardour (see the
# synchronization section of docs/maschine-daw-design.md).
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

# The emulator is its own timing master and asks PipeWire for the graph
# driver role (node.want-driver); the flapping driver role destabilizes
# other clients' scheduling. In DAW mode the ALSA device stays the driver.
export PIPEWIRE_PROPS='{ node.want-driver = false }'

echo "=== starting emulator"
# MAME stays off cores 8-11: it runs SCHED_RR and starves SCHED_OTHER audio
# helpers; luasession is pinned opposite.
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

# Interpose a server-side null sink between the emulator and Ardour:
# linking a pw-jack client directly to MAME's stream node makes the client
# miss cycles (phase 3 runs 7/9; run 8 without links held). The null sink
# is processed punctually every cycle regardless of the emulator stream's
# own pacing; Ardour records from its monitor ports. (pw-loopback's virtual
# nodes never appear in the JACK view — the pactl null sink does.)
tap_module=$(pactl load-module module-null-sink sink_name=mpc_tap channels=2)
sleep 2
for ch in FL FR; do
	pw-link ":speaker:output_$ch" "mpc_tap:playback_$ch" \
		|| echo "WARN: tap link $ch rc=$?"
done
export MPC_PORT_PATTERN=mpc_tap

# Straight to a file: a grep in the pipeline buffers the live output and
# hides where a hang happens.
taskset -c 8-11 "$lua" "$repo_root/scripts/daw/phase3-poc.lua" > "$base/lua.log" 2>&1 &
lua_pid=$!
tail -f "$base/lua.log" --pid=$lua_pid 2>/dev/null | \
	grep -vE "WARNING|Falling|buffer of size" &

wait $lua_pid
rc=$?

[ -n "${tap_module:-}" ] && pactl unload-module "$tap_module" 2>/dev/null
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
