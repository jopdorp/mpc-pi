#!/bin/sh
# Present the appliance to a computer as a class-compliant USB 2.0 audio
# interface (UAC2) plus two MIDI cables, via configfs. See
# docs/maschine-daw-design.md, "USB audio interface (both directions)".
#
# REBUILT FROM AN EARLIER, MEASURED VERSION (git show de9326e^:...), removed
# in de9326e "strip to the MPC side" while the crackle investigation needed
# every variable it could remove. The SCHED_RR fix that investigation led to
# is what makes bringing this back worthwhile - see docs/audio-chain.md.
# Restored with the desk's new names (LOOP1-5 in place of GTR1/GTR2/MIC/AUX)
# and the current quantum (64, not the 32 this was last measured at); every
# other parameter below - the rate, the channel directions, the MIDI cables,
# the safety check - is the earlier, proven value, not a re-guess.
#
#   mpc-usb-gadget.sh start   create the gadget and bind it to the UDC
#   mpc-usb-gadget.sh stop    unbind and tear it down
#   mpc-usb-gadget.sh status  print what is configured, exit 0 if bound
#
# Requires dtoverlay=dwc2,dr_mode=peripheral in config.txt and a reboot
# after adding it - this script cannot make a UDC appear on a kernel that
# booted without one.
set -eu

G=/sys/kernel/config/usb_gadget/mpc
UAC=$G/functions/uac2.usb0
MIDI=$G/functions/midi.usb0
CFG=$G/configs/c.1

log() { echo "mpc-usb-gadget: $*"; }

# 22 channels up (the gadget's "p_" - playback - side: what WE play
# locally becomes what the HOST records), 2 down ("c_" - capture: what
# the host plays becomes what we read locally). Concurrent, not
# switchable - an earlier version took turns between MPC and DAW on ten
# channels, which quietly reinvented the chained topology this design
# forbids. Bandwidth is not the constraint: 22ch of 24-bit 44.1k is
# 2.9MB/s, 363 bytes per 125us microframe, well inside one high-speed
# packet.
CHANNELS_UP=${MPC_USB_CHANNELS_UP:-22}
CHANNELS_DOWN=${MPC_USB_CHANNELS_DOWN:-2}
# 44100, NOT 48000: the MPC is a 44.1kHz machine end to end. A 48k gadget
# resamples every channel on the way to the computer - measured once
# already, silently, as a 48000 node sitting in a 44100 graph with every
# number elsewhere reporting normal. The read-back check below exists
# because of that exact incident.
RATE=${MPC_USB_RATE:-44100}
SSIZE=${MPC_USB_SSIZE:-3}     # 24-bit: the emulator and the DAC are both clean at it

mask() {
	i=0; m=0
	while [ "$i" -lt "$1" ]; do m=$((m | (1 << i))); i=$((i + 1)); done
	printf '0x%x\n' "$m"
}

teardown() {
	[ -d "$G" ] || return 0
	[ -s "$G/UDC" ] && : > "$G/UDC" 2>/dev/null
	rm -f "$CFG"/uac2.usb0 "$CFG"/midi.usb0 2>/dev/null || true
	rmdir "$CFG/strings/0x409" "$CFG" 2>/dev/null || true
	rmdir "$UAC" "$MIDI" 2>/dev/null || true
	rmdir "$G/strings/0x409" "$G" 2>/dev/null || true
}

