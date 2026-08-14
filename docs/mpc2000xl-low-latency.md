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
- all MPC main and assignable host outputs exposed by default, with an
  optional stereo topology for a two-channel DAC or headphones;
- stock target-sized artwork by default, with an optional fixed 1280x720 CPU
  artwork raster experiment that leaves the LCD, UI, window geometry and input
  mapping at actual resolution;
- accurate LCD frame commits by default, with an exact unchanged-frame skip
  for the LCD-only deployment preset;
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

The compact deployment preset intentionally differs in two host settings: it
uses native 44.1 kHz and the LCD-only `Screen 0` view. At the unchanged 3 kHz
sound-update cadence, producer batches contain 14 or 15 frames;
with q32, the largest internal quantum-plus-update window is 47 frames, about
1.066 ms. No optimization in this guide raises the quantum or lowers the
producer cadence.

The fast wrapper makes 44.1 kHz native by temporarily setting PipeWire's
global `clock.force-rate` and `clock.force-quantum`, verifying both values,
and restoring the prior settings on exit or a signal. This affects the shared
graph while MAME is running, so a per-user lock rejects a second graph-forcing
fast launch until the first has restored its lease. In this wrapper,
`MPC_PIPEWIRE_FRAMES` and `PIPEWIRE_RATE_HZ` are authoritative: it replaces
inherited `PIPEWIRE_QUANTUM` and `PIPEWIRE_LATENCY` with the matching
`<frames>/<rate>` client request. Use `MPC_FORCE_PIPEWIRE_GRAPH=0` only when
the host already enforces the desired graph rate and quantum.

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

For the authoritative patch-by-patch map, raw switch names, compatibility
fallbacks and reproducible presets, see
[MAME patch stack and launch modes](mame-patch-stack.md).

| Setting | Default | Effect |
|---|---|---|
| Second launcher argument | `32` | PipeWire client latency and quantum request in frames |
| `PIPEWIRE_RATE_HZ` | `48000` | Host sample rate |
| `PIPEWIRE_QUANTUM` | derived | Defaults to `<second argument>/<PIPEWIRE_RATE_HZ>`; override the client quantum request |
| `PIPEWIRE_LATENCY` | derived | Defaults to `<second argument>/<PIPEWIRE_RATE_HZ>`; override the client latency request |
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
| `MPC_ARTWORK_RESOLUTION` | `auto` | Stock target-sized artwork; use `1280x720` for the fixed-raster resize experiment |
| `MPC_GL_VBO` | `1` | Keep MAME's stock per-texture VBO path; set `0` for the faster experimental client-memory path |
| `MPC_OUTPUT_MODE` | `all` | Expose all outputs, or use `stereo` for only floppy and main L/R host channels |
| `MPC_LCD_UPDATE_MODE` | `accurate` | Commit every LCD frame, or use `changed` to suppress commits when LCD RAM is unchanged |
| `MPC_FORCE_PIPEWIRE_GRAPH` | fast wrapper: `1` | Temporarily force/verify the requested graph rate and quantum, then restore the previous global settings at exit |
| `MPC_PANEL_MODE` | `event` | Event-driven MPC2000XL panel UART |
| `MPC_PANEL_TIMER_MODE` | `accurate` | Choose per-transition or cycle-equivalent coalesced panel timer output |
| `MPC_MIDI_INPUT_MODE` | `accurate` | Choose accurate wire timing, fast external MIDI, or direct internal-pad events |
| `MPC_MIDI_CLOCK_MODE` | `event` | Event-driven external MIDI baud clocks; use `accurate` for periodic-clock compatibility |
| `MPC_V53_STATUS_MODE` | `accurate` | Choose interpreted or ROM-gated HLE execution for one hot V53 firmware service |
| `MPC_V53_EVENT_SERVICE_MODE` | `accurate` | Choose interpreted or ROM-gated HLE execution for the bounded BRK FD event service |
| `MPC_V53_DISPATCH_MODE` | `accurate` | Choose canonical or MPC-profiled direct dispatch for eight hot V53 opcodes |
| `MPC_V53_DIVIDE_MODE` | `accurate` | Choose canonical execution or the ROM-gated 32-bit divide superblock |
| `MPC_V53_FETCH_MODE` | `accurate` | Choose handler-dispatch opcode fetch or the direct-pointer 16 KiB fetch window (`window`, fast preset default) |
| `MPC_V53_DATA_MODE` | `accurate` | Choose handler-dispatch data access or the direct-pointer data window (`window`; x86-null, Cortex-A53 candidate) |
| `MPC_SOUND_UPDATES_PER_QUANTUM` | unset | Derive the sound-update cadence from the quantum (`2` in the fast preset); unset keeps the fixed 3 kHz cadence |

