#!/bin/bash
# One-time setup so netboot can be driven without a password afterwards.
#
# Run this ONCE with sudo. After it, `sudo -n mpcpi-netboot start|stop|
# status` works with no prompt, which is what lets the assistant iterate
# on the appliance without waiting for a human.
#
#   sudo scripts/netboot/install-privileges.sh
#
# What it does, and why each part is shaped this way:
#
#  * Copies the netboot script to /usr/local/sbin, owned by root and not
#    writable by the user. This is the part that matters: a NOPASSWD rule
#    pointing at a user-writable script is just passwordless root with
#    extra steps, because anyone who can edit the script can run anything
#    as root. Root-owning the target closes that.
#  * Writes a sudoers rule scoped to that ONE command, validated with
#    visudo before install so a syntax error cannot lock you out of sudo.
#  * Pins the interface, so the server can never bind an unplugged
#    dongle again.
set -euo pipefail

REPO="/home/jopdorp/development/mpc-pi"
SRC="$REPO/scripts/netboot/mpcpi-netboot"
DEST="/usr/local/sbin/mpcpi-netboot"
SUDOERS="/etc/sudoers.d/mpcpi-netboot"
IFACE_FILE="/etc/mpcpi-netboot.iface"
USER_NAME="${SUDO_USER:-jopdorp}"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

# Pick the wired interface that has a cable in it right now.
pin=""
for i in /sys/class/net/*; do
	n=$(basename "$i")
	case "$n" in lo|wl*|docker*|virbr*|veth*|tap*|wg*|br-*|mpqemubr*) continue ;; esac
	if [ "$(cat "$i/carrier" 2>/dev/null)" = "1" ]; then pin="$n"; break; fi
done
if [ -n "${NETBOOT_IFACE:-}" ]; then pin="$NETBOOT_IFACE"; fi
if [ -n "$pin" ]; then
	echo "$pin" > "$IFACE_FILE"
	echo "pinned interface: $pin  ($IFACE_FILE)"
else
	echo "warning: no wired interface with a carrier; not pinning" >&2
fi

install -o root -g root -m 0755 "$SRC" "$DEST"
echo "installed $DEST (root-owned, not user-writable)"

tmp=$(mktemp)
cat > "$tmp" <<EOF
# Lets $USER_NAME drive the appliance netboot server without a password.
# Scoped to one root-owned command that takes no path arguments.
$USER_NAME ALL=(root) NOPASSWD: $DEST
EOF
if visudo -cqf "$tmp"; then
	install -o root -g root -m 0440 "$tmp" "$SUDOERS"
	echo "installed $SUDOERS"
else
	echo "sudoers syntax check FAILED - nothing installed" >&2
	rm -f "$tmp"; exit 1
fi
rm -f "$tmp"

# NFS needs the export present; add it once so runtime needs no root.
NFS_ROOT="$REPO/.cache/br-rpi5/target"
if [ -d "$NFS_ROOT" ] && ! grep -qF "$NFS_ROOT" /etc/exports 2>/dev/null; then
	echo "$NFS_ROOT 192.168.7.0/24(rw,sync,no_subtree_check,no_root_squash)" \
		>> /etc/exports
	exportfs -ra || true
	echo "added NFS export for $NFS_ROOT"
fi

echo
echo "done. verify with:   sudo -n mpcpi-netboot status"
