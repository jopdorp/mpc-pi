# MPC2000XL remaining performance analysis and optimization plan

## Scope and current baseline

This plan is current after the independently flagged V53 BRK88 status-service
HLE and bounded BRK FD event-service HLE were validated on top of commit
`7ca0bcd`, which coalesces the unconnected uPD78C10 panel timer output. These
cuts preserve guest time and leave the
validated low-latency audio configuration unchanged:

- 32-frame PipeWire quantum;
- 16-sample MAME sound-update cadence;
- event-driven panel UART and MIDI baud clocks;
- coalesced panel timer output where explicitly selected; and
- the full-panel renderer with asynchronous OpenGL drawing and presentation.

The former scheduler hotspot is already gone. After the event-driven UART and
MIDI-clock work, `device_scheduler::timeslice()` was 1.24% and the combined
named scheduler cost was about 2.19% of the much smaller workload. Reworking
the scheduler again is not a current optimization target.

The latest accepted cut is the panel timer coalescing in `7ca0bcd`. A
five-pair alternating-order A/B of the loaded Logic workload measured these
median reductions:

| Metric | Accurate timer | Coalesced timer | Change |
| --- | ---: | ---: | ---: |
| Task clock | 34,393.46 ms | 30,647.48 ms | -10.89% |
| CPU cycles | 77.80 billion | 69.21 billion | -11.04% |
| Instructions | 194.28 billion | 160.29 billion | -17.50% |
| Branches | 33.43 billion | 27.92 billion | -16.50% |

The complete boot/load/play panel TXD trace and the rendered PCM remained
byte-identical. The evidence is in
`results/diagnostics/panel-timer-coalesced-perf-WHD9uw` and
`results/diagnostics/panel-timer-coalesced-txd-0vMqPy`.

## Current findings and priorities

| Area | Current conclusion | Action |
| --- | --- | --- |
| Scheduler | The MHz-scale scheduler hotspot has been removed by the event-driven clock work | Do not spend more time here without new profile evidence |
| Panel fixed-clock timer | Large, exact win: -10.89% task clock and -17.50% retired instructions | Accepted in `7ca0bcd`; retain accurate fallback |
| Panel ROM routine at `03d5` | Exact decoder shortcut saved only about 0.08% instructions and no task clock | Reject; do not carry its 186-line maintenance cost |
| V53 BRK88 service | Exact ROM-gated HLE reduced task clock 4.04% and instructions 5.43% | Accepted behind its own default-off flag |
| V53 BRK FD service | Exact ROM-gated HLE reduced instructions 1.35%; two pairs did not prove a task-clock gain | Retain only as a separate default-off option; do not claim throughput yet |
| General V53 fetch/data path | Still a large raw cost but requires MAME-core changes | Re-profile before selecting a shared-core experiment |
| Rendering | Must still be measured separately for full-panel and LCD-only deployment shapes | Optimize only from a dedicated render profile |

The V53 remains the largest broad CPU consumer. The post-MIDI-clock profile
attributed about 39.96% directly to named V53/V33 symbols, with generic memory
handlers adding more work on its behalf. That profile remains useful for
attribution, but absolute percentages before `7ca0bcd` must not be presented as
shares of the current post-coalescing workload.

## Accepted panel optimization and rejected decoder prototype

The panel firmware selects a fixed-clock uPD78C10 timer mode that toggles TO
once per 4 MHz machine cycle. On the MPC2000XL that output is unconnected and
is not selected on Port C, but the generic core still performed per-transition
work. Commit `7ca0bcd` coalesces only those externally unobservable
transitions, advances serial state by the same count, and preserves the exact
final phase. It dynamically falls back when TO or the relevant serial state can
be observed.

After that cut, the panel PC histogram showed a common no-input routine at
`03d5`. Its 11 guest instructions account for 6,922,696 of 24,934,639 panel
instruction dispatches, or 27.764%. A boundary-preserving prototype bypassed
their generic decoder while retaining every original timer, instruction-count,
IRQ and delayed-IFF boundary. This was the safest exact form of the idea: it
did not skip guest cycles and could resume stock execution at any interior PC.

The measured return was too small. Two matched short A/B pairs in
`results/diagnostics/panel-scan-fast-perf-1TsKEL` both showed only about 0.08%
fewer retired instructions and no task-clock improvement. The hot routine's
cost after timer coalescing is therefore in the timer/IRQ/semantic work that an
exact decoder shortcut must retain, not primarily in opcode decoding. A
186-line ROM-specific implementation is not justified by that result and is
rejected rather than accumulated as permanent speed-hack debt.

A complete panel protocol HLE remains a possible future optional mode, but it
would be a different project with a much larger validation surface. It is not
the immediate next step.

