# Desktop bundle cheat sheet

Everything here was run against the installed bundle
`~/Applications/mpcpi-20260819-c1297dd-linux-x86_64` on the development
workstation, from inside that directory:

    cd ~/Applications/mpcpi-20260819-c1297dd-linux-x86_64

Anything typed after `./mpcpi` is handed straight to MAME: the wrapper appends
`"$@"` to `run-mpc2000xl-fast.sh`, which appends it to `run-mpc.sh`, which ends
its `exec` line with `"$@"`. So every MAME option works, and the launcher's
tuning still applies.

Launch through `./mpcpi`, not `./bin/mpc`: the raw binary skips the wrapper's
graph tuning, its realtime setup and the sampler input.

MAME also stops twice at boot on press-any-key screens — system information,
then known problems. **Neither launcher skips them.** Both screens hang off
MAME's `skip_gameinfo` option, `./bin/mpc -showconfig` reports it as `0`, and
`skip_gameinfo` appears nowhere in `mpcpi`, `run-mpc2000xl-fast.sh` or
`run-mpc.sh`. Pass it yourself if you want them gone:

    ./mpcpi -skip_gameinfo -flop project.img

That passes through cleanly (checked); whether the two screens are then gone
from a windowed launch is **[verify by hand]**, because the screens are
suppressed automatically under `-video none`, under `-seconds_to_run` below 300,
and under the debugger — which is also why scripted runs never see them and no
check from here can. A windowed launch that looks frozen with no sound is
usually sitting on one of them.

If you see `-skip_gameinfo` in a running instance's `ps` line, that is the
person or script who launched it appending the flag, not the wrapper. Reading
one live command line and generalising it to the launcher is exactly how the
wrong version of this paragraph got written.

A handful of steps are keypresses in the focused emulator window and could not
be executed from here. They are marked **[verify by hand]** and collected at the
bottom.

## 1. Play the MPC from an external controller

List the ports first — the name has to match exactly, spaces and all:

    ./mpcpi -listmidi

On this machine that prints:

    MIDI input ports:
    Midi Through Port-0 (default)
    Akai MPD18 MIDI 1

Then launch with the controller on MIDI IN 1:

    MPC_MIDI_INPUT_MODE=internal-pads ./mpcpi -midiin1 'Akai MPD18 MIDI 1'

`midiin1`/`midiin2` are the media instance names MAME publishes for this
driver's two MIDI IN sockets (`./bin/mpc -listmedia mpc2000xl`); `-midiout1`
and `-midiout2` are the outputs.

Two things confirm it took. The launcher's own header prints

    MIDI input: internal-pads mode

and `aconnect -l` shows the controller wired to MAME's ALSA sequencer client:

    client 24: 'Akai MPD18' [type=kernel,card=2]
        0 'Akai MPD18 MIDI 1'
    	Connecting To: 128:3[real:0]
    client 128: 'Client-128' [type=user,pid=1117529]     # the mpc process

### What the three input modes mean

`MPC_MIDI_INPUT_MODE` is read by `scripts/run-mpc.sh`, which turns it into
environment the patched driver reads:

| value | what it does |
|---|---|
| `accurate` (default) | Nothing set. Bytes are clocked into the emulated UART at MIDI baud — the machine's own MIDI IN, exactly as the hardware behaves. |
| `fast` | `MAME_MPC_MIDI_FAST_INPUT=1`. Whole bytes are handed to the driver instead of being serialised through the UART (patch 0020). Still MIDI IN, just without the baud-rate queueing. |
| `internal-pads` | Adds `MAME_MPC_MIDI_INTERNAL_PADS=1`. The driver parses the MIDI itself and injects **panel** events, so the controller becomes the MPC's own pads and buttons rather than something plugged into its MIDI IN. |

### The internal-pads mapping

* **Notes 36–51** → pads 1–16, bank A, with velocity.
* **Notes 52 and up** → front-panel keys, codes contiguous from 1, so note 52 is
  Soft Key 1. The full table is `docs/mpc2000xl-panel-protocol.md`.
* **CC 1** → the DATA wheel, **relative** two's complement, the way every DAW
  encodes an endless encoder: 1–63 is clockwise (3 = three clicks up), 65–127 is
  anticlockwise (125 = three clicks down).
