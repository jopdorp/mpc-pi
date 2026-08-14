# MAME patch stack and launch modes

This is the source-of-truth index for the ordered MAME patch stack. The order
below is the order used by `scripts/build-mame.sh`; later patches may rely on
earlier ones.

There are two different kinds of defaults:

- **raw MAME defaults** preserve the compatibility path when an experimental
  environment switch is absent;
- **`scripts/run-mpc.sh` defaults** select the project's normal MPC2000XL
  desktop configuration explicitly.

Do not infer one from the other. Use the launcher settings below so stale shell
environment never silently selects a path.

## Status vocabulary

- **Correctness**: unconditional fix; no alternate behavior is supported.
- **Exact fast path**: externally equivalent optimization with the original
  implementation retained where needed.
- **Timing-preserving**: preserves protocol/state and remains inside its
  measured timing envelope, but can move event phase.
- **Latency-changing**: intentionally bypasses emulated transport or scanning.
- **Presentation isolation**: intentionally drops/coalesces visual frames when
  the renderer cannot keep up, without dropping emulated audio work.
- **Host topology**: changes which emulated outputs are exposed to the host;
  this can intentionally make output-specific voices inaudible.
- **Experimental**: optional fork path; accurate/stock behavior remains the
  supported fallback.

## Ordered patch inventory

