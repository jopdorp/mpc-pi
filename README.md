# MPC Pi

A compact, standalone MPC-style instrument built around an MPD pad assembly, with a software implementation first and an FPGA implementation as the later path.

## Current implementation

Phase 1 now has reproducible tooling for a focused MAME build and ROM audit:

```bash
./scripts/bootstrap-mame.sh
./scripts/build-mame.sh
./scripts/test-mame.sh
```

See [Phase 1: MAME baseline](docs/phase-1.md) for firmware placement, exact test scope, and the native PipeWire latency launcher.

The selected MPC3000 listening default is MIDI Mark Demo Disk 1, sequence
`96BPM-SNOOPBLAK`. With the downloaded disk in place, launch it at the default
128-frame PipeWire period with:

```bash
./scripts/listen.sh
```

Pass another PipeWire period as the first argument, for example
`./scripts/listen.sh 256`. Loading is accelerated; playback runs at normal
speed. The patched launcher suppresses MAME's startup warning when
`-skip_gameinfo` is used, so the audition starts without a manual key press.

## Project plan

## Goal

Build a compact, standalone MPC-style instrument around the **MPD pad assembly**, with the controls and workflow of a real Akai MPC rather than a generic groovebox.

The physical concept is:

```text
┌───────────────────────────────────────┐
│       5.5" 256×64 display            │
│                                       │
│ F1 F2 F3 F4 F5 F6      DATA WHEEL    │
│                                       │
│     MPC navigation/mode buttons       │
│                                       │
│       MPD 4×4 pad assembly            │
│       ■ ■ ■ ■                         │
│       ■ ■ ■ ■                         │
│       ■ ■ ■ ■                         │
│       ■ ■ ■ ■                         │
│                                       │
│ REC  OVERDUB  STOP  PLAY  PLAY START │
└───────────────────────────────────────┘
```

CNC wood and/or 3D-printed enclosure later. **No custom control PCB is required.** A donor USB-keyboard PCB can handle the many front-panel buttons; the data wheel can eventually be a real quadrature encoder.

### The important findings so far

* **MAME actually runs the original Akai firmware**, unlike vMPC, which is a behavioral reimplementation.
* MAME currently has drivers for **MPC60, MPC3000 and MPC2000XL**. All are still marked `MACHINE_NOT_WORKING`; MPC60 is additionally `MACHINE_IMPERFECT_SOUND`. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc2000.cpp)][1])
* The **MPC3000 and MPC2000XL are particularly attractive as one shared project**. Both use a 32 MHz NEC V53 plus Akai L6028 sampler DSP, and MAME explicitly says the 2000/XL's actual sound generation is identical to the 3000. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc2000.cpp)][1])
* The L6028 produces **10 digital outputs: stereo main L/R + eight individual outputs**. The L6029 is identified as the companion “second digital filter.” ([[GitHub](https://github.com/mamedev/mame/blob/master/src/devices/sound/l7a1045_l6028_dsp_a.cpp)][2])
* MAME's L6028 isn't yet guaranteed bit-accurate to the physical ASIC. That makes MAME our **first executable specification**, not necessarily the final truth.
* The MPC2000XL display MAME renders is **248×60**. MPC3000 is **240×64**. Your proposed **256×64 5.5-inch display is therefore basically perfect for either machine**. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc2000.cpp)][1])
* Most importantly, the pads are handled internally through the MPC panel controller. In the current MPC2000XL driver, the panel CPU selects pad rows and reads four analog channels, but MAME currently simplifies each hit to `0xff` or zero. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc2000.cpp)][1])
* Therefore the **MPD should NOT appear to the emulated MPC as external MIDI**. We use the MPD's USB MIDI only as a convenient physical sensor protocol: note + velocity are converted inside our MAME patch into the emulated MPC's **built-in pad matrix/velocity inputs**.
* The MPC's external MIDI ports remain free and behave as actual MPC MIDI ports.