* **CC 2** → the NOTE VARIATION slider, **absolute** 0–127.

Assign a knob to CC 1 and a fader to CC 2 in the controller's editor. Actually
hearing a pad is **[verify by hand]**.

## 2. Sound card and buffer size

### Which card

The emulator publishes a PipeWire node called `:speaker`, and it follows the
**default sink**. Changing the default sink moves it live — measured on a
running instance, out and back:

    pactl list sinks short          # the names
    pactl set-default-sink alsa_output.pci-0000_00_1f.3.analog-stereo

    # before
    :speaker:output_FL
      |-> alsa_output.usb-...USB_AUDIO_CODEC-00.analog-stereo:playback_FL
    # after
    :speaker:output_FL
      |-> alsa_output.pci-0000_00_1f.3.analog-stereo:playback_FL

Check it with `pw-link -l | grep -A3 '^:speaker'`.

The desktop's own **Settings → Sound → Output** sets that same default sink, so
it moves the emulator the same way, running or not — **[verify by hand]**, since
nothing here may drive the desktop.

MAME has its own answer too, and it is the one that sticks to *this machine*
rather than the whole desktop: Scroll Lock, Tab, **Audio Mixer**, and map
`:speaker` to a named host device (**[verify by hand]**). The mapping is saved
per system — you can read it in `runtime/cfg-stereo/mpc2000xl.cfg`:

    <sound_map tag=":speaker">
        <node_mapping node="" db="0.000000" />
    </sound_map>

An empty `node` means "follow whatever the desktop default is", which is why the
`pactl` switch above moves it. A named node pins it to one card and survives
restarts.

### Buffer size and rate

Both are launch-time environment, read once by `run-mpc2000xl-fast.sh`:

    MPC_PIPEWIRE_FRAMES=128 ./mpcpi -flop project.img

| variable | default | notes |
|---|---|---|
| `MPC_PIPEWIRE_FRAMES` | `64` | ≈1.33 ms at 48 kHz. The verified-clean value. `32` is the untested opt-in — the launcher accepts it, but it has never passed a listening test here. `128` and up is the safe direction on a weak machine or under load. |
| `PIPEWIRE_RATE_HZ` | `48000` | Deliberate, not a fallback. The MPC is a 44.1 kHz machine, but this workstation's built-in analog path cannot be: `/proc/asound/card0/codec#0` reads `rates [0x540]: 48000 96000 192000`, with no 44.1 kHz at all, so every attempt to force it was futile at the hardware level. Rate-matching the graph to 48 kHz is what stops the resampler that pins the device. Check your own device before changing this — the USB codec on this machine *does* list 44100 (`/proc/asound/card3/stream0`), and on a device that really follows 44.1, `PIPEWIRE_RATE_HZ=44100` is the better setting. |

**A change needs a relaunch.** There is no runtime control; the values are read
at startup and the graph is forced once.

Verify what the system actually did rather than what was asked for:

    pw-metadata -n settings 0 | grep -i 'force-rate\|force-quantum'
    update: id:0 key:'clock.force-quantum' value:'128' type:''
    update: id:0 key:'clock.force-rate'    value:'48000' type:''

The launcher restores both to `0` when the emulator exits (checked). Note that
the ALSA device's own period is a separate number — with the graph at q128 the
USB codec was still running `period_size: 64` in
`/proc/asound/card3/pcm0p/sub0/hw_params` — so read the metadata, not just the
card, when checking the quantum.

One instance owns the graph at a time. A relaunch within about 5–10 seconds of
the last one exiting fails with `another MPC fast launch owns the PipeWire graph
settings`; wait for the lock
(`$XDG_RUNTIME_DIR/mpc-pi-pipewire-graph-$UID.lock`) and try again.

### Device Settings

The panel has a visible menu bar across its top edge: **DEVICE SETTINGS | DISK
| MIDI | AUDIO**. Click **DEVICE SETTINGS** for the complete list. The other
three entries open the same menu at the relevant section, and work while MAME's
keyboard UI remains switched off. The bar, full-menu click, direct disk click,
normal panel click and normal panel key were verified on a private Xvfb display.