| Patch | Purpose | Class | Activation and fallback | Current evidence/status |
|---|---|---|---|---|
| `0001` | Guard HD61830 startup before text pitch is configured | Correctness | Always active | Focused MPC boots/validation |
| `0002` | Add MPC60 Vimana 3.15 BIOS metadata | Content | Select `MAME_BIOS=vimana315` or raw `-bios vimana315`; normal MPC60 BIOS remains launcher default | Included, not the primary validated MPC60 BIOS |
| `0003` | Reset Akai DSP voice/envelope/filter state on key-on | Correctness | Always active | Present in all frozen PCM references; no dedicated isolated A/B |
| `0004` | Add PipeWire audio-clock pacing and low-latency diagnostics | Infrastructure | `MAME_TIMING_MASTER=audio`; raw diagnostics: `MAME_PIPEWIRE_STATS`, `MAME_PIPEWIRE_CAPTURE_WAV` | Final pacing behavior is completed by `0009`-`0011` |
| `0005` | Suppress the emulation warning when `-skip_gameinfo` is explicit | Correctness/UX | Always active when the option is used | Launcher/listen automation |
| `0006` | Asynchronous SDL/OpenGL presentation | Presentation isolation | `MPC_ASYNC_PRESENT=1`; raw `MAME_ASYNC_PRESENT`; diagnostics: `MAME_VIDEO_STATS`; launcher default `1` | Intentionally drops visual frames while busy; ownership/lifecycle corrected by `0013` and `0029` |
| `0007` | Use a periodic timer for 50% duty clocks | Exact fast path | Always active | Exact edge behavior; measured scheduler reduction |
| `0008` | Isolate Linux SDL event pumping from emulation | Host isolation | `MPC_SDL_EXTERNAL_EVENT_LOOP=1`; raw `MAME_SDL_EXTERNAL_EVENT_LOOP`; launcher default `1` | Linux-only live interaction path; shutdown fixed by `0013` |
| `0009` | Pace from the primary speaker only | PipeWire pacing infrastructure | Active with `MAME_TIMING_MASTER=audio` | Auxiliary callbacks no longer hold the emulation clock |
| `0010` | Reduce host sound updates to 16 samples | Latency-changing infrastructure | Always active in this build | Producer cadence is 3 kHz at 48 kHz |
| `0011` | Keep one producer update beyond the PipeWire quantum | Latency infrastructure | Always active in the patched PipeWire callback; audio-clock selection independently controls pacing | 32-frame quantum + 16-sample producer block = 48 frames / 1.000 ms |
| `0012` | Replace MB89371 clock devices with direct periodic BRG timers | Exact fast path | Always active | Byte-identical PCM; measured CPU reduction |
| `0013` | Synchronize async renderer/event-loop shutdown | Correctness | Always active | Removes teardown lifecycle race |
| `0014` | Batch complete MB89371 BRG cycles | Exact fast path | Always active | UART timing regressions |
| `0015` | Complete i8251 clock cycles in one call | Exact fast path | Always active | UART timing regressions |
| `0016` | Skip stable idle-high i8251 receive shifts | Exact fast path | Always active | Idle RX regression |
| `0017` | Skip stable idle i8251 transmit callbacks | Exact fast path | Always active | Idle TX regression |
| `0018` | Cache exact scheduler cycle divisors | Exact fast path | Always active | Scheduler timing regression |
| `0019` | Event-driven MPC2000XL panel UART | Timing-preserving | `MPC_PANEL_MODE=event|accurate`; raw `MAME_MPC_PANEL_EVENT_DRIVEN`; launcher default `event` | Protocol/state preserved; event mode may shift RX phase by up to 0.5 us and is not the canonical PCM control |
| `0020` | Fast external MIDI and direct internal-pad injection | Latency-changing | `MPC_MIDI_INPUT_MODE=accurate|fast|internal-pads`; default `accurate` | Direct pads bypass MIDI serialization and panel scan/debounce intentionally |
| `0021` | Event-driven MB89371 MIDI baud clocks | Timing-preserving | `MPC_MIDI_CLOCK_MODE=event|accurate`; raw `MAME_MPC_MIDI_EVENT_DRIVEN`; launcher default `event` | Key-on order/grouping retained; canonical PCM uses `accurate` |
| `0022` | Coalesce an unconnected uPD7810 timer output | Exact fast path | `MPC_PANEL_TIMER_MODE=coalesced|accurate`; raw `MAME_MPC_PANEL_TIMER_COALESCED`; default `accurate` | Exact 14,320-edge panel trace; measured CPU reduction |
| `0023` | ROM-gated V53 BRK 88 status-service HLE | Experimental exact fast path | `MPC_V53_STATUS_MODE=hle|accurate`; raw `MAME_MPC_V53_BRK88_HLE`; default `accurate`; only MPC2000XL OS v1.20 SHA-1 `382be688972fe3d85caeca99abff4b6c391347fb` plus the validated RAM handler can activate | Exact PCM, key-on ticks, forced branches and unsupported-ROM fallback |
| `0024` | ROM-gated V53 BRK FD event-service HLE | Experimental exact fast path | `MPC_V53_EVENT_SERVICE_MODE=hle|accurate`; raw `MAME_MPC_V53_BRKFD_HLE`; default `accurate`; same OS v1.20 and RAM-handler gate | Exact common/rare branches and repeated frozen PCM; current LCD matrix measured 3.49% less task CPU, 2.46% fewer cycles and 2.06% fewer instructions |
| `0025` | Replace generic NEC opcode callback with concrete cache access | Exact fast path | Always active | MPC2000XL PCM plus synthetic V20/V30 fixtures passed; MPC3000 final CPU/NVRAM matched, but volatile RAM/frame-boundary differences mean broad exact equivalence is not yet established |
| `0026` | Direct-dispatch eight hot MPC2000XL V53 opcodes | Experimental exact fast path | `MPC_V53_DISPATCH_MODE=direct|accurate`; raw `MAME_MPC_V53_DIRECT_DISPATCH`; default `accurate` | Exact PCM; x86 cycle gain measured, native Cortex-A53 result still required |
| `0027` | Skip unused primitive generation for `-video none` | Exact headless fast path | `MPC_VIDEO_MODE=none` | Headless/LCD-less measurement only; contributes nothing to a visible full-panel build |
| `0028` | Cache configured sound-device interface enumeration | Exact fast path | Always active | Exact PCM and live Lua hook toggling; fork-stack benefit is amplified by the 3 kHz update cadence |
| `0029` | Generate machine-visible primitives on the emulation thread | Correctness | Always active | Fixes the async full-layout scheduler race while retaining asynchronous GL draw/present |
| `0030` | Fixed internal artwork raster resolution | Experimental visual fast path | `MPC_ARTWORK_RESOLUTION=WIDTHxHEIGHT|auto`; launcher and raw MAME default `auto` | Opt-in `1280x720` is canonical-size pixel-exact and cut resize primitive tail from 115.7 ms to 2.43 ms; strict live resize/xrun gate remains open |
| `0031` | Expose only the floppy and main stereo outputs to a stereo host | Host topology | `MPC_OUTPUT_MODE=all|stereo`; raw `MAME_MPC_STEREO_ONLY`; launcher and raw MAME default `all` | Optional for a stereo DAC or headphones. Full and stereo captures retained identical floppy/main L/R samples; stereo mode intentionally hides voices assigned exclusively to the eight assignable outputs |
| `0032` | ROM-gated V53 32-bit divide firmware superblock | Experimental exact fast path | `MPC_V53_DIVIDE_MODE=superblock|accurate`; raw `MAME_MPC_V53_DIVIDE_SUPERBLOCK`; default `accurate`; MPC2000XL OS v1.20 only | Frozen PCM exact; matched ABBA measured 1.88% less task CPU and 2.33% fewer cycles, retained as a cumulative small win |
| `0033` | Suppress unchanged MPC2000XL LCD texture commits | Exact visual fast path | `MPC_LCD_UPDATE_MODE=changed|accurate`; raw `MAME_MPC_LCD_SKIP_UNCHANGED`; normal launcher and raw MAME default `accurate`; fastest preset `changed` | Full LCD pixels are still copied on every screen callback; only unchanged commits are suppressed. Frozen PCM and five raw/PNG checkpoints were exact; an official-binary live 44.1 kHz/q32 ABBA measured 3.27% less task CPU, 3.82% fewer cycles, 1.69% fewer instructions, and 1.90% fewer branches |
| `0034` | Derive the host sound-update cadence from frames and rate | Timing-preserving | `MPC_SOUND_UPDATES_PER_QUANTUM=<k>`; raw `MAME_SOUND_UPDATE_FRAMES` plus `MAME_SOUND_UPDATE_RATE` (both required); normal launcher and raw MAME default is the fixed 3 kHz cadence; fastest preset `2` | Inverts the cadence dependency so one update carries `quantum / k` frames instead of `rate / 3000`. At 44.1 kHz/q32 with `k=2` this gives exactly 16-frame updates, a 32/16 = 2 callback-to-update ratio, and an exact 48-frame margin instead of 47 with 14/15 alternation. The launcher rejects a `k` that does not divide the quantum. Mechanism is exact: at 48 kHz `16/48000` reproduces the frozen PCM `a65077eb...` bit-for-bit, and with the option unset the ordered binary still renders `a65077eb...`. The 44.1 kHz cadence of 2756.25 Hz moves stream chunk boundaries and therefore changes emulated PCM, so it is timing-preserving, not an exact fast path. Measured 8.0% fewer sound-manager updates. On the deployment CPUs both arms already record zero playback underruns and throughput is unchanged within run-to-run spread; on a marginal deadline (CPUs `20-21` at RR1) a matched ABBA measured playback underruns of 4/4/4/4 against 1/2/2/3, a halving with complete separation, plus about 1.8% higher speed |
| `0035` | Direct-pointer V33 opcode fetch window | Exact fast path (opt-in) | `MPC_V53_FETCH_MODE=window|accurate`; raw `MAME_MPC_V53_FETCH_WINDOW`; launcher and raw MAME default `accurate`; fastest preset `window` | Inlines the V33 translation and caches a host pointer to the containing 16 KiB translation page, so a fetch inside the window is a bounds check plus an array load. Keyed on the translated physical address, so a translation-table write moves the next fetch out of the window and refills it. The page is adopted only when `read_ptr()` resolves both ends to one contiguous RAM/ROM block. Opt-in because it assumes a static program map: the MPC2000XL V53 map is entirely `.ram()`/`.rom()` in blocks of at least 512 KiB with no `membank`/`bankdev`, and 16 KiB pages divide those blocks evenly. Frozen 48 kHz all-output PCM is bit-identical off and on (`a65077eb...`). An interleaved ABBA of eight runs per arm on an idle host measured 727.2% against 803.4% average speed, a 10.49% gain with all eight adjacent pairs positive (a noisier earlier run under competing load measured 482.3% against 531.6%, +10.2%); profiling showed `handler_entry_read_memory<1,0>::read` fall from 8.27% to 2.19% and out-of-line `v33_translate` from 8.09% to 2.79% |
| `0036` | Direct-pointer V33 data access window | Exact fast path (opt-in, A53 candidate) | `MPC_V53_DATA_MODE=window|accurate`; raw `MAME_MPC_V53_DATA_WINDOW`; default `accurate` everywhere, including the fast preset | Replaces the two-indirect-call address-space dispatch on V33 data reads/writes with a 64-entry direct-mapped table of translated 16 KiB host page pointers, split read/write so ROM never bypasses the handler path, with negative caching and page-crossing fallback. Frozen PCM bit-identical off and on (`a65077eb...`). Desktop x86 wall clock is null (+0.10% over sixteen interleaved runs) but retired instructions fall 2.59% and branch misses 2.32%, deterministic across repeats; retained default-off as a Cortex-A53 candidate where removed dispatch work is not hidden by out-of-order execution |
| `0037` | Exact V33 idle-iteration recorder and skip | Exact fast path (opt-in) | `MPC_V53_IDLE_MODE=skip|accurate`; raw `MAME_MPC_V53_IDLE_SKIP`; launcher and raw MAME default `accurate`; fastest preset `skip`. Diagnostic: `MAME_MPC_V53_PC_HISTOGRAM=<path>` dumps a per-instruction guest-PC histogram | Records one iteration per registered loop head - the OS v1.20 main scheduler loop (RAM linear `0x0077f`) and the tick-counter wait loop (`0x01691`): live-in reads, first-write old values, cycle cost. Skippable only as a verified pure fixed point: registers/flags/prefetch/mode identical at the next loop head, every written address back at its pre-iteration value (first-write dedup handles the shared stack slot re-pushed by each call), no I/O, no external interrupt. While armed and interrupt-free, whole iterations are charged without executing; the sub-iteration remainder always executes, so timeslice boundaries and interrupts land mid-loop exactly as unskipped. Read-set verification runs once per timeslice, which is exact because no other device runs within a slice; any change re-records. Frozen PCM bit-identical with 440,668 iterations skipped; live 44.1 kHz/q32 fast preset recorded zero underruns in boot and playback with 444,477 skips; matched ABBA measured 819.6% against 1036.3%, +26.4% with complete separation; adding the second head raised the mean to 1062%; the third revision adds induction-variable and dead-store classification, letting the third head skip the calibrated 164-cycle feed-wait loop: 4.09M skipped iterations bit-exact, zero live underruns, ABBA 858.3% against 1165.6% in its window |
| `0038` | Direct-pointer L7A1045 wave-RAM window | Exact fast path (opt-in, A53 candidate) | `MPC_DSP_READ_MODE=window|accurate`; raw `MAME_MPC_DSP_WINDOW`; default `accurate` everywhere | Replaces the per-sample handler dispatch in the DSP mix loop with a cached host pointer to the 64 KiB wave-RAM page, both-ends contiguity checked; flash pages do not resolve and keep the handler path. Frozen PCM bit-identical off and on; desktop wall clock inside noise (median +0.9%); retained as a Cortex-A53 candidate |

