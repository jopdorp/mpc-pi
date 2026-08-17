#!/bin/bash
# Turn a freshly-written Pi OS Lite card into the appliance. Runs ON THE
# PI, as root, with the card in its slot and the Pi itself netbooted.
#
# Why on the Pi rather than on the development host:
#
#   * The Pi is arm64. Package installation and the provisioning scripts
#     run natively in a chroot, with no qemu-user and no binfmt. The
#     host is x86_64 and its libguestfs is broken anyway (supermin cannot
#     read /boot/vmlinuz-*, mode 0600).
#   * Growing the partition needs root to make the kernel re-read the
#     table. write-card.sh runs unprivileged via the `disk` group and
#     cannot do it - it reported "growpart declined" and left a 2.3GB
#     root on a 7.4GB card, 86% full, which our payload does not fit in.
#
# The Pi's own root is NFS, so the card is never the running root and
# this can safely repartition it.
#
#   provision-card.sh            grow, mount, install, configure
#   provision-card.sh --no-apt   skip package installation (offline)
set -euo pipefail

CARD="${MPCPI_CARD:-/dev/mmcblk0}"
MNT=/mnt/mpcpi-card
SRC="${MPCPI_SRC:-/opt/mpc-pi-src}"
NO_APT=""
[ "${1:-}" = "--no-apt" ] && NO_APT=1

die() { echo "provision-card: $*" >&2; exit 1; }
log() { printf '\n== %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -b "$CARD" ] || die "no card at $CARD - is it in the Pi's slot?"

# The running root must not be on this device. On a netbooted Pi it is
# NFS, so this is belt and braces - but this script repartitions, and a
# wrong device here is unrecoverable.
rootsrc=$(findmnt -n -o SOURCE / 2>/dev/null || true)
case "$rootsrc" in
	"$CARD"*) die "$CARD carries the running root. Refusing." ;;
esac
echo "card    : $CARD"
echo "root fs : $rootsrc (not the card)"

P1="${CARD}p1"; P2="${CARD}p2"
[ -b "$P2" ] || die "no $P2 - was the base image written? run write-card.sh"

log "grow the root partition"
before=$(blockdev --getsize64 "$P2")
if command -v growpart >/dev/null 2>&1; then
	growpart "$CARD" 2 || echo "  growpart: nothing to do"
else
	parted -s "$CARD" resizepart 2 100% || echo "  resizepart: nothing to do"
fi
partprobe "$CARD" 2>/dev/null || partx -u "$CARD" 2>/dev/null || true
e2fsck -fp "$P2" || true
resize2fs "$P2" || true
after=$(blockdev --getsize64 "$P2")
printf '  %s -> %s\n' \
	"$(numfmt --to=iec "$before")" "$(numfmt --to=iec "$after")"
[ "$after" -gt 3000000000 ] ||
	die "root is still $(numfmt --to=iec "$after") - the payload will not fit"

log "mount"
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P2" "$MNT"
mkdir -p "$MNT/boot/firmware"
mountpoint -q "$MNT/boot/firmware" || mount "$P1" "$MNT/boot/firmware"
df -h "$MNT" | tail -1 | sed 's/^/  /'

cleanup() {
	umount "$MNT/boot/firmware" 2>/dev/null || true
	for d in dev/pts dev proc sys; do umount "$MNT/$d" 2>/dev/null || true; done
	umount "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

log "kernel: the RT build, under its own name"
# NOT kernel_2712.img. That is the filename apt writes when it installs
# linux-image-*-rpi-2712, and it is exactly how the stock kernel silently
# replaced our PREEMPT_RT one on the netboot root - the board then ran
# 6.18.34+rpt for an unknown stretch while every doc claimed RT.
KREL=$(uname -r)
case "$KREL" in
	*mpcpi-rt*) ;;
	*) echo "  WARNING: this Pi is running $KREL, not an RT kernel." >&2
	   echo "           Copying its modules would ship the wrong set." >&2 ;;
esac
if [ -f /boot/firmware/kernel-mpcpi-rt.img ]; then
	cp /boot/firmware/kernel-mpcpi-rt.img "$MNT/boot/firmware/"
elif [ -f "$SRC/../.cache/rt-kernel/linux/arch/arm64/boot/Image" ]; then
	cp "$SRC/../.cache/rt-kernel/linux/arch/arm64/boot/Image" \
		"$MNT/boot/firmware/kernel-mpcpi-rt.img"
else
	echo "  no RT kernel image found locally; fetching from the netboot server"
	tftp_ip=$(awk '/nfsroot=/{sub(/.*nfsroot=/,""); sub(/:.*/,""); print}' /proc/cmdline)
	curl -sfL "tftp://$tftp_ip/kernel-mpcpi-rt.img" \
		-o "$MNT/boot/firmware/kernel-mpcpi-rt.img" ||
		die "could not obtain the RT kernel"
fi
mkdir -p "$MNT/lib/modules"
if [ -d "/lib/modules/$KREL" ]; then
	rsync -a --delete "/lib/modules/$KREL" "$MNT/lib/modules/"
	echo "  modules: $KREL"
fi
echo "  image  : kernel-mpcpi-rt.img"

