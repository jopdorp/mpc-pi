#!/usr/bin/env bash
set -euo pipefail

# Assemble a redistributable desktop bundle from a built emulator binary and
# the repo launchers. The bundle carries no ROMs: Akai firmware is
# copyrighted, so the recipient supplies their own dumps into roms/.
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame"}
mame_bin=${MAME_BIN:-"$mame_source_dir/mpc"}
out_dir=${1:-"$repo_root/dist"}
# The packaging host may not be the binary's host (cross builds), so the
# architecture is a parameter rather than uname.
arch=${MPCPI_ARCH:-$(uname -m)}
version=${MPCPI_VERSION:-"$(date -u +%Y%m%d)-$(git -C "$repo_root" rev-parse --short --dirty HEAD)"}
name="mpcpi-$version-linux-$arch"
repo_url=$(git -C "$repo_root" remote get-url origin | sed 's/\.git$//')

if [[ ! -x "$mame_bin" ]]; then
    printf 'error: emulator binary not found at %s; run scripts/build-mame.sh first\n' "$mame_bin" >&2
    exit 1
fi
if [[ ! -f "$mame_source_dir/COPYING" ]]; then
    printf 'error: MAME licence not found at %s/COPYING; the bundle may not ship without it\n' \
        "$mame_source_dir" >&2
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
mkdir -p "$staging"/{bin,scripts,roms,share/applications,share/icons}

# Strip a copy; the build tree keeps its symbols for profiling.
cp -- "$mame_bin" "$staging/bin/mpc"
strip --strip-unneeded "$staging/bin/mpc"

# A binary that misses a shared library fails on machines that lack it, so
# resolve every dependency here instead of at the recipient's first launch.
if missing=$(ldd "$staging/bin/mpc" 2>/dev/null | grep 'not found' || true); then
    if [[ -n "$missing" ]]; then
        printf 'error: binary has unresolved shared libraries:\n%s\n' "$missing" >&2
        exit 1
    fi
else
    printf 'error: ldd failed on the packaged binary\n' >&2
    exit 1
fi

cp -- "$repo_root/scripts/run-mpc.sh" "$repo_root/scripts/run-mpc2000xl-fast.sh" \
    "$repo_root/scripts/run-mpc2000xl-turbo.sh" "$staging/scripts/"
# The appliance's ExecStartPost fix: MAME's audio threads inherit the
# emulation thread's SCHED_RR and starve behind it (9.7% -> 101.6% of
# realtime audio when raised). The bundle runs it right after launch, as
# docs/audio-chain.md prescribes.
cp -- "$repo_root/board/rpi5/rootfs_overlay/usr/bin/mpc-audio-thread-priority.sh" \
    "$staging/scripts/"
