#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame"}
mame_jobs=${MAME_JOBS:-4}
mame_sources=src/mame/akai/mpc60.cpp,src/mame/akai/mpc2000.cpp,src/mame/akai/mpc3000.cpp
mame_patches=(
    "$repo_root/patches/mame/0001-hd61830-guard-unconfigured-text-pitch.patch"
    "$repo_root/patches/mame/0002-mpc60-add-vimana-3.15-bios.patch"
    "$repo_root/patches/mame/0003-akai-dsp-reset-voice-state-on-key-on.patch"
    "$repo_root/patches/mame/0004-pipewire-audio-clock-and-low-latency-buffer.patch"
    "$repo_root/patches/mame/0005-skip-emulation-warning-with-skip-gameinfo.patch"
    "$repo_root/patches/mame/0006-sdl-asynchronous-rendering.patch"
    "$repo_root/patches/mame/0007-clock-use-periodic-timer-for-50-percent-duty.patch"
    "$repo_root/patches/mame/0008-sdl-isolate-event-loop-from-emulation.patch"
    "$repo_root/patches/mame/0009-pipewire-use-primary-output-as-audio-clock.patch"
    "$repo_root/patches/mame/0010-sound-use-16-sample-host-updates.patch"
    "$repo_root/patches/mame/0011-pipewire-keep-one-producer-update-of-margin.patch"
    "$repo_root/patches/mame/0012-mb89371-use-direct-periodic-brg-timers.patch"
    "$repo_root/patches/mame/0013-sdl-synchronize-async-render-shutdown.patch"
    "$repo_root/patches/mame/0014-mb89371-batch-complete-brg-cycles.patch"
    "$repo_root/patches/mame/0015-i8251-complete-clock-cycle.patch"
    "$repo_root/patches/mame/0016-i8251-skip-stable-idle-high-rx-shifts.patch"
    "$repo_root/patches/mame/0017-i8251-skip-stable-idle-transmit-callbacks.patch"
    "$repo_root/patches/mame/0018-scheduler-cache-exact-cycle-divisors.patch"
    "$repo_root/patches/mame/0019-mpc2000xl-event-driven-panel-uart.patch"
    "$repo_root/patches/mame/0020-mpc2000xl-low-latency-midi-pad-input.patch"
    "$repo_root/patches/mame/0021-mpc2000xl-event-driven-midi-baud-clocks.patch"
)

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

make -C "$mame_source_dir" \
    SUBTARGET=mpc \
    SOURCES="$mame_sources" \
    USE_QTDEBUG=0 \
    DEBUG=0 \
    SYMBOLS=0 \
    REGENIE=1 \
    -j"$mame_jobs"

test -x "$mame_source_dir/mpc"
"$mame_source_dir/mpc" -help | sed -n '1p'
