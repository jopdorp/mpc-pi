#!/bin/sh
# What does the emulator cost on the appliance, and does the graph
# survive it?
#
# This is the measurement the freeze-flow question has been waiting on:
# cores 0 (housekeeping), 1 (PipeWire data loop), 2-3 (Ardour's DSP
# workers) are all spoken for, so wherever the emulator lands it shares
# with someone. Whether the sharing works is not arguable from the
# layout; it is a number.
#
# Runs the deployment preset - the same HLE/event flags as
# run-mpc2000xl-fast.sh, spelled as the MAME_MPC_* variables the binary
# actually reads - because the accurate modes are not what the appliance
# ships. Sound goes through PipeWire so the emulator is a real client of
# the same graph Ardour lives in, not a headless approximation.
#
#   bench-emulator-board.sh [seconds] [cpulist]     default: 60, core 3
#
# Reports:
#   * MAME's own average speed (100% = real time; below is falling behind)
#   * the process's CPU share, measured from /proc, attributed per core
#   * the driver's error delta over the window, so an emulator that
#     starves the graph is visible in the same breath
set -u
SECONDS_TO_RUN="${1:-60}"
CPUS="${2:-3}"
U=$(id -u mpc)
R="sudo -u mpc env XDG_RUNTIME_DIR=/run/user/$U"
BIN=/usr/local/bin/mpc
ROMS=/opt/mpc-roms
RUNTIME=/tmp/mpc-runtime
LOG=/var/log/mpcpi-emubench.txt

[ -x "$BIN" ] || { echo "no emulator at $BIN" >&2; exit 1; }
mkdir -p "$RUNTIME/cfg" "$RUNTIME/nvram"

driver_err() {
	$R timeout 8 pw-top -b -n 2 2>/dev/null |
		grep -E "^R +[0-9]+ +[1-9][0-9]* +[1-9][0-9]*" | tail -1 |
		awk '{print $9}'
}

a=$(driver_err)

# The full fast preset. Kept in one place ON PURPOSE: if this list and
# run-mpc2000xl-fast.sh drift apart, this benchmark measures a machine
# the appliance does not ship.
setsid taskset --cpu-list "$CPUS" chrt --rr 20 env \
	MAME_MPC_V53_BRK88_HLE=1 MAME_MPC_V53_BRK77_HLE=1 \
	MAME_MPC_V53_BRK92_HLE=1 MAME_MPC_V53_BRKFD_HLE=1 \
	MAME_MPC_V53_DIRECT_DISPATCH=1 MAME_MPC_V53_DIVIDE_SUPERBLOCK=1 \
	MAME_MPC_V53_FETCH_WINDOW=1 MAME_MPC_V53_DATA_WINDOW=1 \
	MAME_MPC_V53_IDLE_SKIP=1 MAME_MPC_DSP_WINDOW=1 \
	MAME_MPC_LCD_SKIP_UNCHANGED=1 \
	MAME_MPC_PANEL_EVENT_DRIVEN=1 MAME_MPC_PANEL_TIMER_COALESCED=1 \
	MAME_MPC_MIDI_EVENT_DRIVEN=1 \
	MAME_MPC_STEREO_ONLY=1 \
	MPC_SOUND_UPDATES_PER_QUANTUM=2 \
	SDL_VIDEODRIVER=dummy \
	XDG_RUNTIME_DIR="/run/user/$U" \
	"$BIN" mpc2000xl \
	-rompath "$ROMS" \
	-cfg_directory "$RUNTIME/cfg" -nvram_directory "$RUNTIME/nvram" \
	-sound pipewire -samplerate 44100 \
	-video none -seconds_to_run "$SECONDS_TO_RUN" \
	> "$LOG" 2>&1 &
PID=$!

# CPU accounting from /proc, sampled twice WHILE the process runs -
# utime+stime in ticks, delta over wall time. Sampling "around" the run
# does not work: /proc/PID is gone the moment the process exits, and the
# first version tried to read the second sample from a corpse. The
# window skips the first 5 seconds, which are boot - the firmware
# initialising is real work but not the steady state a player lives in.
sleep 5
[ -d "/proc/$PID" ] || { echo "emulator died at start:"; tail -5 "$LOG"; exit 1; }
t0=$(awk '{print $14 + $15}' "/proc/$PID/stat" 2>/dev/null)
w0=$(date +%s)
span=$((SECONDS_TO_RUN - 10))
[ "$span" -gt 5 ] || span=5
sleep "$span"
t1=$(awk '{print $14 + $15}' "/proc/$PID/stat" 2>/dev/null)
w1=$(date +%s)

wait "$PID" 2>/dev/null
b=$(driver_err)

speed=$(grep -oE "Average speed: [0-9.]+%" "$LOG" | tail -1)
hz=$(getconf CLK_TCK)
wall=$((w1 - w0))
echo "emulator: ${speed:-NO SPEED LINE - see $LOG} over ${SECONDS_TO_RUN}s on core(s) $CPUS"
if [ -n "${t0:-}" ] && [ -n "${t1:-}" ] && [ "$wall" -gt 0 ]; then
	awk -v a="$t0" -v b="$t1" -v w="$wall" -v hz="$hz" 'BEGIN {
		printf "cpu: %.1f%% of one core (steady state, %ds window)\n",
			(b - a) * 100 / (hz * w), w }'
fi
echo "driver errors during run: $((${b:-0} - ${a:-0}))"
tail -2 "$LOG" | head -1
echo EMUBENCH-DONE
