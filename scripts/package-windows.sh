#!/usr/bin/env bash
set -euo pipefail

# Assemble the redistributable Windows bundle from a cross-built mpc.exe.
# The mingw executable needs the UCRT64 runtime and SDL2 DLLs beside it;
# collect the transitive closure of DLL dependencies from the toolchain
# image rather than guessing a list. No ROMs: Akai firmware is copyrighted.
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame-win"}
mame_bin=${MAME_BIN:-"$mame_source_dir/mpc.exe"}
out_dir=${1:-"$repo_root/dist"}
version=${MPCPI_VERSION:-"$(date -u +%Y%m%d)-$(git -C "$repo_root" rev-parse --short --dirty HEAD)"}
name="mpcpi-$version-windows-x86_64"
image=${MPCPI_WIN_IMAGE:-mpcpi-mame-win}
repo_url=$(git -C "$repo_root" remote get-url origin | sed 's/\.git$//')

if [[ ! -f "$mame_bin" ]]; then
    printf 'error: Windows binary not found at %s; run scripts/build-mame-windows.sh first\n' "$mame_bin" >&2
    exit 1
fi
if ! command -v zip >/dev/null; then
    printf 'error: zip is required to package the Windows bundle\n' >&2
    exit 1
fi

# Two concurrent runs would rm -rf each other's staging tree; hold the
# output directory exclusively for the whole assembly.
mkdir -p -- "$out_dir"
exec 9>"$out_dir/.package.lock"
if ! flock -n 9; then
    printf 'error: another packaging run holds %s/.package.lock\n' "$out_dir" >&2
    exit 1
fi

staging="$out_dir/$name"
rm -rf -- "$staging"
mkdir -p "$staging"/{bin,roms,share/applications,share/icons}

cp -- "$mame_bin" "$staging/bin/mpc.exe"
cp -r -- "$mame_source_dir/plugins" "$staging/plugins"
cp -- "$mame_source_dir/COPYING" "$staging/COPYING"

# Transitive DLL closure: start from mpc.exe, copy every dependent DLL the
# toolchain provides (system DLLs are not in /ucrt64/bin and fall out), and
# follow the dependencies of what was copied. Strip the executable first;
# the build tree keeps its symbols for debugging. One command line: the
# wine-based msys2 wrapper does not preserve multi-line scripts.
# wine-based msys2 wrapper: the Linux mount is the process CWD (via -w),
# NOT an msys path - "cd /work" resolves inside the Wine filesystem. Use
# relative paths only; /ucrt64/bin is a real msys path.
docker run --rm \
    -w /work \
    -v "$staging/bin":/work \
    "$image" \
    msys2 -c 'strip --strip-unneeded mpc.exe && queue=mpc.exe && while [ -n "$queue" ]; do next= ; for f in $queue; do for dll in $(objdump -p "$f" | awk "/DLL Name/{print \$3}"); do if [ -f "/ucrt64/bin/$dll" ] && [ ! -f "./$dll" ]; then cp "/ucrt64/bin/$dll" . ; next="$next $dll" ; fi ; done ; done ; queue=$next ; done'

# Default entry: every accepted fast path, the accurate panel (the
# event-driven panel UART ghosts presses on desktop), the complete panel
# view, and the layout helper plugin for mouse-driven knobs and sliders.
cat >"$staging/mpcpi.bat" <<'BAT'
@echo off
setlocal
set MPC_PANEL_MODE=accurate
set MPC_PANEL_TIMER_MODE=accurate
set MPC_MIDI_CLOCK_MODE=event
set MPC_V53_STATUS_MODE=hle
set MPC_V53_EVENT_SERVICE_MODE=hle
set MPC_V53_DISPATCH_MODE=direct
set MPC_V53_DIVIDE_MODE=superblock
set MPC_V53_FETCH_MODE=window
set MPC_V53_IDLE_MODE=skip
set MPC_V53_FEED_FLAG_MODE=hle
set MPC_V53_TICK_READ_MODE=hle
set MPC_LCD_UPDATE_MODE=changed
set MAME_MPC_STEREO_ONLY=1
bin\mpc.exe mpc2000xl -rompath roms -pluginspath plugins -plugin layout -window -maximize %*
BAT

# Stock-accurate paths, and the entry for the other machines.
cat >"$staging/mpcpi-accurate.bat" <<'BAT'
@echo off
setlocal
if "%1"=="" (set SYSTEM=mpc2000xl) else (set SYSTEM=%1)
bin\mpc.exe %SYSTEM% -rompath roms -pluginspath plugins -plugin layout -window -maximize %2 %3 %4 %5 %6 %7 %8 %9
BAT

cat >"$staging/roms/PUT-YOUR-ROMS-HERE.txt" <<'ROMS'
This bundle ships no ROMs: the Akai firmware is copyrighted and may not be
redistributed. Place ROM sets you are legally entitled to use next to this
file, named exactly as MAME expects them:

    mpc2000xl.zip    Akai MPC2000XL (OS 1.20 dump set)
    mpc3000.zip      Akai MPC3000
    mpc60scsi.zip    Akai MPC60 (SCSI expansion)
    hd61830.zip      Hitachi HD61830 LCD controller ROM (MPC60 family)

Verify from the bundle directory:  bin\mpc.exe -listroms mpc2000xl
ROMS

cat >"$staging/README.md" <<README
# MPC-Pi Windows bundle $version

A focused MAME build (Akai MPC60, MPC3000, MPC2000XL only) carrying this
project's ordered patch stack, cross-compiled with MSYS2's UCRT64
toolchain.

## Requirements

* Windows 10/11 x86-64. Everything else the bundle needs (SDL2, runtime
  DLLs) is included beside the executable.

## ROMs

Unzip the bundle, put your own MPC ROM sets in \`roms/\` (see
\`roms/PUT-YOUR-ROMS-HERE.txt\`).

## Play

    mpcpi.bat                MPC2000XL, accepted fast paths, full panel
    mpcpi-accurate.bat       stock-accurate paths
    mpcpi-accurate.bat mpc3000

The panel's knobs and sliders are mouse-controlled through the bundled
layout helper plugin. Press Tab for MAME's input menu. UI text uses MAME's
built-in bitmap font: the Windows link did not pick up SDL2_ttf, so no
TrueType rendering is compiled in.

## Audio and timing on Windows

The Linux bundle paces the emulator from a patched PipeWire audio clock;
Windows has no equivalent port yet, so this build runs stock MAME timing
(video-throttled) with the default audio module. A WASAPI-exclusive audio
clock is the planned follow-up.

## Pad controllers

Any USB-MIDI pad controller (MPD18, MPD218, ...) can drive the machine's
own pads. List ports with \`bin\\mpc.exe -listmidi\`, then add
\`-midiin1 "PORT NAME"\` to the launcher's command line together with
\`set MPC_MIDI_INPUT_MODE=internal-pads\` above it. Notes 36-51 map to
pads 1-16 with velocity; CC 1 is the DATA wheel (relative), CC 2 the
NOTE VARIATION slider (absolute).

## Source and licence

GPL-2.0+ MAME with local modifications; see \`COPYING\`. Source and patch
stack: $repo_url at $version's tree.
README

( cd "$out_dir" && zip -q -r "$name.zip" "$name" && sha256sum "$name.zip" >"$name.zip.sha256" )

printf 'Packaged %s\n  %s/%s.zip (%s)\n' "$name" "$out_dir" "$name" \
    "$(du -h "$out_dir/$name.zip" | cut -f1)"
