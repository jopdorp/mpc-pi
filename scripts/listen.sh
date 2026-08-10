#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pipewire_frames=${1:-128}
default_disk="$repo_root/.cache/free-projects/midimark-demo1/DEMODISK.TD0"

if [[ ! -f "$default_disk" ]]; then
    printf 'error: default project disk is missing: %s\n' "$default_disk" >&2
    printf 'download https://www.midimark.com/mpcdemo1.zip and extract DEMODISK.TD0 there\n' >&2
    exit 1
fi

printf 'Default: MIDI Mark Demo 1, sequence 1, 96BPM-SNOOPBLAK\n'
printf 'The disk takes about 90 seconds to load; playback then starts automatically.\n'

exec "$repo_root/scripts/run-mpc.sh" mpc3000 "$pipewire_frames" \
    -flop "$default_disk" \
    -skip_gameinfo \
    -seconds_to_run 299 \
    -autoboot_script "$repo_root/scripts/lua/listen-loaded-mpc3000.lua"