# The Maschine MK1 hub stack. Appliance-proven; the desktop wiring is provided
# by mpcpi-maschine but marked experimental in the README until it has been
# verified with hardware attached to a desktop.
mkdir -p "$staging/maschine"
cp -- "$repo_root"/scripts/maschine/*.py "$staging/maschine/"

# Default entry is the accepted fast preset: every measured, timing-preserving
# speed path on, at the tuned 44.1 kHz/q32 desktop settings - but with the
# complete MPC panel in the window instead of the preset's LCD-only view,
# because a bundle ships to people who want the machine on screen. The turbo
# preset is intentionally not bundled: it is headless (appliance panel export)
# and its internal-pads input path intentionally changes latency.
cat >"$staging/mpcpi" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
here=\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)
export MAME_BIN="\$here/bin/mpc"
export MAME_ROM_DIR="\$here/roms"
export MAME_RUNTIME_DIR="\$here/runtime"
# The full CPU range comes from the kernel, not nproc: nproc reports the
# caller's affinity mask, which can be narrower than the machine (agent
# shells, cgroup limits) and silently excludes cores. On hybrid CPUs pin to
# the P-cores for the tuned latency (MPC_CPUSET=0-11 on a Core Ultra).
all_cpus=\$(cat /sys/devices/system/cpu/online)
all_cpus=\${all_cpus#0-}
export MAME_CPUSET="\${MAME_CPUSET:-0-\${all_cpus:-0}}"
# Raise MAME's audio threads above the emulation thread once it is up;
# without the realtime rlimit this is skipped with a warning.
raise_audio_threads()
{
    local mpid=
    for (( i = 0; i < 20; i++ )); do
        mpid=\$(pgrep -x mpc | head -1) && [ -n "\$mpid" ] && break
        sleep 1
    done
    [ -n "\$mpid" ] || return 0
    if ! "\$here/scripts/mpc-audio-thread-priority.sh"; then
        printf 'warning: could not raise audio thread priority (chrt); audio may underrun\n' >&2
    fi
    "\$here/scripts/mpcpi-sampler-input" || true
}
# The full panel, maximized: the fast preset's LCD-only 1240x300 view is a
# diagnostic shape, not what a player wants to look at.
export MPC_VIEW_NAME="\${MPC_VIEW_NAME:-Default Layout}"
export MPC_WINDOW_RESOLUTION="\${MPC_WINDOW_RESOLUTION:-auto}"
export MPC_MAXIMIZE="\${MPC_MAXIMIZE:-1}"
# The preset's event-driven panel UART ghosts button presses on the desktop -
# presses revert or are skipped. The accurate panel path (real panel CPU,
# stock UART timing) behaves; a desktop has the CPU headroom for it. The
# appliance is unaffected: it runs the panel HLE, a different path.
export MPC_PANEL_MODE="\${MPC_PANEL_MODE:-accurate}"
export MPC_PANEL_TIMER_MODE="\${MPC_PANEL_TIMER_MODE:-accurate}"
# Audio: rate-match the graph to the device (48 kHz on ACP-pinned drivers)
# and run the verified-clean 64-frame quantum. 32 frames is the untested
# opt-in.
# ACP-off is OPT-IN. Measured on this workstation (Meteor Lake HDA,
# SN6140): with ACP disabled the emulator never creates its PipeWire
# nodes at all and stalls at ~5% CPU, old and new binaries alike;
# restoring ACP brought it straight back. Auto-installing it turned a
# working machine into a black window, so it ships behind a flag.
if [ -n "\${MPCPI_DISABLE_ACP:-}" ]; then
    "\$here/scripts/mpcpi-audio-setup"
fi
export PIPEWIRE_RATE_HZ="\${PIPEWIRE_RATE_HZ:-48000}"
export MPC_PIPEWIRE_FRAMES="\${MPC_PIPEWIRE_FRAMES:-64}"
"\$here/scripts/run-mpc2000xl-fast.sh" \\
    -pluginspath "\$here/plugins" -plugin layout "\$@" &
fast_pid=\$!
raise_audio_threads
trap '"\$here/scripts/mpcpi-sampler-input" --stop 2>/dev/null || true' EXIT INT TERM
wait "\$fast_pid"
WRAPPER

# Stock-accurate paths, and the entry for the other machines (the fast
# paths are MPC2000XL-only): ./mpcpi-accurate mpc3000
cat >"$staging/mpcpi-accurate" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
here=\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)
export MAME_BIN="\$here/bin/mpc"
export MAME_ROM_DIR="\$here/roms"
export MAME_RUNTIME_DIR="\$here/runtime"
# See mpcpi for why the CPU range comes from the kernel, not nproc.
all_cpus=\$(cat /sys/devices/system/cpu/online)
all_cpus=\${all_cpus#0-}
export MAME_CPUSET="\${MAME_CPUSET:-0-\${all_cpus:-0}}"
# Audio setup and rate matching, as in mpcpi.
# ACP-off is OPT-IN. Measured on this workstation (Meteor Lake HDA,
# SN6140): with ACP disabled the emulator never creates its PipeWire
# nodes at all and stalls at ~5% CPU, old and new binaries alike;
# restoring ACP brought it straight back. Auto-installing it turned a
# working machine into a black window, so it ships behind a flag.
if [ -n "\${MPCPI_DISABLE_ACP:-}" ]; then
    "\$here/scripts/mpcpi-audio-setup"
fi
export PIPEWIRE_RATE_HZ="\${PIPEWIRE_RATE_HZ:-48000}"
"\$here/scripts/run-mpc.sh" "\${1:-mpc2000xl}" 64 "\${@:2}" &
fast_pid=\$!
# The audio-thread starvation fix applies to the accurate path too.
if "\$here/scripts/mpc-audio-thread-priority.sh"; then :; else
    printf 'warning: could not raise audio thread priority (chrt); audio may underrun\n' >&2
fi
"\$here/scripts/mpcpi-sampler-input" || true
trap '"\$here/scripts/mpcpi-sampler-input" --stop 2>/dev/null || true' EXIT INT TERM
wait "\$fast_pid"
WRAPPER
chmod +x "$staging/mpcpi" "$staging/mpcpi-accurate"

# Maschine MK1 as the front panel: hub owns the USB device, writes MPC-bound
# events as MIDI into a snd-virmidi port, and the emulator (turbo preset with
# the window put back) reads the same port. The virmidi card number is found
# at launch, because it depends on what else is plugged in.
cat >"$staging/mpcpi-maschine" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
here=\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)
export MAME_BIN="\$here/bin/mpc"
export MAME_ROM_DIR="\$here/roms"
export MAME_RUNTIME_DIR="\$here/runtime"
all_cpus=\$(cat /sys/devices/system/cpu/online)
all_cpus=\${all_cpus#0-}
export MAME_CPUSET="\${MAME_CPUSET:-0-\${all_cpus:-0}}"
# ACP-off is OPT-IN. Measured on this workstation (Meteor Lake HDA,
# SN6140): with ACP disabled the emulator never creates its PipeWire
# nodes at all and stalls at ~5% CPU, old and new binaries alike;
# restoring ACP brought it straight back. Auto-installing it turned a
# working machine into a black window, so it ships behind a flag.
if [ -n "\${MPCPI_DISABLE_ACP:-}" ]; then
    "\$here/scripts/mpcpi-audio-setup"
fi
export PIPEWIRE_RATE_HZ="\${PIPEWIRE_RATE_HZ:-48000}"
export MPC_PIPEWIRE_FRAMES="\${MPC_PIPEWIRE_FRAMES:-64}"

virmidi_card=\$(grep -l '^VirMIDI ' /proc/asound/card*/name 2>/dev/null | head -1 | grep -o 'card[0-9]*' | grep -o '[0-9]*' || true)
if [[ -z "\$virmidi_card" ]]; then
    printf 'error: no snd-virmidi card found; run: sudo modprobe snd-virmidi\n' >&2
    exit 1