The repaired V53 hotblock experiment is preserved outside the ordered stack at
`patches/experiments/mpc2000xl-v53-hotblocks-repaired.patch`. It is pixel/PCM
exact after repairing its unbraced shift macro, but the larger cumulative LCD
matrix measured 1.31% more cycles in isolation and 2.48% more cycles when
combined with the divide patch. It is not a shipped patch or launcher mode.

`MPC_GL_VBO=0` is not another patch. It selects an existing OpenGL
client-memory coordinate path exposed by the launcher. It reduced renderer CPU
work on this host, but both its candidate and control failed the strict live
32-frame sample-timeline gate. The supported default remains `MPC_GL_VBO=1`.

## Launcher settings

These are the public settings to use. Raw MAME environment names are included
for diagnosis only.

`MAME_PIPEWIRE_AUDIO_CLOCK`, `MAME_MPC_MIDI_FAST_INPUT`, and
`MAME_MPC_MIDI_INTERNAL_PADS` are enabled by **presence**, so assigning `0`
does not disable them. The launcher unsets them for fallback modes.

| Public launcher setting | Values | MPC2000XL launcher default | Accurate/stock fallback | Raw switch |
|---|---|---|---|---|
| second argument | positive frame count | `32` | N/A | `PIPEWIRE_QUANTUM`, `PIPEWIRE_LATENCY` |
| `MAME_TIMING_MASTER` | `audio`, `video` | `audio` | `video` | `MAME_PIPEWIRE_AUDIO_CLOCK` |
| `MPC_ASYNC_PRESENT` | `0`, `1` | `1` | `0` | `MAME_ASYNC_PRESENT` |
| `MPC_SDL_EXTERNAL_EVENT_LOOP` | `0`, `1` | `1` | `0` | `MAME_SDL_EXTERNAL_EVENT_LOOP` |
| `MPC_ARTWORK_RESOLUTION` | `auto`, `WIDTHxHEIGHT` | `auto` | `auto` | MAME option `-artwork_resolution` |
| `MPC_GL_VBO` | `0`, `1` | `1` | `1` | MAME option `-gl_vbo`/`-nogl_vbo` |
| `MPC_OUTPUT_MODE` | `all`, `stereo` | `all` | `all` | `MAME_MPC_STEREO_ONLY` |
| `MPC_LCD_UPDATE_MODE` | `accurate`, `changed` | `accurate` | `accurate` | `MAME_MPC_LCD_SKIP_UNCHANGED` |
| `MPC_V53_FETCH_MODE` | `accurate`, `window` | `accurate`; fast wrapper: `window` | `accurate` | `MAME_MPC_V53_FETCH_WINDOW` |
| `MPC_V53_DATA_MODE` | `accurate`, `window` | `accurate` | `accurate` | `MAME_MPC_V53_DATA_WINDOW` |
| `MPC_V53_IDLE_MODE` | `accurate`, `skip` | `accurate`; fast wrapper: `skip` | `accurate` | `MAME_MPC_V53_IDLE_SKIP` |
| `MPC_DSP_READ_MODE` | `accurate`, `window` | `accurate` | `accurate` | `MAME_MPC_DSP_WINDOW` |
| `MPC_SOUND_UPDATES_PER_QUANTUM` | unset, or a positive integer dividing the quantum | unset (fixed 3 kHz); fast wrapper: `2` | unset | `MAME_SOUND_UPDATE_FRAMES` + `MAME_SOUND_UPDATE_RATE` |
| `MPC_FORCE_PIPEWIRE_GRAPH` | `0`, `1` | fast wrapper: `1` | N/A | Temporarily force/verify the requested PipeWire rate and quantum, then restore them on exit |
| `MPC_PANEL_MODE` | `accurate`, `event` | `event` | `accurate` | `MAME_MPC_PANEL_EVENT_DRIVEN` |
| `MPC_PANEL_TIMER_MODE` | `accurate`, `coalesced` | `accurate` | `accurate` | `MAME_MPC_PANEL_TIMER_COALESCED` |
| `MPC_MIDI_INPUT_MODE` | `accurate`, `fast`, `internal-pads` | `accurate` | `accurate` | `MAME_MPC_MIDI_FAST_INPUT`, `MAME_MPC_MIDI_INTERNAL_PADS` |
| `MPC_MIDI_CLOCK_MODE` | `accurate`, `event` | `event` | `accurate` | `MAME_MPC_MIDI_EVENT_DRIVEN` |
| `MPC_V53_STATUS_MODE` | `accurate`, `hle` | `accurate` | `accurate` | `MAME_MPC_V53_BRK88_HLE` |
| `MPC_V53_EVENT_SERVICE_MODE` | `accurate`, `hle` | `accurate` | `accurate` | `MAME_MPC_V53_BRKFD_HLE` |
| `MPC_V53_DISPATCH_MODE` | `accurate`, `direct` | `accurate` | `accurate` | `MAME_MPC_V53_DIRECT_DISPATCH` |
| `MPC_V53_DIVIDE_MODE` | `accurate`, `superblock` | `accurate` | `accurate` | `MAME_MPC_V53_DIVIDE_SUPERBLOCK` |
| `MPC_VIDEO_MODE` | MAME renderer name | `opengl` | N/A | MAME option `-video` |