## DAC and host-output topology

The default `MPC_OUTPUT_MODE=all` exposes the floppy channel, main stereo pair
and all eight assignable MPC outputs. Use it with a multichannel audio
interface, or with any project that routes voices to the assignable outputs.

For a two-channel DAC or headphones, use:

```bash
MPC_OUTPUT_MODE=stereo scripts/run-mpc.sh mpc2000xl 32
```

This exposes only the floppy and main left/right host channels. It does not
downmix the eight assignable outputs: voices routed exclusively to one of
those outputs are intentionally inaudible. The launcher stores stereo-mode
configuration in `cfg-stereo` and falls back to the normal `cfg` directory for
reads, so using a stereo DAC does not overwrite the saved mapping for a later
multichannel run.

The option is retained for the simpler physical output topology and as an
independently removable cumulative small win. A fresh matched ABBA measured
about 1.39% less task clock, 1.72% fewer cycles, 1.93% fewer retired
instructions and 1.62% higher reported speed. The full-output reference and
stereo capture retained identical floppy/main L/R samples. Reproduce the
topology, PCM and configuration checks with:

```bash
MAME_BIN="$PWD/.cache/mame/mpc" \
  scripts/diagnostics/test-mpc2000xl-stereo-output.sh
```

## Cumulative small-win paths

Patches 0024 and 0032 retain two independent, default-off MPC2000XL OS v1.20
CPU fast paths. Patch 0031's stereo topology is also retained under the
cumulative-small-wins policy. For a two-channel DAC, enable the complete
through-0032 measured candidate with:

```bash
MAME_BIOS=default \
MPC_V53_DIVIDE_MODE=superblock \
MPC_V53_EVENT_SERVICE_MODE=hle \
MPC_OUTPUT_MODE=stereo \
scripts/run-mpc.sh mpc2000xl 32
```

In the comprehensive LCD matrix, divide independently reduced cycles by 1.52%
and BRK FD HLE reduced them by 2.46%; stereo output reduced them by 2.18%. A
separate fixed-work ABBA on the official through-0032 build-script binary
measured 6.36% less task CPU, 6.19% fewer cycles, 4.73% fewer instructions and
6.97% higher emulation speed. The paths
also passed repeated frozen PCM composition gates. Use `MPC_OUTPUT_MODE=all`
if the project needs assignable outputs.

The repaired V53 hotblock experiment is not part of the ordered stack. It is
pixel/PCM exact, but the comprehensive matrix measured 1.31% more cycles alone
and 2.48% more with divide. It remains preserved under `patches/experiments`
for future block-design work, not as a launcher option. Evidence is in
`results/diagnostics/cumulative-0033-gate-20260813` and
`results/diagnostics/official-0032-winning-stack-abba-20260813`.

The `0033` embedded in the first artifact name is an optimization-campaign
candidate number. It predates and is unrelated to ordered patch 0033 below.

The recorded artifacts are
`results/diagnostics/stereo-output-pyexS7` and
`results/diagnostics/current-stack-stereo-perf-VntjgN`.

## LCD unchanged-frame mode

