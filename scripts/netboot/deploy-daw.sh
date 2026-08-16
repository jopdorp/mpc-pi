#!/bin/bash
# Install the DAW control layer into the netboot rootfs.
#
# These are the parts that need no cross-compilation - Python daemons,
# Lua session scripts, the panel renderer - so they can be deployed and
# iterated on without rebuilding Buildroot at all. Editing a file here
# and rebooting the Pi is the whole cycle.
#
# The audio ENGINE (Ardour and the LV2 plugins) is a separate problem and
# is deliberately not handled here: see docs/rpi5-buildroot.md.
#
#   deploy-daw.sh [target-root]
set -euo pipefail

REPO="/home/jopdorp/development/mpc-pi"
TARGET="${1:-$REPO/.cache/br-rpi5/target}"
DEST="$TARGET/opt/mpc-pi"

[ -d "$TARGET" ] || { echo "no target rootfs at $TARGET" >&2; exit 1; }

mkdir -p "$DEST/daw" "$DEST/maschine"

# Control layer: daemons, engine, bindings.
install -m 0755 "$REPO/scripts/daw/daw-ctl"                "$DEST/daw/"
install -m 0644 "$REPO/scripts/daw/daw_ctl.py"             "$DEST/daw/"
install -m 0644 "$REPO/scripts/daw/daw_ctl_clock.py"       "$DEST/daw/"
install -m 0644 "$REPO/scripts/daw/osc.py"                 "$DEST/daw/"
install -m 0644 "$REPO/scripts/daw/chains.py"              "$DEST/daw/"
install -m 0644 "$REPO/scripts/daw/chains.json"            "$DEST/daw/"
install -m 0644 "$REPO/scripts/daw/session-template.lua"   "$DEST/daw/"
install -m 0644 "$REPO/scripts/daw/session-governor.lua"   "$DEST/daw/"
install -m 0644 "$REPO/scripts/daw/transport-export.lua"   "$DEST/daw/"

# Panel: renderer, control map, plugin manifest, hub.
install -m 0644 "$REPO/scripts/maschine/ui.py"             "$DEST/maschine/"
install -m 0644 "$REPO/scripts/maschine/daw_ui.py"         "$DEST/maschine/"
install -m 0644 "$REPO/scripts/maschine/control_map.py"    "$DEST/maschine/"
install -m 0644 "$REPO/scripts/maschine/ardour_bindings.py" "$DEST/maschine/"
install -m 0644 "$REPO/scripts/maschine/plugins.py"        "$DEST/maschine/"
install -m 0755 "$REPO/scripts/maschine/daw-ui-daemon.py"  "$DEST/maschine/"
install -m 0755 "$REPO/scripts/maschine/maschine-hub.py"   "$DEST/maschine/"

# The panel renderer imports its siblings by directory, and daw-ctl
# imports across both, so make the layout on the Pi match the repo.
cat > "$TARGET/etc/init.d/S40dawctl" <<'EOF'
#!/bin/sh
# The DAW control layer. Starts only if an audio engine is present:
# without Ardour there is nothing for it to drive, and a daemon looping
# on a missing socket is worse than one that says why it stopped.
case "$1" in
start)
	if [ ! -x /usr/bin/ardour9 ] && [ ! -x /usr/local/bin/ardour9 ]; then
		echo "daw-ctl: no Ardour on this image, skipping"
		exit 0
	fi
	printf 'Starting daw-ctl: '
	/usr/bin/python3 /opt/mpc-pi/daw/daw-ctl \
		--fifo /run/daw-ctl.fifo \
		--state /dev/shm/daw-ui-state.json \
		>/var/log/daw-ctl.log 2>&1 &
	echo "OK"
	;;
stop)
	pkill -f "daw/daw-ctl" 2>/dev/null
	;;
restart) "$0" stop; "$0" start ;;
esac
EOF
chmod 0755 "$TARGET/etc/init.d/S40dawctl"

cat > "$TARGET/etc/init.d/S41dawui" <<'EOF'
#!/bin/sh
# Renders screen R and publishes it as an MPCL frame. Runs even without
# Ardour: the panel showing its own state is useful during bring-up, and
# it is how you tell the display path works before the DAW exists.
case "$1" in
start)
	printf 'Starting daw-ui: '
	/usr/bin/python3 /opt/mpc-pi/maschine/daw-ui-daemon.py \
		--out /dev/shm/daw-ui --hz 30 \
		>/var/log/daw-ui.log 2>&1 &
	echo "OK"
	;;