## Launch-mode examples

Start these from a clean shell environment; the launcher explicitly sets or
unsets raw compatibility flags, but unrelated public `MPC_*` options can still
alter renderer, scheduling or media behavior. Both HLE examples require
`MAME_BIOS=default` (MPC2000XL OS v1.20) to activate.

### Accurate emulation control

This retains the low-latency host audio and renderer infrastructure while
disabling all optional MPC firmware/device speed paths:

```bash
MPC_PANEL_MODE=accurate \
MPC_PANEL_TIMER_MODE=accurate \
MPC_MIDI_INPUT_MODE=accurate \
MPC_MIDI_CLOCK_MODE=accurate \
MPC_V53_STATUS_MODE=accurate \
MPC_V53_EVENT_SERVICE_MODE=accurate \
MPC_V53_DISPATCH_MODE=accurate \
MPC_V53_DIVIDE_MODE=accurate \
MPC_LCD_UPDATE_MODE=accurate \
MAME_BIOS=default \
scripts/run-mpc.sh mpc2000xl 32
```

### Measured-win timing-preserving preset

This includes only options with a demonstrated material CPU reduction. Panel
and MIDI clocks remain device-timed, but their documented event phase means
this is not the canonical byte-for-byte PCM control:

```bash
MPC_PANEL_MODE=event \
MPC_PANEL_TIMER_MODE=coalesced \
MPC_MIDI_INPUT_MODE=accurate \
MPC_MIDI_CLOCK_MODE=event \
MPC_V53_STATUS_MODE=hle \
MPC_V53_EVENT_SERVICE_MODE=hle \
MPC_V53_DISPATCH_MODE=direct \
MPC_V53_DIVIDE_MODE=superblock \
MPC_LCD_UPDATE_MODE=changed \
MAME_BIOS=default \
scripts/run-mpc.sh mpc2000xl 32
```