## Accepted V53 BRK88 status-service HLE

The MPC's 32 MHz V53A interprets the operating system instruction by
instruction. Broad interpreter work is spread across opcode fetch, V33 address
translation, effective-address helpers, flags, cycle accounting, interrupts,
and mapped memory/I/O. Optimizing those shared paths may eventually help, but
small MAME-core changes are difficult to upstream and must show broad impact.

BRK88 proved to be a bounded software status query rather than an audio ISR or
idle loop. It runs about 39,900 times per second. The accepted implementation
starts only after normal BRK entry, reproduces its register, stack, flag,
prefetch and memory-read effects, and charges branch-dependent totals derived
from the actual V33 interpreter including prefetch stalls. It is gated to OS
v1.20 and a validated 49-byte RAM handler; every unproved state falls back.

The HLE and event-mode control produced byte-identical PCM and the same 86 DSP
key-ons at identical 48 MHz ticks. A three-pair pinned A/B measured -4.04% task
clock, -4.70% cycles, -5.43% instructions and -5.29% branches. This is below
the original 5-8% task-clock estimate but remains a material whole-emulator
gain with an exact timing result.

## Secondary V53 opportunities

### Bounded BRK FD event service

The post-BRK88 profile identified BRK FD as the smallest remaining
firmware-specific seam. It runs about 19,656 times per second and contains a
bounded 20-byte handler. The optional HLE preserves normal interrupt entry,
the handler's stack and atomic memory effects, comparison semantics, prefetch
state, and its 51/54-cycle branch totals. The common workload render remains
byte-identical to the frozen event-mode reference.

The otherwise unobserved value-at-least-100 branch was forced independently.
Across 907 completed calls per mode, interpreted and HLE execution both took
81 total cycles / 81 ticks at 32 MHz and returned identical complete CPU,
event-byte and prefetch state.

Two short pinned pairs measured -1.35% retired instructions and -1.27%
branches, but +0.78% task clock and +0.68% cycles in noisy host conditions.
This establishes a deterministic retired-work reduction, not a host-time
speedup. Keep the implementation independent and default-off, and revisit its
deployment value with Cortex-A53 measurements rather than overstating the
desktop result.

### Firmware-specific exact blocks

After BRK88 and BRK FD, use the guest-PC/basic-block histogram to rank any other dominant
services or polling loops. Each candidate must be evaluated independently.
Fast-forwarding is allowed only when the exact next causal event is known;
otherwise the interpreter must run normally.

The next bounded candidate, the hot `3f76` far-callback wrapper, was prototyped
and rejected. A split implementation preserved the stock scheduler boundary,
matched the frozen event/HLE PCM byte-for-byte, and handled 99.51% of wrapper
entries. One non-instrumented pair measured -0.09% cycles, +0.05% retired
instructions, and a noisy -0.92% task clock. That return does not justify its
271-line prototype diff, so it is not part of the patch
stack.

### Opcode and data-access machinery

The concrete opcode-cache accessor is now patch 0025. On the loaded Logic
workload it reduced task clock by 4.48%, cycles by 4.43%, and retired
instructions by 3.59%, with exact reference PCM and focused V20/V30/V33
coverage.

Patch 0026 adds an independent MPC2000XL-only direct-dispatch experiment. A
playback histogram found that eight V53 opcodes represent 44.09% of dispatches.
Calling the existing canonical instruction methods directly for those opcodes
reduced host cycles by 6.14% and task clock by 4.24% relative to its accurate
mode while preserving the frozen PCM byte-for-byte. The accurate CPU loop is a
separate compile-time specialization, so the flag decision is outside the hot
instruction loop. The selected opcode set remains subject to native
Cortex-A53 validation.

Patch 0027 removes primitive generation from MAME's `none` renderer. The
renderer previously built and scaled the complete layout every frame before
discarding it. Returning no primitive list is the exact no-render contract;
screen/device updates and snapshot targets remain independent, and visible
renderers are unchanged. On the loaded Logic headless workload this reduced
task clock by 7.61%, cycles by 9.51%, retired instructions by 6.50%, and peak
RSS by about 169 MiB. The frozen PCM remained exact, and matched 1600x900
OpenGL captures confirmed that full visual rendering was unaffected. This gain
applies only to `-video none`, not the full-body desktop view or an LCD view
that still uses a visible renderer.

