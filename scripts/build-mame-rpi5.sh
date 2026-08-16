#!/usr/bin/env bash
set -euo pipefail

# Cross compile MAME for the Raspberry Pi 5 appliance.
#
# Deliberately separate from the Buildroot tree: the emulator is rebuilt far
# more often than the image, and wrapping it as a package meant a full package
# rebuild for every change.
#
# The sysroot is the ROOTFS THE BOARD ACTUALLY RUNS. That used to be
# Buildroot's, correctly - the binary has to link against exactly the
# libraries in the image it ships with. Then the appliance base moved to
# Raspberry Pi OS and this script did not, so it kept building against a
# rootfs the board no longer boots. The result ran nowhere: every NEEDED
# library present, interpreter resolved, highest requirement GLIBC_2.38
# against Debian's 2.41, and a segfault before main() - built against
# Buildroot's glibc, started by Debian's.
#
# MPC_SYSROOT points at the netboot rootfs by default. Buildroot's
# cross-gcc is 14.3.0 and Debian trixie ships gcc 14 with
# libstdc++.so.6.0.33, so the toolchain is fine; only the sysroot was
# wrong.
#
# Produces board/rpi5/rootfs_overlay/usr/bin/mpc, which the next Buildroot
# image build picks up automatically.
#
# Usage:
#   scripts/build-mame-rpi5.sh              # build with the default output dir
#   MAME_JOBS=8 scripts/build-mame-rpi5.sh
#
# Prerequisite: the Buildroot sysroot must exist. Create it with
#   make -C <buildroot> O=<output> BR2_EXTERNAL=<this repo> mpcpi_rpi5_defconfig
#   make -C <buildroot> O=<output> sdl2 pipewire alsa-lib fontconfig \
#        freetype flac sqlite portmidi expat zlib

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame"}
br_output=${BR_OUTPUT:-"$repo_root/.cache/br-rpi5"}
mame_jobs=${MAME_JOBS:-$(nproc)}
out_binary="$repo_root/board/rpi5/rootfs_overlay/usr/bin/mpc"

host_dir="$br_output/host"
staging_dir="$br_output/staging"
# The prefix differs between an internal toolchain and an external one
# (aarch64-buildroot-linux-gnu- vs aarch64-linux-), so discover it.
cross_gcc=$(ls "$host_dir"/bin/aarch64-*-gcc 2>/dev/null | grep -v '\.br_real$' | head -1 || true)
cross_prefix=${cross_gcc%gcc}

for required in "$host_dir" "$staging_dir" "$cross_gcc"; do
    if [[ -z "$required" || ! -e "$required" ]]; then
        printf 'error: no aarch64 toolchain under %s\n' "$host_dir" >&2
        printf 'build the Buildroot sysroot first; see the header of this script\n' >&2
        exit 1
    fi
done
printf 'toolchain: %s\n' "$cross_gcc"

if [[ -n "$(git -C "$mame_source_dir" status --porcelain --untracked-files=no)" ]]; then
    printf 'error: refusing to build from a dirty MAME checkout at %s\n' "$mame_source_dir" >&2
    exit 1
fi

# Same ordered stack the desktop build applies, reversed on exit so the
# checkout is left as it was found whether or not the build succeeds.
mapfile -t mame_patches < <(ls "$repo_root"/patches/mame/0*.patch | sort)
patches_applied=0
cleanup() {
    status=$?
    trap - EXIT
    for (( index=patches_applied - 1; index >= 0; index-- )); do
        if ! git -C "$mame_source_dir" apply --reverse "${mame_patches[index]}"; then
            printf 'error: failed to reverse %s\n' "${mame_patches[index]}" >&2
            status=1
        fi
    done
    exit "$status"
}
trap cleanup EXIT

for mame_patch in "${mame_patches[@]}"; do
    if ! git -C "$mame_source_dir" apply --check "$mame_patch"; then
        printf 'error: patch does not apply cleanly: %s\n' "$mame_patch" >&2
        exit 1
    fi
    git -C "$mame_source_dir" apply "$mame_patch"
    (( patches_applied += 1 ))
done

# ARCHITECTURE is left empty on purpose. MAME derives it from the build host's
# uname, and PTR64=1 maps straight to _x64, which selects the linux_x64 target
# and passes -m64. An empty value selects the plain "linux" target, the one
# every non-x86 build uses.
#
# MAME composes $(TOOLCHAIN)$(OVERRIDE_CC) when probing the compiler version,
# so TOOLCHAIN stays unset here and the OVERRIDE_* values carry full paths.
# Setting both makes the probe fail and the build stops claiming it needs a
# newer GCC than the one it was handed.

