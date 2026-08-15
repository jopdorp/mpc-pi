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

Ardour's cue grid is the loop engine. One Ardour track per loop lane
(GTR1-L, GTR2-L, MIC-L, AUX-L), 8 slots per lane, launch quantization set to
1 bar, follow-action loop.

```text
             A     B     C     D   ...
GTR1-L      [●]   [▶]   [ ]   [ ]      ● record-armed slot
GTR2-L      [▶]   [▶]   [ ]   [ ]      ▶ playing
MIC-L       [ ]   [●]   [ ]   [ ]
AUX-L       [▶]   [ ]   [ ]   [ ]
```

| Requirement | Mechanism |
|---|---|
| Arm / record / quantized start-end / play | Native cue recording, length in bars |
| Stop, start, mute, launch | `/trigger_bang`, `/trigger_unbang`, slot isolate |
| Scenes | Cue rows; one bang launches the row |
| Replace | Re-record the slot |
| Duplicate | Lua: copy region to another slot |
| **Overdub** | **Layer pairs**: each lane is two Ardour tracks (L, L+). Overdub records into the paired track's same slot while the base keeps looping; both play together. Undo = clear the top layer. Deeper stacks bounce L+L+ into L (Lua region combine) and free the overdub lane |
| Undo/redo | Layer discard for overdubs; Ardour undo for everything else |
| Tempo lock | Ardour transport slaved to MPC clock (below) |
| Persistence | Slots are ordinary regions in the session — saved with it |
| **Arrangement integration** | The same regions are dragged to the timeline by Lua (`playlist:add_region`) — no export/import, no second audio model |
| Record the live performance | The master or a bus records to a normal track while performing |

The layer-pair design is the one place we add looper logic on top of Ardour,
and it stays inside Ardour's own object model: every layer is a normal region
on a normal track, so arrangement, saving, undo and disk formats are all
Ardour's problem, not ours. This is the direct answer to the "no isolated
looper objects" requirement, and why SooperLooper is not used: it would own
its audio outside the session.

## Synchronization

The MPC emulator is the authority. The emulated MPC2000XL already transmits
MIDI Clock and Song Position Pointer when its sequencer runs — authentic
firmware behaviour, no patch needed. That stream leaves MAME through a
virmidi port; Ardour's transport master is set to MIDI Clock on that port.

- Play/stop/position: MIDI start/stop/continue + SPP.
- BPM: clock rate; Ardour follows tempo drift continuously (DLL).
- Quantization: Ardour quantizes cue launches to its bar grid, which the
  clock sync keeps aligned to the MPC's bars.

This is deliberately the least invasive design. If measured jitter is ever
musically significant, the escalation path is a shared-memory sample clock
published by patch 0004's audio-clock code and consumed by a small Ardour
transport-master plugin — sample-accurate, but only built if the measurement
says the MIDI path is not good enough.

## Mixer and routing

PipeWire is the single graph (already the emulator's environment; Ardour uses
its JACK API). Physical inputs land on Ardour tracks; the MPC's stereo out is
just another Ardour input track.

```text
in1 (gtr1) ─► GTR1  ─ chain ─┐            GTR1-L/L+ (loop lanes) ─┐
in2 (gtr2) ─► GTR2  ─ chain ─┤            GTR2-L/L+ ──────────────┤
in3 (mic1) ─► MIC1  ─ chain ─┼─► master ◄─ MIC-L/L+ ──────────────┤
in4 (mic2) ─► MIC2  ─ chain ─┤            AUX-L/L+ ───────────────┘
MPC out    ─► MPC   ─────────┘                 ▲ reverb/delay send bus
```

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

The second 255x64 screen renders from `/dev/shm/daw-ui`, same MPCL frame
format as the MPC LCD export, produced by `daw-ctl`'s page renderer
(1-bit text/blocks; font from the MPC export tooling). Pages:

```text
[LOOP]  cue grid + record state        pads = slot launch/arm
[MIX]   5 strips, encoder-per-strip    encoders = gain, shift=pan
[FX]    chain of focused strip         encoders = 8 mapped params
[SONG]  timeline overview + locate     encoders = scrub/zoom
```

Mode buttons on the Maschine switch pages; `maschine-hub` routes input by
page (pads to MPC virmidi in MPC mode, to OSC bangs in LOOP mode; encoders
always to the DAW). Both-screen modes (e.g. SONG spanning L+R) are possible
later since the hub owns both framebuffers; the MPC screen resumes on exit.

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

| Component | Status |
|---|---|
| Design (this document) | done |
| Phase 1 PoC | **passing 10/10** on desktop Ardour 9 with the JACK/PipeWire backend (`scripts/daw/phase1-run.sh`): backend, session, track, physical input connected, a-EQ insert, param set, record (region captured), playback, save |
| Phases 2-5 | not started |

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