Ordered patch 0033 adds `MPC_LCD_UPDATE_MODE=changed` for MPC2000XL LCD-only
deployment. The normal launcher and raw MAME behavior remain `accurate`; the
fast preset selects `changed`. Both modes still copy the complete 248x60 LCD
bitmap on every screen callback so the working render target and hidden
snapshot paths stay current. Changed mode returns MAME's unchanged-frame flag
only when no LCD RAM byte changed, avoiding the redundant texture commit and
presentation work.

The frozen PCM remained byte-exact, and five raw-pixel plus five PNG
checkpoints matched accurate mode exactly and repeated deterministically. The
same gates passed again on the ordered-stack binary. In its live Screen 0 ABBA
with active PipeWire at native 44.1 kHz and q32, changed mode reduced task CPU
by 3.27%, cycles by 3.82%, retired instructions by 1.69%, and branches by
1.90%. Both chronological pairs improved every metric. Every sampled
marker-window PipeWire node remained at `ERR=0`; because monitoring began at
the marker, startup before that point and the full end-to-end xrun gate remain
unresolved.

The packaged-binary evidence is in
`results/diagnostics/ordered-0033-correctness-20260813-uOi97M` and
`results/diagnostics/official-0033-lcd-live-abba-20260813`. The earlier
prototype evidence remains in
`results/diagnostics/lcd-dirty-r2-pixels-20260813-Peyu3B`.

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

## 44.1 kHz/q32 sound-tail diagnosis

The live LCD-only path is not limited by average sound throughput. The effects
worker accounts for about 2.96% of sampled cycles, the in-process PipeWire
loop 2.05%, and the external event-loop thread 1.80%. Linux wakeup-to-run
histograms put the relevant p95 wake delay in the low single-digit
microseconds. In the default-affinity capture, representative MAME and
PipeWire maxima were about 400 us; a CPU-targeted follow-up reduced the
PipeWire data-loop maximum to 19 us and the observed MAME maxima to 217 us,
although that follow-up workload exited unsuccessfully and is diagnostic only.

The stricter delivered-audio tests found a different tail inside MAME's 3 kHz
producer/effects handoff. A predicate-only wake fix still allowed old speaker
batches to be overwritten. A one-slot generation handshake eliminated those
drops exactly (`discarded_updates=0`, `discarded_frames=0`) without adding a
queue or changing q32, but exposed producer stalls: 24 waits with a 407 us
maximum. Raising the actual effects worker from RR1 to RR2 reduced the maximum
only to 347 us, still longer than the 333.33 us producer period; both runs
continued to underrun and failed the delivered-sample timeline comparator.
The in-emulator WAV stayed byte-identical throughout.

Consequently neither experimental sound flag is shipped or enabled by the
fast launcher. The evidence points to rare worker-availability or lock tails
before it can claim the next generation; average effects-worker CPU is only
about 6 us per generation. The current producer-wait counter also begins at
the following 3 kHz tick and after acquiring the data mutex, so it understates
the full notify-to-snapshot tail.

A subsequent synchronous-inline experiment removed the worker handoff without
changing q32, cadence, buffering, PCM arithmetic, or the PipeWire sink. Its
48 kHz all-output control and candidate WAVs both matched the frozen reference
exactly. Live q32 still failed: the threaded control added 14 underruns and the
inline candidate added 12, with delivered-audio timeline steps at 0, 300, 621,
and 669 samples. Moving effects and the PipeWire push onto the producer shaved
two events but did not solve the tail and removed useful worker overlap, so it
is also rejected.

### Correction: there was no sound tail

Every experiment above was measured with `MAME_CPUSET=20-21`,
`MAME_NICE=0` and `MAME_RT_PRIORITY=1`. On this host CPUs 20-21 are the two
2.5 GHz low-power efficiency cores of a Core Ultra 7 155H, and RR1 is the
lowest real-time priority. `scripts/run-mpc.sh` deploys on CPUs `0-11`
(4.5 GHz P-cores) at nice `-10` and `SCHED_RR` priority `20`. The deployment
configuration was therefore never measured, and the reported ~160% speed was a
property of the measurement cores, not of the emulator.