stop)
	pkill -f "daw-ui-daemon" 2>/dev/null
	;;
restart) "$0" stop; "$0" start ;;
esac
EOF
chmod 0755 "$TARGET/etc/init.d/S41dawui"

echo "deployed DAW control layer to $DEST"
find "$DEST" -type f | wc -l | xargs echo "files:"
echo "init scripts: S40dawctl (needs Ardour), S41dawui (runs regardless)"

# ---------------------------------------------------------------------
# Raspberry Pi OS roots need more than a payload drop: they are systemd,
# and they ship with no login at all. Everything below is a no-op on the
# Buildroot target, which has its own init and its own console.
# ---------------------------------------------------------------------
[ -x "$TARGET/lib/systemd/systemd" ] || exit 0
echo
echo "Raspberry Pi OS root detected - provisioning access"

# SSH, because an appliance with no login cannot be iterated on. Pi OS
# Lite ships sshd installed, disabled, and with no host keys and no user,
# so all three have to be supplied from here. Host keys are ordinary
# files with no architecture, so generating them on the build host is
# both legitimate and much faster than a first-boot service.
mkdir -p "$TARGET/etc/ssh"
for t in rsa ecdsa ed25519; do
	k="$TARGET/etc/ssh/ssh_host_${t}_key"
	[ -s "$k" ] || ssh-keygen -q -t "$t" -N "" -f "$k" -C "mpc-pi" </dev/null
done

# Key-only root login. The alternative is inventing a password for an
# appliance that should never have one.
PUBKEY=""
for c in /home/jopdorp/.ssh/id_ed25519.pub /home/jopdorp/.ssh/id_rsa.pub; do
	[ -s "$c" ] && { PUBKEY="$c"; break; }
done
if [ -n "$PUBKEY" ]; then
	mkdir -p "$TARGET/root/.ssh"
	cat "$PUBKEY" > "$TARGET/root/.ssh/authorized_keys"
	chmod 700 "$TARGET/root/.ssh"
	chmod 600 "$TARGET/root/.ssh/authorized_keys"
	echo "  authorized_keys <- $(basename "$PUBKEY")"
else
	echo "  WARNING: no public key found; ssh will refuse every login" >&2
fi

# Two independent switches, because they fail differently: the unit
# symlink is what actually starts sshd, and the /boot marker is what Pi
# OS's own sshswitch honours if the unit is ever reset.
mkdir -p "$TARGET/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/ssh.service \
	"$TARGET/etc/systemd/system/multi-user.target.wants/ssh.service"
touch "$TARGET/boot/firmware/ssh" 2>/dev/null || true

# The panel daemon as a real unit. Restart=always because a renderer
# that dies silently leaves a frozen screen, which reads as a hung
# instrument rather than a crashed process.
cat > "$TARGET/etc/systemd/system/mpcpi-daw-ui.service" <<'EOF'
[Unit]
Description=MPC-Pi panel renderer (screen R)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/mpc-pi/maschine/daw-ui-daemon.py --out /dev/shm/daw-ui --hz 30
Restart=always
RestartSec=1
Nice=-5

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/mpcpi-daw-ui.service \
	"$TARGET/etc/systemd/system/multi-user.target.wants/mpcpi-daw-ui.service"

echo "mpc-pi" > "$TARGET/etc/hostname"
sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tmpc-pi/' "$TARGET/etc/hosts" 2>/dev/null || true

