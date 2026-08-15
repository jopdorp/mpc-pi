#!/bin/bash
# Strip Raspberry Pi OS down to something that boots like an instrument.
#
# A player powers on and expects to play. Debian's default service set is
# the obstacle, and most of it exists for a general-purpose desktop this
# appliance will never be. Every disable below is justified by what the
# appliance actually needs; nothing is removed just to save a package.
#
# This script only DISABLES services and adjusts boot flags - it removes
# no packages, so anything switched off here can be switched back on with
# one systemctl command if it turns out to be needed.
#
#   sudo ./tune-boot.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
BOOT="/boot/firmware"; [ -d "$BOOT" ] || BOOT="/boot"
log() { printf '\n== %s\n' "$*"; }

log "before"
systemd-analyze time 2>/dev/null || echo "  (systemd-analyze unavailable)"

log "services the appliance does not need"
# Grouped by why, because "disable these 14 units" is unmaintainable
# without the reason attached.
disable() {
	for u in "$@"; do
		if systemctl list-unit-files "$u" >/dev/null 2>&1; then
			systemctl disable --now "$u" >/dev/null 2>&1 && echo "  - $u" || true
		fi
	done
}
# Desktop and login plumbing: the appliance has no desktop.
disable lightdm.service gdm3.service cups.service cups-browsed.service \
        colord.service ModemManager.service
# Discovery and printing on a stage rig is noise, and avahi in particular
# wakes periodically.
disable avahi-daemon.service avahi-daemon.socket triggerhappy.service \
        triggerhappy.socket
# Periodic maintenance: these fire while you are playing.
disable apt-daily.timer apt-daily-upgrade.timer man-db.timer \
        e2scrub_all.timer fstrim.timer logrotate.timer \
        systemd-tmpfiles-clean.timer
# Waiting for network at boot costs seconds and the rig works offline.
disable NetworkManager-wait-online.service systemd-networkd-wait-online.service \
        dhcpcd.service.wait
# Bluetooth: nothing here uses it, and its stack polls.
disable bluetooth.service hciuart.service
# Swap: already off in the RT tuning, but its unit still delays boot.
disable dphys-swapfile.service

log "boot flags"
CFG="$BOOT/config.txt"
add_cfg() {
	grep -qxF "$1" "$CFG" 2>/dev/null || { echo "$1" >> "$CFG"; echo "  + $1"; }
}
# The firmware waits for nothing we need.
add_cfg "boot_delay=0"
add_cfg "disable_splash=1"
# Bluetooth's UART costs enumeration time and we disabled the stack.
add_cfg "dtoverlay=disable-bt"
# The Pi 5 has no analogue video and probing it is pure delay.
add_cfg "disable_overscan=1"

CMD="$BOOT/cmdline.txt"
add_cmd() {
	grep -qw -- "$1" "$CMD" 2>/dev/null || { sed -i "s/\$/ $1/" "$CMD"; echo "  + $1"; }
}
# Console output to the framebuffer is surprisingly expensive; keep the
# serial console (we need it for bring-up) but stop painting the screen.
add_cmd "quiet"
add_cmd "loglevel=3"
# Do not spend boot time probing for a filesystem check we do not want
# mid-gig; the appliance fscks on a schedule, not on every power cycle.
add_cmd "fsck.mode=skip"

log "journald"
# Persistent journald writes to the SD card during playback. Keep logs in
# RAM, bounded, so a long session cannot fill the card or stall on it.
install -d /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/95-mpcpi.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
SystemMaxUse=32M
EOF

log "after (reboot to see the real number)"
cat <<'EOF'
  systemd-analyze time
  systemd-analyze blame | head -20
  systemd-analyze critical-chain

Anything still slow will name itself in `blame`. Disable it there rather
than guessing here - the point of measuring is that the list above is a
starting set, not a finished one.
EOF