Direct instrumentation of the deployment configuration settles the question:

| Quantity | Deployment (`0-11`, RR20) | Measurement config (`20-21`, RR1) |
|---|---|---|
| PipeWire callback gap, nominal 725 us | 716-737 us | 716-731 us |
| Underruns during the muted 400% boot phase | 105 | 1531 |
| **Underruns during paced 44.1 kHz/q32 playback** | **0** | **5** |

Callback jitter is at most 12 us. There is no scheduling stall, no lost
wakeup and no worker-availability tail; the paced playback window on the
deployment configuration delivers every quantum. The predicate wake fix, the
one-slot generation handshake, the RR2 worker boost, the batched output
publication and the synchronous inline effects path were all aimed at a stall
that does not exist, which is why each of them "failed" the same gate
regardless of what it changed.

The delivered-audio comparator is not a valid acceptance gate for this
fixture. `live-logic-mpc2000xl.lua` boots for 24 emulated seconds at
`speed_factor = 4000`, where `realtime_pacing` is disabled (it requires
`speed_factor <= 1100`) and the output is muted. During that phase MAME
free-runs and the `abuffer` overrun path discards most of the generated audio.
How much it discards depends on how fast the host boots, so a faster host
corrupts the comparator's alignment more. That is why the deployment
configuration scored roughly twenty times worse on the comparator
(`integer_timeline_lags` around -750 versus around +-40) while simultaneously
producing *fewer* real underruns. The comparator ranks the arms in the
opposite order to their actual audio quality.

Raising the pacing high-water mark does not help the playback window, because
it is already clean. Sweeping `requested + N * requested` at 44.1 kHz/q32
reduced only the inaudible boot-phase burst, with no playback benefit:

| Prebuffer target | Queued latency | Boot-phase underruns | Playback underruns |
|---|---|---|---|
| 47 frames (`quantum` + one producer update, shipped) | 1.066 ms | 105 | 0 |
| 64 frames | 1.451 ms | 50 | 1 |
| 96 frames | 2.177 ms | 36 | 0 |
| 192 frames | 4.354 ms | 16 | 0 |

The shipped 47-frame margin is retained. Note that at 44.1 kHz the producer
update is 14 or 15 frames, not 16: patch `0010` fixes the cadence at 3 kHz
(`48000 / 16`), so at 44.1 kHz each update carries `44100 / 3000 = 14.7`
frames on average. The 48-frame figure applies at 48 kHz.

No new sound patch is warranted. Evidence is in
`results/diagnostics/prebuffer-ab-20260813` (underrun split and prebuffer
sweep), `results/diagnostics/pacing-stats-20260813` (deployment callback
gaps), `results/diagnostics/scheduling-abba-20260813` and
`results/diagnostics/cpuset-width-20260813` (scheduling ABBA), with the
earlier rejected candidates retained in
`results/diagnostics/sound-effects-inline-0033-gate-20260813-215500`,
`results/diagnostics/live-timing-S9qJfy` and
`results/diagnostics/live-timing-sumMYs`.

## V33 opcode fetch window

Profiling the fast stack (`scripts/diagnostics/profile-mpc2000xl-throughput.sh`)
put 63.5% of emulation cycles in the V53 core and its memory accesses. The
fetch path was the concentrated part of that: every opcode byte went through
`v33_translate`, emitted out of line and worth 8.09%, and then a memory-cache
read that dispatched into `handler_entry_read_memory<1, 0>::read`, worth 8.27%.
A V33 instruction is one to six bytes, so that chain runs several times per
instruction.

Patch `0035` inlines the translation and caches a host pointer to the
containing 16 KiB translation page, so a fetch inside the window costs a bounds
check and an array load. The window is keyed on the translated physical
address, so a write to the translation table simply moves the next fetch
outside the window and triggers a refill; no invalidation hook is needed. A
page is adopted only when `read_ptr()` resolves both ends to one contiguous
RAM/ROM block, which rejects handler-backed or discontiguous regions.