# Put the whole Pi OS boot set back into TFTP. `deploy` copies the
# Buildroot kernel AND the Buildroot config.txt unconditionally, and
# config.txt is the one that decides which kernel actually runs.
#
# Restoring only the kernel is not enough and cost real hardware time:
# the Buildroot config.txt names `kernel=Image`, so the board loaded a
# Buildroot kernel against a Pi OS root, reached userspace far enough to
# set its hostname, and then died minutes later. From the outside that is
# indistinguishable from a failing power supply, and it was diagnosed as
# one twice.
#
# The stale Image is deleted rather than left in place. A kernel that
# must never be selected should not be sitting in the directory the
# bootloader reads.
TFTP="/srv/tftp/mpcpi"
if [ -d "$TARGET/boot/firmware" ] && [ -d "$TFTP" ]; then
	cp "$TARGET/boot/firmware"/kernel*.img "$TFTP/" 2>/dev/null || true
	cp "$TARGET/boot/firmware"/*.dtb "$TFTP/" 2>/dev/null || true
	cp "$TARGET/boot/firmware/config.txt" "$TFTP/config.txt" 2>/dev/null || true
	[ -d "$TARGET/boot/firmware/overlays" ] &&
		cp -r "$TARGET/boot/firmware/overlays" "$TFTP/" 2>/dev/null || true
	rm -f "$TFTP/Image"
	echo "  restored the Pi OS kernel, config.txt and overlays into $TFTP"
fi

# The RT kernel, if one has been built. Image and DTB go to TFTP, and -
# the part that is easy to forget - the modules go into the NFS root,
# because a kernel whose modules are missing boots and then quietly has
# no I2S, no gadget, no overlay support: it looks tuned and is actually
# gutted. config.txt gets an explicit kernel= line because on a Pi 5 the
# firmware's default pick is kernel_2712.img, which stays the stock
# fallback: put the SD card... rather, flip the kernel= line back and the
# board is stock again, which is the rollback story.
RTK="$REPO/.cache/rt-kernel/linux"
if [ -s "$RTK/arch/arm64/boot/Image" ] && [ -d "$TFTP" ]; then
	BRBIN="$REPO/.cache/br-rpi5/host/bin"
	rel=$(cat "$RTK/include/config/kernel.release" 2>/dev/null || echo unknown)
	if [ ! -d "$TARGET/lib/modules/$rel" ]; then
		echo "  installing modules $rel into the rootfs..."
		PATH="$BRBIN:$PATH" make -C "$RTK" ARCH=arm64 \
			CROSS_COMPILE=aarch64-linux- \
			INSTALL_MOD_PATH="$TARGET" modules_install >/dev/null 2>&1 ||
			echo "  WARNING: modules_install failed; NOT switching kernels" >&2
	fi
	if [ -d "$TARGET/lib/modules/$rel" ]; then
		cp "$RTK/arch/arm64/boot/Image" "$TFTP/kernel_2712_rt.img"
		cp "$RTK/arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dtb" \
			"$TFTP/" 2>/dev/null || true
		if grep -q "^kernel=" "$TFTP/config.txt" 2>/dev/null; then
			sed -i "s/^kernel=.*/kernel=kernel_2712_rt.img/" "$TFTP/config.txt"
		else
			printf '\nkernel=kernel_2712_rt.img\n' >> "$TFTP/config.txt"
		fi
		echo "  RT kernel $rel staged (kernel= set in TFTP config.txt)"
	fi
fi

# The realtime cmdline has to go where a netbooted board actually reads
# it. tune-boot.sh edits /boot/firmware/cmdline.txt, which is correct for
# a card in a slot and completely ignored over the network - the kernel
# takes its arguments from TFTP. Tuning "applied" cleanly and isolcpus
# was live while nohz_full was silently absent, which is the worst shape
# for a latency fix: present in the script, missing from the kernel.
#
# Appended rather than regenerated, so the nfsroot line stays owned by
# the one place that builds it, and re-running changes nothing.
CMDLINE="$TFTP/cmdline.txt"
if [ -f "$CMDLINE" ]; then
	line=$(tr -d '\n' < "$CMDLINE")
	# nohz_full and rcu_nocbs were absent while the board ran the stock
	# Pi OS kernel, which ships without CONFIG_NO_HZ_FULL and silently
	# ignores them - an option that cannot work reads, later, as a tuning
	# already applied. The mpcpi-rt kernel is built with NO_HZ_FULL and
	# RCU_NOCB_CPU, so on it they mean exactly what they say.
	for opt in nohz_full=2-3 rcu_nocbs=2-3 irqaffinity=0-1 audit=0; do
		case " $line " in
			*" $opt "*) ;;
			*) line="$line $opt" ;;
		esac
	done
	printf '%s\n' "$line" > "$CMDLINE"
	echo "  realtime cmdline in TFTP: nohz_full, rcu_nocbs, irqaffinity"
fi

# Enabling a unit in the rootfs does nothing to an already-running
# system, so a board that booted before this ran still has no sshd and
# needs one power cycle. Only the first one: from then on the reboot is
# `ssh root@mpc-pi reboot` and iteration needs nobody in the room.
echo "ssh: root@<pi> with your key; hostname mpc-pi"
echo "a board already running from before this deploy needs one reboot"
