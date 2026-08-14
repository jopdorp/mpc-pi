#!/usr/bin/env bash
# Compile the MPC audio overlay and stage boot files, then build the image.
set -euo pipefail

BOARD_DIR="$(dirname "$0")"
BINARIES_DIR="${BINARIES_DIR:-$1}"
# The overlay is compiled here rather than shipped as a blob so the source
# stays reviewable and tracks whatever kernel the build selected.
dtc_bin="${HOST_DIR}/bin/dtc"
[[ -x "$dtc_bin" ]] || dtc_bin=$(command -v dtc)
if [[ -z "$dtc_bin" ]]; then
    echo "post-image: no dtc available to build mpc-audio overlay" >&2
    exit 1
fi
mkdir -p "${BINARIES_DIR}/rpi-firmware/overlays"
"$dtc_bin" -@ -I dts -O dtb \
    -o "${BINARIES_DIR}/rpi-firmware/overlays/mpc-audio.dtbo" \
    "${BOARD_DIR}/overlays/mpc-audio-overlay.dts"

# config.txt and cmdline.txt are installed by the rpi-firmware package via
# BR2_PACKAGE_RPI_FIRMWARE_CONFIG_FILE / _CMDLINE_FILE.

# The upstream board/raspberrypi5/post-image.sh runs genimage after this one.