Patch 0028 caches the configured device sound interfaces once in
`sound_manager` instead of rebuilding the same RTTI-based device enumeration
on every sound update. It preserves configuration order and continues to read
each interface's Lua hook flag on every update. On the fork's 3 kHz
low-latency sound cadence, a matched loaded-Logic ABBA of the independently
measured C++-local cache prototype reduced task clock by 6.92%, cycles by
6.01%, and retired instructions by 5.65%; average emulation speed increased
from 321.13% to 346.20%. Patch 0028 moves the same ordered cache into its
owning `sound_manager`, removing the prototype's process-global map lookup.
The final implementation kept the frozen PCM byte-identical and passed
off/on/off Lua hook tests across five interfaces, save/load, and machine
recreation. This is a semantics-preserving topology cache rather than an
alternate emulation mode, so it has no runtime flag. Its benefit is specific
to the high update cadence in this patch stack; at stock MAME's lower cadence
it is unlikely to justify a standalone upstream core change without broader
measurements. Prototype counters are under
`/dev/shm/mpc-nec-lto-gY0QN7/perf-sound-cache-cpu15`; the final regression is
under `results/diagnostics/sound-interface-cache-qsROeR`.

Patch 0029 corrects the asynchronous renderer's ownership boundary. Primitive
generation had been moved to the presenter, where the full layout's raw analog
input read raced the scheduler and intermittently trapped in clock conversion.
The emulation thread now publishes a completed primitive list while OpenGL
drawing and presentation remain asynchronous. This is a correctness repair,
not a performance claim. Three consecutive 30-second loaded-Logic full-layout
runs completed cleanly. The full OpenGL PCM retained the frozen event/HLE hash,
and two independent 1600x900 captures were pixel-identical to the preserved
renderer reference. The live resize/xrun check remains the acceptance gate
before handoff. Its first balanced-policy 32-frame run reported one underrun
per MAME output stream during aggressive resizing, so resize scaling remains a
separate measured optimization target rather than being hidden by moving live
machine reads back to the presenter.

Patch 0030 adds an independently selectable fixed artwork raster. It leaves
the actual target, input geometry, LCD and UI resolution unchanged while using
a canonical 1280x720 transform only for layout-element texture generation.
The core and launcher default to `auto`; the opt-in
`MPC_ARTWORK_RESOLUTION=1280x720` path uses the fixed raster. In a matched
440-request resize storm, the
emulation-thread primitive-generation maximum fell from 115.667 ms to 2.433 ms
after warm-up, about 47.5x. The exact canonical-size fixed/auto image comparison
had zero changed pixels. OpenGL linearly samples fixed artwork; extending the
filter hint to other backends and reducing the separate presenter-side resize
upload/present tail are independent possible changes. The live 32-frame
PipeWire resize run remains open: an automated-resize run had no in-interval
buffer events but failed delivered-audio timeline comparison, while a matched
no-resize control independently underrun after a 6.483 ms producer update.
Patch 0030 is therefore accepted on its deterministic PCM, visual and
resize-compute evidence, not as a completed live xrun result.

The next independent cut uses MAME's existing `-nogl_vbo` option rather than
adding renderer code. The legacy OpenGL path otherwise uploads 32 bytes of
texture coordinates for every textured quad, although its vertex array already
uses client memory. A current-stack, marker-scoped steady-playback full-layout
ABBA test measured 23.20% less task CPU and 23.44% fewer host cycles; an
independent whole-process boot/load/play ABBA measured 19.31% and 18.06%.
The two paths were pixel-identical; the client-memory full-render capture
retained the frozen PCM byte for byte.
`MPC_GL_VBO=0` selects this path, while the launcher retains stock MAME VBOs by
default. MAME makes PBO unavailable when this VBO path is disabled, so the
project does not add another PBO setting. The candidate remains experimental:
strict live 32-frame candidate and stock-VBO control runs both lost whole
samples in the delivered PipeWire capture despite stable emulator buffer
counters, so the required live audio/resize acceptance remains open.

The earlier profile's largest single symbol, at 12.99%, was the V53 opcode-byte
fetch lambda configured by `nec_common_device::device_start()`. Each byte goes
through a `std::function`, V33 address translation, and MAME's cached
address-space lookup:

```text
fetch/fetchop -> m_dr8 -> m_cache16.read_byte(v33_translate(address))
```

This is abstraction and emulated-bus cost, not evidence that host DRAM
bandwidth is exhausted. Possible later experiments are:

1. A concrete, inlinable NEC opcode accessor selected by CPU/bus type.
2. A translation-state fast path that preserves both XA modes exactly.
3. Typed/specific data access where all mapped handlers, mirrors, DMA
   visibility and save-state behavior remain intact.
4. Dispatch-layout changes only if branch-counter evidence justifies them on
   both x86-64 and AArch64.

Keep generic NEC-core experiments on a separate branch and in separate
commits. Require complete NEC CPU coverage and a material cross-driver benefit
before proposing them upstream. An MPC-only gain belongs in the MPC driver,
not disguised as generic core complexity.

## Execution plan