## Phase 1 — get stock MAME running

This is the next step. **No enclosure, soldering, FPGA or fancy LCD yet.**

Use an ordinary Linux machine first and obtain your own legitimate MPC ROM dumps. Bring up:

```text
mpc2000xl
mpc3000
mpc60
```

The first questions are simply:

```text
Does it boot?
Does the LCD operate?
Can we load/save?
Does sampling work?
Does the sampler play correctly?
Which driver is currently the most usable?
```

Because MAME officially still marks these drivers as unfinished, this experiment needs to happen before we design anything around them. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc2000.cpp)][1])

For controls initially:

```text
normal PC keyboard → MPC buttons/pads
mouse / mapped keys → data wheel
normal audio output → speakers/headphones
```

MAME already treats the data entry control as an `IPT_DIAL`; the current 2000XL default decrement/increment bindings are F14/F15, so remapping it to something convenient is straightforward. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc2000.cpp)][1])

## Phase 2 — establish the latency floor

This is probably the **single most important experiment**.

Use MAME's native **PipeWire** backend. The previous PortAudio test selected the
ALSA compatibility device rather than opening a native low-latency stream, and
MAME's PipeWire backend deliberately ignores `-audio_latency`. Request the
per-client period from PipeWire instead with `PIPEWIRE_LATENCY`.

So test approximately:

```text
PIPEWIRE_LATENCY=256/48000     ~5.33 ms
PIPEWIRE_LATENCY=128/48000     ~2.67 ms
PIPEWIRE_LATENCY=64/48000      ~1.33 ms
PIPEWIRE_LATENCY=32/48000      ~0.67 ms
```

I'd also test at **44.1 kHz**, since that's the natural MPC domain:

```text
PIPEWIRE_LATENCY=128/48000 .cache/mame/mpc mpc2000xl \
  -sound pipewire -samplerate 44100
```

The launcher wraps this as `scripts/run-mpc.sh <machine> <frames>`. It defaults
to 32 frames and sets both the native PipeWire quantum and latency request.
`pw-jack` is for JACK clients running on PipeWire and is not
needed for MAME's native PipeWire backend.

For an ALSA-backed default sink, `MPC_ALSA_HEADROOM=<frames>` changes
PipeWire's device headroom before launch. The default is `keep`, which leaves
the sink untouched. Zero headroom passed the interactive resize test, but a
matched 60-second run produced eight main-output underruns versus three with
48 frames, so zero is not the stable default. This setting is separate from
MAME's 16-sample producer cadence and its 48-frame internal deadline margin.

The launcher also uses `nice -10` and round-robin real-time scheduling at
priority 20. PipeWire runs at RR 90 on this host, so its processing remains
higher priority. Override these with `MAME_NICE` and `MAME_RT_PRIORITY` when
needed.

The launcher enables the patched PipeWire audio clock and disables MAME's
independent video throttle. Fast loading remains unpaced, but at normal speed
the main speaker output is paced from PipeWire with one negotiated graph
quantum plus one producer update of margin. At 48 kHz MAME exports 16-sample
blocks at 3 kHz; with a 32-frame PipeWire quantum this keeps the intended host
window to 48 samples (1 ms). The extra producer update lets one late 16-sample
tick recover without immediately starving the next PipeWire callback.

The default desktop video path is the complete MPC panel, rendered with
OpenGL in a maximized window. MPC2000XL panel artwork is rasterized at stable
1280x720-derived dimensions and linearly scaled by OpenGL, while the LCD, UI,
window geometry and input mapping retain the actual output resolution. This
avoids rerasterizing hundreds of SVG and text elements at every intermediate
window size. Set `MPC_ARTWORK_RESOLUTION=auto` for stock target-sized artwork.
The OpenGL path hands completed primitive lists to a low-priority presenter
thread without waiting and drops a visual frame if the presenter is busy. The SDL
software path keeps SDL texture upload and presentation on the main thread, as
required by SDL, while a low-priority worker rasterizes primitives into
double-buffered pixel storage.
It also drops a visual frame before primitive-list generation if the worker is
busy. Both `-scalemode none` and `-scalemode hwbest` pass the live timing test
on the accelerated desktop display.

