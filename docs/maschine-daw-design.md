# Maschine DAW: design for the second screen

A live-looping, mixing and effects workstation for the second Maschine MK1
display, integrated with the MPC2000XL emulator as sequencing brain. This is
the design of record; implementation status is tracked per component at the
bottom.

## What this is and is not

The MPC emulator keeps everything it already does: drum/sample playback,
programs, sequences, song mode, tempo. The DAW side adds what the MPC cannot
do: multitrack audio recording, RC-505-style live looping, a mixer with
effects for guitars and microphones, and a linear audio arrangement. It is
audio-oriented; it is not a second MIDI sequencer.

The foundation is **headless Ardour**, controlled over OSC and Lua, never its
GTK interface. Ardour supplies recording, looping infrastructure, mixing,
routing, plugin hosting, latency compensation, sessions, undo and disk
safety; we supply a 255x64 pixel frontend and the glue that makes the MPC the
timing authority. We deliberately do not reimplement any of the DAW layer.

## Architecture

```text
                        MASCHINE MK1 (USB)
        screen L        screen R       pads/buttons/encoders
           ▲               ▲                    │
           │               │                    ▼
   ┌───────┴───────────────┴────────────────────────────┐
   │              maschine-hub  (one process,           │
   │               sole owner of the USB device)        │
   │  screen L ◄─ /dev/shm/mpc-lcd   (existing 0039)    │
   │  screen R ◄─ /dev/shm/daw-ui    (same MPCL format) │
   │  pads/buttons ─► virmidi (MPC)  or  OSC (DAW)      │
   │  encoders ────► OSC (DAW mixer/FX pages)           │
   └────────────────────────────────────────────────────┘
              │                          │
     ┌────────▼─────────┐      ┌────────▼─────────┐
     │  MPC2000XL       │ MIDI │  daw-ctl daemon   │
     │  emulator (MAME) │clock╱│  (python/C++)     │
     │  2 cores         │ SPP ►│  - OSC client     │
     │                  │      │  - luasession govr│
     │  audio out ──────┼──┐   │  - loop state mach│
     └──────────────────┘  │   │  - UI page render │
                           │   └────────┬─────────┘
                           │            │ OSC + lua
                        PipeWire   ┌────▼─────────────────┐
                        (JACK API) │  Ardour (headless)   │
                           │       │  tracks/cues/mixer/FX │
     guitars/mics ─────────┴──────►│  1-1.5 cores          │
                                   └────────┬─────────────┘
                                            ▼
                                      stereo output
```

Process model: four long-running processes — MAME, Ardour, `daw-ctl`,
`maschine-hub` — all PipeWire clients where they touch audio. No shared
memory between them except the two screen frame files; all control flows are
OSC (UDP, localhost) or MIDI (virmidi), both of which survive either side
restarting.

### Why not embed libardour directly

`luasession` plus the OSC surface covers every operation this design needs
(verified below), ships with Ardour, and keeps us on supported API. Direct
libardour embedding is the documented escalation path if a hard requirement
appears that neither Lua nor OSC exposes — none has so far. The cost of
embedding (tracking internal ABI across Ardour releases, building the C++
glue for ARM64) is not paid until something forces it.

## Ardour integration facts (researched, with sources)