It is opt-in because it assumes the program map never changes. That holds here:
the MPC2000XL V53 map is entirely `.ram()`/`.rom()` in blocks of at least
512 KiB with no `membank` or `bankdev` anywhere in the driver, and 16 KiB pages
divide those blocks evenly, so a page cannot straddle two regions. A machine
that banks its V33 program space must leave `MPC_V53_FETCH_MODE=accurate`.

Frozen 48 kHz all-output PCM is bit-identical with the window off and on, and
again on the official ordered binary with the window enabled
(`a65077eb...`), so this is an exact fast path rather than a
timing-preserving one.

An interleaved ABBA on the deployment CPUs measured:

An interleaved ABBA of eight runs per arm on an otherwise idle host measured:

| Arm | Mean | Median | Range |
|---|---|---|---|
| `accurate` | 727.2% | 720.2% | 686-786 |
| `window` | 803.4% | 816.5% | 721-845 |

That is a 10.49% gain on means and 10.52% averaged over adjacent pairs, with
all eight pairs positive. An earlier ABBA taken while an unrelated 4-vCPU
libvirt guest was competing for the same P-cores measured 482.3% against
531.6%, a 10.2% gain: the relative result is stable across both noise
conditions, but only the idle-host figures should be quoted as absolute
throughput.

Re-profiling with the window enabled confirmed the mechanism:
`handler_entry_read_memory<1, 0>::read` fell from 8.27% to 2.19% and
out-of-line `v33_translate` from 8.09% to 2.79%, the residual being data
accesses rather than instruction fetch. Artifacts are in
`results/diagnostics/profile-20260814`,
`results/diagnostics/profile-fetchwindow-20260814`,
`results/diagnostics/fetchwindow-pcm-20260814` and
`results/diagnostics/fetchwindow-speed-20260814`.

## Sound-update cadence derived from the quantum

`STREAMS_UPDATE_FREQUENCY` is a fixed rate, so the frames carried by one host
sound update are whatever `output rate / 3000` happens to be. At 48 kHz that is
exactly 16, but at the MPC2000XL's native 44.1 kHz it is 14.7, so updates
alternate between 14 and 15 frames and a 32-frame callback consumes a drifting
2.177 updates rather than a whole number. The 47-frame margin follows from that
alternation: it is `quantum + max(update)`, not a chosen value.

Patch `0034` inverts the dependency. `MPC_SOUND_UPDATES_PER_QUANTUM=k` makes one
update carry `quantum / k` frames, and `attotime::from_ticks` builds the period
from an exact tick ratio, so a cadence that is not a whole number of hertz
(44100 / 16 = 2756.25 Hz) carries no rounding drift. Exactly 16 frames at
44.1 kHz/q32 is unreachable with a fixed integer cadence, because 44100 has no
power-of-two divisor above 4; expressing the period rather than the frequency
removes that constraint entirely.

At `k=2` the shipped 44.1 kHz/q32 path gets exactly 16-frame updates, a 32/16 =
2 callback-to-update ratio, and a 48-frame margin (1.088 ms, 0.023 ms above the
47-frame margin it replaces).

The mechanism is exact. At 48 kHz, `16/48000` is the historical 3 kHz cadence,
and it reproduced the frozen PCM `a65077eb...` bit-for-bit; with the option
unset the ordered binary also still renders `a65077eb...`. The 44.1 kHz cadence
does move stream chunk boundaries and renders `d2fc99d7...`, so it is
timing-preserving rather than an exact fast path, and enabling it means the
fast preset is not a canonical PCM control. That preset already carries panel
and MIDI event modes and the HLE paths, so this is not a new category for it.

The deployment CPUs cannot measure the benefit: both arms record zero playback
underruns and throughput differences sit inside run-to-run spread (control
716.4/742.6%, derived 718.7/722.1%). The 8.0% reduction in sound-manager
updates is real but does not surface where per-update overhead is a small share
of the work.

