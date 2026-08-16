# Repository guidance

This file applies to the entire repository. This project maintains a focused,
ordered patch stack over MAME for Akai MPC systems. Preserve stock emulation as
the behavioural reference and keep every optimisation independently measurable
and removable.

## Change Discipline

Before editing, trace the current path and identify the smallest existing seam
that can provide the required behavior. Keep the existing business path as the
source of truth.

Default to the smallest correct implementation and reviewable diff. Prefer an
option on an existing function, type, or file over a parallel abstraction or
subsystem.

Separate the required fix from optional improvements. Put independently useful
or measurable changes in separate PRs so each can be accepted or rejected on
its own merits.

Treat a working implementation as a behavior reference, not proof that the
design is ready. If it duplicates logic or produces a large diff, rethink it
from the start and look for a substantially smaller solution before handoff.

Prefer deletion, reduction, and simplification over new code. New files, types,
models, migrations, dependencies, compatibility layers, and protocol machinery
each require a concrete justification.

Keep tests narrow: protect the changed contract or a demonstrated regression,
and reuse existing coverage when the production path is reused.

For performance work, measure optional producer or infrastructure changes
independently before deciding that their maintenance cost is justified.

A broad rewrite is appropriate only when the user explicitly requests it or a
smaller change cannot meet correctness, safety, or performance requirements.
State why the smaller option is insufficient and still minimize the rewrite.

Before publishing, review the complete diff again and remove speculative
generality, duplicate coverage, incidental cleanup, and changes that cannot be
justified.

Never add AI or tool attribution anywhere, including commit trailers, pull
request descriptions, comments, reviews, issues, documentation, or source
comments.

## Repository workflow

- Treat `.cache/mame` and disposable MAME checkouts as generated work areas,
  not as the deliverable. Prototype there when useful, then represent an
  intended MAME change as an ordered patch under `patches/mame/` and add it to
  `scripts/build-mame.sh`.
- Do not commit ROMs, firmware, downloaded projects, runtime state, profiling
  output, or generated build products. The existing ignored `roms/`,
  `results/`, `.cache/`, runtime, and `.firecrawl/` paths remain local.
- Preserve unrelated user changes. Stage only files belonging to the current
  change, and inspect both the staged and complete diff before committing.
- Keep documentation and launcher arguments synchronized with code. A setting
  required for correctness or performance must be explicit in the launcher and
  documented; do not rely on remembered shell state.
- Do not change the validated PipeWire quantum or MAME sound-update cadence as
  part of CPU optimisation work. Buffer experiments are a different change and
  require separate authorization and measurements.
- Use one patch and one commit per independently useful behaviour. In
  particular, keep these MPC2000XL experiments independent:
  1. a stock-timing front-panel CPU fast path;
  2. a cycle-exact V53 fast path; and
  3. a latency-changing direct panel-input path.
- Give each speed path its own opt-in flag and retain the accurate path as the
  fallback. Do not silently enable a new experimental path by changing an
  existing flag's meaning.

## Performance and timing work

- Start from a reproducible workload and record the MAME revision, patch stack,
  BIOS, project image, launcher arguments, CPU affinity/governor, video mode,
  audio graph rate/quantum, and whether host audio is active.
- Reuse one preserved reference capture when the accurate implementation and
  test fixture have not changed. Re-render the reference only when a dependency
  of the reference changes.
- Measure candidates against a matched control. Report at least emulation
  speed, task-clock time, cycles, and retired instructions when available; use
  profiles to attribute the gain rather than inferring it from wall time.
- Never claim a speedup from an instrumented build without a matched
  non-instrumented measurement. Treat the 10x objective as a stretch target,
  not a result, until end-to-end evidence demonstrates it.
- Distinguish event-onset timing from continuous audio timing. Once a sample is
  triggered, a speed path must not alter its PCM data, playback rate, or sample
  clock.
- For V53 optimisation, require cycle-equivalent architectural state and no
  added sequencer or audio-event jitter. Preserve DSP key-on identity, order,
  grouping, and timestamps. If the exact next causal boundary is unknown, do
  not fast-forward it.
- For stock-timing panel optimisation, preserve panel protocol byte content,
  order, debounce behaviour, and hardware-visible timing. The current project
  acceptance limit for added panel timing error is 1 ms, but prefer exact
  timing where practical.
- A direct panel-input bypass intentionally changes latency. Measure that
  latency separately and never use it as evidence that the stock-timing panel
  optimisation is correct.
- Run repeat captures to detect nondeterminism, and perform a live PipeWire,
  MIDI-pad, playback, window-resize, and xrun check after offline regressions
  pass.

## Working on the board

- **Persist it or do not do it.** Any setting applied over ssh - a
  wireplumber fragment, an IRQ priority, a default sink, a kernel module -
  is gone at the next reboot, and this board reboots. Put the change in the
  provisioning script (`scripts/pios/tune-realtime.sh` and friends), commit
  it, deploy once. Re-applying the same tweak by hand after every reboot
  wastes the run and, worse, means measurements are taken against a
  configuration nobody can reproduce.
- Config lives in the repo, not on the board. When a value has to be found
  by experiment, the experiment goes in `scripts/diagnostics/` and the
  winning value goes in provisioning with the measurement that chose it.
- The board **netboots**. `config.txt` and `cmdline.txt` are read from the
  TFTP copy, which `mpcpi-netboot deploy` populates from the NFS root's
  `/boot/firmware`. Editing the repo copy alone changes nothing on the next
  boot; the chain is edit -> deploy -> reboot, and it must be verified after
  the reboot, not assumed.