### Phase 1: exact BRK88 service HLE — completed

The reference was frozen once, temporary state/cycle/key-on tracing was removed
after validation, and the production change remains behind a separate
default-off flag. The three clean serialized pairs were sufficient to show a
consistent material effect after contaminated measurements were discarded.

### Phase 2: rank the next measured bottleneck — headless capture completed

A clean post-BRK88-plus-BRKFD playback profile is stored at
`results/diagnostics/post-v53-combined-steady-final-91KVZ1`. It used the
loaded Logic workload, CPU 20, the balanced host policy, no video or host
sound, unthrottled emulation, event-driven panel and MIDI clocks, and both V53
service HLEs. The five-second playback-only capture collected 10,058 samples
with none lost and averaged 334.49% emulation speed.

The remaining steady-state hotspots are:

- opcode-fetch callback: 15.58%;
- V53 `execute_run()`: 14.90%;
- program-memory reads: 4.55%;
- panel timers: 3.20%;
- DSP audio processing: 3.08%; and
- scheduler: 0.95%.

The scheduler is no longer a useful target in this workload. Opcode
fetch/access is the clear next headless target; panel and DSP work follow it.
LCD-only and full-render profiles with host audio still remain
before making an end-to-end Pi deployment claim.

### Phase 3: generic NEC-core work only when justified — in progress

Try fetch, translation and typed-access changes as isolated MAME-core patches.
Each patch must independently demonstrate enough broad impact to justify core
review. Do not combine these with driver HLE, launcher flags, audio changes or
rendering changes.

The first concrete opcode-access candidate removes the type-erased
`std::function` from `fetch()` and `fetchop()` while retaining the same MAME
cache reads and V33 address translation. Two serialized balanced-mode pairs on
the loaded Logic workload, stored at
`/dev/shm/mpc-v53-fetch-QCcHhS/perf`, measured:

| Counter | Baseline median | Concrete accessor median | Change |
|---|---:|---:|---:|
| Task clock | 27,091.10 ms | 25,876.38 ms | -4.48% |
| Host cycles | 38.401 billion | 36.699 billion | -4.43% |
| Retired instructions | 86.388 billion | 83.286 billion | -3.59% |
| Retired branches | 14.620 billion | 15.222 billion | +4.12% |

The candidate produced byte-identical MPC2000XL PCM in both accurate mode
(`22f76ffaaedc4364b8279a79672a07a35f93997f180b8665e9ef3a576ae176a9`)
and the combined event/HLE mode
(`a65077eb074df2671731ea0e3f315f627044b4ece480c75de2871b8fd81b4014`)
against the existing frozen references. Its NEC object was smaller in `.text`.
The increased branch count makes AArch64 measurement important; do not claim
the x86-64 result as a Pi gain until it is measured on Cortex-A53. A
smaller-looking V33-only conditional that retained `std::function` was
rejected because it lost the retired-instruction gain and increased branch
work further.

This is a semantics-preserving core implementation simplification, not an
alternate emulation or timing mode, so there is no runtime speed flag or
accurate fallback: both forms perform the same cache access. It remains an
independent patch and branch so it can be accepted or removed separately.

Cross-driver artifacts are under `/dev/shm/mpc-nec-fetch-cross-YB9Xyz`.
MAME validation passed, and MPC2000XL 1.20, MPC3000 Vailixi 3.50, and MPC60
SCSI 2.14 all booted. Tiny deterministic fixtures covering the V20 8-bit and
V30 16-bit cache branches returned identical registers and test RAM. At an
exact five-second MPC3000 boundary, exposed CPU state, NVRAM, and the final
screen matched, but 12 volatile RAM bytes and the boot capture's silent-frame
count differed. Those differences are consistent with an idle/exit-boundary
phase shift, but this evidence does not justify claiming whole-machine
bit-identical MPC3000 state.

### Cumulative headless result

A direct alternating end-to-end comparison is stored at
`results/diagnostics/cumulative-performance-q828JV`. The control selected
accurate periodic panel and MIDI clocks, the transition-by-transition panel
timer, and interpreted V53 services. The current mode selected event-driven
panel and MIDI clocks, coalesced panel timer output, both service HLEs, and the
concrete opcode accessor. Both used the same short loaded-Logic workload,
video/sound disabled, CPU 20, balanced host policy, and unthrottled video-master
execution.

| Counter | Accurate control mean | Current mean | Change |
|---|---:|---:|---:|
| Task clock | 43,161.66 ms | 15,207.90 ms | -64.77% |
| Host cycles | 99.249 billion | 34.896 billion | -64.84% |
| Retired instructions | 277.772 billion | 84.734 billion | -69.50% |
| Retired branches | 64.481 billion | 15.268 billion | -76.32% |
| Average emulation speed | 104.93–110.56% | 324.86–330.18% | about 3x reported speed |

