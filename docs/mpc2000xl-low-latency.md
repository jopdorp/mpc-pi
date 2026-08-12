# MPC2000XL low-latency desktop settings

## Validated configuration

The known-good full-panel desktop path is:

- native PipeWire audio at 48 kHz;
- 32-frame PipeWire graph quantum and client latency request;
- unchanged ALSA device headroom by default, with an explicit zero-headroom
  experimental option;
- 16-sample MAME sound-update cadence;
- one quantum plus one producer update of internal margin (48 samples);
- audio-master pacing with MAME video throttling disabled;
- OpenGL full-panel rendering, bilinear filtering, and a maximized window;
- asynchronous low-priority primitive generation, drawing, and presentation;
- SDL event pumping isolated on the low-priority process main thread;
- emulation on CPUs 0-11 at nice -10 and SCHED_RR priority 20; and
- MPC2000XL event-driven panel UART mode; and
- event-driven MB89371 MIDI baud clocks with the periodic compatibility mode
  retained for canonical regression renders.

The SDL library is not patched or replaced. These video changes are confined
to MAME's SDL OSD/backend source (`src/osd/sdl`), which uses the stock system
SDL runtime.

Launch the Logic tutorial project with the MPD18 as MIDI input:

```bash
MPC_MIDI_INPUT_MODE=internal-pads scripts/run-mpc.sh mpc2000xl 32 \
  -flop results/projects/mpc-tutor-logic-mpc2000xl.img \
  -skip_gameinfo \
  -midiin1 'Akai MPD18 MIDI 1' \
  -autoboot_script scripts/lua/listen-loaded-mpc2000xl.lua
```

The launcher leaves the default ALSA PipeWire sink unchanged. Set
`MPC_ALSA_HEADROOM=0` for the lower-latency experiment or, for example,
`MPC_ALSA_HEADROOM=48` for an A/B comparison. The setting remains on that
PipeWire node after MAME exits.

## Launch-time configuration

These settings are not compiled into MAME. They are launcher defaults or
host-level commands and must remain documented whenever they change.

| Setting | Default | Effect |
|---|---|---|
| Second launcher argument | `32` | PipeWire client latency and quantum request in frames |
| `PIPEWIRE_RATE_HZ` | `48000` | Host sample rate |
| `PIPEWIRE_QUANTUM` | `32/48000` | Override the client quantum request |
| `PIPEWIRE_LATENCY` | `32/48000` | Override the client latency request |
| `MPC_ALSA_HEADROOM` | `keep` | Leave device-side ALSA headroom unchanged, or set a frame count |
| `MAME_TIMING_MASTER` | `audio` | PipeWire output paces emulation and MAME runs `-nothrottle` |
| `MAME_CPUSET` | `0-11` | CPU affinity for the MAME process and its workers |
| `MAME_NICE` | `-10` | Emulation process nice level |
| `MAME_RT_PRIORITY` | `20` | Emulation SCHED_RR priority; PipeWire is RR 90 on the test host |
| `MPC_VIDEO_MODE` | `opengl` | Desktop renderer |
| `MPC_ASYNC_PRESENT` | `1` | Enable asynchronous presentation |
| `MPC_SDL_EXTERNAL_EVENT_LOOP` | `1` | Isolate SDL event pumping from emulation |
| `MPC_VIEW_NAME` | `Default Layout` | Render the complete MPC panel |
| `MPC_FILTER_MODE` | `1` | Enable bilinear filtering |
| `MPC_MAXIMIZE` | `1` | Start maximized |
| `MPC_WINDOW_RESOLUTION` | `auto` | Let MAME size the render target |
| `MPC_PANEL_MODE` | `event` | Event-driven MPC2000XL panel UART |
| `MPC_PANEL_TIMER_MODE` | `accurate` | Choose per-transition or cycle-equivalent coalesced panel timer output |
| `MPC_MIDI_INPUT_MODE` | `accurate` | Choose accurate wire timing, fast external MIDI, or direct internal-pad events |
| `MPC_MIDI_CLOCK_MODE` | `event` | Event-driven external MIDI baud clocks; use `accurate` for periodic-clock compatibility |

## MPD18 input modes

The default `accurate` mode keeps the original emulation path: host MIDI is
serialized at 31.25 kbaud into the MPC's emulated external MIDI UART. `fast`
skips that redundant wire serialization but still enters through the
MB89371 UART and the MPC firmware's external-MIDI parser.

