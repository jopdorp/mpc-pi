#!/usr/bin/env bash
set -euo pipefail

# Cross-build the focused MAME target for Windows x86-64 in the MSYS2
# UCRT64 toolchain image. The whole ordered patch stack applies at source
# level; the SDL-OSD and PipeWire patches have no effect here because the
# Windows OSD does not compile them, and the emu/driver patches are
# portable. A SEPARATE checkout from the desktop and Pi builds, for the
# same reason as build-mame-rpi5.sh: one genie project per tree.
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame-win"}
mame_jobs=${MAME_JOBS:-16}
image=${MPCPI_WIN_IMAGE:-mpcpi-mame-win}
mame_sources=src/mame/akai/mpc60.cpp,src/mame/akai/mpc2000.cpp,src/mame/akai/mpc3000.cpp

mapfile -t mame_patches < <(ls "$repo_root"/patches/mame/0*.patch | sort)

# The ASIO SDK (2.3.4, proprietary-or-GPLv3) feeds the toolchain image so
# PortAudio can be built with the ASIO host API. It is downloaded, never
# committed; .cache is the ignored work area.
asio_sdk_dir="$repo_root/.cache/asio-sdk/ASIOSDK"
if [[ ! -d "$asio_sdk_dir" ]]; then
    mkdir -p "$repo_root/.cache/asio-sdk"
    curl -sSL -o "$repo_root/.cache/asio-sdk/ASIO-SDK.zip" \
        "https://download.steinberg.net/sdk_downloads/ASIO-SDK_2.3.4_2025-10-15.zip"
    unzip -q -o "$repo_root/.cache/asio-sdk/ASIO-SDK.zip" -d "$repo_root/.cache/asio-sdk"
fi

# Small docker build context holding just the SDK and the PortAudio source;
# .cache at large must not become context (it contains multi-gigabyte MAME
# trees), and cloning inside the wine-based image can hang without a TTY.
context_dir="$repo_root/.cache/win-build-context"
mkdir -p -- "$context_dir"
docker run --rm -v "$context_dir":/work alpine chown -R "$(id -u):$(id -g)" /work
rm -rf -- "$context_dir"
mkdir -p -- "$context_dir"
mkdir -p "$context_dir"
cp -r -- "$asio_sdk_dir" "$context_dir/asio-sdk"
portaudio_dir="$context_dir/portaudio"
if [[ ! -d "$portaudio_dir/.git" ]]; then
    git clone --depth 1 --branch v19.7.0 https://github.com/portaudio/portaudio.git "$portaudio_dir"
fi

if [[ ! -f "$mame_source_dir/makefile" ]]; then
    printf 'error: MAME source not found at %s; run MAME_SOURCE_DIR=%s ./scripts/bootstrap-mame.sh first\n' \
        "$mame_source_dir" "$mame_source_dir" >&2
    exit 1
fi

if [[ ! "$mame_jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: MAME_JOBS must be a positive integer, got %s\n' "$mame_jobs" >&2
    exit 1
fi

if [[ -n "$(git -C "$mame_source_dir" status --porcelain --untracked-files=no)" ]]; then
    printf 'error: refusing to build from a dirty MAME checkout at %s\n' "$mame_source_dir" >&2
    exit 1
fi

# The wine build writes as a mapped root; hand the tree back so later runs
# can patch and clean it from the host.
docker run --rm -v "$mame_source_dir":/work alpine chown -R "$(id -u):$(id -g)" /work

# Genie makefiles do not track flag changes (see build-mame.sh): a stamp
# file forces a clean object tree whenever the genie-visible configuration
# differs, so a flag like USE_SYSTEM_LIB_PORTAUDIO cannot silently reuse
# the previous project and link the wrong PortAudio.
flags_stamp="$mame_source_dir/build/.mpc-flags"
flags_now="system-portaudio=1 subtarget=mpc sources=$mame_sources"
if [[ ! -f "$flags_stamp" || "$(cat "$flags_stamp" 2>/dev/null)" != "$flags_now" ]]; then
    printf 'Build flags changed; clearing object tree for a clean rebuild\n'
    rm -rf -- "$mame_source_dir/build"
    mkdir -p -- "$mame_source_dir/build"
    printf '%s' "$flags_now" >"$flags_stamp"
fi

patches_applied=0
cleanup_patch() {
    status=$?
    trap - EXIT
    for (( index=patches_applied - 1; index >= 0; index-- )); do
        if ! git -C "$mame_source_dir" apply --reverse "${mame_patches[index]}"; then
            printf 'error: failed to reverse MAME patch %s\n' "${mame_patches[index]}" >&2
            status=1
        fi
    done
    exit "$status"
}
trap cleanup_patch EXIT

for mame_patch in "${mame_patches[@]}"; do
    if ! git -C "$mame_source_dir" apply --check "$mame_patch"; then
        printf 'error: MAME compatibility patch does not apply cleanly: %s\n' "$mame_patch" >&2
        exit 1
    fi
    git -C "$mame_source_dir" apply "$mame_patch"
    (( patches_applied += 1 ))
done

docker build -q -t "$image" -f "$repo_root/scripts/docker/Dockerfile.msys2" "$context_dir" >/dev/null

# The MSYS2/Wine container runs as root, so the object files it writes into
# the mounted checkout come out root-owned; hand them back afterwards.
cleanup_ownership() {
    docker run --rm -v "$mame_source_dir":/work alpine chown -R "$(id -u):$(id -g)" /work
}
trap 'cleanup_ownership; cleanup_patch' EXIT

docker run --rm \
    -v "$mame_source_dir":/work -w /work \
    "$image" \
    msys2 -c "make -j$mame_jobs SUBTARGET=mpc SOURCES='$mame_sources' USE_QTDEBUG=0 DEBUG=0 SYMBOLS=0 REGENIE=1 USE_SYSTEM_LIB_PORTAUDIO=1"

test -f "$mame_source_dir/mpc.exe"
printf 'built %s/mpc.exe\n' "$mame_source_dir"
