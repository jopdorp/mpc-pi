#!/bin/bash
# Turn a stock Raspberry Pi OS (64-bit, Bookworm+) into the MPC appliance.
#
# Run ON the Pi, as root. Idempotent: re-running upgrades in place, which
# is the whole point - the appliance is provisioned, not imaged, so a fix
# is an apt line rather than a card reflash.
#
# Why Debian rather than Buildroot: Ardour and every plugin in the design
# (LSP, guitarix, Dragonfly, x42, Zam) are packaged for Debian arm64 and
# none of them exist as Buildroot packages. Porting that dependency tree
# - boost, lilv/serd/sord, rubberband, aubio, fftw, taglib, waf - would
# cost weeks.
#
# But this is an INSTRUMENT, so the two things Buildroot would have given
# us for free are not optional and have to be bought back by hand:
#
#   * Fast boot. A player powers on and expects to play, not to watch a
#     distro start. Debian's default service set is the enemy here, so
#     tune-boot.sh strips it and MEASURES what is left.
#   * Predictable realtime. Stable is not "usually fine": one xrun in a
#     take is a ruined take. tune-realtime.sh pins the tuning and
#     verify.sh measures actual scheduling latency rather than asserting
#     it.
#
# Neither is a comment in a config file; both are scripts with numbers.
#
#   sudo ./provision.sh [--no-apt]
set -euo pipefail

REPO_SRC="${MPCPI_SRC:-/opt/mpc-pi-src}"
PREFIX="/opt/mpc-pi"
BOOT="/boot/firmware"
[ -d "$BOOT" ] || BOOT="/boot"

log() { printf '\n== %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

# --- packages --------------------------------------------------------

if [ "${1:-}" != "--no-apt" ]; then
log "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
# Audio engine and the verified effect set. Every one of these was
# instantiated in Ardour on the build host before being listed here.
apt-get install -y --no-install-recommends \
	ardour \
	lsp-plugins-lv2 \
	guitarix \
	dragonfly-reverb \
	x42-plugins \
	zam-plugins \
	pipewire pipewire-jack pipewire-alsa wireplumber \
	alsa-utils \
	python3 python3-usb \
	dtc device-tree-compiler \
	nfs-common
fi

# NAM is not in Debian: it ships as a prebuilt aarch64 LV2 that links
# only libc and libm. Building it locally is actively worse - the A2 fast
# path is reported slower on GCC 12, which is what Bookworm ships.
log "neural amp modeler (A2)"
NAM_DIR=/usr/lib/lv2/neural_amp_modeler.lv2
if [ ! -d "$NAM_DIR" ]; then
	tmp=$(mktemp -d)
	url="https://github.com/mikeoliphant/neural-amp-modeler-lv2/releases/latest/download/neural_amp_modeler_lv2_rpi5.tgz"
	if curl -fsSL "$url" -o "$tmp/nam.tgz"; then
		tar -xzf "$tmp/nam.tgz" -C /usr/lib/lv2/
		echo "installed NAM LV2"
	else
		echo "WARNING: could not fetch NAM; guitarix amps still work" >&2
	fi
	rm -rf "$tmp"
else
	echo "already present"
fi
mkdir -p /opt/mpc-pi/nam-models

# --- boot configuration ----------------------------------------------

log "boot config"
CFG="$BOOT/config.txt"
add_cfg() {
	grep -qxF "$1" "$CFG" 2>/dev/null || { echo "$1" >> "$CFG"; echo "  + $1"; }
}
grep -q "MPC-PI APPLIANCE" "$CFG" 2>/dev/null || cat >> "$CFG" <<'EOF'

# ===== MPC-PI APPLIANCE =====
EOF
# Onboard/HDMI audio off so the I2S card is the only sound device and
# lands on card 0, which is what the emulator's PipeWire path expects.
add_cfg "dtparam=audio=off"
add_cfg "dtoverlay=vc4-kms-v3d,noaudio"
# PCM5102A DAC + PCM1808 ADC on the shared I2S bus.
add_cfg "dtoverlay=mpc-audio"
# USB-C device mode, so the appliance can BE an audio interface.
add_cfg "dtoverlay=dwc2,dr_mode=peripheral"
add_cfg "enable_uart=1"

# The audio overlay is ours and must be compiled into the boot partition.
if [ -f "$REPO_SRC/board/rpi5/overlays/mpc-audio-overlay.dts" ]; then
	dtc -@ -I dts -O dtb -o "$BOOT/overlays/mpc-audio.dtbo" \
		"$REPO_SRC/board/rpi5/overlays/mpc-audio-overlay.dts" 2>/dev/null &&
		echo "  compiled mpc-audio.dtbo"
fi

# Isolate the emulator's cores. Appended rather than rewritten: the stock
# cmdline carries the root UUID and clobbering it bricks the boot.
CMD="$BOOT/cmdline.txt"
if ! grep -q "isolcpus" "$CMD" 2>/dev/null; then
	sed -i 's/$/ isolcpus=2-3 threadirqs/' "$CMD"
	echo "  + isolcpus=2-3 threadirqs"
fi

# --- payload ---------------------------------------------------------

log "appliance payload"
mkdir -p "$PREFIX"
for d in daw maschine; do
	if [ -d "$REPO_SRC/scripts/$d" ]; then
		mkdir -p "$PREFIX/$d"
		cp -r "$REPO_SRC/scripts/$d/." "$PREFIX/$d/"
	fi
done
[ -f "$REPO_SRC/.cache/mame/mpc" ] &&
	install -m0755 "$REPO_SRC/.cache/mame/mpc" /usr/local/bin/mpc
mkdir -p /usr/local/share/mpc-pi/roms
[ -d "$REPO_SRC/roms" ] && cp -r "$REPO_SRC/roms/." /usr/local/share/mpc-pi/roms/ || true

# --- realtime audio --------------------------------------------------

log "realtime limits"
cat > /etc/security/limits.d/95-mpcpi.conf <<'EOF'
# The emulator and Ardour both need RT scheduling; without memlock the
# JACK/PipeWire path fights the page cache under load.
@audio   -  rtprio     95
@audio   -  memlock    unlimited
@audio   -  nice      -19
EOF
usermod -aG audio "${SUDO_USER:-pi}" 2>/dev/null || true

# --- services --------------------------------------------------------

log "services"
cat > /etc/systemd/system/mpcpi-daw-ui.service <<EOF
[Unit]
Description=MPC-PI panel renderer (screen R)
After=multi-user.target

[Service]
# Runs even without the emulator or Ardour: the panel showing its own
# state is how you prove the display path works during bring-up.
ExecStart=/usr/bin/python3 $PREFIX/maschine/daw-ui-daemon.py --out /dev/shm/daw-ui --hz 30
Restart=always
RestartSec=2
User=${SUDO_USER:-pi}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/mpcpi-daw-ctl.service <<EOF
[Unit]
Description=MPC-PI loop engine and Ardour control
After=mpcpi-daw-ui.service

[Service]
ExecStart=/usr/bin/python3 $PREFIX/daw/daw-ctl --fifo /run/daw-ctl.fifo --state /dev/shm/daw-ui-state.json
Restart=always
RestartSec=2
User=${SUDO_USER:-pi}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mpcpi-daw-ui.service >/dev/null 2>&1 || true

log "done"
cat <<EOF
Provisioned. Reboot for the overlays and isolcpus to take effect.

Verify after reboot:
  aplay -l                       # expect the mpc-audio card
  lv2ls | wc -l                  # plugin count (expect 300+)
  systemctl status mpcpi-daw-ui
  ls /sys/class/udc              # USB gadget controller present
EOF