A marginal deadline does show it. On CPUs `20-21` at `SCHED_RR` 1, a matched
ABBA of eight runs measured:

| Arm | Playback underruns | Mean | Average speed |
|---|---|---|---|
| Fixed 3 kHz | 4, 4, 4, 4 | 4.00 | 151.9% |
| `k=2` (16 frames) | 1, 2, 2, 3 | 2.00 | 154.6% |

The arms separate completely, and the control repeats exactly four underruns in
every run, which is the signature of a deterministic beat rather than random
jitter -- consistent with a callback-to-update ratio that drifts instead of
dividing. The residual 1 to 3 in the derived arm is scattered, so what remains
looks like ordinary scheduling noise. The preset therefore enables `k=2`, and
the normal launcher keeps the fixed cadence so the canonical PCM control is
unchanged. Artifacts are in
`results/diagnostics/cadence-marginal-20260814`,
`results/diagnostics/cadence-pcm-20260814`,
`results/diagnostics/cadence-pcm-regression-20260814` and
`results/diagnostics/cadence-ab-20260814`.

## Profile-guided official build and the idle-iteration skip

Two further layers moved the fastest stack well past the fetch window.

The official binary is now built profile-guided: `scripts/build-mame-pgo.sh`
builds instrumented (`-fprofile-generate`), runs the Logic playback fixture
with the full deployment options to collect a profile, and rebuilds with
`-fprofile-use`. The flags baseline is `-march=native -ffp-contract=off` plus
`LTO=1`. `-ffp-contract=off` is mandatory: plain `-march=native` enables FMA
contraction, which changes float rounding in the stream-mixing chain and
breaks the frozen PCM (`d37a16c5...` instead of `a65077eb...`). LTO without
PGO is a measured regression (-7.87%, binary bloat 80 MB to 200 MB), but with
the profile it inverts: PGO+LTO measured +11.44% over the generic `-O3` build
in a matched ABBA with complete separation, PCM bit-identical.
`scripts/build-mame.sh` gained `MAME_ARCHOPTS`/`MAME_LTO` passthrough and a
flags stamp that clears the object tree whenever the configuration changes,
because genie-generated makefiles neither track flag changes nor apply new
`ARCHOPTS` without `REGENIE=1`.

On top of that, patch `0037` eliminates most idle guest work. A guest-PC
histogram (`MAME_MPC_V53_PC_HISTOGRAM`) showed twenty 64-byte regions covering
72.5% of all executed V53 instructions, led by the OS main scheduler loop at
RAM linear `0x0077f`: eleven service calls polling task flags, then a jump
back. The skip records one full iteration and arms only when it closes as a
verified pure fixed point (details in the patch-stack table); whole idle
iterations are then charged without executing while the read set stays
unchanged and no interrupt is pending. The sub-iteration remainder always
executes normally, so interrupts land mid-loop exactly as unskipped.

Acceptance: frozen PCM bit-identical with 440,668 iterations skipped; the
live 44.1 kHz/q32 preset recorded zero PipeWire underruns in both the boot
and playback windows (the boot burst that previously produced about a hundred
inaudible underruns disappears entirely, because the unpaced boot now outruns
the producer margin); and a matched interleaved ABBA measured:

| Arm | Mean | Range |
|---|---|---|
| skip off | 819.6% | 777-882 |
| skip on | 1036.3% | 990-1070 |

+26.4% with complete separation. A second recorded head covering the
tick-counter wait loop at linear `0x01691` raised the mean to 1062% (peak
1119%) with 3,044,036 skipped iterations, still bit-exact and still zero
playback underruns. The remaining guest work concentrates in the 31.4 kHz
sample-feed service (V53 DMA programming toward the DSP) and the DMA-ready
poll at `0x36115`, which are real work rather than idle and would need
service-level HLE or device-cooperative completion hints. Artifacts:
`results/diagnostics/idleskip-pcm2-20260814`,
`results/diagnostics/idleskip-live-20260814`,
`results/diagnostics/idleskip-abba-20260814`,
`results/diagnostics/v53-pc-histogram-101531`,
`results/diagnostics/pgo-abba-20260814`,
`results/diagnostics/flags-abba-20260814`.

