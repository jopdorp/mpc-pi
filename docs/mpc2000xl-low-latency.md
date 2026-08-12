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
- a fixed 1280x720 CPU artwork raster, with actual-resolution LCD, UI, window
  geometry and input mapping;
- machine-state primitive generation on the emulation thread, with OpenGL
  drawing and presentation on a low-priority asynchronous worker;
- SDL event pumping isolated on the low-priority process main thread;
- emulation on CPUs 0-11 at nice -10 and SCHED_RR priority 20; and
- MPC2000XL event-driven panel UART mode; and
- event-driven MB89371 MIDI baud clocks with the periodic compatibility mode
  retained for canonical regression renders; and
- an optional cycle-equivalent V53 status-service HLE, with the interpreter
  retained as the default; and
- an independently selectable V53 event-service HLE, also defaulting to the
  interpreter.

The SDL library is not patched or replaced. These video changes are confined
to MAME's render core and SDL OSD/backend source, which use the stock system
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
| `MPC_ARTWORK_RESOLUTION` | `1280x720` | Fix MPC2000XL CPU-side panel-art raster dimensions; use `auto` for stock target-sized artwork |
| `MPC_PANEL_MODE` | `event` | Event-driven MPC2000XL panel UART |
| `MPC_PANEL_TIMER_MODE` | `accurate` | Choose per-transition or cycle-equivalent coalesced panel timer output |
| `MPC_MIDI_INPUT_MODE` | `accurate` | Choose accurate wire timing, fast external MIDI, or direct internal-pad events |
| `MPC_MIDI_CLOCK_MODE` | `event` | Event-driven external MIDI baud clocks; use `accurate` for periodic-clock compatibility |
| `MPC_V53_STATUS_MODE` | `accurate` | Choose interpreted or ROM-gated HLE execution for one hot V53 firmware service |
| `MPC_V53_EVENT_SERVICE_MODE` | `accurate` | Choose interpreted or ROM-gated HLE execution for the bounded BRK FD event service |
| `MPC_V53_DISPATCH_MODE` | `accurate` | Choose canonical or MPC-profiled direct dispatch for eight hot V53 opcodes |

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

## V53 status-service HLE

`MPC_V53_STATUS_MODE=hle` replaces one bounded MPC2000XL V53 firmware service,
BRK 88 at `0000:4ffc`, after the CPU core has performed the normal interrupt
entry. The service runs about 39,900 times per second in the loaded Logic
workload and returns a small status snapshot in registers. The HLE preserves
the interrupt frame, saved-DS stack write, register and flag results, memory
read order, prefetch state, and branch-dependent guest cycle count.

This mode is deliberately narrow and defaults to `accurate`. It is enabled
only for MPC2000XL OS v1.20 with ROM SHA-1
`382be688972fe3d85caeca99abff4b6c391347fb`. The handler's 49 bytes are also
validated after the firmware copies them to RAM. Debugging, tracing, an
unexpected CPU state, a changed address mapping, modified handler code, a
pending NMI, insufficient scheduler budget, or an unsupported ROM falls back
to the interpreter. The raw MAME switch is `MAME_MPC_V53_BRK88_HLE`; prefer
the launcher setting so the fallback is explicitly selected otherwise.

The event-mode reference and HLE render were byte-identical, with SHA-256
`a65077eb074df2671731ea0e3f315f627044b4ece480c75de2871b8fd81b4014`.
Temporary 48 MHz DSP tracing found the same 86 key-ons at exactly the same
ticks: maximum onset delta was 0 samples and 0 microseconds. A deliberately
modified ROM also exercised the unsupported-ROM fallback. Forced tests of the
two otherwise unobserved status branches matched the interpreter exactly as
well: 114 total cycles / 171 ticks at 48 MHz for submode zero, and 116 cycles /
174 ticks for submode one, with all logged architectural state identical.

A three-pair, pinned short A/B used the loaded Logic playback, video and sound
outputs disabled, and event-driven panel/MIDI clocks with coalesced panel timer
output. Medians were:

| Metric | Accurate | HLE | Change |
|---|---:|---:|---:|
| Task clock | 16,202.97 ms | 15,548.95 ms | -4.04% |
| CPU cycles | 38.14 billion | 36.35 billion | -4.70% |
| Instructions | 93.71 billion | 88.62 billion | -5.43% |
| Branches | 16.44 billion | 15.57 billion | -5.29% |

The raw counter files are retained locally in the ignored diagnostics directory
`results/diagnostics/v53-status-hle-perf-guard`.

Run the focused deterministic regression without regenerating the frozen
event-mode reference:

```bash
scripts/diagnostics/test-mpc2000xl-v53-status-hle.sh
```

## V53 event-service HLE

`MPC_V53_EVENT_SERVICE_MODE=hle` independently replaces the bounded BRK FD
handler at `0000:28ac`. The service runs about 19,656 times per second in the
loaded Logic workload. It atomically fetches and clears one firmware event
byte, returns values below 100 in `AL`, and clamps larger values to zero.