`internal-pads` is the lowest-latency MPD18 mode. It translates MIDI notes
36-51 to MPC pads 1-16, preserves Note On velocity, translates Note Off (and
zero-velocity Note On) to pad release, and injects the panel's native two-byte
pad message into the V53 SCU. This bypasses the panel CPU's analog scan and
debounce, while retaining the MPC main firmware and L6028 DSP paths. Other
notes and non-note MIDI messages are ignored in this mode, so use `fast` for a
general MIDI controller.

A controlled 20-hit test through the host's virtual MIDI port measured:

| Mode | Host poll to complete message, median | Host poll to DSP key-on, median | DSP key-on p95 |
|---|---:|---:|---:|
| `fast` external MIDI | 0.137 ms | 0.895 ms | 1.434 ms |
| `internal-pads` | 0.104 ms | 0.868 ms | 1.305 ms |

The direct internal-pad route is only about 0.03 ms faster than `fast`, because
both optimized modes already bypass the physical MIDI wire. Its larger gain is
relative to `accurate`: an earlier physical-MPD trace measured 1.144 ms from
host polling through reception of the three serialized MIDI bytes, before the
firmware/DSP response. The injection boundary itself stayed below 0.122 ms in
all 20 direct-pad events. These figures stop at DSP key-on and do not include
the separate host audio-buffer delay.

## MIDI baud-clock scheduling

`MPC_MIDI_CLOCK_MODE` is independent of `MPC_MIDI_INPUT_MODE`. The input mode
chooses how host MIDI enters the emulated machine. The clock mode chooses how
the MPC2000XL's two MB89371 UART baud generators are scheduled.

The compatibility `accurate` mode schedules both 2 MHz oversampling clocks
periodically, including while both UARTs are idle. The default `event` mode
fast-forwards idle clock phase analytically and schedules only the next UART
sample or transmit boundary that can change state. Incoming RX transitions
and firmware writes first advance to their exact emulated time, so active MIDI
still uses the UART and its 31.25 kbaud wire timing. Use this canonical control
when comparing byte-identical legacy renders:

```bash
MPC_PANEL_MODE=accurate MPC_MIDI_CLOCK_MODE=accurate \
  scripts/run-mpc.sh mpc2000xl 32 [MAME options]
```

On the 84.9-second loaded Logic benchmark, scheduler instrumentation measured
337,462,371 MB89371 callbacks in periodic mode and 54 in event mode. A matched
uninstrumented, single-CPU, video-disabled A/B measured:

| Metric | Periodic | Event | Change |
|---|---:|---:|---:|
| Task clock | 58,170.18 ms | 30,628.32 ms | -47.34% |
| CPU cycles | 139.46 billion | 73.21 billion | -47.50% |
| Instructions | 405.79 billion | 192.53 billion | -52.56% |
| Average emulation speed | 148.99% | 289.38% | +94.23% |

Event mode produced the same 86 DSP key-ons in the same order, channels,
sample addresses, and simultaneous-event groups. Against the theoretical
86 BPM / 96 PPQN sequence grid, the current event-panel control had an
873.2 us worst residual and event-driven MIDI clocks had an 885.9 us worst
residual. Their median residuals were 16.0 and 15.1 samples respectively. The
PCM phase changes, so canonical hash checks explicitly select `accurate` MIDI
clocks; sample playback remains continuously clocked after each key-on.

## Panel timer-output coalescing

`MPC_PANEL_TIMER_MODE=coalesced` removes a separate source of panel CPU host
work without changing its guest clock. The MPC2000XL panel firmware selects
the uPD78C10 fixed-clock timer output, which toggles TO once per 4 MHz machine
cycle. TO is not connected on this machine and firmware does not expose it on
Port C, but the generic CPU core still performed a callback and a serial-clock
update for every transition.

Coalesced mode advances the internal serial state by the same transition count
in one operation and retains the exact final TO phase. It dynamically uses the
original transition-by-transition path if the TO callback is connected, TO is
selected on Port C, or the serial mode changes. The raw MAME switch is
`MAME_MPC_PANEL_TIMER_COALESCED`; use the launcher setting above so accurate
mode explicitly clears it.

