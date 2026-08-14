#!/usr/bin/env bash
# Install pieces that belong to the appliance but not to any package: the ROM
# set the emulator boots from. TARGET_DIR is $1.
set -euo pipefail
TARGET_DIR="$1"
EXTERNAL="$(dirname "$0")/../.."
install -D -m 0644 "$EXTERNAL/roms/mpc2000xl.zip" \
    "$TARGET_DIR/usr/share/mpc-pi/roms/mpc2000xl.zip"