The launcher also isolates stock SDL's desktop event loop from the emulation
timeline on Linux. SDL initialization and event pumping stay on the process
main thread at normal low priority, while MAME's frontend/emulation worker
inherits the requested real-time policy. Interactive window resizing can block
SDL for tens of milliseconds without pausing emulated audio. This uses the
system SDL unchanged; no custom SDL build or runtime library override is
required. Set `MPC_SDL_EXTERNAL_EVENT_LOOP=0` only for comparison with the
original single-threaded event path.

Audio-master pacing follows the main speaker output only. The MPC's auxiliary
outputs remain synchronized, but a delayed auxiliary PipeWire callback cannot
hold the emulation timeline or underrun the audible output. A bounded wait also
prevents a missed callback notification from stalling the emulation thread.

Profiling the normal-speed Logic-project playback path shows that rendering is
not the steady-state bottleneck once asynchronous presentation is enabled. The
full panel spends roughly 0.8--1.0 ms drawing a typical synchronous OpenGL
frame on this workstation, while the LCD-only view spends roughly 0.13 ms.
Most emulator CPU time is instead in the device scheduler and the MPC's two
high-rate MIDI UART baud clocks. Patch 0007 preserves every clock edge but uses
MAME's periodic timer support for 50-percent-duty clocks, eliminating a timer
queue remove/reinsert on every transition. In the matched playback profile,
`emu_timer::adjust` fell from 10.16 percent of samples to zero and total sampled
CPU time fell by about 7.5 percent without changing the reference PCM or live
timing result.

Patch 0012 removes the remaining generic `clock_device` and `devcb` dispatch
from the MB89371's two internal baud-rate generators. The replacement still
uses periodic emulation timers, emits every rising and falling edge, and saves
the clock phase for save states. Across three interleaved full-project runs on
a busy powersave workstation, the patched path reduced total MAME task-clock by
6.0 percent, P-core cycles by 5.9 percent, and retired instructions by 7.7
percent. Its deterministic Logic-project PCM is byte-identical to the periodic
clock-device baseline.

Patch 0013 fixes the teardown lifecycle race in the isolated SDL event loop.
The main thread stops pumping SDL before window/backend teardown. Patch 0029
later restores machine-state primitive generation to the emulation thread
after the full layout's analog-input read exposed an intermittent scheduler
race and `SIGFPE` on the presenter. OpenGL drawing and swap remain on the
low-priority presenter, and the event-driven handoff still drops frames when
it is busy. Patch 0030 bounds CPU-side layout rasterization independently of
the physical window; a matched resize storm reduced the measured primitive
generation maximum from 115.7 ms to 2.43 ms. Continuous-resize audio stability
at the 32-frame PipeWire setting remains the live acceptance gate.
These patches modify MAME's SDL OSD/backend code, not the SDL library; the
system SDL runtime remains stock.

Patch 0014 batches each MB89371 baud generator's rising and falling USART edges
into one periodic scheduler callback while preserving their logical order. This
halves baud-clock scheduler events; three interleaved busy-system runs reduced
retired instructions by 6.76 percent and cycles by 4.74 percent over patch 0012.
The Logic-project PCM remains byte-identical, and live ALSA MIDI input still
drives the MPC program correctly.

Patch 0015 adds an exact full-cycle operation to the i8251 and uses it from the
MB89371 baud timer, avoiding four state-normalizing calls per baud cycle. Three
interleaved MPC2000XL runs reduced whole-emulator retired instructions by 1.41
percent over patch 0014. The Logic-project PCM remains byte-identical, and a
live eight-note ALSA MIDI test produced the same -42.6 dB mean and -4.1 dB peak
capture.

