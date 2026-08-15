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
