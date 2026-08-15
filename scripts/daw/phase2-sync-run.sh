#!/usr/bin/env bash
# Phase 2 sync: prove headless Ardour slaves to external MIDI clock.
# See docs/maschine-daw-design.md. The clock comes from scripts/daw/mclk.c
# (ALSA seq, kernel-timed); in the real appliance it comes from the MPC
# emulator's MIDI out.
set -uo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
lua=${LUASESSION:-/usr/lib/ardour9/luasession}
base=$(mktemp -d /tmp/daw-sync-XXXXXX)
export SYNC_DIR=$base

ardour_prefix=$(dirname "$lua")
export ARDOUR_DATA_PATH=${ARDOUR_DATA_PATH:-/usr/share/$(basename "$ardour_prefix")}
export ARDOUR_CONFIG_PATH=${ARDOUR_CONFIG_PATH:-/etc/$(basename "$ardour_prefix")}
export ARDOUR_DLL_PATH=$ardour_prefix
export LD_LIBRARY_PATH=$ardour_prefix${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

mclk=$base/mclk
gcc -O2 -o "$mclk" "$repo_root/scripts/daw/mclk.c" -lasound || exit 1

"$lua" "$repo_root/scripts/daw/phase2-sync-poc.lua" 2>&1 | \
	grep -vE "WARNING|Falling|buffer of size" &
lua_pid=$!

# Wait for the session to be up with external sync enabled.
n=0
until [ -f "$base/ready" ]; do
	sleep 1; n=$((n+1))
	if [ $n -gt 60 ] || ! kill -0 $lua_pid 2>/dev/null; then
		echo "FAIL: luasession never became ready"; kill $lua_pid 2>/dev/null
		exit 1
	fi
done

# Delay the MIDI Start until after the port is linked: Ardour's MIDI Clock
# master only rolls once it sees Start/Continue.
"$mclk" "${SYNC_BPM:-120}" 8 &
clk_pid=$!
sleep 2

echo "=== linking clock to Ardour"
out_port=$(pw-link -o 2>/dev/null | grep -i "mclk" | head -1)
in_port=$(pw-link -i 2>/dev/null | grep -i "MIDI Clock in" | head -1)
echo "  out: ${out_port:-NONE}  in: ${in_port:-NONE}"
if [ -z "$out_port" ] || [ -z "$in_port" ]; then
	echo "FAIL: clock or sync port missing in graph"
	pw-link -i 2>/dev/null | grep -i ardour | head -10
	kill $clk_pid $lua_pid 2>/dev/null; exit 1
fi
pw-link "$out_port" "$in_port" || echo "WARN: pw-link returned $?"

wait $lua_pid
rc=$?
kill $clk_pid 2>/dev/null
exit $rc
