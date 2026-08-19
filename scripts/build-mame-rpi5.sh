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
# rootfs the board no longer boots.
#
# That was a real bug and it is fixed here, but it was NOT the reason the
# binary died: every NEEDED library resolved and the highest requirement
# was GLIBC_2.38 against Debian's 2.41, which is fine. The segfault
# before main() was a 4K-aligned binary meeting a 16K-page kernel - see
# max_page below.
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
# The toolchain's bin directory - it holds the cross ld that -B must find.
cross_bin=$(dirname "$cross_gcc")

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
ldextra=""
if [ -d "$MPC_SYSROOT/usr/lib/aarch64-linux-gnu" ]; then
    staging_dir="$MPC_SYSROOT"
    archopts="$archopts --sysroot=$MPC_SYSROOT"
    # Debian is multiarch: bits/wordsize.h and friends live under
    # /usr/include/aarch64-linux-gnu, a path Debian's own cross gcc
    # searches by default and Buildroot's does not. Adding it explicitly
    # is what lets a non-Debian toolchain use a Debian sysroot.
    archopts="$archopts -I$MPC_SYSROOT/usr/include/aarch64-linux-gnu"
    # And the same multiarch problem on the link side, which bites
    # harder because it is silent in the wrong direction. Debian keeps
    # Scrt1.o, crti.o, crtn.o and libc.so under
    # /usr/lib/aarch64-linux-gnu; Buildroot's gcc looks only in
    # <sysroot>/usr/lib and <sysroot>/lib. -B adds a startfile prefix,
    # -L the library search path, and -rpath-link lets ld resolve the
    # DT_NEEDED of a shared library without recording a host path.
    # -B ALSO REDIRECTS THE SEARCH FOR ld, NOT JUST FOR LIBRARIES.
    #
    # This pointed only at the sysroot's library directory, which contains
    # no linker, so gcc fell through to the host's and tried to link
    # aarch64 objects with /usr/bin/x86_64-linux-gnu-ld.bfd:
    #
    #   ld.bfd: version.o: Relocations in generic ELF (EM: 183)
    #   ld.bfd: version.o: error adding symbols: file in wrong format
    #
    # EM 183 is AArch64 - every object was compiled correctly and only the
    # link was wrong, which is why the failure arrives after twenty minutes
    # of successful compilation rather than immediately.
    #
    # The toolchain's own bin directory goes first so its ld wins.
    ldextra="-B$cross_bin -B$MPC_SYSROOT/usr/lib/aarch64-linux-gnu"
    for d in usr/lib/aarch64-linux-gnu lib/aarch64-linux-gnu usr/lib; do
        ldextra="$ldextra -L$MPC_SYSROOT/$d -Wl,-rpath-link,$MPC_SYSROOT/$d"
    done
    echo "sysroot: $MPC_SYSROOT (the netbooted Debian root)"
else
    # Refuse rather than warn. This branch is how a Buildroot-linked
    # binary shipped in the first place: the message went to stderr, the
    # build succeeded, and the difference only appeared as an instant
    # segfault on the board an hour later. The appliance runs Debian; a
    # silent fallback to a sysroot it does not boot produces a binary
    # that is wrong in a way nothing on this host can detect.
    printf 'error: no Debian sysroot at %s\n' "$MPC_SYSROOT" >&2
    printf '       the board boots Raspberry Pi OS; linking against\n' >&2
    printf '       Buildroot staging produces a binary it cannot run.\n' >&2
    printf '       Set MPC_SYSROOT, or mount the netboot root.\n' >&2
    exit 1
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

# Align the LOAD segments for a 64K page, not the linker's 4K default.
#
# This is what "segfault before main()" actually was. The board runs a
# 16K-page kernel (bcm2712 defconfig; getconf PAGESIZE says 16384), and
# a binary whose segments are only 4K-aligned cannot be mapped by it at
# all: the loader gives up with "ELF load command address/offset not
# page-aligned" before a single instruction of the program runs.
#
# It was misread as a libc problem twice, because the symptom - dies
# instantly, no output, exit 139 - is what a glibc mismatch also looks
# like, and because the sysroot genuinely WAS wrong at the time. Fixing
# the sysroot changed nothing, which should have been the clue. The
# check at the end of this script is here so the next wrong guess costs
# a build instead of a day: ask the loader, not the theory.
#
# 64K rather than 16K so the same binary maps on a 4K, 16K or 64K page
# kernel. The cost is under 64KB of padding in a 54MB executable.
max_page=65536

# REGENIE only when the project actually needs regenerating.
#
# This passed REGENIE=1 on every invocation, which regenerates the GENie project
# files, which makes every object look out of date - so a one-line change to one
# .cpp recompiled the entire emulator. A full cross build is ~15 minutes; the
# incremental one it should have been is well under one.
#
# The project depends on the build parameters, not on the source, so regenerate
# when those change (or when the project is missing) and not otherwise. The
# stamp below is the same idea build-mame.sh already uses for its object tree.
regenie_stamp="$mame_source_dir/build/.mpcpi-rpi5-genie-stamp"
regenie_key=$(printf '%s|%s|%s|%s' \
    "$cross_prefix" "$MPC_SYSROOT" "$archopts" \
    'SUBTARGET=mpc OSD=sdl NO_X11=1 NO_USE_PULSEAUDIO=1 NO_OPENGL=1 NO_USE_XINPUT=1' |
    sha256sum | cut -d' ' -f1)
regenie_argument=()
if [[ ! -d "$mame_source_dir/build/projects" ]] ||
        [[ ! -f "$regenie_stamp" ]] ||
        [[ "$(cat "$regenie_stamp" 2>/dev/null)" != "$regenie_key" ]]; then
    printf 'build parameters changed (or first build); regenerating the project\n'
    regenie_argument=(REGENIE=1)
    mkdir -p "$(dirname "$regenie_stamp")"
    printf '%s' "$regenie_key" > "$regenie_stamp"
else
    printf 'project unchanged; incremental build\n'
fi

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
    "${regenie_argument[@]}" \
    CROSS_BUILD=1 \
    OVERRIDE_CC="${cross_prefix}gcc" \
    OVERRIDE_CXX="${cross_prefix}g++" \
    OVERRIDE_LD="${cross_prefix}g++" \
    AR="${cross_prefix}ar" \
    ARCHOPTS="$archopts" \
    LDOPTS="--sysroot=$staging_dir $ldextra -Wl,-z,max-page-size=$max_page" \
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

# Gate on the thing that cannot be seen by running it here: this host has
# 4K pages, so a binary that no 16K-page board can map runs fine on the
# desktop and dies on the target. Read the alignment out of the ELF and
# refuse to ship anything the board's loader would reject.
readelf_bin=$(command -v "${cross_prefix}readelf" || command -v readelf)
if [[ -n "$readelf_bin" ]]; then
    worst=$("$readelf_bin" -lW "$out_binary" |
        awk '$1 == "LOAD" { print strtonum($NF) }' | sort -n | head -1)
    if [[ -n "$worst" && "$worst" -lt 16384 ]]; then
        printf 'error: LOAD segments aligned to %s; the board pages at 16384\n' \
            "$worst" >&2
        printf '       the loader will refuse this binary before main()\n' >&2
        exit 1
    fi
    printf '  segment alignment: %s (board pages at 16384)\n' "$worst"
fi
