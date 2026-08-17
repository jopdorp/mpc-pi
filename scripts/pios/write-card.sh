#!/bin/bash
# Write the Pi OS Lite base onto an SD card, then grow it to fill the card.
#
# This is the one irreversible step in building the appliance image, and
# the failure mode is not "the card is wrong" - it is "the wrong device
# was named and a disk is gone". So the target is checked against every
# property of the card it is supposed to be before a byte is written,
# and any surprise is a refusal rather than a prompt.
#
# Runs unprivileged if you are in the `disk` group. It deliberately does
# NOT take a device argument by default: it finds the card itself and
# makes you confirm it, because a typo'd argument is exactly the mistake
# being guarded against.
#
#   write-card.sh              find the card, show it, write it
#   write-card.sh /dev/sdX     use this device instead (still checked)
set -euo pipefail

BASE="${MPCPI_BASE_IMG:-/var/tmp/pios-arm64-lite.img}"
MIN_GIB=4       # a Pi OS Lite image plus our payload does not fit below this
MAX_GIB=128     # anything larger is far more likely to be a real disk

die() { echo "write-card: $*" >&2; exit 1; }

[ -s "$BASE" ] || die "no base image at $BASE
  fetch one:  sudo mpcpi-netboot fetch-pios"

# Find the card, or check the one named. Either way it must pass the
# same tests - the argument is a convenience, not an override.
target="${1:-}"
if [ -z "$target" ]; then
	for d in /sys/block/mmcblk* /sys/block/sd*; do
		[ -e "$d" ] || continue
		n=$(basename "$d")
		sz=$(cat "$d/size" 2>/dev/null || echo 0)
		[ "$sz" -gt 0 ] || continue
		gib=$((sz / 2 / 1024 / 1024))
		[ "$gib" -ge "$MIN_GIB" ] && [ "$gib" -le "$MAX_GIB" ] || continue
		# A card reader is removable, or is an MMC host controller.
		case "$n" in
			mmcblk*) target="/dev/$n"; break ;;
		esac
		[ "$(cat "$d/removable" 2>/dev/null)" = "1" ] &&
			{ target="/dev/$n"; break; }
	done
	[ -n "$target" ] || die "no SD card found - is it inserted?"
fi

[ -b "$target" ] || die "$target is not a block device"

# The root filesystem's disk is the thing this must never be. Resolve it
# through any LVM and dm-crypt rather than comparing names, because
# /dev/mapper/... looks nothing like the /dev/nvme0n1 underneath it.
# `lsblk -s` walks the chain downwards to the physical disk. It must be
# -r (raw): without it the output carries tree-drawing characters and
# the name comes back as "\-nvme0n1", which matches nothing - a safety
# check that silently cannot identify what it is protecting.
rootsrc=$(findmnt -n -o SOURCE / 2>/dev/null || true)
rootdisks=$(lsblk -s -rno NAME,TYPE "$rootsrc" 2>/dev/null |
	awk '$2=="disk"{print $1}')
[ -n "$rootdisks" ] ||
	die "cannot determine which disk carries /, refusing to write anything"
tname=$(basename "$target")
for rd in $rootdisks; do
	[ "$rd" = "$tname" ] &&
		die "$target carries the running root filesystem. Refusing."
done

sz=$(cat "/sys/block/$tname/size" 2>/dev/null || echo 0)
gib=$((sz / 2 / 1024 / 1024))
[ "$gib" -ge "$MIN_GIB" ] || die "$target is ${gib}GiB, below the ${MIN_GIB}GiB minimum"
[ "$gib" -le "$MAX_GIB" ] || die "$target is ${gib}GiB - too large to be a card. Refusing."

# Nothing mounted, anywhere under it. Writing under a live mount
# corrupts both the card and the page cache's idea of it.
if lsblk -no MOUNTPOINTS "$target" 2>/dev/null | grep -q .; then
	echo "$target has mounted filesystems:" >&2
	lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS "$target" >&2
	die "unmount them first"
fi