fi
midi_device="/dev/snd/midiC\${virmidi_card}D0"
midi_port="Virtual Raw MIDI \${virmidi_card}-0"
if [[ ! -w "\$midi_device" ]]; then
    printf 'error: %s is not writable; see the Maschine section of README.md\n' "\$midi_device" >&2
    exit 1
fi
command -v python3 >/dev/null || { printf 'error: python3 is required for the hub\n' >&2; exit 1; }
python3 -c 'import PIL' 2>/dev/null || { printf 'error: the hub needs Pillow (python3-pil)\n' >&2; exit 1; }

hub_pid=
cleanup() {
    if [[ -n "\$hub_pid" ]] && kill -0 "\$hub_pid" 2>/dev/null; then
        kill "\$hub_pid" 2>/dev/null || true
        wait "\$hub_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

printf 'Maschine hub: MIDI %s, emulator reads %s\n' "\$midi_device" "\$midi_port"
python3 "\$here/maschine/maschine-hub.py" --midi "\$midi_device" &
hub_pid=\$!

# Turbo preset with the window back on: internal-pads input and the LCD
# export the hub reads, plus a visible LCD.
export MPC_VIDEO_MODE="\${MPC_VIDEO_MODE:-opengl}"
export MPC_LCD_EXPORT_PATH="\${MPC_LCD_EXPORT_PATH:-/dev/shm/mpc-lcd}"
"\$here/scripts/run-mpc2000xl-turbo.sh" -midiin1 "\$midi_port" "\$@" &
fast_pid=\$!
# The audio-thread starvation fix applies here too.
if "\$here/scripts/mpc-audio-thread-priority.sh"; then :; else
    printf 'warning: could not raise audio thread priority (chrt); audio may underrun\n' >&2
fi
"\$here/scripts/mpcpi-sampler-input" || true
trap '"\$here/scripts/mpcpi-sampler-input" --stop 2>/dev/null || true' EXIT INT TERM
wait "\$fast_pid"
WRAPPER
chmod +x "$staging/mpcpi-maschine"

cp -- "$mame_source_dir/COPYING" "$staging/COPYING"

# The audio bootstrap: installs the WirePlumber rule that keeps the sink off
# the ACP path. On many current drivers ACP pins the ALSA device at 48 kHz
# with a fixed profile and resamples the graph into it, which no force
# setting can override and which stalls the emulator's audio clock at small
# quanta (silence at 32, crackle at 64). With ACP off and the graph
# rate-matched to the device, 48 kHz/q64 is verified clean.
cat >"$staging/scripts/mpcpi-audio-setup" <<'AUDIOSETUP'
#!/usr/bin/env bash
set -euo pipefail
rule_dir=${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d
rule_file=$rule_dir/50-mpcpi-no-acp.conf
if [[ -f "$rule_file" ]]; then
    exit 0
fi
mkdir -p "$rule_dir"
cat >"$rule_file" <<'RULE'
# Installed by the MPC-Pi bundle: keep ALSA devices off the ACP path so the
# graph rate is not resampled into a pinned 48 kHz device profile.
monitor.alsa.rules = [
  {
    matches = [ { device.name = "~^alsa_card\\..*" } ]
    actions = { update-props = { api.alsa.use-acp = false } }
  }
]
RULE
printf 'Installed %s (one-time); restarting wireplumber once to apply it\n' "$rule_file"
systemctl --user restart wireplumber || true
sleep 3
AUDIOSETUP
chmod +x "$staging/scripts/mpcpi-audio-setup"

# A RATE-MATCHED SINK IN FRONT OF THE SAMPLER INPUT.
#
# Linking a browser (or any app) straight into :mic sounds broken, and the
# reason is measurable: with the graph at 64 frames / 48 kHz, Chrome's own
# node sat at 1024 frames / 44.1 kHz and was the only node in the graph
# accumulating errors - :speaker and :mic both read zero. An app adapting
# its buffer AND resampling directly against the emulator's audio clock is
# what crackles.
#
# So give it something to adapt into: a null sink at the graph's own rate,
# whose monitor feeds :mic. The app meets a well-behaved node, the emulator
# sees one clean stream, and the bridge survives the app restarting -
# a direct app->:mic link dies with the app's stream and has to be redone
# by hand every time.
cat >"$staging/scripts/mpcpi-sampler-input" <<'SAMPLERIN'
#!/usr/bin/env bash
# Publish "MPC-Sampler-Input" and wire it into the emulator's sampling input.
# Select it as the output device for whatever you want to sample.
set -uo pipefail
sink=mpc_sampler_in
rate=${PIPEWIRE_RATE_HZ:-48000}

if ! command -v pactl >/dev/null || ! command -v pw-link >/dev/null; then
    printf 'mpcpi-sampler-input: pactl/pw-link not found; skipping\n' >&2
    exit 0
fi

# TAKE IT AWAY AGAIN ON EXIT. The sink outlives the emulator otherwise, and
# an "MPC-Sampler-Input" sitting in the sound settings with no machine
# behind it is a device that silently swallows whatever you select into it.
if [ "${1:-}" = "--stop" ]; then
    for m in $(pactl list modules short 2>/dev/null | grep "sink_name=$sink" | cut -f1); do
        pactl unload-module "$m" 2>/dev/null
    done
    exit 0
fi

# Idempotent: a second launch must not stack another module.
if ! pactl list sinks short 2>/dev/null | grep -q "[[:space:]]$sink[[:space:]]"; then
    # Hyphens, not spaces: pactl splits sink_properties on whitespace, and
    # every escaping tried here still arrived truncated - the sink came up
    # described as plain "MPC".
    if ! pactl load-module module-null-sink sink_name="$sink" \
            sink_properties=device.description=MPC-Sampler-Input \
            rate="$rate" >/dev/null 2>&1; then
        printf 'mpcpi-sampler-input: could not create the sink; skipping\n' >&2
        exit 0
    fi
fi

# :mic exists from machine start (patch 0053), but the machine still has to
# get there - wait rather than race it.
for _ in $(seq 30); do
    pw-link -i 2>/dev/null | grep -q '^:mic:input_FL$' && break
    sleep 1
done
if ! pw-link -i 2>/dev/null | grep -q '^:mic:input_FL$'; then
    printf 'mpcpi-sampler-input: :mic never appeared; not bridging\n' >&2
    exit 0
fi

for ch in FL FR; do
    pw-link "$sink:monitor_$ch" ":mic:input_$ch" 2>/dev/null
done

# ANYTHING ELSE ON :mic IS A SECOND COPY. The session manager auto-connects
# the default capture device to any free capture node - that is the room
# microphone landing on the sampler input, and with the monitor up it is a
# feedback loop. It also re-links an application that was pointed here
# directly, so the same audio arrives twice, summed. Leave only the bridge.
keep="$sink:monitor_"
# Node names contain spaces ("Google Chrome:output_FL"), so this cannot
# field-split: take everything after the arrow, and carry the pair on a tab.
pw-link -l 2>/dev/null | awk -v keep="$keep" '
    /^:mic:input_(FL|FR)$/ { dst = $1; next }
    dst && /^[[:space:]]*\|<-[[:space:]]/ {
        src = $0
        sub(/^[[:space:]]*\|<-[[:space:]]*/, "", src)
        sub(/[[:space:]]+$/, "", src)
        if (index(src, keep) != 1) print src "\t" dst
        next
    }
    /^[^[:space:]]/ { dst = "" }
' | while IFS=$'\t' read -r src dst; do
    [ -n "$src" ] && [ -n "$dst" ] && pw-link -d "$src" "$dst" 2>/dev/null
done

# AND NOTHING SHOULD TAP :mic's MONITOR. Observed live: the session manager
# linked :mic:monitor_FL straight to the speakers' RIGHT channel, so the raw
# input reached the ears cross-channel, bypassing the machine and summing
# with the MPC's own monitor. Monitoring is the emulated machine's job.
pw-link -l 2>/dev/null | awk '
    /^:mic:monitor_(FL|FR)$/ { src = $1; next }
    src && /^[[:space:]]*\|->[[:space:]]/ {
        dst = $0
        sub(/^[[:space:]]*\|->[[:space:]]*/, "", dst)
        sub(/[[:space:]]+$/, "", dst)
        print src "\t" dst
        next
    }
    /^[^[:space:]]/ { src = "" }
' | while IFS=$'\t' read -r src dst; do
    [ -n "$src" ] && [ -n "$dst" ] && pw-link -d "$src" "$dst" 2>/dev/null
done

printf 'mpcpi-sampler-input: MPC-Sampler-Input -> the sampler; select it as the output device of whatever you want to sample\n'
SAMPLERIN
chmod +x "$staging/scripts/mpcpi-sampler-input"

# The MPC2000XL panel layout is drawn for the layout helper plugin: without
# it the knobs and sliders render a warning string and are not mouse-driven.
# The plugins tree ships in the bundle because the mpc-named binary does not
# find an executable-relative plugins directory on its own.
cp -r -- "$mame_source_dir/plugins" "$staging/plugins"

cat >"$staging/roms/PUT-YOUR-ROMS-HERE.txt" <<'ROMS'
This bundle ships no ROMs: the Akai firmware is copyrighted and may not be
redistributed. Place ROM sets you are legally entitled to use next to this
file, named exactly as MAME expects them:

    mpc2000xl.zip    Akai MPC2000XL (OS 1.20 dump set)
    mpc3000.zip      Akai MPC3000
    mpc60scsi.zip    Akai MPC60 (SCSI expansion)
    hd61830.zip      Hitachi HD61830 LCD controller ROM (MPC60 family)

With the sets in place, verify them from the bundle directory:

    ./mpcpi -listroms mpc2000xl
ROMS

cat >"$staging/share/icons/mpcpi.svg" <<'ICON'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="8" fill="#1a1a1a"/>
  <rect x="8" y="8" width="48" height="16" rx="2" fill="#c8e64a"/>
  <g fill="#4a4a4a">
    <rect x="8" y="30" width="10" height="10" rx="2"/><rect x="21" y="30" width="10" height="10" rx="2"/>
    <rect x="34" y="30" width="10" height="10" rx="2"/><rect x="47" y="30" width="9" height="10" rx="2"/>
    <rect x="8" y="43" width="10" height="10" rx="2"/><rect x="21" y="43" width="10" height="10" rx="2"/>
    <rect x="34" y="43" width="10" height="10" rx="2"/><rect x="47" y="43" width="9" height="10" rx="2"/>
  </g>
</svg>
ICON

desktop_file="$staging/share/applications/mpcpi.desktop"
# Exec must name an absolute path once installed; the recipient rewrites it
# when they add a menu entry (README), so ship the bare command.
cat >"$desktop_file" <<DESKTOP
[Desktop Entry]
Type=Application
Name=MPC-Pi
GenericName=Akai MPC Emulator
Comment=Akai MPC2000XL / MPC3000 / MPC60 through a focused MAME build
Exec=mpcpi
Icon=mpcpi
Terminal=true
Categories=AudioVideo;Audio;Emulator;
DESKTOP

cat >"$staging/README.md" <<README
# MPC-Pi desktop bundle $version

A focused MAME build (Akai MPC60, MPC3000, MPC2000XL only) carrying this
project's ordered low-latency patch stack, packaged with the repo launchers.

## Requirements

* Linux $arch
* PipeWire audio (\`pipewire\`, \`wireplumber\` running in your session)
* The shared libraries listed by \`ldd bin/mpc\`; on Debian/Ubuntu:
  libsdl2, libpipewire-0.3-0 / libpipewire-0.3-modules, libfontconfig,
  libx11, libxext, libxinerama, libxkbcommon, OpenGL (libgl1), and
  \`util-linux\` (chrt, taskset)
* For the Maschine MK1 hub only: \`python3\` with Pillow (\`python3-pil\`)

## ROMs

Unpack the bundle, put your own MPC ROM sets in \`roms/\` (see
\`roms/PUT-YOUR-ROMS-HERE.txt\`), and check them:

    ./mpcpi -listroms mpc2000xl

## Play

    ./mpcpi                  # MPC2000XL, accepted fast preset: the complete
                             # MPC panel maximized, 44.1 kHz/q32 graph, every
                             # accepted fast path
    ./mpcpi-accurate         # stock-accurate paths, all 11 outputs
    ./mpcpi-accurate mpc3000 # the other machines (fast paths are 2000XL-only)
    ./mpcpi -flop project.img   # any MAME argument passes straight through

The default entry temporarily forces the PipeWire graph to 44.1 kHz/32
frames while it runs and restores the previous global settings on exit,
and raises MAME's audio threads above its emulation thread once started -
without that, SCHED_RR starvation cracks the audio at small quanta (see
the project's audio-chain notes). On a hybrid CPU (P+E cores), pin to the
P-cores for the tuned latency: \`MAME_CPUSET=0-11 ./mpcpi\` on a Core
Ultra 7 155H.

Pads, buttons and the data wheel follow MAME's default input for these
machines; press Tab in the window for MAME's input menu. The panel's knobs
and sliders are mouse-controlled through the bundled layout helper plugin,
which \`./mpcpi\` enables; \`./mpcpi-accurate\` does not pass it, so add
\`-pluginspath plugins -plugin layout\` there if you want it.

The default panel path is the accurate one: the faster event-driven panel
UART still ghosts button presses on desktop (presses revert or skip), so
the bundle stays on the accurate path until that is fixed.

## Audio, and what the launcher does to it

\`./mpcpi\` rate-matches the graph to your sound device (48 kHz by default)
and runs a 64-frame quantum (~1.3 ms).

If your device runs through PipeWire's ACP path it may be pinned to one
rate and period with a resampler in front of it; \`MPCPI_DISABLE_ACP=1\`
installs a one-time WirePlumber rule at
\`~/.config/wireplumber/wireplumber.conf.d/50-mpcpi-no-acp.conf\` that takes
ALSA devices off it. **Try it only if you have a problem, and be ready to
undo it**: on one machine measured here (Meteor Lake HDA, SN6140 codec)
disabling ACP stopped the emulator creating its audio nodes at all - it
sat at ~5% CPU with a black window - and deleting the file plus
\`systemctl --user restart wireplumber\` brought it back immediately.

The 32-frame quantum is the untested opt-in on rate-matched devices:

    MPC_PIPEWIRE_FRAMES=32 ./mpcpi

On a device that natively follows the graph rate, the original 44.1 kHz
tuning still applies:

    PIPEWIRE_RATE_HZ=44100 MPC_PIPEWIRE_FRAMES=32 ./mpcpi

## Pad controllers (MPD18, MPD218, any USB-MIDI pads)

A pad controller becomes the MPC's own pads, not its MIDI input: notes
36-51 map to pads 1-16 (bank A) with velocity, and the panel-key injection
is the low-latency internal-pads path. List the port name first:

    ./mpcpi -listmidi

then launch with the controller's port and internal-pads input:

    MPC_MIDI_INPUT_MODE=internal-pads ./mpcpi -midiin1 'PORT NAME FROM -listmidi'

Continuous controls reach the machine through two CCs: **CC 1 drives the
DATA wheel as a relative delta** (3 = three clicks up, 125 = three down)
and **CC 2 sets the NOTE VARIATION slider absolutely** (0-127). Assign a
knob to CC 1 and a fader to CC 2 in your controller's editor.

## Maschine MK1 as the front panel (experimental on desktop)

\`./mpcpi-maschine\` runs the hub that owns the MK1 (both screens, lamps,
pads, encoders) and the emulator in the deployment preset with the window
back on. One-time setup:

    sudo modprobe snd-virmidi
    sudo setfacl -m u:\$USER:rw /dev/snd/midiC*D0   # hub write access

This is the appliance's proven configuration; the desktop wiring is new
and not yet hardware-verified - report what works.

If your user holds no realtime rlimit the launcher exits at \`chrt\`; relaunch
with \`MAME_RT_PRIORITY=0 ./mpcpi\`.

## Menu entry (optional)

    sed "s|^Exec=.*|Exec=$PWD/mpcpi|" share/applications/mpcpi.desktop \
        >~/.local/share/applications/mpcpi.desktop

## Source and licence

This is GPL-2.0+ MAME with local modifications; see \`COPYING\`. The exact
source (patch stack and launchers) is $repo_url at commit
$version's tree; the patches apply over MAME revision
$(git -C "$mame_source_dir" rev-parse --short HEAD) with
\`scripts/bootstrap-mame.sh\` and \`scripts/build-mame.sh\`.
README

mkdir -p "$out_dir"
tar --create --gzip --file "$out_dir/$name.tar.gz" --directory "$out_dir" \
    --owner=0 --group=0 --numeric-owner "$name"
( cd "$out_dir" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256" )

printf 'Packaged %s\n  %s/%s.tar.gz (%s)\n' "$name" "$out_dir" "$name" \
    "$(du -h "$out_dir/$name.tar.gz" | cut -f1)"