- Verify a setting by reading what the system actually did, not by reading
  back the file that asked for it: `hw_params` while the device is open,
  the interrupt rate in `/proc/interrupts`, `pw-top` for who drives the
  graph, `systemctl is-active` for units. Several settings in this project
  were "applied" for days while doing nothing.
- Keep kernel forensics armed. `mpcpi-netconsole` ships the console to the
  development host over UDP; the board panics, and a panic reaches no
  journal, no serial port, and no NFS-mounted log. A crash with no trace
  costs a whole investigation.
- systemd units on this board order `After=basic.target`. Ordering against
  `network-online.target` leaves the job silently unqueued on a netbooted
  machine - "enabled" and "inactive (dead)" at once, no journal entry. This
  has now bitten two separate units.

## Measurement discipline

- Know what the instrument is measuring before believing it. Several
  metrics here have lied for days at a time: `pw-top`'s client ERR column
  counts something that is not a dropout; a cumulative interrupt total
  divided by uptime was quoted as a rate; and a waveform continuity test
  reported thousands of defects that were another source mixed onto the
  measured channel.
- Verify the signal path of a measurement, not only its result. For an
  audio capture that means: check what is routed into the channel
  (`pw-link -l`), and check the peak level - a peak at full scale usually
  means something is summed in that should not be.
- When several independent levers all fail to move a number, stop pulling
  levers and suspect the number. Six consecutive null results is evidence
  about the instrument, not about the system.
- Prefer, in order: the producer's own statistics, the consumer's own
  counter, the driver's error count, and a recorded waveform with its
  routing verified. Do not build an argument on a single metric that
  nothing else corroborates.
- Take a positive control before trusting a new measurement channel. A
  silent log and a working-but-silent log look identical.
- Record negative results with the same care as positive ones, including
  the ones that refute an earlier conclusion in this repository. A
  document that confidently explains the wrong mechanism is worse than no
  document.

## MAME upstreamability

Follow MAME's current official contribution documentation:

- [Contributing to MAME](https://docs.mamedev.org/contributing/index.html)
- [MAME C++ Coding Guidelines](https://docs.mamedev.org/contributing/cxx.html)

The rules below were checked against those pages on 2026-08-12:

- Base upstream work on current `mamedev/mame` `master`, and make the patch
  apply cleanly without depending on unrelated patches from this fork.
- Make commits descriptive: state the affected component and intended result.
  Keep each commit buildable, testable, and understandable on its own.
- Follow the style already present in an existing source file before applying
  general style rules. For new MAME C++ files, follow the official naming,
  source-format, include-order, scoping, licensing, and structural guidance.
- Keep tabs and file formatting compatible with MAME and run `srcclean` on
  modified MAME source before proposing it upstream. Remove commented-out
  code, temporary tracing, and diagnostic-only output. Leave `VERBOSE` at zero
  and do not enable alternate logging output.
- Build and test locally. Before upstream publication, verify a clean full MAME
  build and a `DEBUG=1` build, in addition to this repository's focused MPC
  build and timing regressions.
- Give a pull request a specific title and a self-contained description of the
  behaviour, hardware basis, measurements, and validation. Do not use an issue
  as a support or design-discussion forum; MAME's issue tracker is for
  reproducible issues.
- Keep reusable MAME-core improvements separate from MPC driver changes. A core
  patch needs evidence of broad impact and regression coverage appropriate to
  every affected user; otherwise prefer the smallest MPC-specific seam.
- Prefer optimising an existing emulated hardware path while preserving its
  externally observable behaviour. Do not assume that a firmware-PC hook,
  hard-coded ROM address, event-driven replacement, hidden environment switch,
  or optional HLE mode is acceptable upstream merely because similar HLE code
  exists elsewhere in MAME.
- If firmware-specific HLE is the only effective seam, scope it to verified ROM
  revisions, reproduce registers, flags, memory, I/O, interrupts and consumed
  guest cycles, retain the original implementation, and document the hardware
  evidence and measured benefit. Treat it as an experimental fork patch until
  maintainers accept the design.
- For a panel HLE, model the documented panel device and serial protocol at its
  hardware-visible boundary. Do not bypass scan/debounce latency in a patch
  presented as accuracy-preserving. Submit any low-latency input bypass as a
  separate optional proposal with the behavioural difference stated plainly.
- For systems that require media to boot, preserve a reproducible software-list
  or legally redistributable test route where possible, as the MAME guidelines
  recommend, while never committing copyrighted Akai firmware or unlicensed
  project media here.

MAME's current contribution page requires an AI-assisted pull request to name
the model and version in its initial description. That conflicts with the
repository rule above forbidding AI or tool attribution. Do not add such
attribution and do not open or publish an upstream MAME pull request while this
conflict exists. Prepare upstream-quality patches locally, then stop and ask the
user to resolve the publication-policy conflict explicitly.

## Validation and handoff

- At minimum, run `./scripts/build-mame.sh` for patch-stack changes and the
  narrow diagnostic covering the changed contract. For MPC2000XL timing work,
  use `scripts/diagnostics/test-mpc2000xl-timing.sh` and the live timing test
  when the required audio/MIDI hardware is available.
- Record commands and artifact paths in the relevant document, but do not add
  generated artifacts to Git.
- Before committing, run whitespace checks, inspect the full diff, and confirm
  that each new flag defaults to the documented fallback.
- In the handoff, report measured gains, timing/PCM deltas, tests run, flags,
  commit boundaries, and any unverified hardware or upstream gate. Do not
  describe a prototype or partially tested speed path as complete.