This is 2.84x throughput from task clock and cycles, or 3.28x less retired
instruction work. It measures this optimization campaign rather than pristine
upstream MAME: shared earlier fork patches are present on both sides. It is
also headless x86-64 evidence, not yet proof that the full-render audio path
fits one Cortex-A53 core.

Applying the independently measured patch-0026, patch-0027, and patch-0028
ratios multiplicatively gives a provisional through-0028 headless estimate of
about 3.45x by task clock and 3.56x by host cycles relative to that same
campaign control. This is not a new end-to-end measurement: the component
benchmarks used different pinned CPUs and may interact. Excluding the
headless-only patch 0027 gives an estimated 3.2x throughput, or roughly 69%
less underlying emulation and sound work, but does not estimate a visible
renderer. A new matched end-to-end run and native Cortex-A53 measurement are
required before using either estimate as Raspberry Pi readiness evidence.

### Pristine-MAME cumulative candidate result

A fresh fixed-work ABBA at
`results/diagnostics/vanilla-vs-0033-headless-20260813` compares pristine MAME
revision `f8c55f4cdad70fa5b7dfae9a26a15114aea70f9a` with the cumulative
candidate including the repaired hotblock experiment. Both sides ran the same
loaded-Logic fixture for 84 emulated seconds on CPU 20 with video, host audio
and throttling disabled. The
optimized side selected event panel/MIDI clocks, coalesced panel timing,
BRK88 HLE, direct top-eight V53 dispatch, stereo host topology, the divide
superblock and all three repaired hotblocks; BRK FD remained accurate.

Here `0033` is the historical optimization-campaign candidate number in the
artifact name. It predates and is unrelated to ordered patch 0033, the
unchanged-LCD-frame path documented below.

| Counter | Pristine mean | Candidate mean | Reduction / ratio |
|---|---:|---:|---:|
| Task clock | 79,296.40 ms | 18,521.20 ms | 76.64% / 4.28x |
| Host cycles | 192.817 billion | 44.920 billion | 76.70% / 4.29x |
| Retired instructions | 601.733 billion | 130.963 billion | 78.24% / 4.59x |
| Retired branches | 139.491 billion | 25.831 billion | 81.48% / 5.40x |
| Average emulation speed | 108.07% | 473.67% | 4.38x |

The two runs on each side were tightly grouped: pristine cycles differed by
0.005% and optimized cycles by 0.41%. This is the first direct pristine-MAME
versus cumulative-stack measurement. It is headless, host-audio-inactive
evidence and includes patch 0027's headless-only primitive skip, so it must not
be presented as an LCD, full-panel, live-PipeWire or Raspberry Pi readiness
result. The larger current-stack matrix subsequently rejected the hotblocks;
the retained divide + stereo + BRK FD combination is measured separately
below.

### Post-accessor candidates

Patch 0031 retains an optional stereo-only host topology for a two-channel DAC
or headphones. The launcher default remains `MPC_OUTPUT_MODE=all` for a
multichannel interface and for projects that use the eight assignable
outputs. `MPC_OUTPUT_MODE=stereo` removes those eight host endpoints without
downmixing them, so voices routed exclusively to an assignable output are
intentionally inaudible. A separate `cfg-stereo` directory protects the saved
all-output channel mapping.

A clean current-stack ABBA measured only 1.39% less task CPU, 1.72% fewer
cycles, 1.93% fewer instructions and 1.62% higher reported speed. The full and
stereo captures preserved the floppy and main L/R channels sample-for-sample.
It is retained for host-topology convenience and as an independently removable
cumulative small win. The focused validation and performance evidence are in
`results/diagnostics/stereo-output-pyexS7` and
`results/diagnostics/current-stack-stereo-perf-VntjgN`.

Patch 0032 retains the independently selectable, ROM-gated V53 32-bit divide
superblock under the revised cumulative-small-wins policy. Its matched ABBA
measured 1.88% less task CPU and 2.33% fewer cycles, and its 11-channel PCM
matched the frozen reference exactly. The launcher keeps it off by default;
`MPC_V53_DIVIDE_MODE=superblock` selects it.

Patch 0033 adds the independently selectable LCD unchanged-frame path.
`MPC_LCD_UPDATE_MODE=changed` still copies the full 248x60 bitmap on every
screen callback, but returns MAME's unchanged-frame status when no LCD RAM byte
changed so the renderer can suppress a redundant texture commit. The normal
launcher and raw MAME default remain `accurate`; the fastest LCD-only preset
selects `changed`.

