#!/bin/sh
# Take the sink off timer-based scheduling and measure what changes.
#
# What this is chasing:
#
#   /proc/asound/card0/pcm1p/sub0/hw_params, with the graph forced to a
#   32-sample quantum:
#
#       period_size: 1024
#       buffer_size: 32768
#
# The ALSA device is running 1024-frame periods behind a 743-millisecond
# buffer while the graph wakes every 32 frames. PipeWire defaults to
# timer-based scheduling: it sets a large hardware buffer, wakes on its
# own timer once per quantum, and estimates where the DMA pointer must
# have got to. The estimate is a DLL over a pointer that only genuinely
# advances 43 times a second, and IRQ 141 fires at exactly that rate -
# about 86 a second across both directions - which is the proof that
# nothing here is following the hardware.
#
# That model is why the sink misses deadlines with no graph attached at
# all: 13 to 51 errors per ten seconds on a node doing four microseconds
# of work. It also explains why none of the work above the sink helped -
# thread count, plugin load, core placement, interrupt affinity - since
# none of it touches how the sink decides when to wake.
#
# disable-tsched makes PipeWire wake on the period interrupt instead, so
# the graph follows the hardware rather than predicting it. period-size
# then means what it says, and should match the quantum being run.
#
#   sweep-alsa-sched.sh
set -u
U=$(id -u mpc)
R="sudo -u mpc env XDG_RUNTIME_DIR=/run/user/$U"
# 98, not 94. wireplumber merges wireplumber.conf.d in lexical order and
# later files win, so a fragment numbered below the existing
# 95-mpcpi-i2s.conf would have had its period-num and headroom silently
# overridden by that file - the sweep would have varied period-num
# through five configurations and measured the same one five times.
RULE=/etc/wireplumber/wireplumber.conf.d/98-mpcpi-sched.conf
OUT=/var/log/mpcpi-alsasched.txt

restore() {
	rm -f "$RULE"
	systemctl --user -M "mpc@" restart wireplumber pipewire 2>/dev/null ||
		$R systemctl --user restart wireplumber pipewire 2>/dev/null
	sleep 6
}
trap restore EXIT INT TERM

apply() {
	# $1 = "tsched" or a period size; $2 = period-num
	if [ "$1" = "tsched" ]; then
		rm -f "$RULE"
	else
		cat > "$RULE" <<WP
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_output.platform-soc_107c000000_sound.*" }
      { node.name = "~alsa_input.platform-soc_107c000000_sound.*" }
    ]
    actions = {
      update-props = {
        api.alsa.disable-tsched = true
        api.alsa.period-size    = $1
        api.alsa.period-num     = $2
        api.alsa.headroom       = 0
      }
    }
  }
]
WP
	fi
	$R systemctl --user restart wireplumber pipewire 2>/dev/null
	sleep 8
}

: > "$OUT"
# tsched first, as the baseline this is being compared against, then
# interrupt-driven at the two quanta that matter and a couple of buffer
# depths. aplay measured this device underrunning at 32-frame periods
# with 4 of them and running clean with 8, so 8 is where to start.
for cfg in "tsched 0" "48 8" "48 4" "32 8" "32 4"; do
	set -- $cfg
	echo "=== period-size=$1 period-num=$2 ===" | tee -a "$OUT"
	apply "$1" "$2"
	# hw_params is printed by sink-alone itself, while the device is
	# open. Reading it here would always find the file empty: the sink
	# is idle between runs, and an empty hw_params reads as "no
	# information" rather than "not measured".
	MPCPI_REPEATS=3 sh /opt/mpc-pi-src/scripts/diagnostics/sink-alone.sh 48 32 |
		grep --line-buffered -E "^  q=" | tee -a "$OUT"
done
echo ALSASCHED-DONE | tee -a "$OUT"