Patch 0016 skips i8251 receive-register updates only when the asynchronous
receiver is idle high and its complete shift register is already `0xffff`,
making the skipped shift a literal no-op. Three interleaved E-core runs reduced
whole-emulator retired instructions by another 1.60 percent and cycles by 0.57
percent. The intrinsic PCM is still byte-identical, and the live eight-note
ALSA MIDI capture is unchanged.

Patch 0017 keeps every baud-timer deadline but skips asynchronous i8251
transmit work when the shift register and buffer are empty and all exposed
status levels are already stable. It tracks break release so the transition
back to the marking state still occurs on the original transmit boundary.
Three interleaved E-core runs reduced whole-emulator retired instructions by
0.39 percent, cycles by 2.64 percent, and task time by 4.16 percent over patch
0016. Two deterministic Logic-project renders retained the exact reference PCM,
and MIDI injected through a live ALSA sequencer connection produced audible
output at -34.9 dB mean and -3.2 dB peak.

Patch 0018 removes the scheduler's runtime 64-by-32 division from every CPU
timeslice. Device clocks change rarely, so the execute interface caches an
exact reciprocal when its clock changes; the hot path uses multiply-high plus
an exact one-count correction. MAME's inline-arithmetic validity suite covers
random and boundary inputs. Two release-build Logic renders remain
byte-identical to the reference PCM. In an interleaved release A/B test on an
E-core, the change reduced whole-emulator task time by 3.17 percent and cycles
by 1.80 percent, despite retiring 1.61 percent more low-cost instructions. The
benefit is expected to be larger on the Raspberry Pi 3's Cortex-A53, where the
replaced runtime 64-bit division is substantially more expensive.

For a compact LCD-only view (for example on a Raspberry Pi display or for
diagnostics), use:

```bash
MPC_VIEW_NAME='Screen 0' MPC_WINDOW_RESOLUTION=1240x300 scripts/run-mpc.sh
```

Override `MPC_VIEW_NAME`, `MPC_WINDOW_RESOLUTION`,
`MPC_ARTWORK_RESOLUTION`, `MPC_FILTER_MODE`, `MPC_VIDEO_MODE`,
`MPC_ASYNC_PRESENT`, `MPC_MAXIMIZE`, or `MPC_ALSA_HEADROOM` as needed. Set
`MPC_MAXIMIZE=0 MPC_WINDOW_RESOLUTION=1240x894` for a fixed-size desktop
window.

Run the deterministic offline and full live MPC2000XL timing regressions with:

```bash
./scripts/diagnostics/test-mpc2000xl-timing.sh
MPC_ASYNC_PRESENT=1 MPC_VIDEO_MODE=opengl MPC_VIEW_NAME='Screen 0' \
  ./scripts/diagnostics/test-mpc2000xl-live-timing.sh
```

The exact desktop listening configuration and the resize-regression evidence
are recorded in
[MPC2000XL low-latency desktop settings](docs/mpc2000xl-low-latency.md).

The live test captures exactly what the PipeWire callback delivered, requires
zero buffer corrections during playback, rejects inserted or removed whole
samples, and removes one fitted constant fractional offset before requiring a
maximum residual below 0.01 sample.

For every setting record:

```text
CPU utilisation
emulation speed %
audio underruns/xruns
audible glitches
stability over e.g. 10–30 minutes
```

Don't use MAME's `-lowlatency` option as the audio test; that option changes when video frames are drawn relative to throttling and isn't the audio-buffer control. ([[MAME Documentation](https://docs.mamedev.org/commandline/commandline-all.html)][3])

Then repeat on:

```text
PC baseline
   ↓
Pi 5
   ↓
Pi 3B+
   ↓
Zero 2 W, if the first results justify buying/testing one
```

The **Pi 5** tells us whether MAME itself is capable of the latency we want without CPU being a constraint.

The **3B+** gives us a good estimate of slower Cortex-A53 behavior.