start() {
	# libcomposite is CONFIG_USB_LIBCOMPOSITE=m on this kernel (the design
	# doc's kernel fragment asked for =y; Kconfig's own dependency
	# resolution changed it). Without the module, /sys/kernel/config/
	# usb_gadget does not exist at all, and every mkdir below fails with a
	# message that looks like a typo in the path rather than a missing
	# module.
	modprobe libcomposite 2>/dev/null || true
	modprobe dwc2 2>/dev/null || true       # best-effort: may be built in
	mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
	[ -d /sys/kernel/config/usb_gadget ] ||
		{ log "usb_gadget/ still missing after modprobe - libcomposite will not load"; return 1; }

	UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
	if [ -z "$UDC" ]; then
		log "no UDC - is dtoverlay=dwc2,dr_mode=peripheral in config.txt, and did you reboot after adding it?"
		return 1
	fi

	teardown
	mkdir -p "$G"
	# Linux Foundation's generic gadget VID/PID. Class-compliance is about
	# the UAC2 interface descriptors the host matches on, not about who
	# made the silicon.
	echo 0x1d6b > "$G/idVendor"
	echo 0x0104 > "$G/idProduct"
	echo 0x0100 > "$G/bcdDevice"
	echo 0x0200 > "$G/bcdUSB"
	mkdir -p "$G/strings/0x409"
	echo "mpc-pi"                  > "$G/strings/0x409/manufacturer"
	echo "MPC2000XL Audio Interface" > "$G/strings/0x409/product"
	echo "0001"                    > "$G/strings/0x409/serialnumber"

	mkdir -p "$UAC"
	echo "$(mask "$CHANNELS_DOWN")" > "$UAC/c_chmask"
	echo "$RATE"                    > "$UAC/c_srate"
	echo "$SSIZE"                   > "$UAC/c_ssize"
	echo "$(mask "$CHANNELS_UP")"   > "$UAC/p_chmask"
	echo "$RATE"                    > "$UAC/p_srate"
	echo "$SSIZE"                   > "$UAC/p_ssize"

	# Read the rate back before binding. Newer f_uac2 takes a
	# comma-separated rate list, so compare against the first entry.
	for side in c p; do
		got=$(cut -d, -f1 < "$UAC/${side}_srate" 2>/dev/null)
		if [ "$got" != "$RATE" ]; then
			log "${side}_srate is $got, wanted $RATE - refusing to bind a resampling gadget"
			return 1
		fi
	done
	# 125us service interval instead of the 1ms default - what makes a
	# small host-side buffer realistic. Not every kernel exposes the
	# attribute; failing to set it is not fatal, just slower.
	for attr in p_hs_bint c_hs_bint; do
		[ -f "$UAC/$attr" ] && echo 1 > "$UAC/$attr" 2>/dev/null ||
			log "no $attr on this kernel - 1ms service interval, not 125us"
	done
	echo "${MPC_USB_REQS:-2}" > "$UAC/req_number" 2>/dev/null || true

	# MIDI rides the same composite gadget. Two virtual cables because
	# they are two different instruments to the computer: cable 1 is the
	# MPC (notes and clock, either direction - a host DAW can slave to the
	# MPC or drive it), cable 2 is the Maschine's decoded controls. See
	# mpc-usb-midi-bridge.sh for what actually feeds them.
	mkdir -p "$MIDI"
	echo 2 > "$MIDI/in_ports"
	echo 2 > "$MIDI/out_ports"

	mkdir -p "$CFG/strings/0x409"
	echo "UAC2" > "$CFG/strings/0x409/configuration"
	echo 250    > "$CFG/MaxPower"
	ln -s "$UAC" "$CFG/"
	ln -s "$MIDI" "$CFG/"

	echo "$UDC" > "$G/UDC"
	log "bound to $UDC (${CHANNELS_UP}ch up / ${CHANNELS_DOWN}ch down @ ${RATE}, 2x MIDI)"
}

status() {
	if [ -d "$G" ] && [ -n "$(cat "$G/UDC" 2>/dev/null)" ]; then
		echo "bound to $(cat "$G/UDC")"
		echo "up:   $(cat "$UAC/p_chmask" 2>/dev/null) chmask @ $(cat "$UAC/p_srate" 2>/dev/null | cut -d, -f1)Hz"
		echo "down: $(cat "$UAC/c_chmask" 2>/dev/null) chmask @ $(cat "$UAC/c_srate" 2>/dev/null | cut -d, -f1)Hz"
		return 0
	fi
	echo "not bound"
	return 1
}

case "${1:-}" in
	start)  start ;;
	stop)   teardown; log "torn down" ;;
	status) status ;;
	*) echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac
