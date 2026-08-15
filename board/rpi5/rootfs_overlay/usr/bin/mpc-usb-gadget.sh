#!/bin/sh
# Present the appliance to a computer as a class-compliant USB 2.0 audio
# interface (UAC2), so the MPC's ten channels or Ardour's mix can be
# recorded on a host with no drivers. See docs/maschine-daw-design.md,
# "USB audio interface (both directions)".
#
# The gadget shows up locally as an ordinary ALSA card, which is what lets
# PipeWire route emulator or DAW channels into it: what the host records is
# what we play into that card, and what the host plays arrives as a capture
# device here.
set -eu

G=/sys/kernel/config/usb_gadget/mpc
UDC_DIR=/sys/class/udc

# Ten channels: MPC stereo plus the eight individual outs (mask 0x3ff).
CHANNELS_IN=${MPC_USB_CHANNELS_IN:-10}
CHANNELS_OUT=${MPC_USB_CHANNELS_OUT:-2}
RATE=${MPC_USB_RATE:-48000}
# 24-bit over the wire: the emulator and the DAC are both 24-bit clean and
# it costs a quarter less bandwidth than padding to 32.
SSIZE=${MPC_USB_SSIZE:-3}

mask() {
	# Build a channel bitmask with $1 low bits set.
	i=0; m=0
	while [ "$i" -lt "$1" ]; do m=$((m | (1 << i))); i=$((i + 1)); done
	printf '0x%x\n' "$m"
}

stop() {
	[ -d "$G" ] || return 0
	if [ -s "$G/UDC" ]; then : > "$G/UDC"; fi
	rm -f "$G"/configs/c.1/uac2.usb0 2>/dev/null || true
	rmdir "$G"/configs/c.1/strings/0x409 2>/dev/null || true
	rmdir "$G"/configs/c.1 2>/dev/null || true
	rmdir "$G"/functions/uac2.usb0 2>/dev/null || true
	rmdir "$G"/strings/0x409 2>/dev/null || true
	rmdir "$G" 2>/dev/null || true
}

case "${1:-start}" in
stop)
	stop
	exit 0
	;;
esac

modprobe libcomposite 2>/dev/null || true
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

udc=$(ls "$UDC_DIR" 2>/dev/null | head -1)
if [ -z "$udc" ]; then
	echo "mpc-usb-gadget: no UDC available (is dtoverlay=dwc2 in config.txt?)" >&2
	exit 1
fi

stop
mkdir -p "$G"
# Vendor 0x1d6b (Linux Foundation) with the multifunction product id: the
# UAC2 class descriptors are what hosts actually bind to, not the ids.
echo 0x1d6b > "$G/idVendor"
echo 0x0104 > "$G/idProduct"
echo 0x0100 > "$G/bcdDevice"
echo 0x0200 > "$G/bcdUSB"
mkdir -p "$G/strings/0x409"
echo "mpc-pi" > "$G/strings/0x409/manufacturer"
echo "MPC2000XL Audio Interface" > "$G/strings/0x409/product"
echo "0001" > "$G/strings/0x409/serialnumber"

mkdir -p "$G/functions/uac2.usb0"
F=$G/functions/uac2.usb0
# "c_" is the gadget's capture side (host plays to us), "p_" the playback
# side (host records from us): the ten MPC channels travel on p_.
echo "$(mask "$CHANNELS_OUT")" > "$F/c_chmask"
echo "$RATE" > "$F/c_srate"
echo "$SSIZE" > "$F/c_ssize"
echo "$(mask "$CHANNELS_IN")" > "$F/p_chmask"
echo "$RATE" > "$F/p_srate"
echo "$SSIZE" > "$F/p_ssize"
# Service the isochronous endpoints every microframe (125 us) instead of
# the 1 ms default, and keep few requests in flight: this is what makes a
# 32-sample buffer usable on the host. Older kernels lack the bInterval
# attributes, so failing to set them is not fatal.
echo 1 > "$F/p_hs_bint" 2>/dev/null || true
echo 1 > "$F/c_hs_bint" 2>/dev/null || true
echo "${MPC_USB_REQS:-2}" > "$F/req_number" 2>/dev/null || true

mkdir -p "$G/configs/c.1/strings/0x409"
echo "UAC2" > "$G/configs/c.1/strings/0x409/configuration"
echo 250 > "$G/configs/c.1/MaxPower"
ln -s "$F" "$G/configs/c.1/"

echo "$udc" > "$G/UDC"
echo "mpc-usb-gadget: bound to $udc (${CHANNELS_IN} in / ${CHANNELS_OUT} out @ ${RATE})"
