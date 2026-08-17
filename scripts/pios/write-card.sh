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
	if command -v growpart >/dev/null 2>&1; then
		growpart "$target" 2 || echo "  growpart declined (already full?)"
	else
		parted -s "$target" resizepart 2 100% || echo "  resizepart declined"
	fi
	partx -u "$target" 2>/dev/null || true
	e2fsck -fp "$part2" || true
	resize2fs "$part2"
	echo "  $(lsblk -no SIZE "$part2" | tr -d ' ') root partition"
fi

echo
echo "done. Next: move the card to the Pi, then provision it there -"
echo "the Pi is arm64, so packages and provisioning run natively:"
echo "  scripts/pios/provision-card.sh"