Like the status-service optimization, this mode is default-off, restricted to
MPC2000XL OS v1.20, and validates the RAM handler before use. Normal BRK entry,
the transient saved-DS stack write, XCHG read/register/write ordering, flags,
prefetch state, address translation, and branch-dependent guest cycles are
preserved. Debugging, modified code, an unsupported ROM or CPU state, aliasing
with the handler, pending NMI, or insufficient scheduler budget falls back to
the interpreter. The raw switch is `MAME_MPC_V53_BRKFD_HLE`.

The final common-path render was byte-identical to the frozen event-mode PCM,
SHA-256 `a65077eb074df2671731ea0e3f315f627044b4ece480c75de2871b8fd81b4014`.
The common handler costs 51 V33 cycles; its value-at-least-100 branch costs 54.
An independent forced test of that rare branch matched 907 interpreted and
HLE calls exactly: 81 total cycles and 81 ticks at 32 MHz, with identical
architectural state and prefetch state.
Two pinned short pairs measured 1.35% fewer retired host instructions and
1.27% fewer branches. Their task-clock and cycle results were noisy and did
not establish a wall-clock speedup, so this remains an optional exact cut
rather than a claimed throughput improvement.

Run its focused regression without regenerating the reference:

```bash
scripts/diagnostics/test-mpc2000xl-v53-event-service-hle.sh
```

## V53 direct opcode dispatch

`MPC_V53_DISPATCH_MODE=direct` keeps the canonical NEC interpreter as the
source of truth, but directly calls its existing implementations for eight
opcodes that account for 44.09% of V53 dispatches in the loaded Logic playback
workload. All other opcodes still use the canonical dispatch table. The mode
does not bypass opcode fetches, memory handlers, debugger hooks, instruction
semantics, prefetch accounting, or guest cycle accounting.

The eight-opcode set was selected by measuring four-, eight-, and sixteen-case
variants with the current x86-64 compiler. Eight cases produced the lowest host
cycle count. This selection is workload- and compiler-specific rather than an
architecture-neutral result; it must be remeasured on Cortex-A53 before using
it as Raspberry Pi performance evidence. The mode is MPC2000XL-only,
independently switchable, and defaults to `accurate`. Its raw MAME switch is
`MAME_MPC_V53_DIRECT_DISPATCH`.

A clean CPU-17 comparison selected the mode once per CPU slice, leaving the
accurate inner loop unchanged. Means from two runs per configuration were:

| Metric | Accurate | Direct | Change |
|---|---:|---:|---:|
| Task clock | 9,690.07 ms | 9,279.62 ms | -4.24% |
| CPU cycles | 33.20 billion | 31.16 billion | -6.14% |
| Instructions | 84.60 billion | 85.79 billion | +1.41% |
| Branches | 15.25 billion | 16.27 billion | +6.74% |
| Branch misses | 119.52 million | 106.46 million | -10.93% |

The frozen Logic render remains byte-identical, SHA-256
`a65077eb074df2671731ea0e3f315f627044b4ece480c75de2871b8fd81b4014`.
The Ableton tutorial project provided a second workload. One initial accurate
capture differed, but the repeated accurate capture and two direct captures
were byte-identical with SHA-256
`bc7c2fedaf6735d78b09928c2dc0b71b1f8fb9b7f693b8d9a01923cc6aed2900`.
This demonstrates the cold-run difference was not specific to direct mode.
Run the focused regression with:

```bash
scripts/diagnostics/test-mpc2000xl-v53-direct-dispatch.sh
```

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

## Async rendering and resize regression

Primitive-list generation reads live layout inputs, outputs, screen
containers, textures, and scheduler time. It must therefore run on the
emulation thread. An earlier isolation patch moved `get_primitives()` to the
presenter along with OpenGL drawing. The full MPC layout's raw `DATAENTRY`
dial then made the presenter call `machine().time()` concurrently with the
V53 scheduler. Stress testing reproduced a `SIGFPE` in
`device_t::clocks_to_attotime()` from that race.

Patch `0029-sdl-generate-primitives-on-emulation-thread.patch` restores the
smallest safe ownership boundary: the emulation thread produces and publishes
a locked primitive list, and the low-priority presenter only draws and swaps
that completed list. Three consecutive 30-second loaded-Logic full-layout
runs completed cleanly after the change; the broken path had failed
intermittently within the same interval. OpenGL drawing and presentation
remain asynchronous. A full OpenGL Logic capture also retained the frozen
event/HLE PCM SHA-256
`a65077eb074df2671731ea0e3f315f627044b4ece480c75de2871b8fd81b4014`.
Two independent 1600x900 captures were pixel-identical to the preserved
renderer reference, SHA-256
`5e8f7e6f7cf5323e13f4f417ae80a20637e29d4fb2bc54246f288ee57e88859d`.
The validation artifacts are under `/dev/shm/mpc-async-fixed-pcm-HcusqQ` and
`/dev/shm/mpc-async-fixed-visual2-c7gsdQ`.

