# MPC2000XL remaining performance analysis and optimization plan

## Scope and current baseline

This plan is current after the independently flagged V53 BRK88 status-service
HLE was validated on top of commit `7ca0bcd`, which coalesces the unconnected
uPD78C10 panel timer output. Both cuts preserve guest time and leave the
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

### Firmware-specific exact blocks

After BRK88, use the guest-PC/basic-block histogram to rank any other dominant
services or polling loops. Each candidate must be evaluated independently.
Fast-forwarding is allowed only when the exact next causal event is known;
otherwise the interpreter must run normally.

### Opcode and data-access machinery

The earlier profile's largest single symbol, at 12.99%, was the V53 opcode-byte
fetch lambda configured by `nec_common_device::device_start()`. Each byte goes
through a `std::function`, V33 address translation, and MAME's cached
address-space lookup:

```text
fetch/fetchop -> m_dr8 -> m_cache16.read_byte(v33_translate(address))
```

This is abstraction and emulated-bus cost, not evidence that host DRAM
bandwidth is exhausted. Possible later experiments are:

1. A concrete, inlinable V33/V53 opcode accessor selected once at startup.
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

### Phase 2: rank the next measured bottleneck

Capture fresh profiles using the same loaded Logic workload and
fixed affinity/governor:

- video none with the normal audio path;
- LCD-only rendering with normal audio; and
- full asynchronous panel rendering with normal audio.

Use at least five serialized repetitions. Record core frequency, task clock,
cycles, instructions, IPC, branches, branch misses and cache misses. Choose the
next target from the post-BRK88 profile rather than carrying forward stale
percentages.

### Phase 3: generic V53 work only when justified

Try fetch, translation and typed-access changes as isolated MAME-core patches.
Each patch must independently demonstrate enough broad impact to justify core
review. Do not combine these with driver HLE, launcher flags, audio changes or
rendering changes.

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

Commit the validated BRK88 service independently, then capture one fresh
post-HLE profile. Rank the remaining bounded V53 firmware services against the
general fetch/data path and choose the next smallest measurable seam. Do not
resume panel decoder or generic scheduler work unless that evidence redirects
the work.