The divide, BRK FD and unchanged-LCD paths are retained as cumulative small
wins. Add `MPC_OUTPUT_MODE=stereo` for a two-channel DAC; keep `all` for
projects using assignable outputs. A current-stack fixed-work ABBA of divide +
BRK FD + stereo measured 6.36% less task CPU, 6.19% fewer cycles and 4.73%
fewer instructions on the official through-0032 build-script binary. Patch
0033 was then measured independently on the live LCD-only 44.1 kHz/q32 path;
do not multiply the results into a claimed end-to-end total without a new
combined measurement.
Native Cortex-A53 qualification is still required before making these paths a
device default.

### Lowest input latency

Use the measured-win example above and change its MIDI line to:

```bash
MPC_MIDI_INPUT_MODE=internal-pads
```

This is intentionally not accuracy-preserving: it skips the external MIDI
wire and the panel CPU's scan/debounce path.

### Headless profiling

```bash
MPC_VIDEO_MODE=none scripts/run-mpc.sh mpc2000xl 32 -sound none
```

Do not use the headless gain to predict a Pi configuration that renders the
full MPC panel.

### Host output topology

Leave `MPC_OUTPUT_MODE=all` for a multichannel audio interface or whenever a
project uses the MPC's eight assignable outputs. Select the smaller host
topology for a two-channel DAC or headphones with:

```bash
MPC_OUTPUT_MODE=stereo scripts/run-mpc.sh mpc2000xl 32
```

Stereo mode still exposes the floppy and main left/right channels, but it does
not fold the eight assignable outputs into the main mix. A voice routed
exclusively to an assignable output is therefore inaudible. The launcher uses
a separate `cfg-stereo` directory so a stereo run cannot overwrite the saved
channel mapping for the default all-output mode.

This option is retained both for a common physical stereo-DAC topology and as
an independently removable cumulative small win. A fresh matched ABBA measured
about 1.39% less task clock, 1.72% fewer cycles, 1.93% fewer instructions and
1.62% higher reported speed. The focused topology/PCM/cfg test is
`scripts/diagnostics/test-mpc2000xl-stereo-output.sh`; artifacts are
`results/diagnostics/stereo-output-pyexS7` and
`results/diagnostics/current-stack-stereo-perf-VntjgN`.

## Validation boundaries

- Canonical PCM currently means the preserved 11-channel Logic fixture, not a
  claim that every project and every physical output is bit-perfect.
- Offline `-sound none` performance tests still execute internal sound
  processing, but they do not prove PipeWire latency or xrun behavior.
- Patch 0033's official-binary live ABBA kept every sampled marker-window
  PipeWire node at `ERR=0`. The monitor began at the marker, so the pre-marker
  startup interval remains outside this proof. It is accepted for exact output
  and CPU reduction, not yet as a complete xrun-free launch proof.