The menu key remains supported, as does the configured fallback for a keyboard
without one. For example, putting `MPCPI_SETTINGS_HOTKEY=KEYCODE_F12` in
`~/.config/mpcpi/settings.env` makes F12 open the full menu; the wrapper exports
sourced settings so the plugin receives it.

## 3. Load a floppy at launch

    ./mpcpi -flop ~/development/mpc-pi/results/projects/mpc-tutor-logic-mpc2000xl.img

A ZIP containing one floppy image works the same way; MAME reads the image
directly from the archive, so there is nothing to unpack first:

    zip -j /tmp/mpc-tutor-logic.zip ~/development/mpc-pi/results/projects/mpc-tutor-logic-mpc2000xl.img
    ./mpcpi -flop /tmp/mpc-tutor-logic.zip

`flop` is the brief name of the media MAME calls `floppydisk`; there is one
drive. `./bin/mpc -listmedia mpc2000xl` prints the floppy formats inside an
image or archive:

    mpc2000xl  floppydisk  (flop)  .mfi .dfi .mfm .td0 .imd .dsk .ima .img .ufi .360 .ipf .hfe

Test images live in `~/development/mpc-pi/results/projects/`. The Device
Settings disk picker also accepts `.zip`; an archive with no supported floppy
image is left unmounted and reports the load error.

## 4. Change the floppy while it is running

### The manual way

This machine emulates a keyboard, so **MAME's UI controls start switched off** —
otherwise Tab would be an MPC button, not a menu. Confirmed from a Lua probe on
a running instance: `manager.ui.ui_active` is `false` at startup, and `true` when
launched with `-ui_active`.

1. **Scroll Lock** toggles the UI — on its own; the binding explicitly excludes
   either Shift, so Shift+Scroll Lock is not it. A popup confirms: *"UI controls
   enabled / Use Scroll Lock to toggle"*.
2. **Tab** opens the main menu.
3. Choose **Media Control**. This MAME calls it Media Control, not File Manager
   — the entry appears because the floppy drive is user-loadable.
4. Select **floppydisk**, then **[file manager]**, browse to the `.img`, and
   pick an access mode on the *Select access mode* screen — **Read-only** leaves
   the image on disk untouched, **Read-write** lets the MPC save to it.
5. **Scroll Lock** again to hand the keyboard back to the MPC.

All five keypresses are **[verify by hand]**. Every label above was read out of
this build's UI source; the menu itself could not be driven from here.

To skip step 1 entirely, launch with the UI already on:

    ./mpcpi -ui_active

That is MAME's own `ui_active` core option ("enable user interface on top of
emulated keyboard"), and it does exactly that here — checked with a Lua probe,
`manager.ui.ui_active` is `false` without it and `true` with it. The cost is
that MAME's UI bindings are live from the first frame, on a panel whose keys
overlap them.

Do not press Scroll Lock while the sequencer is running unless you mean it — the
MPC stops receiving the keyboard the moment the UI takes it.

### The proof that the mechanism works

The mount itself, and the firmware noticing it, were verified from Lua on a
running machine — an `-autoboot_script` that unloaded one image and loaded
another:

```lua
-- Find the drive by INSTANCE NAME. The tag here is ":fdc:0:35hd", and a
-- hardcoded tag is exactly what silently resolves to nil after a MAME bump.
local drive
for _, img in pairs(manager.machine.images) do
    local ok, inst = pcall(function() return img.instance_name end)
    if ok and inst == "floppydisk" then drive = img end
end
emu.wait(26)                       -- let the machine finish booting first
drive:unload()
drive:load("/path/to/other.img")
print(drive.filename)
```

Run it with `./mpcpi -flop A.img -autoboot_script swap.lua -autoboot_delay 1`.
MAME reported the new filename immediately, and — the part that matters — the
MPC's own LOAD screen (Shift + `3 / Load`) changed with it. Read back through
`MAME_MPC_LCD_EXPORT`, the file field went from

    ALL PGMS        (mpc-tutor-logic-mpc2000xl.img)

to

    BEAT1           (mpc-tutor-chopping-beat1-mpc2000xl.img)

