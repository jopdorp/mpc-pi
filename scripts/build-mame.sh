#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame"}
mame_jobs=${MAME_JOBS:-4}
# Optional performance build configuration. MAME_ARCHOPTS feeds compiler and
# linker flags (genie applies it to both); MAME_LTO enables link-time
# optimization. Genie makefiles do not track flag changes, so a stamp file
# forces a clean object tree whenever the configuration differs.
mame_archopts=${MAME_ARCHOPTS:-}
mame_lto=${MAME_LTO:-0}
mame_sources=src/mame/akai/mpc60.cpp,src/mame/akai/mpc2000.cpp,src/mame/akai/mpc3000.cpp
# The whole ordered stack from patches/mame/, numbered and sorted, exactly as
# build-mame-rpi5.sh takes it. A hand-maintained list here froze at patch 0044
# while the directory grew to 0052, so the desktop build silently lost the
# panel-injection fixes, MIDI CC wheel/slider support and the sampling input.
mapfile -t mame_patches < <(ls "$repo_root"/patches/mame/0*.patch | sort)

if [[ ! -f "$mame_source_dir/makefile" ]]; then
    printf 'error: MAME source not found at %s; run scripts/bootstrap-mame.sh first\n' "$mame_source_dir" >&2
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

flags_stamp="$mame_source_dir/build/.mpc-flags"
flags_now="archopts=$mame_archopts lto=$mame_lto"
if [[ ! -f "$flags_stamp" || "$(cat "$flags_stamp" 2>/dev/null)" != "$flags_now" ]]; then
    printf 'Build flags changed; clearing object tree for a clean rebuild\n'
    rm -rf "$mame_source_dir/build/linux_gcc/obj" "$mame_source_dir/build/linux_gcc/bin"
    mkdir -p "$mame_source_dir/build"
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

make_arguments=(
    SUBTARGET=mpc
    SOURCES="$mame_sources"
    USE_QTDEBUG=0
    DEBUG=0
    SYMBOLS=0
    REGENIE=1
)
[[ -z "$mame_archopts" ]] || make_arguments+=(ARCHOPTS="$mame_archopts")
[[ "$mame_lto" != 1 ]] || make_arguments+=(LTO=1)
make -C "$mame_source_dir" "${make_arguments[@]}" -j"$mame_jobs"

test -x "$mame_source_dir/mpc"
"$mame_source_dir/mpc" -help | sed -n '1p'