The complete panel TXD trace across boot, project loading, idle/status traffic,
and a scripted Play press contained 14,320 edges. Accurate and coalesced modes
had byte-identical 12 MHz timestamps and line states, with SHA-256
`33258ed401e24fbc014ad69dd6612d641da281a6f715b978d24d567e99141786`.
Two coalesced Logic renders were also byte-identical to each other and to the
canonical accurate PCM SHA-256
`22f76ffaaedc4364b8279a79672a07a35f93997f180b8665e9ef3a576ae176a9`.
The trace artifact is
`results/diagnostics/panel-timer-coalesced-txd-0vMqPy`.

A five-pair, alternating-order A/B used the 84-second loaded Logic workload on
CPU 20 with the host in balanced mode, video and sound output disabled, video
timing, event-driven panel/MIDI clocks, and SDL event-loop isolation disabled.
Medians were:

| Metric | Accurate | Coalesced | Change |
|---|---:|---:|---:|
| Task clock | 34,393.46 ms | 30,647.48 ms | -10.89% |
| CPU cycles | 77.80 billion | 69.21 billion | -11.04% |
| Instructions | 194.28 billion | 160.29 billion | -17.50% |
| Branches | 33.43 billion | 27.92 billion | -16.50% |

The steady-state part of this workload is deliberately throttled to normal
speed, so its average-speed percentage is not a throughput measurement. The
retired-instruction reduction is the most portable evidence for the intended
Cortex-A53 target. Performance artifacts are in
`results/diagnostics/panel-timer-coalesced-perf-WHD9uw`.

The client request alone does not guarantee a 32-frame graph when other
PipeWire clients request a larger quantum. The validated host explicitly
forces it:

```bash
pw-metadata -n settings 0 clock.force-quantum 32
```

Verify both the forced setting and the running graph:

```bash
pw-metadata -n settings 0 | grep clock.force-quantum
pw-top
```

Release the host-wide override after testing with:

```bash
pw-metadata -n settings 0 clock.force-quantum 0
```

The launcher needs permission for negative nice values and SCHED_RR. On this
workstation those permissions were configured outside the repository. A launch
that fails at `nice` or `chrt` is not equivalent to the validated run; either
restore the host permissions or explicitly choose documented fallback values,
for example `MAME_NICE=0 MAME_RT_PRIORITY=1`.

## Resize regression

Primitive-list generation includes resize-dependent layout and artwork
scaling. It must run on the asynchronous presenter, not on the
emulation/audio-producing thread. A regressed build put `get_primitives()` on
the emulation thread. Profiling an active resize measured:

| Stage | Normal | Active-resize worst case |
|---|---:|---:|
| Cursor update | about 18 us | 64.5 us |
| Layout setup | about 9 us | 94.2 us |
| Primitive generation | about 150 us | 192.6 ms |

The primitive spike coincided with 80-190 ms gaps in the main audio producer
and immediate MAME buffer underruns. Restoring primitive generation to the
low-priority presenter eliminated audible resize xruns in the interactive
full-panel test. With that fixed, the PCM2900C default sink also passed the
same short interactive resize test at zero device headroom. PipeWire's sink
error counter stayed unchanged during that run. At the time of that test,
`powerprofilesctl get` reported `power-saver`, and CPUs 0 and 10 both reported
the `powersave` governor with `energy_performance_preference=power`.

Zero headroom did not pass the longer stability gate. Matched 60-second
audio-master runs with the same clean binary, 32-frame graph, 16-sample
cadence, event-driven panel, and video disabled measured:

| ALSA headroom | Main-output underruns |
|---:|---:|
| 48 frames | 3 |
| 0 frames | 8 |

The comparison shows that device headroom influences tolerance but does not
fix the producer tail: even 48 frames was not clean. Zero therefore remains an
explicit latency experiment, not the launcher default.

Patch `0013-sdl-synchronize-async-render-shutdown.patch` therefore retains the
safe SDL teardown ordering without moving primitive generation back to the
emulation thread.

## Verification

Run the deterministic and live timing checks after rebuilding:

```bash
scripts/diagnostics/test-mpc2000xl-timing.sh
MPC_ASYNC_PRESENT=1 MPC_VIDEO_MODE=opengl \
  scripts/diagnostics/test-mpc2000xl-live-timing.sh
```

During an interactive test, confirm the active graph and error counters with:

```bash
pw-top
pw-cli enum-params "$(wpctl inspect @DEFAULT_AUDIO_SINK@ | sed -n '1s/^id \([0-9][0-9]*\),.*/\1/p')" Props
```

Do not increase the PipeWire quantum or MAME sound cadence to mask a resize
failure. A resize xrun is evidence that desktop video work has leaked back into
the emulation timeline.