The **Zero 2 W** is the enticing final software platform because it's only **65×30 mm, quad-core Cortex-A53 at 1 GHz with 512 MB RAM and USB 2.0 OTG**. ([[Raspberry Pi](https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/?variant=raspberry-pi-zero-2-w&utm_source=chatgpt.com)][4])

The target I would consider a success is roughly:

> **stable ≤5 ms actual strike-to-audio latency**

and I'd be very interested if we can get close to **2–3 ms**.

Eventually measure this physically rather than inferring it from buffers:

```text
scope CH1 = impact/piezo on MPD pad
scope CH2 = analog audio output

           <----- actual latency ----->
impact  ___|‾|________________________
audio   ___________|~~~~~~~
```

That captures USB polling, MPD scanning, Linux, MAME, emulated panel CPU, L6028, audio buffering and DAC latency all together.

## Phase 3 — make the MPD the internal MPC pads

Once MAME itself works, patch the driver.

Current MPC2000XL MAME behavior is essentially:

```text
keyboard pad
    ↓
selected pad row
    ↓
ADC input = 0 or 255
    ↓
real emulated uPD78C10 panel firmware
```

The source shows the panel controller scanning the drum row and `an0_pads_r()` through `an3_pads_r()` currently returning binary values. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc2000.cpp)][1])

We replace that front end with:

```text
MPD18 physical pad
      ↓
MPD's own velocity sensing
      ↓
USB note + velocity
      ↓
our host-side pad adaptor
      ↓
emulated MPC pad row + analog velocity signal
      ↓
original MPC panel-controller ROM
      ↓
original MPC firmware
```

The important conceptual point:

> **USB MIDI is only the wire protocol between the MPD electronics and our emulator.**

The emulated MPC never sees it as MIDI IN.

Eventually we may model the actual pad-sensor pulse rather than simply map MIDI velocity 1–127 to ADC 0–255. Then the original Akai panel firmware gets to perform its own velocity interpretation.

## Phase 4 — software-hardware prototype

Once that works, move to the actual loose hardware.

For the first physical prototype:

```text
Pi 5 initially
│
├── MPD18 over USB
├── normal USB keyboard
├── ordinary mouse / scroll wheel
├── 5.5" 256×64 display
├── stereo ADC
└── stereo DAC
```

No enclosure.

The display is almost a native match:

```text
MPC2000XL : 248×60
your LCD  : 256×64

MPC3000   : 240×64
your LCD  : 256×64
```

MAME itself confirms those framebuffer dimensions. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc2000.cpp)][1])

We still need to check the **exact controller/interface of that €45 display** before choosing how the Pi or FPGA drives it.

### Audio hardware

You already have something in the **PCM1808-ish ADC family** plus PCM5102-type DAC hardware, so the final basic analog path only needs:

```text
LINE INPUT L/R
      ↓
1 × stereo ADC
      ↓
MPC
      ↓
1 × stereo DAC
      ↓
MAIN OUTPUT L/R
```

There's no reason to physically reproduce all eight individual outputs unless we particularly want them.

## Phase 5 — physical controls

For the case:

```text
MPD18 original PCB + rubber pads + sensors
     = velocity-sensitive 4×4 pad assembly

old USB keyboard PCB
     = almost all MPC buttons

rotary encoder
     = DATA wheel
```

For initial testing, **mouse scroll is enough for the wheel**.

For the finished software version, an Alps EC12E-class **24-detent/24-pulse quadrature encoder** can connect directly to Pi GPIO.

No custom PCB needed.

Buttons mounted in the CNC/printed top panel can simply close chosen contacts on the donor keyboard PCB. We just need to choose matrix positions that don't ghost on important combinations such as **REC + PLAY**.

The finished enclosure can use CNC wood for the structural shell/top panel and 3D printing for button plungers, screen bezel, PCB mounts, encoder mount and internal brackets.

## Phase 6 — optional USB multichannel interface

This could be a killer modern addition.