- Performance and xrun results are only meaningful against the CPU set,
  nice level and `SCHED_RR` priority that will actually be deployed. This host
  is a hybrid Core Ultra 7 155H: CPUs `0-11` are 4.5 GHz P-cores, `12-19` are
  3.8 GHz E-cores and `20-21` are 2.5 GHz low-power E-cores. Several earlier
  harnesses pinned to `20-21` at nice `0` and RR `1`, which is a valid quiet
  environment for a *relative* A/B but is not the deployment configuration and
  must not be used for absolute speed or for xrun acceptance. The launcher
  defaults are CPUs `0-11`, nice `-10`, RR `20`.
- The delivered-audio comparator
  (`scripts/diagnostics/compare-live-audio-timing.py`) is not a valid
  acceptance gate for the `live-logic-mpc2000xl.lua` fixture. That fixture
  boots at `speed_factor = 4000`, where realtime pacing is disabled and the
  overrun path discards audio; the faster the host, the more it discards and
  the worse the comparator scores, independent of playback quality. Use
  in-window PipeWire underrun counts split at the
  `realtime audio-clock pacing started` marker instead. See
  [`mpc2000xl-low-latency.md`](mpc2000xl-low-latency.md).
- A 32-frame graph quantum at 48 kHz is 0.667 ms. The intentional internal
  producer margin is one quantum plus one 16-sample update: 48 frames, exactly
  1.000 ms. This is not total pad-to-analog latency.
- The fast preset uses 44.1 kHz. At the fixed 3 kHz producer cadence, updates
  contain 14 or 15 frames, so q32 plus the largest update is 47
  frames, about 1.066 ms. Neither patch 0033 nor the fast preset increases the
  quantum or changes the producer cadence.
- `run-mpc2000xl-fast.sh` temporarily forces the global PipeWire graph to the
  requested rate and quantum, verifies both metadata values, and restores the
  previous values on normal exit or a signal. An exclusive per-user lock
  rejects a concurrent graph-forcing launch. `MPC_PIPEWIRE_FRAMES` and
  `PIPEWIRE_RATE_HZ` replace inherited client quantum/latency requests so the
  client exactly matches the forced graph. This is what makes its 44.1 kHz
  claim native even on a host whose normal graph is 48 kHz. Set
  `MPC_FORCE_PIPEWIRE_GRAPH=0` only if host policy configures the graph itself.
- Native Cortex-A53 performance and a live 32-frame PipeWire/MIDI/resize run
  remain required before declaring Raspberry Pi 3B+ support.

Detailed measurements and artifact paths remain in
[`mpc2000xl-low-latency.md`](mpc2000xl-low-latency.md) and
[`mpc2000xl-performance-optimization-plan.md`](mpc2000xl-performance-optimization-plan.md).

## Upstream disposition

- Small generic candidates: `0001`, `0007`, `0012`, `0014`-`0018`, `0022`,
  `0025`, `0027`, and `0028`, each only after the cross-driver/full-build gates
  listed in the detailed docs.
- SDL/PipeWire series: `0004`, `0006`, `0008`-`0011`, `0013`, and `0029` need
  decomposition and broad host/backend review.
- MPC driver/timing series: `0019`-`0021` must be split at reusable device
  seams before upstream review.
- Firmware HLE/direct dispatch: `0023`, `0024`, and `0026` remain fork-only
  experiments.
- `0030` is a generic render option, but its cross-layout/backend and strict
  live acceptance gates remain open.
- `0031` remains a fork-only host-topology option; it intentionally removes
  assignable-output endpoints and is not an accuracy-preserving optimization.
- `0032` is a ROM-specific V53 firmware fast path and remains a fork-only
  experiment until its firmware-address seam is acceptable upstream.
- `0033` is MPC2000XL-specific until broader LCD-device and renderer coverage
  justifies a reusable core seam.