echo "target : $target  (${gib} GiB)"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$target" | sed 's/^/         /'
echo "source : $BASE  ($(du -h "$BASE" | cut -f1))"
echo "root fs lives on $(echo $rootdisks | sed 's|[^ ]*|/dev/&|g') - not this device"
echo
if [ -z "${MPCPI_YES:-}" ]; then
	printf 'Everything on %s will be destroyed. Type the device name to confirm: ' "$target"
	read -r answer
	[ "$answer" = "$target" ] || die "not confirmed (you typed '$answer')"
fi

echo "writing..."
dd if="$BASE" of="$target" bs=8M conv=fsync status=progress
sync
partx -u "$target" 2>/dev/null || blockdev --rereadpt "$target" 2>/dev/null || true
sleep 1

# Grow the root partition to the card. Done here rather than by Pi OS's
# own first-boot resize because this appliance's boot time is measured:
# a first boot that repartitions itself is not the boot we want a number
# from.
part2="${target}p2"
[ -b "$part2" ] || part2="${target}2"
if [ -b "$part2" ]; then
	echo "growing $part2 to fill the card..."
	# growpart is in cloud-guest-utils; parted's resizepart is the fallback.
	grown=""
	if command -v growpart >/dev/null 2>&1; then
		growpart "$target" 2 && grown=1
	else
		parted -s "$target" resizepart 2 100% && grown=1
	fi
	partx -u "$target" 2>/dev/null || true
	if [ -n "$grown" ]; then
		e2fsck -fp "$part2" || true
		resize2fs "$part2"
	fi
	size=$(lsblk -bno SIZE "$part2" | head -1 | tr -d ' ')
	card=$(lsblk -bno SIZE "$target" | head -1 | tr -d ' ')
	# Say plainly when the grow did not happen. This printed "growpart
	# declined (already full?)" after a failure and left a 2.3GB root on
	# a 7.4GB card - 86% full, too small for the payload - while reading
	# like a successful no-op.
	if [ -n "$size" ] && [ -n "$card" ] &&
		[ "$size" -lt $((card * 70 / 100)) ]; then
		echo
		echo "  NOTE: root is $(numfmt --to=iec "$size") on a $(numfmt --to=iec "$card") card - NOT grown."
		echo "  growpart needs root to make the kernel re-read the partition"
		echo "  table, and this script runs unprivileged via the disk group."
		echo "  provision-card.sh grows it on the Pi, where it has root."
	else
		echo "  root partition $(numfmt --to=iec "$size")"
	fi
fi

# Make the card UNBOOTABLE until it has been provisioned.
#
# A Pi 5 boot-prefers SD over network. Writing a bootable Pi OS Lite base
# to a card and putting it in a netbooting Pi means the card wins: the
# board comes up as stock "raspberrypi" on a different DHCP lease, with
# ssh disabled and userconfig.service blocking boot on a console prompt
# nobody can answer. It is unreachable, and the netboot rig it was
# supposed to be provisioned FROM has been displaced by it.
#
# The firmware needs config.txt to boot. Moving it aside leaves the card
# fully intact as a data device - which is exactly what provisioning
# needs - while letting the Pi fall through to netboot. provision-card.sh
# writes the real config.txt at the end, so the card becomes bootable
# only once it is actually the appliance.
#
# Done with mtools on the raw vfat partition: no mount, so no root.
part1="${target}p1"
[ -b "$part1" ] || part1="${target}1"
if [ -b "$part1" ] && command -v mcopy >/dev/null 2>&1; then
	if mren -i "$part1" ::config.txt ::config.pnd 2>/dev/null; then
		echo "  config.txt -> config.pnd: the card will NOT boot yet"
	else
		echo "  WARNING: could not move config.txt aside." >&2
		echo "  The card IS bootable, and a Pi 5 prefers SD over network -" >&2
		echo "  it will hijack the netboot and come up unreachable." >&2
	fi
fi

echo
echo "done. The card is deliberately not bootable yet."
echo
echo "Next: put it in the Pi (which will still netboot), then provision"
echo "it there - the Pi is arm64, so packages run natively:"
echo "  ssh root@192.168.7.110 'sh /opt/mpc-pi-src/scripts/pios/provision-card.sh'"