# -ffp-contract=off is mandatory, not tuning: the DSP mixes in float and
# contracted multiply-add pairs change the rendered PCM, which would silently
# diverge from the reference render the desktop build is gated against.
# -DUSE_OZONE keeps bgfx's bundled EGL header off the X11 path. Its guard is
# "#elif defined(__unix__)", so MAME's own NO_X11 never reaches it, and this
# sysroot is KMS/DRM with no X11 headers at all. The types it selects instead
# are only used by bgfx's EGL context, which the appliance never creates.
archopts="-mcpu=cortex-a76 -ffp-contract=off -DUSE_OZONE"

# Build against the rootfs the Pi boots, not the one it used to.
MPC_SYSROOT="${MPC_SYSROOT:-/srv/nfs/mpcpi-pios}"
if [ -d "$MPC_SYSROOT/usr/lib/aarch64-linux-gnu" ]; then
    staging_dir="$MPC_SYSROOT"
    archopts="$archopts --sysroot=$MPC_SYSROOT"
    # Debian is multiarch: bits/wordsize.h and friends live under
    # /usr/include/aarch64-linux-gnu, a path Debian's own cross gcc
    # searches by default and Buildroot's does not. Adding it explicitly
    # is what lets a non-Debian toolchain use a Debian sysroot.
    archopts="$archopts -I$MPC_SYSROOT/usr/include/aarch64-linux-gnu"
    echo "sysroot: $MPC_SYSROOT (the netbooted Debian root)"
else
    echo "sysroot: $staging_dir (Buildroot - the board must be running it)" >&2
fi

# pkg-config has to look inside the sysroot, and Debian keeps its .pc
# files under the multiarch directory that Buildroot does not have.
export PKG_CONFIG="${PKG_CONFIG:-pkg-config}"
export PKG_CONFIG_SYSROOT_DIR="$staging_dir"
export PKG_CONFIG_LIBDIR="$staging_dir/usr/lib/aarch64-linux-gnu/pkgconfig:$staging_dir/usr/lib/pkgconfig:$staging_dir/usr/share/pkgconfig"

# Debian's own cross toolchain if it is installed - it is the exact
# compiler the target's libstdc++ was built with. Buildroot's gcc 14.3
# against a Debian gcc 14 sysroot works too, which is what this used
# before crossbuild-essential-arm64 was available.
if command -v aarch64-linux-gnu-g++ >/dev/null 2>&1; then
    export CROSS_BUILD_PREFIX="aarch64-linux-gnu-"
    echo "toolchain: Debian aarch64-linux-gnu ($(aarch64-linux-gnu-g++ -dumpversion))"
else
    echo "toolchain: Buildroot cross-gcc against the Debian sysroot"
fi
export SDL_INSTALL_ROOT="$staging_dir/usr"

make -C "$mame_source_dir" \
    SUBTARGET=mpc \
    SOURCES=src/mame/akai/mpc60.cpp,src/mame/akai/mpc2000.cpp,src/mame/akai/mpc3000.cpp \
    TARGETOS=linux \
    OSD=sdl \
    NO_X11=1 \
    NO_USE_PULSEAUDIO=1 \
    NO_OPENGL=1 \
    NO_USE_XINPUT=1 \
    USE_QTDEBUG=0 \
    DEBUG=0 \
    SYMBOLS=0 \
    NOWERROR=1 \
    ARCHITECTURE= \
    REGENIE=1 \
    CROSS_BUILD=1 \
    OVERRIDE_CC="${cross_prefix}gcc" \
    OVERRIDE_CXX="${cross_prefix}g++" \
    OVERRIDE_LD="${cross_prefix}g++" \
    AR="${cross_prefix}ar" \
    ARCHOPTS="$archopts" \
    LDOPTS="--sysroot=$staging_dir" \
    ${MAME_EXTRA_OPTS:-} \
    -j"$mame_jobs"

install -D -m 0755 "$mame_source_dir/mpc" "$out_binary"
# The checkout is shared with the desktop build: leaving the aarch64 binary
# as .cache/mame/mpc silently breaks every desktop harness that runs it.
rm -f "$mame_source_dir/mpc"
echo "note: removed aarch64 mpc from the checkout; desktop harnesses need"
echo "      scripts/build-mame.sh to restore the x86 binary"
printf '\nbuilt %s\n' "$out_binary"
file "$out_binary" | sed 's/^/  /'