## Throughput with sound and the LCD enabled

`scripts/diagnostics/test-mpc2000xl-headroom.sh` runs the Logic fixture with
MAME's own throttle far above real time, so the reported average speed is
achieved throughput rather than a paced playback rate. Sound is fully
processed and the OpenGL LCD is presented in every arm; only the CPU set, nice
level and `SCHED_RR` priority differ. Two passes, ordered patch stack, fast
preset options, `MPC_LCD_UPDATE_MODE=changed`, stereo host topology:

| Arm | CPUs | Clock | Achieved speed |
|---|---|---|---|
| Deployment P-cores, nice -10, RR20 | `0-11` | 4.5 GHz | **706.6%, 698.3%** (through `0033`; ~803% with `0035`) |
| E-cores, nice -10, RR20 | `12-19` | 3.8 GHz | 502.5%, 486.6% |
| Earlier measurement config, nice 0, RR1 | `20-21` | 2.5 GHz | 283.8%, 299.8% |

The deployment configuration sustains about 7x real time with sound and the
LCD active, so a 450% target is met with roughly 55% margin, and even the
E-cores clear it. A live 44.1 kHz device still consumes audio at 1.0x; this
number is the headroom available to absorb spikes, not a playback rate.
Artifacts are in `results/diagnostics/headroom-20260813`.

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
geometry from CPU-side layout-element rasterization. With the opt-in
`MPC_ARTWORK_RESOLUTION=1280x720`, panel SVGs, labels and static artwork use
one stable cache key through a resize; OpenGL linearly samples those textures
at the actual window size. Primitive bounds, mouse/pad hit mapping, the
emulated LCD, MAME UI and hidden snapshot targets retain their actual
resolution. `auto` is both MAME's core default and the launcher default, and
restores the original target-sized artwork path. Other machines also remain on
`auto` unless explicitly overridden.

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

The OpenGL backend's default VBO path allocates one 32-byte texture-coordinate
buffer per texture and updates it for every textured quad. The MPC2000XL full
layout has hundreds of such quads, while its vertex array already uses client
memory. In a current-stack, marker-scoped steady-playback 1600x900 ABBA test,
selecting `MPC_GL_VBO=0` reduced task CPU by 23.20%, host cycles by 23.44%,
retired instructions by 10.83%, branches by 11.19%, branch misses by 15.17%,
and cache misses by 9.22%. An independent whole-process boot/load/play ABBA
also measured 19.31% less task CPU and 18.06% fewer cycles. The two paths
produced pixel-identical captures (AE=0), and the client-memory full-render
capture retained the frozen PCM byte for byte. Disabling this VBO path also
disables PBO use in MAME's legacy OpenGL backend, so no separate PBO setting
is exposed. This remains opt-in because strict live 32-frame runs of both the
client-memory candidate and its stock-VBO control lost whole samples in the
delivered PipeWire capture despite unchanged in-emulator underrun/overrun
counters. The candidate therefore has not passed the live audio/resize gate.
The artifacts are
`/dev/shm/mpc-ogl-vbo-fullstack-steady-abba-7ebX0M`,
`/dev/shm/mpc-ogl-vbo-fullstack-boot-abba-lZgbvf`,
`/dev/shm/mpc-ogl-vbo-fullstack-visual-ZB7ZzD`, and
`/dev/shm/mpc-ogl-vbo-fullstack-pcm-lV0l4T`; the live candidate and control are
`results/diagnostics/live-timing-nSyTv6` and
`results/diagnostics/live-timing-izb7YV`.

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
  MPC_ARTWORK_RESOLUTION=1280x720 MPC_GL_VBO=0 \
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