Since the emulated L6028 already creates:

```text
Main L
Main R
Out 1
Out 2
...
Out 8
```

we can route those directly to a computer digitally rather than installing ten DAC channels. MAME's L6028 implementation explicitly exposes all ten outputs. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/devices/sound/l7a1045_l6028_dsp_a.cpp)][2])

So the Pi could enumerate to a DAW as:

```text
USB Audio Class 2

MPC → PC:
10 channels

PC → MPC:
2 channels stereo return/sampling input

optional:
USB MIDI too
```

That means a single USB cable can give a DAW **all eight individual MPC outs plus stereo mix**, while the physical box still only needs one stereo DAC.

### Zero 2 W caveat

The Zero 2 W has **one USB 2.0 OTG controller**. ([[Raspberry Pi](https://www.raspberrypi.com/news/new-raspberry-pi-zero-2-w-2/?utm_source=chatgpt.com)][5])

Therefore it can be:

```text
USB HOST
→ MPD
```

or:

```text
USB DEVICE
→ PC audio interface
```

but not both simultaneously through that controller.

A front-panel **STANDALONE / USB** switch is therefore perfectly reasonable:

```text
STANDALONE
Zero = host
MPD active
analog I/O active

USB / EXPORT / SERVICE
Zero = USB device
PC sees audio/MIDI/service functions
```

That works particularly well if multichannel USB is mainly for **playing back/separating an existing sequence into the DAW**.

If we ultimately demand **live MPD finger drumming and 10-channel UAC2 to the PC simultaneously**, use the **Pi 5** or add a separate USB host solution. Raspberry Pi officially supports OTG/device mode on Pi 5's USB-C while its other USB ports remain available as host interfaces. ([[Raspberry Pi Product Information Portal](https://pip-assets.raspberrypi.com/categories/685-app-notes-guides-whitepapers/documents/RP-009276-WP/Using-OTG-mode-on-Raspberry-Pi-SBCs?utm_source=chatgpt.com)][6])

## Phase 7 — decide whether software is already good enough

This is the fork.

If something tiny like a Zero 2 W gives us:

```text
100% MAME speed
stable tiny audio buffers
~2–5 ms measured end-to-end latency
reliable MPC operation
```

then **the FPGA version becomes a fun authenticity/engineering project rather than a necessity**.

The software machine could already be:

```text
Zero 2 W
MPD guts
256×64 LCD
keyboard PCB
encoder
PCM180x ADC
PCM5102 DAC
microSD
```

That's ridiculously compact and inexpensive.

If MAME can't achieve the required deterministic latency or there are still too many driver/audio inaccuracies, proceed to FPGA.

---

# FPGA path — next stage

Your **DE10-Nano + 128 MB MiSTer SDRAM** is the development platform.

That is exactly what I'd use instead of fighting DDR3. The old Akai machines don't need DDR bandwidth; deterministic SDRAM access is much nicer.

Start with the **MPC3000 / MPC2000XL common platform**, because that's where the reuse is highest:

```text
                 common Akai core
┌────────────────────────────────────────┐
│ NEC V53 @ 32 MHz                       │
│ DMA / timer / interrupt / serial       │
│                                        │
│ uPD78C10 panel-controller environment  │
│                                        │
│ L6028 sampler DSP                      │
│                                        │
│ sample RAM controller                  │
│ MIDI                                   │
│ storage                                │
└─────────────────┬──────────────────────┘
                  │
          machine wrapper
             /         \
        MPC3000       MPC2000XL
```

MAME documents both as 32 MHz V53 systems; the 2000XL additionally identifies its 12 MHz uPD78C10 panel CPU and L6028, and explicitly states the sound generation is identical to the 3000. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc2000.cpp)][1])

### FPGA development methodology

Don't try to make it “better than MAME” initially.

First:

```text
MAME C++ implementation
        ↓
      golden
     reference
        ↕
SystemVerilog implementation
        ↓
    Verilator
 differential tests
```