- **Recording into cue slots is native.** The Cue page records audio or MIDI
  into a slot with a bar-count length (or until-stopped) and auto-plays the
  clip when the length elapses — exactly the arm/record/quantize/play loop
  core. ([manual: Recording cues](https://manual.ardour.org/cue/cue-recording/))
- **Overdub into a slot is not supported** (open feature request only), so
  overdubbing is designed as layered slots below.
  ([discourse](https://discourse.ardour.org/t/record-overdub-in-cue-midi/113436))
- **OSC controls the clip launcher** including `/trigger_bang` and
  `/trigger_unbang` per track/slot, with feedback, plus the whole mixer
  (gain/pan/mute/solo/rec-arm), transport and plugin parameters.
  ([osc.cc](https://github.com/Ardour/ardour/blob/master/libs/surfaces/osc/osc.cc),
  [manual: OSC](https://manual.ardour.org/using-control-surfaces/controlling-ardour-with-osc/))
- **`luasession` runs a full session headless** from the command line
  (`load_session`, AudioEngine global, ARDOUR:Session bindings), which covers
  session/track/plugin creation and anything OSC lacks.
  ([manual: Lua scripting](https://manual.ardour.org/lua-scripting/),
  [class reference](https://manual.ardour.org/lua-scripting/class_reference/))
- **Sync sources**: Ardour slaves its transport to MIDI Clock (with Song
  Position Pointer), MTC, LTC or JACK transport.

## Live looping design

**Phase 3 falsified the cue-grid plan.** Ardour's TriggerBox has *no*
headless control path: zero Lua bindings (verified in the installed binary
and upstream `luabindings.cc`), and the OSC surface only exposes
`/trigger_bang`, `/trigger_unbang`, `/trigger_stop`, `/trigger_stop_all`,
`/trigger_cue_row` — playback of already-filled slots, no record-arm, no
region-into-slot. Slot recording is driven only by the GUI and the C++
grid surfaces (Launchpad etc.). Patching the OSC surface stays possible
later, but the loop engine cannot depend on it.

The loop engine is therefore built from what is fully Lua-bound and already
proven: normal tracks, recording under external sync, playlists, and region
placement. Each loop lane is a **track pair** (L base, L+ overdub); the
transport rolls linearly, slaved to the MPC clock, and "looping" is the
daw-ctl daemon laying the captured region repeatedly ahead of the playhead
on the timeline.

```text
timeline ──────────────────────────────────────▶
GTR1-L    [rec●][r][r][r][r][r][r]...        base layer, duplicated ahead
GTR1-L+           [rec●][o][o][o]...         overdub layer
MIC-L                   [rec●][r][r]...
```

| Requirement | Mechanism |
|---|---|
| Arm / record / quantized start-end | daw-ctl arms the track and starts/stops capture on MPC bar boundaries (bar position derived from counted MIDI clocks) |
| Loop playback | `playlist:add_region(region, pos, times)` lays N repetitions ahead of the playhead; daw-ctl tops up before the playhead catches up |
| Stop / mute lane | stop topping up (region row simply ends), or `mute_control` on the lane |
| Scenes | a scene is a set of lanes topping up vs. ended; daw-ctl state, regions in session |
| Replace | re-record; new region replaces in the top-up schedule |
| **Overdub** | **Layer pairs**: record into L+ while L's repetitions play; both audible. Undo = remove L+'s regions. Deeper stacks bounce L+L+ into L (Lua region combine) and free the overdub lane |
| Undo/redo | Layer discard for overdubs; Ardour undo for everything else |
| Tempo lock | Ardour transport slaved to MPC clock (below) |
| Persistence | Loops are ordinary regions on the timeline — saved with the session |
| **Arrangement integration** | There is no separate loop store at all: the performance *is* the arrangement, exactly as played, region by region |
| Record the live performance | The master or a bus records to a normal track while performing |

This is looper logic on top of Ardour, but it stays inside Ardour's own
object model: every layer is a normal region on a normal track, so
arrangement, saving, undo and disk formats are all Ardour's problem, not
ours. This is the direct answer to the "no isolated looper objects"
requirement, and why SooperLooper is not used: it would own its audio
outside the session. It also degrades gracefully: if a top-up is ever late,
the lane goes silent for a bar instead of drifting.

## Synchronization

The MPC emulator is the authority — but **Ardour does not chase it**.

The original design slaved Ardour's transport to the MPC's MIDI clock.
Phase 3 falsified that over ten instrumented runs: the chase collapses
whenever the emulator shares the PipeWire graph (Ardour's pw-jack client
misses cycles once it is scheduled against MAME's stream; the MIDI-clock
DLL reads the gap as clock death and freezes the transport at a frozen
position with `rolling=true`). Each mitigation — CPU pinning, quantum 256,
`node.want-driver=false`, a server-side tap — moved the failure without
removing it, and the surviving configuration was too fragile to ship
(exact link timing, zombie-port hygiene, no direct links).

Chasing is also unnecessary: **the emulator and Ardour run on the same
hardware audio clock**, so there is no drift between them — only a fixed
offset. Sample-locked sync falls out for free. The design is therefore:

- **Ardour's transport free-runs internally** (rock solid under full
  emulator load — Phase 2 recorded 7/7 this way even at quantum 32).
- **daw-ctl follows an emulator-side transport export**, not MIDI (see
  "MIDI sync out does not work" below). `scripts/daw/transport-export.lua`
  publishes `<playing> <elapsed_ms> <emu_seconds>` to
  `/dev/shm/mpc-transport` at 200 Hz, read straight from the sequencer's
  own state — no serial link, no jitter. **Verified end to end: exactly
  1000.0 counter units per emulated second while playing**
  (`scripts/daw/transport-export-run.sh` → `TRANSPORT EXPORT OK`).
  `scripts/daw/daw_ctl_clock.py` implements the equivalent logic for a real
  MIDI clock source and stays useful for **external** gear driving the rig.

  The signal is the 32-bit little-endian counter at **`0x014188`**
  (mirrored at `0x01418c`): elapsed playback milliseconds, frozen while
  the sequencer is stopped. Found with `scripts/daw/find-transport-state.lua`,
  which diffs RAM between stopped and playing states and reports counters
  that advance monotonically only under playback — the same script re-finds
  it if a firmware revision moves it.

  Tempo still comes from the session (UI/project), not from RAM: pinning
  the tempo address is a small follow-up (change tempo, re-scan, see which
  of the candidate addresses tracks). Bar phase is then exact, because
  playback always starts on a bar line.
- **The bar grid is arithmetic**: at the session tempo, one bar is an exact
  sample count (120 BPM 4/4 → 96 000 samples at 48 kHz). daw-ctl anchors
  the grid once (first record start) and issues record start/stop at bar
  boundaries; captured regions are trimmed to exact bar multiples, so loop
  lengths stay sample-locked to the MPC's audible tempo forever.
- Play/stop follow the MPC via the same MIDI stream, handled by daw-ctl
  issuing transport requests.

### MIDI sync out does not work (measured, 2026-08-15)

The original plan assumed "the emulated MPC2000XL already transmits MIDI
Clock — authentic firmware behaviour, no patch needed". That is **false**
for this emulation, established over 18 instrumented runs:

- Panel navigation to the setting works headlessly and is verified by LCD
  snapshots: Shift+9 opens MIDI/SYNC, then **Right ×2, Up, one data-wheel
  detent** sets `Sync Out ... Mode: MIDI CLOCK`. (The cursor tab order is
  linear, not spatial; one detent is **one** encoder unit — four units, the
  value used by the analog sweep, overshoots to MIDI TIME CODE.)
- With that set and the sequencer visibly running (`Now:` advancing, PLAY
  lit, 86.0 BPM), `aseqdump` on the emulator's MIDI out sees **zero** clock
  and zero start events, on `mdout1` and `mdout2`, with the full-speed and
  all-accurate emulation presets alike.
- An I/O write tap on both MB89371 windows shows the firmware writes
  **only** the mode register (0x0186, value `0xf7`, ~200 times during boot,
  none once playing) and **never writes the data register**. So no byte is
  ever handed to the UART: this is not a UART or host-MIDI problem.
- `0xf7` has `MODE_USE_BRG` **set**, i.e. the firmware selects the internal
  baud-rate generator. An earlier hypothesis that the board's external
  TRNCLK/RVCLK was unmodelled (patch 0044) is therefore **falsified and the
  patch was reverted** — the BRG path was already correct.

Root cause is somewhere in unemulated sync/sequencer plumbing and is not
worth chasing: the transport export above is strictly better for our use
(no jitter, no serial round trip). Re-test the MIDI path only if the MPC
ever needs to drive **external** hardware.

The escalation path if bar-phase accuracy ever measures short: publish a
sample-accurate clock from the emulator's audio-clock code (patch 0004)
alongside the transport export — still no Ardour transport master involved.

## Mixer and routing

PipeWire is the single graph (already the emulator's environment; Ardour uses
its JACK API). Physical inputs land on Ardour tracks; the MPC's stereo out is
just another Ardour input track.

The emulator also models the MPC2000XL's **8 individual outs** (the IB-M208P
board): with `MPC_OUTPUT_MODE=all` (run-mpc.sh's default) MAME exposes a
second PipeWire node `:outputs` with 8 channels next to `:speaker`, fed by
the DSP's OUT0–7 buses. Sounds are assigned to individual outs in the MPC
project, exactly like the hardware. Each lands on its own Ardour track
(MPC1–MPC8) so the MPC's drums can be mixed/mastered per-voice-group in
Ardour. (`MPC_OUTPUT_MODE=stereo` compiles them out for the
latency-first live preset; the DAW stack runs with `all`.)

```text
in1 (gtr1) ─► GTR1  ─ chain ─┐            GTR1-L/L+ (loop lanes) ─┐
in2 (gtr2) ─► GTR2  ─ chain ─┤            GTR2-L/L+ ──────────────┤
in3 (mic1) ─► MIC1  ─ chain ─┼─► master ◄─ MIC-L/L+ ──────────────┤
in4 (mic2) ─► MIC2  ─ chain ─┤            AUX-L/L+ ───────────────┘
MPC out    ─► MPC   ─────────┤                 ▲ reverb/delay send bus
MPC ind. 1-8 ► MPC1..MPC8 ───┘   (:outputs node, MPC_OUTPUT_MODE=all)
```

**The MPC's monitor path never routes through Ardour.** The emulator's
`:speaker` node keeps its own direct link to the hardware sink, exactly as
in the live preset; Ardour's tracks *tap* the same ports in parallel for
recording/looping, and Ardour's master is a second independent route into
the sink. Neither adds serial latency to the other. The one coupling
PipeWire imposes is the **per-device quantum**: every node on one hardware
driver shares its period, and the emulator's quantum-32 request forces
Ardour's client into 0.67 ms cycles it cannot survive (measured: ~490k
cycle errors, clock master starved, slaved transport frozen). So:

- DAW mode runs the shared graph at a compromise quantum (start 256,
  measure 128): the MPC path stays direct, its device period just grows by
  a few ms relative to the solo live preset.
- If the direct path must keep quantum 32, put Ardour's master on a
  *second* audio device (per-driver quantum is independent) — on the Pi,
  e.g. DAC for the direct/live mix, USB interface for the Ardour mix.

### USB audio interface (both directions)

The appliance is a USB audio interface **and** can use one.

**Using an external interface** (type-A ports): class-compliant UAC1/UAC2
devices bind to `snd-usb-audio`, appear in PipeWire, and can host the
guitar/mic chains instead of (or beside) the I2S codecs. The two type-A
ports are separate `snps,dwc3` host controllers, independent of the
gadget below, so an external interface and the gadget run simultaneously.

**Being an interface** (USB-C port): BCM2712 has its own DWC2 OTG at
`usb@480000`, disabled in the stock Pi 5 DTB. `dtoverlay=dwc2,dr_mode=peripheral`
enables it — **verified with `fdtoverlay` against the real
`bcm2712-rpi-5-b.dtb`**, which exports the `usb` symbol the overlay
targets and yields `dr_mode = "otg"` plus gadget FIFO sizes. On top of it
`mpc-usb-gadget.sh` builds a **UAC2** function through configfs:

| Property | Value | Why |
|---|---|---|
| Class | UAC2, USB 2.0 high speed | Driverless on macOS, Windows 10+, Linux |
| Host records | **10 ch** | MPC stereo + the eight individual outs |
| Host plays | 2 ch | back into the rig (backing tracks, reamping) |
| Format | 24-bit / 48 kHz | matches the emulator and the DAC; 25% less bandwidth than padded 32-bit |
| Service interval | **125 µs** (`p_hs_bint=1`) | the 1 ms default is what usually blocks small buffers |
| Requests in flight | 2 (`req_number`) | minimum that still survives scheduling jitter |

Bandwidth is not the constraint: 10 ch × 24-bit × 48 kHz is 1.44 MB/s,
against roughly 8–13 MB/s practical for USB 2.0 high-speed isochronous.
The 125 µs service interval is the part that makes a 32-sample (0.67 ms)
host buffer realistic; expect a round trip of a few ms end to end and
**measure it on hardware before quoting a number** — the gadget adds its
own buffering on top of the host's.

`mpc-usb-route.sh {mpc|ardour|off}` picks what the computer records.
Both sources are ten channels, so one occupies the gadget at a time;
20 channels (MPC *and* Ardour at once) fits the bandwidth but doubles the
endpoint load, so it stays an experiment rather than the default. As
everywhere else in this design these are **taps** — the MPC's monitor path
to the DAC is never routed through the gadget.

Two hardware caveats for the USB-C port, which is also the Pi 5's power
input:

- A computer's USB port will not reliably power a Pi 5 under load. Power
  the appliance from its own supply (GPIO 5 V rail or PoE) and use a
  data-only USB-C cable, or a cable/adapter with VBUS interrupted, to
  avoid back-powering.
- `dr_mode=peripheral` fixes the port as a device. Switch to `otg` only if
  the same port must also host something, which is not our case.

### Physical inputs fan out to both recorders

Start with the one stereo I2S capture pair (PCM1808): channel 1 mic,
channel 2 guitar (later 4 inputs). Each capture port links in parallel to
(a) its Ardour input track (GTR1 / MIC1 chains, loop lanes) and
(b) **the MPC's record-in**, so the emulated sampler can record the same
sources — again taps, no serial chaining.

Ardour-side this is just two port links. MPC-side it is an open emulator
work item — **sampling into the emulated MPC does not work today**
(verified in source, 2026-08-15):

- `WADCSN` (I/O 0x00c0, the Xilinx-FPGA sampling control the firmware
  drives: `0xD2` start, `0x1A` stop, bits 6/7 = L/R input enable, bit 3 =
  analog input disable) is a pure read-back stub in `mpc2000.cpp` — writes
  are stored, nothing happens.
- The L7A1045 sound device is `stream_alloc(0, 10, …)` — zero input
  streams. Wave-DMA plumbing exists (it is how sample data moves), but no
  record direction.

Plan: wire a `MICROPHONE(config, ...)` sound-input device (a PipeWire
capture stream in the same graph, fed from the I2S inputs) and implement
the record DMA the firmware expects from the SAMPLE screen (start/stop via
WADCSN, sampled words DMA'd into main RAM, level metering readable during
record). Same effort class as the panel HLE. Until it lands, sampling into
the MPC means resampling a loop the DAW recorded; the DAW itself records
everything regardless.

Mixer surface (encoders 1-8): per-page volume/pan across the five groups,
mute/solo/rec-arm on buttons, sends on a shift layer. All of it is existing
OSC (`/strip/...`).

## Effects: chosen plugins

Priorities were ARM64, CPU, latency, no-GUI automation, stability. The core
set is Ardour's own `a-*` plugins — they exist precisely for this use case
(no GUI, sample-accurate automation, negligible CPU, ship with Ardour, ARM64
by construction):

| Slot | Plugin | Why |
|---|---|---|
| HPF/LPF, parametric EQ | **a-EQ** (per band switchable) | built-in, ~0 cost |
| Compressor | **a-Compressor** | built-in |
| Delay | **a-Delay** | built-in |
| Reverb (send bus) | **a-Reverb**; upgrade: Dragonfly Hall if CPU allows | built-in first |
| Overdrive | **Guitarix `gx_ts9` / `gx_sd1`** (LV2, DSP-only, light) | mature, tiny |
| Amp sim (optional) | **neural-amp-modeler-lv2**, one instance budgeted | proven on Pi-class in the pedal project |
| Utility/metering | **x42** (fil4, dpl) where a-* falls short | Robin Gareus quality, LV2, headless |

Explicitly avoided: Calf (GUI-era CPU habits), large suites, anything GL-GUI.
Guitar chains (HPF→comp→drive→EQ→[NAM]→delay→reverb-send) and mic chains are
Ardour processor lists saved as track templates; bypass per plugin is OSC.

## Frontend

Two 255x64 panels, side by side behind one bezel. They are **graphical
framebuffers, not character displays**: 5 bits per pixel, so 32 grey
levels are available and the UI can use brightness as a language rather
than drawing everything at full contrast.

- **Screen L** shows the emulated MPC2000XL LCD verbatim (the frame patch
  0039 exports). The instrument is unchanged: an MPC user's muscle memory
  and every screenshot in the MPC manual still apply.
- **Screen R** is the DAW. `scripts/maschine/daw_ui.py` renders it from a
  state dict; `scripts/maschine/ui.py` is the dependency-free framebuffer,
  5x7 font and widget set underneath.

Review the design without hardware:

```sh
scripts/maschine/daw_ui.py --snapshot outdir/          # the four pages
scripts/maschine/preview-panel.py panel.png LOOP \
    /dev/shm/mpc-lcd                                    # both screens
```

`preview-panel.py` composites a real exported MPC frame next to a DAW
page. That is not a convenience — reviewing the panel as one surface is
what caught the header duplication below, which no single-page snapshot
would have shown.

### Geometry: labels go next to their controls

The MK1's **eight buttons sit above the displays and its encoders below**
them (cabl's `DisplayButton1..8`; NI's manual: *"The eight Buttons above
the displays dynamically adapt their function… The action they perform is
shown below each Button in the displays"*). So:

```text
 y0-10   eight button labels          <- adjacent to the buttons above
 y11-19  mode | expanded label | transport, REC count, xruns
 y20-46  page body, eight columns
 y48-63  encoder values and meters    <- adjacent to the encoders below
```

The first four button cells are the pages, so the tab strip and the
legend are the *same* eight cells rather than two competing rows. An
earlier revision of these pages put the button legend along the bottom,
pointing at the encoders — label adjacency is the one rule every surveyed
controller obeys, and getting it backwards makes every press a guess.

### What the survey of shipping controllers changed

Researched against Push 1, Elektron (Digitakt/Octatrack/Rytm), Novation
Circuit/Launchpad, BOSS RC-505mkII/RC-600 and the HeadRush Looperboard:

- **The analogue position sweep is the primary channel, not the number.**
  Every looper surveyed shows loop position as a sweep; BOSS ships *two*
  concentric rings (loop position and bar phase) because both questions
  matter and are distinct. Our lane column now leads with a progress bar
  plus a bar-tick row, and the bar count is set at ordinary text size
  beneath them rather than dominating the column.
- **Never blank the position indicator while recording.** The RC-505mkII
  does exactly that in two of its three indicator modes, which is its
  most-reported UX defect.
- **Bar counters are deliberately absent on BOSS** — quantisation is made
  trustworthy so the player never counts. We keep a count because the DAW
  genuinely knows it, but demoted it accordingly.
- **"Empty" must not look like "stopped".** BOSS retrofitted a distinct
  colour for phrase-exists because users could not tell them apart. Empty
  lanes here are a dim name over a dim rule — a different *shape* from
  every active state, not merely a dimmer one.
- **We have no hue, so the animation axis carries what colour carries
  elsewhere**: static = available, blinking = queued, animated fill =
  active, inverted = selected.
- **An expanded-label line fixes truncation.** Push 1's 8-character
  parameter names were its most-cited flaw — users had to look at the
  computer, defeating the whole point. At 31px per column we have room
  for *five*, so the status line shows the full name and value of
  whichever encoder is moving (Analog Rytm's fix, reusing an existing
  field rather than opening a popup).
- **A persistent mode name in a fixed corner.** Neither Push nor Maschine
  ships one, relying on a lit button instead. Raskin's locus-of-attention
  argument says that indicator fails precisely when attention is on the
  music, and we have the pixels.

### WAVE: the take editor

Reached by SELECT + pad (that lane's take) or NAVIGATE, not from the page
row — editing is contextual to a selected loop, not a place the performer
lives. The waveform fills the body; trim handles are bright rules with
feet; the audio *outside* the trim stays visible but dim, because what a
trim is about to discard is exactly what the eye needs to check. Encoders
map to START / END / ZOOM / GAIN, buttons to TRIM / NORM / UNDO / BACK.
The data comes from Ardour's own peak files for the captured region, so
drawing it costs no extra DSP.

### EDIT: cutting, moving and crossfading on the timeline

The mental model is the ordinary DAW one and the engine already provides
it: a lane is an Ardour track, every recording is a **region on that
track's playlist**, and the playlist spans the whole MPC song because the
timeline and the sequencer share one hardware clock. Editing a rap vocal
works exactly as it would on a desktop, driven from the panel:

1. **Get to the syllable** — scrub with MOVE, or step with the MPC's own
   STEP/BAR keys, which are already mapped.
2. **Cut** — SPLIT (Button 5, and the MPC's printed SHIFT+Pad 4) splits
   the selected region at the playhead.
3. **Move** — MOVE slides the selected region snapped to the grid;
   SHIFT+MOVE is sample-fine; the MPC's printed NUDGE ‹ / › nudge by one
   snap unit.
4. **Crossfade** — slide a region into its neighbour: Ardour crossfades
   overlaps natively, so the picture and the audio agree. XFADE shapes
   the fade, drawn as corner diagonals with the crossing-diagonals glyph
   in the overlap.
5. **Level the phrase** — GAIN is per-region, so one hot syllable comes
   down without touching the track fader.
6. COPY / PASTE / CLEAR / UNDO ride the MPC's printed shift-pad
   functions. The silkscreen on the panel is literally the edit menu.

**Lanes stack and the view zooms.** Three or more lanes at once are
plain blocks, which is the right density for moving parts around; zoomed
in to one or two lanes the regions **draw their waveforms**, because
aligning a syllable is done against the wave, not against a label. ZOOM
is an encoder, so the same view covers both jobs.

Text is deliberately scarce here: lane tags are two characters in a
narrow gutter, the selected region's name and the snap setting ride the
status line, and nothing is written on the audio. Every pixel that is not
text is lane height.

### One geometry for LOOP and MIX

Both pages are the same vertical-strip view through two lenses, because
a channel and a loop lane are the same object seen from different sides.
**A channel occupies the same column on both**, so the hand that just
muted GTR2 on MIX finds GTR2's loop in the same place on LOOP.

All nine strips — eight channels plus master — fit at once at 28px each.
That beats banking three 62px strips, because on this panel a fader is a
*readout*, not a touch target: the encoders set gain. The four encoders
own a moving four-strip focus frame (the bright rule beneath the strips),
BANK slides it, and the encoder row prints the dB of exactly those four.

What differs between the lenses is only what the columns inside a strip
mean:

| | MIX | LOOP |
|---|---|---|
| Meter column | audio level, peak-hold line, clip block that latches | loop position sweep |
| Right columns | sends A and B | bars remaining, as a digit |
| Name row | solo inverts, mute dims | recording inverts bright, overdub dim-fills, armed outlines |
| Non-lane strips | normal | drawn quiet — they have no loop to show |

### Effects: the set, and a custom view for every one

A plugin's own GUI is an X11 window and cannot exist on a 255x64 5-bpp
panel, so **every effect gets a purpose-built view here** — which is what
Push, Elektron and Maschine all do, for the same reason. Views are chosen
by *kind*, so kinds are shared: every compressor draws the same way and
adding one costs nothing.

`scripts/maschine/plugins.py` holds the manifest (`python3 plugins.py`
prints it). Each role lists URIs in preference order, ending in something
that ships inside Ardour, so the appliance boots usable on whatever is
installed rather than silent.

| Role | Plugin | View |
|---|---|---|
| Parametric EQ, hi-pass, lo-pass | **LSP Parametric Equalizer x16** | response curve, marker per band, focused band bright |
| Compressor + sidechain | **LSP Sidechain Compressor** | transfer curve, wide GR meter, sidechain source named |
| Limiter | **LSP Limiter** (x42 dpl fallback) | input bar against a fixed ceiling line, GR, OVER latch |
| Multiband comp / limiter | **LSP Multiband Compressor** | one GR column per band, threshold line, selected band bright |
| Delay | a-Delay | decaying taps spaced by the delay time; ms **and** note division |
| Reverb | **Dragonfly Reverb** (Hall/Room/Plate) | exponential tail whose length is the decay, early reflections as taps |
| Overdrive | **guitarix Tube Screamer** | the clipping curve — soft, mid-humped |
| Distortion | **guitarix Distortion** (DS-1 voicing) | same view, visibly harder knee |
| Guitar amp + cab | **guitarix amp + cabinet** | five voicings, cab, tone stack above the encoders that set it |
| Chorus / flanger | guitarix chorus, flanger | the LFO drawn as the waveform it is, marker on the curve |
| Chopper / repeater | guitarix **switched** tremolo | gate pattern as a square wave, snapped to note divisions of the MPC tempo |
| Tuner | x42 tuna (gxtuner fallback) | big note, needle on a cents scale, wide IN TUNE box |

Amp voicings. These are concrete guitarix amp + cabinet selections read
out of the installed `.ttl` files, so they are selectable values rather
than aspirations — and guitarix models the cab as its own stage, which is
what makes the pairing meaningful:

| | Amp model | Cab | For |
|---|---|---|---|
| DLX | Fender Style | 2x12 | jazz, singer-songwriter, funk |
| PLEXI | JTM-45 Style | 4x12 | Hendrix, RHCP, classic rock |
| IIC+ | Mesa Boogie Style | 4x12 | Metallica, Slipknot, SOAD |
| AC30 | AC-30 Style | 2x12 | British rock, indie jangle, Queen, U2 |
| 5150 | Peavey Style | 4x12 | modern and heavier metal, djent, metalcore |

**Two amp engines, same voicings.** guitarix is the default because it is
a complete single-app chain — tube stage, tone stack and a real cabinet
model — analytic rather than neural, and packaged for arm64. **NAM is the
alternative**: a capture sounds like one specific rig, at the cost of
neural inference per instance and model files in the image.
`plugins.py` keeps both voicing lists the same length with matching names
and the self-test enforces it, so switching engines can never silently
change which amps exist. The panel's amp view is identical either way.

### Neural Amp Modeler A2 (researched 2026-08-15)

| | |
|---|---|
| Plugin | `mikeoliphant/neural-amp-modeler-lv2` v0.2.0+, URI `http://github.com/mikeoliphant/neural-amp-modeler-lv2` |
| Install | **prebuilt aarch64 Pi 5 binary**, `neural_amp_modeler_lv2_rpi5.tgz`, untarred into `/usr/lib/lv2`; links only libc and libm |
| Host | Ardour is a named supported host; model loading uses `atom:Path`, which Ardour drives |
| Alternative | TooB NAM (`http://two-play.com/plugins/toob-nam`), A2-capable **only inside the PiPedal 2 .deb** — standalone ToobAmp releases predate the A2 merge |

Facts worth stating because they are easy to get wrong, and two of them
corrected this design:

- **A2 has exactly two tiers, Full and Lite.** "Nano" and "feather" are
  *A1* names; "A2-Nano" was only a pre-launch name for A2-Lite. Both
  tiers live in one slimmable `.nam` file and are chosen at runtime by
  the plugin's `quality_scale` port (<0.5 Lite, ≥0.5 Full). The
  self-test asserts this so the A1 names cannot creep back.
- **A2-Full is 30–40% cheaper than A1-Standard** at roughly half the
  error, so A2 is worth having on its own terms.
- The often-repeated "~10 A2 models on a Pi 5" is **not substantiated as
  stated**. The nearest hard figure is PiPedal's author measuring **16
  simultaneous A1-Standard instances on a Pi 5** with A76-tuned flags
  (8 without). Since A2-Full is cheaper again, ~10 is plausible — but
  that was PiPedal's host at 128×3 buffers, not Ardour, and nobody has
  published an Ardour figure.
- **Build only with a modern toolchain.** The A2 fast path is reported
  *slower* on GCC 12 — which is what Pi OS Bookworm ships — and faster on
  GCC 15+. The official Pi binaries use a GCC 16 cross-toolchain, so the
  prebuilt tarball beats a local build.
- Two operational constraints: the plugin does **no resampling**, so the
  host must run at the model's 48 kHz (the appliance already does), and
  amp-only captures need a **cab after them**, which is why the guitar
  chain keeps its cab slot either way.

Captures for three of the five voicings are pinned (Fender Deluxe Reverb
A2 by NAM's own author, Marshall JMP-50 Plexi 1969, Mesa Mark IIC+
Hetfield rhythm — all free on tone3000.com). AC30 and 5150 have guitarix
voicings but no pinned capture yet, and the manifest says so rather than
shipping a wrong amp under the right name.

**Packages****Packages** (`sudo apt install lsp-plugins-lv2 dragonfly-reverb guitarix
x42-plugins zam-plugins`) — LSP, x42 and Zam are already present on the
build host; dragonfly-reverb and guitarix are packaged for arm64 but not
yet installed here, so their URIs are the manifest's first choice and are
resolved at session-build time rather than assumed.

### The rules the pages follow

1. **State before detail.** What a lane is doing must be readable without
   focusing, so state is carried by brightness and shape, not words: a
   bright filled name row is recording, a dim filled one is overdubbing,
   an outline is armed, plain is playing, dim is empty.
2. **One meaning per position.** The large number in a loop column always
   means "bars until this comes round" — never sometimes-position,
   sometimes-length. A caption would cost 7 vertical pixels to say what
   consistency says for free.
3. **Do not repeat the screen next door.** Tempo and bar position live on
   the MPC's LCD, inches away. Screen R spends that width on what only the
   DAW knows: an inverted recording count, an xrun counter that stays dim
   while healthy, and a transient message zone.
4. **No modals.** Confirmations, warnings and undo feedback appear in the
   header message zone and fade. A performer must never have to dismiss
   something mid-bar.
5. **Widgets must not rhyme.** A fader is a knob on a thin track; a meter
   is a solid column growing from the bottom. When both were thin vertical
   lines they swapped identities at a glance.
6. **Hardware alignment.** The eight body columns line up with the eight
   encoders and the footer labels with the eight buttons, so the mapping
   is read off the screen rather than remembered.
7. **Footers say what buttons do**, never repeat the row above them. On
   MIX they read MUTE and invert when engaged; on FX they navigate the
   chain, because the encoders already own the parameters.

### Control map

`scripts/maschine/control_map.py` holds it as data (`python3
control_map.py` prints it). The design position is that **the MPC keeps
its identity**: transport, pads and banks map straight onto their MPC
equivalents, and the DAW is reached through a mode rather than by
stealing controls.

| Control | Plain | With SHIFT |
|---|---|---|
| PLAY / REC / ERASE / RESTART | MPC play, record, erase, play-start | play-start, overdub, undo, go-to |
| STEP ◀ ▶ | MPC step left/right | bar left/right |
| GRID | MPC 16 Levels | Full Level |
| Group A–D | MPC pad banks A–D | — |
| Group E–H | DAW page: LOOP, MIX, FX, SONG | — |
| Buttons 1–4 (left screen) | MPC soft keys F1–F4 | F5, F6, —, PIN |
| Buttons 5–8 (right screen) | contextual, labelled on screen | — |
| Knobs 1–4 (left screen) | MPC data wheel, note variation, rec gain, main volume | fine |
| Knobs 5–8 (right screen) | per page: lane level, gain, plugin parameter, scrub | fine |
| Pads | MPC pads (bank-switched) | the MPC's own printed pad functions: undo, redo, quantize, copy, paste, semitone/octave |

Two places the hardware cannot match the MPC one-for-one, both resolved
explicitly rather than silently:

- The MPC has **six** soft keys under its LCD but only **four** buttons
  sit above that screen, so F5 and F6 move onto SHIFT.
- MK1's pad LEDs are single-colour with brightness only, so pad state
  cannot use hue the way every grid controller does. It is carried by
  brightness and by the on-screen pad map instead.

### Modes and the pad map

Modes are **momentary by default and latched only by an explicit,
labelled gesture** — hold the mode button and press Button 1, which the
screen labels PIN. That is Maschine's own idiom, and it matters because a
held mode cannot be forgotten (the muscular effort is the reminder)
whereas a latched one is a mode error waiting for the moment attention
goes to the music.

| Mode | Pads |
|---|---|
| MPC (default) | the MPC's own 4x4, banked by Group A–D |
| LOOP | four columns of four: column = lane, rows are REC / PLAY / STOP / CLEAR |
| MUTE | pad mutes its lane |

Holding PAD MODE draws the **4×4 pad map** over the current page and
releasing reverts it. It is an overlay rather than a page precisely
because holding to preview is what stops a performer getting lost. Its
columns are lanes — the same arrangement as the four screen columns above
and as Akai's own Clip programs — so "column = lane" is simultaneously
true on the pads, on the screen and in the MPC's idiom.

The map draws three genuinely distinct pad states: filled = active,
outlined = available, a thin rule = unavailable. Ableton's own manual
documents the ambiguity this avoids — an inert pad and an empty pad
looking identical.

### Pages

| Page | Body | Encoders | Buttons |
|---|---|---|---|
| LOOP | 8 lane columns: name row (state), bars-remaining, bar ticks, level | lane level | per-lane REC / STOP / DUB / ARM |
| MIX | 8 strips: fader, meter with peak hold, solo/mute in the name row | gain | MUTE per strip, inverted when muted |
| FX | focused track + plugin, 8 parameter cells (dim label, bright value, bar) | the 8 parameters | chain navigation, bypass, preset |
| SONG | arrangement ribbon with sections and playhead, loop count | scrub / zoom | section navigation, save |

`maschine-hub` owns both framebuffers and routes input by page; the MPC
screen resumes whenever the DAW page is left. Both-screen modes (SONG
spanning L+R) stay possible because one process owns both panels.

## CPU budget (Pi 5, 4x A76)

| Component | Budget |
|---|---|
| MPC emulator (cores 2-3, isolated) | ~2 cores |
| Ardour engine + 4-8 loop lanes + chains | ~1 core |
| NAM instance (optional) | ~0.5 core |
| daw-ctl + maschine-hub + UI render | ~0.1 core |
| Headroom / kernel / PipeWire | remainder |

Measured, not assumed, at Phase 2: DSP load, callback duration, xruns,
worst-case callback, disk overhead, loop-launch latency. The RT rules hold
everywhere: no blocking I/O on audio threads; UI and OSC live on their own
threads; autosave on a timer in Ardour's own thread.

## Reliability

Boot-to-music is already the appliance's shape (S-scripts). Added: Ardour
autosave interval, session on tmpfs journal with periodic sync to disk,
`daw-ctl` supervises Ardour and reloads the session on crash, plugins run
in-process (Ardour's own recovery covers a crashed plugin only by session
reload — accepted risk, mitigated by the tiny vetted plugin set). All state
lives in one Ardour session directory; power-loss safety = Ardour's existing
recording recovery plus flush-on-stop.

## Risks, honestly ranked

1. **Ardour on the buildroot image.** Ardour is not a buildroot package;
   building it (glibmm, libxml2, boost...) for the appliance is real work.
   Mitigation: Phase 1-3 run on the desktop and on a stock ARM64 Ardour
   binary (official builds exist); the buildroot recipe is its own later
   task, and a Debian-container fallback exists if it stalls.
2. **Cue OSC surface completeness** for record-arm of slots (bang/unbang are
   confirmed; per-slot record-arm may need `luasession`). Phase 1 verifies.
3. **MIDI-clock sync jitter** under load. Phase 2 measures; shared-clock
   escalation documented above.
4. **Layered-overdub feel** (does a 1-bar-quantized layer commit feel like an
   RC-505). Phase 3 is exactly this test.
5. **MK1 USB bandwidth** for two screens at UI rates — display protocol is
   ~5.4 KB/frame/screen; at 15 fps both screens ≈ 160 KB/s, far under bulk
   USB limits. Low risk.

## Phases (each ends in a runnable artifact)

1. **Headless Ardour PoC** (`scripts/daw/phase1-*`): luasession creates a
   session, adds a track with a-EQ, arms, records, plays back; OSC round-trip
   proven. Runs on the desktop.
2. **Coexistence**: MAME + Ardour on one PipeWire graph, MPC MIDI clock
   slaving Ardour transport, 4 tracks recording while the MPC plays.
3. **One loop lane**: record→loop→overdub(layer)→undo→stop→play, quantized
   to MPC bars.
4. **Maschine UI**: LOOP/MIX/FX pages on screen R via maschine-hub.
5. **Arrangement**: SONG page, region-to-timeline flow, session persistence.

## Implementation status

Four processes, each with a self-test that runs with no hardware and no
emulator. `for t in scripts/daw/osc.py scripts/daw/daw_ctl.py
scripts/daw/daw-ctl scripts/maschine/maschine-hub.py
scripts/maschine/ardour_bindings.py; do python3 $t --self-test; done`

| Component | State | Verified by |
|---|---|---|
| MPC emulator (MAME, 43 patches) | working, ~1600% | instruction counts, live play |
| Transport export | working | 1000.0 counter units per emulated second |
| Ardour session template | **9/9 against real Ardour** | 18 tracks, 2 send buses, EQ + reverb/delay created and saved |
| `daw_ctl.Engine` (loop lifecycle) | working | bar-quantized arm, refill, undo |
| `daw-ctl` daemon | working | transport → arm at the bar → OSC → renderable state |
| `osc.py` | working | wire format against hand-checked bytes |
| `ardour_bindings` | working | every OSC path checked against this Ardour build |
| Panel renderer (7 views) | working | snapshots reviewed as images |
| `maschine-hub` routing | working | buttons, pads, knobs, shift, hold-modes |
| `maschine-hub` USB I/O | **not done** | needs the controller |
| Plugin micro-view parameter binding | **not done** | needs a plugin instance to enumerate |
| Region ops (split/move/fade) | **designed, not wired** | Lua calls named in `ardour_bindings` |
| RPi5 appliance image | built | 11/11 contents verified |
| USB audio gadget | implemented | untested: needs the Pi |

What "not done" means precisely: the USB layer of `maschine-hub` (reading
the MK1's report endpoints and pushing frames) and the Lua session
governor that drains region operations. Both are mechanical given what is
verified — the routing above already produces the exact command lines,
and the Lua calls are named — but neither can be tested here, so neither
is claimed as working.


## Phase 1 findings (hard-won, do not rediscover)

- `luasession` stdout is block-buffered: **flush after every print** or a crash
  eats the log and it lies about where the failure happened.
- Do **not** iterate `AudioEngine:available_backends()` — the returned vector
  is a temporary; iterating it poisons the engine and `create_session`
  segfaults much later. Probe names via `set_backend` instead.
- Pass `ARDOUR.RouteGroup()` (empty shared-ptr constructor), never `nil`, to
  `new_audio_track` — Ardour 9 takes `shared_ptr<RouteGroup>` and `nil`
  segfaults inside LuaBridge with no Lua error.
- `new_audio_track` grew a 9th `trigger_visibility` parameter in Ardour 9 —
  set it `true` for loop lanes.
- Transport: use `request_roll(TRS_UI)`; the old `request_transport_speed`
  Lua signature changed.
- `get_physical_inputs` wants MIDI include/exclude flag ints as args 3-4.
- a-* plugins load as `urn:ardour:a-eq` with `PluginType.LV2`.
- The packaged luasession needs the wrapper env: `ARDOUR_DATA_PATH`,
  `ARDOUR_CONFIG_PATH`, `ARDOUR_DLL_PATH`, `LD_LIBRARY_PATH`.
- **Solved: the pipewire-jack "MTC in" failure.** Never call
  `AudioEngine:start()` before `create_session` on the JACK backend.
  `create_session` restarts the engine as a second JACK client; the first
  client's transport-master ports linger in the PipeWire registry long
  enough that the restarted client's "MTC in" re-registration collides
  (pw-jack's duplicate check is registry-global for these empty-prefix port
  names) and transport-master init dies. With `set_backend` only, the
  session owns the single engine client and everything registers cleanly.
  Diagnosed with a plain-JACK C probe (duplicates rejected, four distinct
  names fine) plus `PIPEWIRE_DEBUG=3` showing the two clients and the
  register-unregister-register race.

## Phase 2 findings

- MAME's native PipeWire module names its nodes after the emulated sound
  device tag: the stereo output is **`:speaker`** (ports
  `:speaker:output_FL/FR`), the floppy noise is `:fdc:0:35hd:flopsndout`.
  Nothing contains "mame" or "mpc" — match on `speaker`.
- Client (non-hardware) ports are enumerated from Lua with
  `AudioEngine:get_backend_ports("", DataType("audio"), PortFlags.IsOutput,
  C.StringVector())`; `get_physical_inputs` only sees hardware.
- Session config accessor is `session:cfg()` (not `config()`);
  `cfg():set_external_sync(true)` works from Lua.
- **TransportMasterManager has no Lua bindings**, but none are needed: with
  a fresh config dir (no `transport_masters` state file),
  `set_default_configuration` adds masters in the order JACK Transport, MTC,
  LTC, MIDI Clock and leaves **the last one — MIDI Clock — current**, and
  `restart()` keeps defaults when there is no state file. To force a
  specific master later, pre-seed `~/.config/ardour9/transport_masters`
  (`<TransportMasters current="MIDI Clock"><TransportMaster type=... name=...
  removeable=.../>...`) — its `current` property is applied after engine
  start.
- Ardour's MIDI Clock master **only rolls after it sees MIDI Start (0xFA) or
  Continue** — bare 0xF8 clocks tune the DLL but never start the transport.
  Link the port first, send Start after.
- The MPC-side runner must `setsid` the run-mpc.sh wrapper and kill the
  whole process group with SIGTERM→SIGKILL escalation: the autoboot
  play-loop can swallow SIGTERM and `wait` hangs forever.
- `scripts/diagnostics/benchmark-loaded-mpc2000xl.lua` self-exits after its
  measurement window; Phase 2 uses `scripts/daw/phase2-autoboot.lua`, which
  boots at 4x, prints `PHASE2_PLAYBACK_READY`, then re-presses PLAY START
  every 15 s forever.
- The desktop and RPi5 cross builds share `.cache/mame`; the cross build now
  deletes its aarch64 `mpc` from the checkout after installing to the
  overlay, otherwise every desktop harness dies with `Syntax error: "("
  unexpected` (shell interpreting an ARM ELF).

## Phase 3 findings

- **Never slave Ardour's transport in this graph** — see the
  Synchronization section for the full falsification (10 runs). Internal
  transport is unconditionally stable under emulator load.
- **Never link a pw-jack client directly to the emulator's stream node**:
  the client starts missing cycles (pw-top shows `+++` and a climbing ERR
  count on the blank-named Ardour node). Interpose a
  `pactl load-module module-null-sink` tap and record from its monitor
  ports. pw-loopback's virtual nodes are NOT visible in the JACK view; the
  pactl null sink is.
- The emulator's streams set `node.want-driver=true` (it is its own timing
  master); in DAW mode export `PIPEWIRE_PROPS='{ node.want-driver =
  false }'` so the ALSA device stays the only graph driver.
- DAW mode runs the emulator at quantum 256 (`DAW_QUANTUM`): at the live
  preset's 32, every other client in the forced 0.67 ms graph dies.
- **Punch-in mid-roll captures, but the region materializes only at
  transport stop** (`Track::transport_stopped_wallclock` consumes
  `capture_info`; `DiskWriter::finish_capture` on punch-out only records
  bookkeeping). The PoC therefore stops+re-rolls (~1.5 s gap) to finalize
  each take, and stopping while Recording also disables session record —
  re-engage before re-rolling. **Production looper needs one of:** (a) a
  small Ardour patch (built from source for the Pi anyway) exposing
  `finalize captures now` to Lua — preferred, upstreamable; (b) daw-ctl
  records loop wavs itself (own PipeWire capture), imports them as sources
  and places whole-file regions via the Lua-bound `ARDOUR.RegionFactory`.
- `maybe_enable_record` is a toggle; calling it while Recording disables
  record. Engage once, before rolling.
- A killed luasession can linger holding its ports ("zombie" `MIDI Clock
  in`); guard runs against leftover processes before starting.