The frozen PCM was byte-exact. Five raw-pixel and five PNG checkpoints were
exact between modes and across repeats, including the official ordered-stack
binary. Its live Screen 0 ABBA with active PipeWire at native 44.1 kHz/q32
measured 3.27% less task CPU, 3.82% fewer cycles, 1.69% fewer retired
instructions, and 1.90% fewer branches. Both chronological pairs improved all
four metrics. Every sampled marker-window PipeWire node stayed at `ERR=0`;
monitoring began at the marker, so the pre-marker startup interval and the
complete end-to-end xrun-free launch gate remain open. Evidence is in
`results/diagnostics/ordered-0033-correctness-20260813-uOi97M` and
`results/diagnostics/official-0033-lcd-live-abba-20260813`.

The repaired hotblock experiment adds three independently selectable,
ROM-gated firmware blocks
while preserving the outer interrupt, debugger, cycle-budget and prefetch
boundary after every guest instruction. An initial BLIT implementation missed
braces around the multi-statement `SHR_WORD` macro: with a zero shift count,
the macro performed undefined shifting and wrote zero to BX, visibly dropping
LCD pixels. The repaired implementation is pixel-identical in repeated native
LCD captures and composes with patch 0032. Two complete 11-channel captures
with divide and all hotblocks active matched the frozen reference. An earlier
narrow ABBA appeared positive, but the larger palindrome LCD matrix
measured 1.31% more cycles for hotblocks alone and 2.48% more cycles with the
divide patch. It is therefore preserved at
`patches/experiments/mpc2000xl-v53-hotblocks-repaired.patch`, outside the
ordered stack and launcher.

The same comprehensive matrix resurrected BRK FD HLE: it measured 3.49% less
task CPU, 2.46% fewer cycles and 2.06% fewer instructions, while two composed
11-channel captures remained byte-exact. The final retained combination—divide
superblock, BRK FD HLE and stereo host topology, with hotblocks absent—measured
6.36% less task CPU, 6.19% fewer cycles, 4.73% fewer instructions and 6.97%
higher emulation speed on the official through-0032 build-script binary in
`results/diagnostics/official-0032-winning-stack-abba-20260813`.

Using the preserved pristine means above with the identically pinned final
candidate runs gives a cross-series estimate of 4.43x task throughput, 4.42x
cycle throughput and 4.53x reported speed versus pristine MAME. The direct
interleaved pristine comparison remains the more conservative 4.28x cycles /
4.38x speed result because its candidate still included the later-rejected
hotblocks.

### Rejected-experiment resurrection policy

Small positive cuts are no longer discarded merely for missing a standalone
3% threshold. Retain them when both chronological pairs improve task CPU and
cycles, correctness is exact, and the implementation remains independently
removable. Under that rule, stereo topology, the divide superblock, and BRK FD
HLE are cumulative candidates, as is the separately measured unchanged-LCD
path. Correct-but-negative hotblocks remain research artifacts rather than
shipped paths.

Do not restore failed implementations unchanged:

- The per-instruction replay cache was exact but added about 20% task CPU and
  cycles because it translated, resolved and compared backing bytes at every
  instruction. Its useful idea survives only as validation amortized across a
  multi-instruction block.
- The timing-atomic `3f76` wrapper moved first audio onset by about 895.8 us.
  Only its scheduler-boundary-preserving split form is admissible, and that
  form measured essentially neutral.
- The panel `03d5` decoder shortcut saved about 0.08% instructions, and the
  forced-inline V33 translation experiment regressed task CPU and cycles.
  Neither has a concrete correctness or implementation bug that would recover
  useful host time.
- The old atomic bit-blit wrapper and OpenGL PBO experiment were genuine host
  regressions. The bit-blit opportunity is superseded by the boundary-exact
  repaired hotblock; the PBO path remains rejected.
- Synchronous inline sound effects preserved the frozen all-output PCM but did
  not resolve live q32 delivery: underruns changed only from 14 in the threaded
  control to 12 inline, and the delivered stream still inserted whole-sample
  timeline steps. It remains a diagnostic artifact, not a patch or launcher
  mode.
- Exact uPD78C10 panel timer batching is not achievable at reasonable cost and
  was reverted after implementation and bisection. A deficit/flush design with
  conservative event bounds covered timer 0/1 matches, the coalesced timer
  F/F, the event counter (the panel runs ETMM=0x0c free-run ECNT), and the A/D
  converter's per-conversion sampling instants, and was engaged 99% of the
  time - but frozen PCM diverged for any window larger than two cycles.
  Bisection showed the panel's serial engine is the blocker: with the timer
  F/F feeding update_sio, a serial edge falls every machine cycle
  (interval/2 = 1 at SMH=0x0c/SML settings), each transmit edge drives
  txd_func toward the V53 mid-transfer, and while receive is enabled every
  edge samples rxd_func hunting for a start bit. Deferring any of that
  reorders panel-to-V53 serial traffic against TXB writes. Reducing panel
  cost further therefore requires extending the 0019-style event-driven
  serial path, not cycle batching. The uPD78C10 remains about 13% of host
  cycles after the idle skip.
