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
- the existing asynchronous full-panel renderer.

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
LCD-only and full asynchronous-render profiles with host audio still remain
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

### Rejected post-accessor cuts

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