log "boot configuration"
tuning=$(tr -d '\n' < "$SRC/board/rpi5/cmdline-tuning")
[ -n "$tuning" ] || die "no cmdline tuning file at $SRC/board/rpi5/cmdline-tuning"
partuuid=$(blkid -s PARTUUID -o value "$P2")
[ -n "$partuuid" ] || die "cannot read PARTUUID of $P2"
# Local root, so none of the netboot overhead: no ip=dhcp, no nfsroot,
# and none of the 3.8s ethernet-link wait or 2.1s NFS mount that make up
# 5.9 of the 6.1s kernel phase on the development rig.
printf 'console=tty1 root=PARTUUID=%s rootfstype=ext4 fsck.repair=yes rootwait %s\n' \
	"$partuuid" "$tuning" > "$MNT/boot/firmware/cmdline.txt"
# write-card.sh parks config.txt as config.pnd so a freshly written card
# cannot hijack a netboot. Writing the real one here is what makes the
# card bootable, and it happens only now that it is the appliance.
rm -f "$MNT/boot/firmware/config.pnd"
cp "$SRC/board/rpi5/config.txt" "$MNT/boot/firmware/config.txt"
grep -q '^kernel=' "$MNT/boot/firmware/config.txt" ||
	printf 'kernel=kernel-mpcpi-rt.img\n' >> "$MNT/boot/firmware/config.txt"
printf 'PARTUUID=%s  /boot/firmware  vfat  defaults  0  2\nPARTUUID=%s  /  ext4  defaults,noatime  0  1\n' \
	"$(blkid -s PARTUUID -o value "$P1")" "$partuuid" > "$MNT/etc/fstab"
echo "  root   : PARTUUID=$partuuid"
echo "  tuning : $tuning"

log "payload"
install -d "$MNT/opt/mpc-pi-src" "$MNT/opt/mpc-roms" "$MNT/usr/local/bin"
rsync -a --delete "$SRC/" "$MNT/opt/mpc-pi-src/"
[ -d /opt/mpc-roms ] && rsync -a /opt/mpc-roms/ "$MNT/opt/mpc-roms/"
[ -f /usr/local/bin/mpc ] && install -m 0755 /usr/local/bin/mpc "$MNT/usr/local/bin/mpc"
for s in mpcpi-latency-hold mpcpi-irq-affinity; do
	[ -f "$SRC/scripts/pios/$s" ] &&
		install -m 0755 "$SRC/scripts/pios/$s" "$MNT/usr/local/sbin/$s"
done
# The overlay carries udev rules, modprobe.d and /usr/bin helpers -
# including the caiaq blacklist without which the Maschine cannot be
# claimed from userspace.
[ -d "$SRC/board/rpi5/rootfs_overlay" ] &&
	rsync -a "$SRC/board/rpi5/rootfs_overlay/" "$MNT/"
echo "  src, roms, emulator, overlay"

log "chroot"
for d in dev dev/pts proc sys; do
	mkdir -p "$MNT/$d"
	mountpoint -q "$MNT/$d" || mount --bind "/$d" "$MNT/$d"
done
cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true

if [ -z "$NO_APT" ]; then
	pkgs=$(grep -vE '^\s*#|^\s*$' "$SRC/board/rpi5/packages.list" | tr '\n' ' ')
	echo "  installing: $(echo "$pkgs" | wc -w) packages"
	chroot "$MNT" /bin/bash -c "
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y --no-install-recommends $pkgs
	" || die "package installation failed"
else
	echo "  --no-apt: skipping package installation"
fi

log "users and units"
chroot "$MNT" /bin/bash -s <<'CHROOT'
set -e
id mpc >/dev/null 2>&1 || useradd -m -u 1001 -s /bin/bash \
	-G audio,video,plugdev,input,render mpc
# The appliance has no display manager to reach.
systemctl set-default multi-user.target >/dev/null 2>&1 || true
# Unit policy from the committed preset, applied per directive - never
# preset-all, whose fallback for unlisted units is `enable`.
if [ -f /opt/mpc-pi-src/scripts/pios/mpcpi-appliance.preset ]; then
	install -D -m 0644 /opt/mpc-pi-src/scripts/pios/mpcpi-appliance.preset \
		/etc/systemd/system-preset/10-mpcpi.preset
	while read -r verb unit; do
		case "$verb" in
		enable|disable) systemctl "$verb" "$unit" >/dev/null 2>&1 || true ;;
		esac
	done < /etc/systemd/system-preset/10-mpcpi.preset
fi
# userconfig blocks boot forever waiting on a console nobody answers.
systemctl mask userconfig.service systemd-networkd-wait-online.service \
	NetworkManager.service rpi-usb-gadget-ics.service >/dev/null 2>&1 || true
CHROOT
echo "  mpc user, preset applied, boot blockers masked"

log "done"
cat <<EOF
  Card is provisioned. Remaining, deliberately NOT done here:

    * tune-realtime.sh has not been run - it writes runtime state
      (governor, sysfs, PipeWire config) that belongs to a booted
      system, not a mounted filesystem. Its unit files are installed
      and will apply on first boot.
    * Nothing has been measured. Boot from the card and run
      scripts/pios/verify.sh, which now FAILS on a stock kernel and
      compares isolation in effect against the tuning file.

  Shut down, move the card to the boot slot, and remove the netboot
  server's claim if you want the card to win:
    sudo mpcpi-netboot stop      (on the development host)
EOF