- The idle-iteration recorder/skip (patch `0037`) is the largest single win in
  the project so far: +26.4% average speed (819.6% to 1036.3%, complete
  separation) with bit-identical frozen PCM while 440,668 iterations were
  skipped, and zero live 44.1 kHz/q32 underruns in both boot and playback
  windows. It descends from the rejected per-instruction replay cache: the
  replay idea was sound but validated at every instruction (+20% overhead);
  amortizing validation across a whole recorded loop iteration and verifying
  the read set once per timeslice makes it profitable. The one non-obvious
  implementation detail: net-zero write accounting must dedup by address on
  the first write, because all eleven same-depth calls in the OS main loop
  re-push the same stack slot, and per-event accounting misreads that as a
  state change. Guest-PC histogram evidence:
  `results/diagnostics/v53-pc-histogram-101531` (top twenty 64-byte regions
  cover 72.5% of executed instructions).
- Compiler-flag experiments on the 36-patch stack: `-march=native` alone
  breaks the frozen PCM (`d37a16c5...` versus `a65077eb...`) because FMA
  contraction changes float rounding in the stream-mixing chain;
  `-ffp-contract=off` restores bit-exactness. With exactness restored,
  `-march=native -ffp-contract=off` plus `LTO=1` measured 7.87% *slower* than
  the generic `-O3` build (817.7% versus 753.4% mean over a matched ABBA), with
  the binary growing from 80 MB to 200 MB: LTO's cross-TU inlining bloats the
  interpreter past its cache-friendly layout. Note that genie-generated
  makefiles do not track flag changes, so every flag experiment must wipe the
  object directory or it silently reuses stale objects. Evidence:
  `results/diagnostics/flags-abba-20260814`,
  `results/diagnostics/nativelto-pcm-20260814` (PCM failure),
  `results/diagnostics/nativefpoff-pcm-20260814` (PCM restored).
- The V33 data-access window (patch `0036`) is the data-side sibling of the
  fetch window. It is PCM-exact and deterministically removes 2.59% of retired
  instructions and 2.32% of branch misses, but desktop wall clock is null
  (+0.10% across sixteen interleaved runs): the out-of-order host hides the
  removed dispatch work. It ships default-off everywhere and is a first-class
  Cortex-A53 qualification candidate, where two indirect calls per data access
  are not free. Evidence: `results/diagnostics/datawindow-speed-20260814` and
  the `datawindow-perf-20260814-*` counter runs.
- The direct-pointer opcode fetch window that won 10.2% on the V53 (patch
  `0035`) does not transfer to the uPD78C10 panel MCU. Its program map is the
  same static ROM shape and the window is PCM-exact there, but an interleaved
  ABBA of eight runs per arm measured +0.23% with a pooled standard deviation
  of 2.69% of the mean: the arms overlap almost completely. `execute_run`'s
  3.20% is the whole panel interpreter, of which fetch is one slice, and the
  MCU retires far fewer instructions than the V53. A prior hypothesis that its
  halted branch was spinning per cycle was falsified by instrumentation
  (`halt_cycles=0`, `run_instructions=17,971,042`); the MCU is never halted.
  Reducing it further needs firmware HLE in the style of `0023`/`0024`, not a
  fetch fast path. Evidence:
  `results/diagnostics/panelwindow-speed-20260814`.
- The whole sound-tail line of work is closed as a measurement error. It was
  conducted on CPUs `20-21` at `SCHED_RR` priority 1; those are this host's
  2.5 GHz low-power E-cores, and the launcher deploys on the 4.5 GHz P-cores
  `0-11` at nice `-10` and RR `20`. Measured on the deployment configuration,
  PipeWire callback gaps stay within 12 us of the 725 us nominal and the paced
  44.1 kHz/q32 playback window records zero underruns, so there is no stall for
  the handshake, RR2 boost, batched publication or inline path to remove. The
  delivered-audio comparator that rejected them is invalid for this fixture:
  its unpaced 400% boot phase discards audio in proportion to host speed, so it
  scored the faster, cleaner deployment configuration roughly twenty times
  worse. Details and the prebuffer sweep are in
  [`mpc2000xl-low-latency.md`](mpc2000xl-low-latency.md).

BRK FD HLE is now a retained default-off small win on this host. Native
Cortex-A53 measurement is still required before enabling it by default.

