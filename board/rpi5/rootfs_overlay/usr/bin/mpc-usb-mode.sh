#!/bin/sh
# Report the audio topology. There are no modes left to switch.
#
# This script used to toggle between a "live" quantum of 32 and a
# "tracking" quantum of 48, on the belief that the full armed desk could
# not run at 32. It can. Measured on the shipped session with all 27
# inserts, sixteen tracks armed, all eight MPC individual-out tracks
# active and the emulator live: Ardour's own xrun counter read +0 across
# eleven consecutive ten-second reports, and the driver logged zero
# errors in every window.
#
# Everything that had argued for 48 turned out to be something else:
# the delivery defects were a measurement artifact (the emulator's audio
# summed onto the test tone's channels), the session deaths were a
# kernel panic in the DAC-less I2S card, and the ~1ms DMA service floor
# belonged to that same card.
#
# So the appliance has one quantum, pinned at both ends so no client can
# renegotiate it mid-take, and one interface width. Keeping a mode
# switch for settings that no longer vary would only invite the question
# "which mode am I in?" during a take.
#
#   mpc-usb-mode.sh          print the topology
set -eu

U=$(id -u mpc)
R="sudo -u mpc env XDG_RUNTIME_DIR=/run/user/$U"

# Read the quantum the graph is RUNNING at, from the driver's own row,
# not the force-quantum request in metadata. Those differ whenever the
# request is cleared and the configured default applies - and reporting
# the request as though it were the state is how settings in this
# project appeared to be in force for days while doing nothing.
top=$($R timeout 6 pw-top -b -n 2 2>/dev/null)
q=$(printf '%s\n' "$top" | awk '$1 == "R" && $3 ~ /^[0-9]+$/ && $3 > 0 {print $3; exit}')

mask=$(cat /sys/kernel/config/usb_gadget/mpc/functions/uac2.usb0/p_chmask 2>/dev/null || echo 0)
up=$(printf '%d\n' "$mask" 2>/dev/null |
	awk '{c=0; v=$1; while (v) {c += v % 2; v = int(v/2)}; print c}')
hw=$(grep -E 'period_size|buffer_size' \
	/proc/asound/card0/pcm0p/sub0/hw_params 2>/dev/null | tr '\n' ' ')
drv=$(printf '%s\n' "$top" |
	awk '$1 == "R" && $3 ~ /^[0-9]+$/ && $3 > 0 {print $NF; exit}')

printf 'quantum   %s samples (%s ms at 44.1k)\n' \
	"${q:-?}" "$(awk -v q="${q:-0}" 'BEGIN{printf "%.2f", q*1000/44100}')"
printf 'interface %s up / 2 down\n' "${up:-?}"
printf 'clock     %s\n' "${drv:-not running}"
printf 'gadget    %s\n' "${hw:-not open}"