Primitive construction is normally small but includes resize-dependent layout
and artwork scaling. Earlier profiling while it ran on the emulation thread
measured:

| Stage | Normal | Active-resize worst case |
|---|---:|---:|
| Cursor update | about 18 us | 64.5 us |
| Layout setup | about 9 us | 94.2 us |
| Primitive generation | about 150 us | 192.6 ms |

The old primitive spike coincided with 80-190 ms gaps in the main audio
producer and immediate buffer underruns. Moving the work to the presenter hid
that symptom but violated MAME's machine-state ownership and caused the crash
above. The correct fix must therefore retain emulation-thread primitive
generation. Continuous-resize PipeWire testing is the remaining gate; if it
still exposes the resize tail, the scaling/cache work must be reduced or
bounded without reading live machine state from the presenter.

The first post-fix live test used the balanced host policy, a forced 32-frame
PipeWire quantum, the full 1600x900 layout, and aggressive manual resizing. It
reported one underrun on each of the three MAME output streams at 16.65 seconds
into the marked playback interval, with callback gaps of 624-630 us. The crash
repair is therefore accepted independently, but resize stability is not yet
accepted. The failed run is
`results/diagnostics/live-timing-CsdHch`; the next renderer patch must remove
this resize cost without changing the validated 32-frame audio settings.

Patch `0030-render-fixed-artwork-resolution.patch` separates physical output
geometry from CPU-side layout-element rasterization. With the launcher default
of `1280x720`, panel SVGs, labels and static artwork use one stable cache key
through a resize; OpenGL linearly samples those textures at the actual window
size. Primitive bounds, mouse/pad hit mapping, the emulated LCD, MAME UI and
hidden snapshot targets retain their actual resolution. `auto` is MAME's core
default and restores the original target-sized artwork path. Other machines
also remain on `auto` unless explicitly overridden.

In the same 440-request 680-to-1920-pixel resize sweep, the fixed path reduced
the emulation-thread primitive-generation maximum from 115.667 ms to 2.433 ms
(about 47.5x), after a single 93.18 ms startup warm-up. The four primitive
passes accepted while the presenter coalesced resize frames were all between
1.96 and 2.43 ms. An exact 1280x720 fixed-versus-auto capture had zero changed
pixels. At larger windows the intended result is linearly scaled 720p body
artwork, while the LCD remains native. The profile artifacts are
`/dev/shm/mpc-fixed-resize-perf-oWztBq` and
`/dev/shm/mpc-artwork-resize-5VKI0g`.

The fixed raster flag is currently consumed for linear sampling by OpenGL.
Other render backends still benefit from stable core artwork cache dimensions
but may use nearest sampling. `MPC_FILTER_MODE` remains the emulated-screen
filter choice; it does not disable fixed-artwork sampling. A small window may
perform more initial artwork work with fixed 720p than with `auto`.

The strict 32-frame live gate is still open. One fixed-artwork run with an
automated resize workload logged no PipeWire buffer events inside the marked
playback interval, but its delivered-audio timeline comparison failed. A
matched no-resize control also failed independently after a 6.483 ms main
audio update inserted 96 samples into the delivered timeline. These artifacts
are `results/diagnostics/live-timing-lr6CRf` and
`results/diagnostics/live-timing-cgsBB0`. The deterministic PCM, visual and
resize-compute results above are accepted for patch 0030; they are not being
presented as a completed live 32-frame/xrun result.

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

Patch `0013-sdl-synchronize-async-render-shutdown.patch` retains the safe SDL
teardown ordering. Patch 0029 changes only frame-production ownership and
keeps that shutdown handshake intact.

## Verification

Run the deterministic and live timing checks after rebuilding:

```bash
scripts/diagnostics/test-mpc2000xl-timing.sh
scripts/diagnostics/test-mpc2000xl-async-present.sh
MPC_PIPEWIRE_FRAMES=32 MAME_TIMING_MASTER=audio \
  MPC_ASYNC_PRESENT=1 MPC_VIDEO_MODE=opengl \
  MPC_VIEW_NAME='Default Layout' MPC_WINDOW_RESOLUTION=1600x900 \
  MPC_ARTWORK_RESOLUTION=1280x720 \
  scripts/diagnostics/test-mpc2000xl-live-timing.sh
```

Continuously resize the MAME window between the playback begin/end markers in
the live test. The diagnostic does not automate desktop window management.

During an interactive test, confirm the active graph and error counters with:

```bash
pw-top
pw-cli enum-params "$(wpctl inspect @DEFAULT_AUDIO_SINK@ | sed -n '1s/^id \([0-9][0-9]*\),.*/\1/p')" Props
```

Do not increase the PipeWire quantum or MAME sound cadence to mask a resize
failure. A resize xrun is evidence that desktop video work has leaked back into
the emulation timeline.