so the firmware re-read the drive and listed a file that exists only on the
second disk. Runtime disk change is real; the Tab menu is just the hand-driven
front end for it.

## 5. Sample the desktop's own audio

`./mpcpi` and `./mpcpi-accurate` both publish a null sink called
`mpc_sampler_in`, described as **MPC-Sampler-Input**, and link its monitor into
the emulator's `:mic` input. Verified on a running instance:

    $ pactl list sinks | grep -A1 mpc_sampler_in
    	Name: mpc_sampler_in
    	Description: MPC-Sampler-Input

    $ pw-link -l | grep -A2 ':mic'
    :mic:input_FL
      |<- mpc_sampler_in:monitor_FL
    :mic:input_FR
      |<- mpc_sampler_in:monitor_FR

Point whatever you want to sample at it — in **Settings → Sound → Applications**
pick *MPC-Sampler-Input* as that application's output device
(**[verify by hand]**), or from a shell:

    pw-play --target=mpc_sampler_in some.wav      # checked, exits 0
    pactl move-sink-input <id> mpc_sampler_in     # move a running stream

Then arm sampling on the MPC itself (Shift + `4 / Sample` opens the record
screen) — **[verify by hand]**.

Two things the launcher does on purpose, and you should not undo:

* It cuts everything else off `:mic`. The session manager auto-connects the
  default capture device to any free capture node — that is the room microphone
  landing on the sampler input, and with the MPC monitoring it that is a
  feedback loop.
* It cuts anything tapping `:mic`'s monitor. Monitoring the input is the
  emulated machine's job, not the graph's.

The sink exists only while the emulator runs: the wrapper unloads it on exit
(checked — zero `mpc_sampler_in` sinks afterwards). A sampler input sitting in
the sound settings with no machine behind it silently swallows whatever you
select into it.

The same Audio Mixer from §2 covers the input side, and this bundle's saved
config already carries the mapping:

    <sound_map tag=":mic">
        <node_mapping node="o:MPC-Sampler-Input" db="0.000000" />
    </sound_map>

So `:mic` is pinned to the sampler sink in `runtime/cfg-stereo/mpc2000xl.cfg`
independently of the `pw-link` bridge the launcher makes. If the bridge ever
looks wrong in a graph tool, that mapping is the other half of the picture.

## 6. Where the keyboard map lives

The PC keyboard drives the whole front panel — pads on the numeric keypad,
transport on the letter keys, soft keys on F1–F6. The picture is
`docs/keyboard-map.png`.

MAME can also show the live bindings, and rebind them: Scroll Lock, then Tab,
then **Input Settings → Input Assignments (this system)** — **[verify by
hand]**.

## [verify by hand] checklist

Everything else in this document was executed once before it was written. These
could not be, because they are keypresses in the focused window or clicks in the
desktop's settings:

1. Hit a pad on the controller and hear pad 1–16 (note 36–51); turn the knob
   assigned to CC 1 and watch the DATA wheel move.
2. **Settings → Sound → Output** switches the running emulator's audio to the
   selected card. (The default-sink mechanism underneath it is verified.)
3. Tab → **Audio Mixer** pins `:speaker` to one named card, and the choice comes
   back after a restart. (The saved `sound_map` it writes is verified.)
4. Scroll Lock in the emulator window pops up *"UI controls enabled"*.
5. Tab → **Media Control** → **floppydisk** → **[file manager]** → pick an
   `.img` → **Select access mode** mounts it, and the MPC's LOAD screen shows
   the new disk. (The mount and the firmware's re-read are verified from Lua.)
6. **Settings → Sound → Applications** lists *MPC-Sampler-Input* as an output
   device for a running application.
7. Shift + `4 / Sample` opens the record screen and samples what is routed into
   MPC-Sampler-Input. (Shift + `3 / Load` for the LOAD screen is verified.)
8. Tab → **Input Settings → Input Assignments (this system)** lists the panel
   bindings.
9. `./mpcpi -skip_gameinfo` really does remove the two press-any-key screens
   from a normal windowed launch. (The flag passing through the wrapper is
   verified; the screens cannot appear in any run that could be scripted here.)
