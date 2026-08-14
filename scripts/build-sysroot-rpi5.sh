#!/usr/bin/env bash
set -euo pipefail

# Build (or update) the Buildroot sysroot the RPi 5 appliance image and the
# MAME cross compile both link against.
#
# HOSTCC/HOSTCXX are pinned to gcc-13 deliberately: several host packages
# (m4's bundled gnulib first among them) do not parse glibc 2.43's headers
# under the C23 default that gcc 15 introduced. gcc-13 defaults to C17.
#
# Usage:
#   scripts/build-sysroot-rpi5.sh              # configure + full build
#   scripts/build-sysroot-rpi5.sh <targets...> # specific packages, e.g. sdl2

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
buildroot=${BUILDROOT_DIR:-/home/jopdorp/development/rpi-pedal-buildroot/buildroot-2025.11}
br_output=${BR_OUTPUT:-"$repo_root/.cache/br-rpi5"}

if [[ ! -f "$buildroot/Makefile" ]]; then
    printf 'error: buildroot not found at %s (set BUILDROOT_DIR)\n' "$buildroot" >&2
    exit 1
fi
for tool in gcc-13 g++-13; do
    command -v "$tool" >/dev/null || {
        printf 'error: %s not found; install with: sudo apt install gcc-13 g++-13\n' "$tool" >&2
        exit 1
    }
done

host_pin=(HOSTCC=gcc-13 HOSTCXX=g++-13)

if [[ ! -f "$br_output/.config" ]]; then
    make -C "$buildroot" O="$br_output" BR2_EXTERNAL="$repo_root" \
        "${host_pin[@]}" mpcpi_rpi5_defconfig
fi

if [[ $# -gt 0 ]]; then
    exec make -C "$buildroot" O="$br_output" "${host_pin[@]}" "$@"
fi
exec make -C "$buildroot" O="$br_output" "${host_pin[@]}"
