#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame"}
mame_bin=${MAME_BIN:-"$mame_source_dir/mpc"}
rom_dir=${MAME_ROM_DIR:-"$repo_root/roms"}
result_dir=${MAME_RESULT_DIR:-"$repo_root/results"}
systems=(mpc2000xl mpc3000 mpc60scsi)
bioses=(default vailixi v214)
require_roms=0

if [[ ${1:-} == --require-roms ]]; then
    require_roms=1
elif [[ $# -ne 0 ]]; then
    printf 'usage: %s [--require-roms]\n' "$0" >&2
    exit 2
fi

if [[ ! -x "$mame_bin" ]]; then
    printf 'error: release MAME binary not found at %s; run scripts/build-mame.sh first\n' "$mame_bin" >&2
    exit 1
fi

mkdir -p -- "$rom_dir" "$result_dir/rom-manifests"
mkdir -p -- "$result_dir/runtime/cfg" "$result_dir/runtime/diff" "$result_dir/runtime/nvram" "$result_dir/runtime/snap" "$result_dir/runtime/sta"

"$mame_bin" -validate
"$mame_bin" -listfull 'mpc*' >"$result_dir/systems.txt"
for expected_system in mpc2000xl mpc3000 mpc60 mpc60scsi; do
    if ! grep -q "^$expected_system[[:space:]]" "$result_dir/systems.txt"; then
        printf 'error: focused MAME binary does not contain %s\n' "$expected_system" >&2
        exit 1
    fi
done

if ! "$mame_bin" -showusage | grep -q 'portaudio'; then
    printf 'error: focused MAME binary does not advertise PortAudio\n' >&2
    exit 1
fi

roms_ready=1
for index in "${!systems[@]}"; do
    system_name=${systems[$index]}
    bios_name=${bioses[$index]}
    "$mame_bin" "$system_name" -listroms >"$result_dir/rom-manifests/$system_name.txt"
    if timeout --signal=INT --kill-after=2s 10s "$mame_bin" "$system_name" \
        -rompath "$rom_dir" \
        -bios "$bios_name" \
        -sound none \
        -video none \
        -seconds_to_run 1 \
        -skip_gameinfo \
        -cfg_directory "$result_dir/runtime/cfg" \
        -diff_directory "$result_dir/runtime/diff" \
        -nvram_directory "$result_dir/runtime/nvram" \
        -snapshot_directory "$result_dir/runtime/snap" \
        -state_directory "$result_dir/runtime/sta" \
        >"$result_dir/$system_name-rom-load.log" 2>&1; then
        printf '%s selected BIOS (%s): PASS\n' "$system_name" "$bios_name"
    else
        printf '%s selected BIOS (%s): FAIL\n' "$system_name" "$bios_name"
        grep -E 'NOT FOUND|Fatal error|exception|core dumped' "$result_dir/$system_name-rom-load.log" || true
        roms_ready=0
    fi
done

printf 'Driver validation: PASS\n'
printf 'PortAudio module: PASS\n'
printf 'ROM manifests: %s\n' "$result_dir/rom-manifests"

if (( require_roms && ! roms_ready )); then
    exit 1
fi
