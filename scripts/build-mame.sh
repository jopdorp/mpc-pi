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
    "$repo_root/patches/mame/0022-upd7810-coalesce-unconnected-timer-output.patch"
    "$repo_root/patches/mame/0023-mpc2000xl-v53-status-service-hle.patch"
    "$repo_root/patches/mame/0024-mpc2000xl-v53-event-service-hle.patch"
    "$repo_root/patches/mame/0025-nec-use-concrete-opcode-cache-access.patch"
    "$repo_root/patches/mame/0026-mpc2000xl-specialize-hot-v53-dispatch.patch"
    "$repo_root/patches/mame/0027-render-none-skip-unused-primitives.patch"
    "$repo_root/patches/mame/0028-sound-cache-device-interfaces.patch"
    "$repo_root/patches/mame/0029-sdl-generate-primitives-on-emulation-thread.patch"
    "$repo_root/patches/mame/0030-render-fixed-artwork-resolution.patch"
    "$repo_root/patches/mame/0031-mpc2000xl-optional-stereo-output.patch"
    "$repo_root/patches/mame/0032-mpc2000xl-v53-divide-superblock.patch"
    "$repo_root/patches/mame/0033-mpc2000xl-skip-unchanged-lcd-frames.patch"
    "$repo_root/patches/mame/0034-sound-derive-host-update-cadence.patch"
    "$repo_root/patches/mame/0035-nec-v33-direct-opcode-fetch-window.patch"
    "$repo_root/patches/mame/0036-nec-v33-direct-data-access-window.patch"
    "$repo_root/patches/mame/0037-nec-v33-idle-iteration-skip.patch"
    "$repo_root/patches/mame/0038-l7a1045-direct-wave-ram-window.patch"
    "$repo_root/patches/mame/0039-mpc2000xl-lcd-frame-export.patch"
    "$repo_root/patches/mame/0040-mpc2000xl-v53-wait-service-hles.patch"
    "$repo_root/patches/mame/0041-upd7810-timer-event-countdown.patch"
    "$repo_root/patches/mame/0042-mpc2000xl-panel-event-bus-hle.patch"
    "$repo_root/patches/mame/0043-mpc2000xl-input-and-dma-latency.patch"
    "$repo_root/patches/mame/0044-mpc2000xl-external-uart-clock.patch"
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