Port the blocks one by one:

```text
L6028 first
V53 / peripherals
panel MCU environment
memory system
LCD
MIDI
storage
```

**Verilator** should be the primary regression tool because the golden reference is already C++. Icarus Verilog remains useful for ordinary HDL tests.

For L6028, feed both implementations:

```text
same RAM
same register writes
same timing
same initial state
```

and require:

```text
MAME PCM == Verilator PCM
```

sample by sample.

Once the FPGA is **MAME-exact**, we have a clean baseline.

Then create an **accuracy branch** where MAME's assumptions are replaced by measurements from real hardware.

That's where your existing **MiSTer-Discrete / analog-modeling work** becomes useful.

The programmable MPC voice filter is digital inside the Akai DSP architecture; the later DAC/output circuitry is separate. So we can independently improve:

```text
L6028 digital behavior
          ↓
DAC behavior
          ↓
analog reconstruction/output model
          ↓
modern DAC
```

without mixing those questions together.

## FPGA memory

For DE10 development:

```text
Cyclone V
   ↓
MiSTer SDRAM controller
   ↓
your 128 MB SDRAM module
```

Expose only whatever RAM the emulated MPC expects.

The final Tang candidate is currently **Tang Primer 25K**, not Nano 20K.

Primer 25K has **23,040 LUT4**, is about **23×18 mm**, and its Dock exposes a 40-pin SDRAM interface. ([[Sipeed Wiki](https://wiki.sipeed.com/hardware/en/tang/tang-primer-25k/primer-25k.html?utm_source=chatgpt.com)][7])

Sipeed sells a matching **2×32 MB SDR SDRAM module**, so 64 MB total. Their 40-pin interface is explicitly partially compatible with the DE10-Nano style interface; they warn specifically that MiSTer SDRAM V3.0 differs on pins 29/30. ([[Sipeed Wiki](https://wiki.sipeed.com/hardware/en/tang/tang-PMOD/FPGA_PMOD.html?utm_source=chatgpt.com)][8])

Since your MiSTer 128 MB module is apparently an older v1/v2-ish revision, **we should check the exact silkscreen/schematic before ever plugging it into a Primer**, but there is a realistic chance it can be reused directly or with a trivial adapter.

### Tang choices

The **Nano 20K** has 20,736 LUT4 and onboard **64 Mbit = 8 MB SDR SDRAM**. That's nice and tiny, but 8 MB is the main limitation for a fully expanded MPC-class machine. ([[Sipeed Wiki](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html?utm_source=chatgpt.com)][9])

Primer 25K:

```text
23,040 LUT4
external plain SDR SDRAM
tiny SOM
```

looks much more appropriate. ([[Sipeed Wiki](https://wiki.sipeed.com/hardware/en/tang/tang-primer-25k/primer-25k.html?utm_source=chatgpt.com)][7])

Our present LUT estimate for a sensible time-multiplexed design is roughly **11–19K LUT4**, perhaps around 14–17K, but that is strictly an engineering estimate. **We do not choose the final FPGA until Quartus and Gowin synthesis give us actual numbers.**

So:

```text
DE10-Nano first
      ↓
working RTL
      ↓
synthesis report
      ↓
if comfortably <23K
     Primer 25K
else
     larger Tang
```

No premature optimization.

## FPGA MPD/control interface

The same conceptual rule applies:

**MPD pads become the built-in MPC pads, not MIDI IN.**

For the FPGA prototype, there are a few possible transport implementations:

```text
MPD USB → USB host → FPGA pad adaptor
```

or use a tiny helper MCU/USB-host controller and send simple pad+velocity events to the FPGA.

The final FPGA core then feeds those into the **real emulated pad matrix/ADC interface**, exactly like the MAME patch.

The keyboard PCB can similarly remain USB HID if we implement/attach a USB host, or its matrix can ultimately be wired directly into FPGA GPIO. We can decide that after the core works.

## Other MPCs

**MPC3000 + MPC2000XL** should be the first shared FPGA target.

**MPC60** is a separate but realistic later project. MAME has a driver, but it uses a **10 MHz 80186 + different L4003 audio architecture**, and MAME currently calls its sound imperfect. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc60.cpp)][10])

**MPC1000/2500/500** are substantially later SH-3 machines and MAME does not currently provide complete machine drivers for them, so they're not phase-one targets. The MPC3000 MAME source merely documents their SH-3 hardware. ([[GitHub](https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc3000.cpp?utm_source=chatgpt.com)][11])

## So the actual order from here

1. **Build/run current MAME on the local Linux machine.**
2. Obtain your own ROM dumps and bring up **2000XL, 3000, and optionally 60**.
3. Determine which functions actually work despite the `MACHINE_NOT_WORKING` status.
4. **Measure PortAudio underruns/xruns at 10 → 5 → 2.5 → 2 ms requested latency.**
5. Repeat on **Pi 5 and 3B+**.
6. Only if results are promising, test a **Zero 2 W** as the tiny final software platform.
7. Patch **MPD → internal pad matrix/velocity ADC**, not external MIDI.
8. Measure **real pad-impact-to-analog-output latency**.
9. Add the **PCM180x-style ADC + PCM5102 DAC** and 256×64 display.
10. Use keyboard + mouse until the entire machine is genuinely enjoyable.
11. Then gut the MPD/keyboard and build the enclosure/control panel.
12. In parallel/later, start **L6028 → SystemVerilog on DE10-Nano**, differential-tested against MAME.
13. Grow that into the common **MPC3000/2000XL FPGA platform** using your 128 MB MiSTer SDRAM.
14. Only after synthesis choose **Primer 25K vs a larger Tang**.

So I would **not buy the Tang yet**. The next useful expenditure is basically zero: get the current MAME tree running and find out whether we already have a genuinely playable MPC at a 2–5 ms buffer. That result decides almost everything else.

[1]: https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc2000.cpp "mame/src/mame/akai/mpc2000.cpp at master · mamedev/mame · GitHub"
[2]: https://github.com/mamedev/mame/blob/master/src/devices/sound/l7a1045_l6028_dsp_a.cpp "mame/src/devices/sound/l7a1045_l6028_dsp_a.cpp at master · mamedev/mame · GitHub"
[3]: https://docs.mamedev.org/commandline/commandline-all.html "Universal Command-line Options — MAME Documentation 0.289 documentation"
[4]: https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/?variant=raspberry-pi-zero-2-w&utm_source=chatgpt.com "Buy a Raspberry Pi Zero 2 W – Raspberry Pi"
[5]: https://www.raspberrypi.com/news/new-raspberry-pi-zero-2-w-2/?utm_source=chatgpt.com "New product: Raspberry Pi Zero 2 W on sale now at $15 - Raspberry Pi"
[6]: https://pip-assets.raspberrypi.com/categories/685-app-notes-guides-whitepapers/documents/RP-009276-WP/Using-OTG-mode-on-Raspberry-Pi-SBCs?utm_source=chatgpt.com "Using OTG mode on Raspberry Pi SBCs"
[7]: https://wiki.sipeed.com/hardware/en/tang/tang-primer-25k/primer-25k.html?utm_source=chatgpt.com "Tang Primer 25K"
[8]: https://wiki.sipeed.com/hardware/en/tang/tang-PMOD/FPGA_PMOD.html?utm_source=chatgpt.com "Tang PMOD"
[9]: https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html?utm_source=chatgpt.com "Tang Nano 20K"
[10]: https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc60.cpp "mame/src/mame/akai/mpc60.cpp at master · mamedev/mame · GitHub"
[11]: https://github.com/mamedev/mame/blob/master/src/mame/akai/mpc3000.cpp?utm_source=chatgpt.com "mame/src/mame/akai/mpc3000.cpp at master"
