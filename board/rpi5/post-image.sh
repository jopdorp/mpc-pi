#!/usr/bin/env bash
# Compile the MPC audio overlay and stage boot files, then build the image.
set -euo pipefail

BOARD_DIR="$(dirname "$0")"
BINARIES_DIR="${BINARIES_DIR:-$1}"
GENIMAGE_CFG="${BOARD_DIR}/genimage.cfg"

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

install -m 0644 "${BOARD_DIR}/config.txt" "${BINARIES_DIR}/rpi-firmware/config.txt"
install -m 0644 "${BOARD_DIR}/cmdline.txt" "${BINARIES_DIR}/rpi-firmware/cmdline.txt"

if [[ -f "$GENIMAGE_CFG" ]]; then
    support/scripts/genimage.sh -c "$GENIMAGE_CFG"
fi