Forcing the existing V33 translation helper inline reduced generated fetch
code and one matched pair retired 1.51% fewer instructions and 6.35% fewer
branches. It nevertheless regressed task clock by 2.52% and cycles by 1.66%,
so it is rejected. The apparent 3.89% flat translation symbol was not
independently removable host time. Direct backing-pointer caching was not
prototyped because it can bypass memory taps, debugger observers, dynamic
handlers, and self-modifying-code visibility.

The remaining named panel path has a hard profile ceiling of about 6.04%:
3.20% in `handle_timers`, 1.68% in panel `execute_run()`, and 1.16% in
`update_sio()`. Frequent ADC/FE1 interrupts, serial completion, debounce,
input sampling, and UART boundaries prevent a small exact batching change from
removing most of it. A complete optional panel-device HLE might recover 4–6%,
but it is a separately scoped device-model project, not another local speed
cut. Do not revive the rejected `03d5` decoder shortcut.

### Phase 4: compiler and deployment-specific builds

Measure LTO, PGO and target tuning after code-path work so compiler effects do
not hide causality. Use native flags only for desktop builds and appropriate
Cortex-A53 tuning for Pi Zero 2 W. Compiler flags cannot discover the exact
firmware/device invariants required for safe HLE.

### Phase 5: validate the deployment shape

Measure Pi Zero 2 W with the emulation thread on one A53 and asynchronous
presentation on a second core. Test full-panel and LCD-only rendering
separately, record actual frequencies and throttling, and repeat with active
MIDI/pad input and UI activity.

No suitable Linux-target AArch64 toolchain was available on the development
host, so static A53 code generation is not a substitute for this test. Build
the pre-accessor and accessor revisions natively with the same compiler and
`-mcpu=cortex-a53`. Pin MAME to one isolated A53, put presentation on another,
fix the performance governor/frequency, and run at least five serialized ABBA
pairs of the loaded 60-second Logic workload after warm-up. Record task clock,
cycles, instructions, branches, branch misses, L1I, dTLB and cache misses,
emulation speed, frequency and thermal/throttle state. Accept the core patch
for Pi only if task clock and cycles improve consistently without a branch,
thermal, PCM, timing, MIDI, resize, or xrun regression.

## Correctness, review and real-time gates

Every optimization must pass the relevant gates before becoming a default:

- Do not change the 32-frame PipeWire quantum or 16-sample sound cadence while
  evaluating CPU optimizations.
- Accurate mode retains canonical PCM SHA-256
  `22f76ffaaedc4364b8279a79672a07a35f93997f180b8665e9ef3a576ae176a9`.
- Repeat renders in an experimental exact mode are byte-identical to each
  other; intrinsic emulator audio jitter remains zero.
- DSP key-on identity, order, voice, sample address, simultaneous grouping and
  timestamps remain identical after any allowed constant offset is removed.
- V53 HLE advances the exact guest time and adds no audio-clock jitter. Unknown
  interrupt, DMA, timer, memory or I/O state forces stock execution.
- Panel traces remain identical for timing-preserving panel optimizations. A
  latency-changing panel-input mode uses a different flag and commit and must
  stay within its separately declared timing envelope.
- Active serialized MIDI and direct-pad paths both work.
- Live PipeWire tests report no MAME buffer corrections or underruns during
  steady playback and the full-render resize/activity gate.
- Performance claims use serialized alternating-order A/B runs and report
  absolute counters alongside percentages.

Experimental speed modes must be default-off, explicitly named, and retain an
accurate fallback. Each logically independent speed optimization, latency
change, core change and documentation/launcher change belongs in a reviewable
commit; do not combine unrelated experiments. Changes to generic MAME core
must be developed separately and proposed upstream only when their measured
cross-driver impact justifies the maintenance cost.

## Immediate next action

Run the native Cortex-A53 comparison and full-render low-latency test before
claiming Pi 3B+/Zero 2 W readiness. The independently flagged `3f76`
callback-wrapper, forced-inlined V33 translation, and small panel shortcuts are
all rejected. The next code-sized opportunity must therefore be a separately
scoped broader V53 dispatch/device-model change with a measured multi-percent
ceiling; do not resume the panel decoder or generic scheduler work unless new
evidence redirects the work.

## Final-push plan

The concrete implementation plan for the two remaining large levers - the
31.4 kHz sample-feed superblock HLE (patch `0040`) and the panel serial event
extension with timer-batch resurrection (patch `0039`) - is maintained in
[`plan-sample-feed-hle-and-panel-serial.md`](plan-sample-feed-hle-and-panel-serial.md),
including the interrupt-vector map extracted from the playback RAM dump, the
disassembled service bodies, the shadow-validation methodology, sequencing,
effort estimates and the acceptance battery.
