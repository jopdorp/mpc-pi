# Final push plan: sample-feed superblock HLE and panel serial event extension

Goal: close the remaining gap from the verified 1077% mean (peak 1119%) toward
1500% average speed on the deployment CPUs, using only exactness-preserving
techniques already proven in this fork. Two work items, ordered by leverage:

1. **Sample-feed service HLE** (V53 guest work, ~30% of remaining guest
   instructions): replace the interpreted 31.4 kHz feed/poll machinery with a
   `0032`-style superblock plus two `0023`-style tiny service HLEs.
2. **Panel serial event extension + timer-batch resurrection** (uPD78C10 host
   work, ~13% of host cycles): make the panel's serial engine safe to defer,
   which removes the one blocker that forced the timer-batching revert.

Both items ship as ordered patches (`0039`, `0040`), default-off, fast preset
opt-in, each gated on the full acceptance battery (section 6).

---

## 1. Evidence base (all reproducible from preserved artifacts)

Artifacts: `results/diagnostics/v53-pc-histogram-101531` (pre-skip),
`results/diagnostics/v53-histogram-skip-20260814` (post-skip),
`results/diagnostics/v53-ram-dump-20260814/ram.bin` (512 KiB linear RAM at
playback), scratchpad tools `rank-pc-histogram.py`, `disasm-hot.sh`
(V33 executes 8086-compatible code; `objdump -m i8086` disassembles it).

Post-idle-skip guest-instruction distribution (118.9M total over the fixture):

| Region | Share | Identified as |
|---|---|---|
| `0x00bb00-0xbbbf` | ~18.6% | feed loop + helpers (below) |
| `0x000fc0-0x0ff8` | 11.1% | `int 0x92` flag service body |
| `0x001680-0x16bf` | 9.3% | tick services + tick-wait loop (loop already skipped) |
| `0x036100-0x3613f` | 5.3% | DMA-ready poll (`in` port `0xc03b`, bit 3) |
| `0x01b180`, `0x01acc0`, `0x0302c0`, `0x037e00` | ~12% | uncharacterized secondary services |

Interrupt vector table (from `ram.bin`, offsets `4*n`):

```
int 0x23 -> 0000:0fd4   hardware ISR inside the fc0 block (source TBD, phase A)
int 0x77 -> 0000:169b   tick read service: mov ax,[0xb8a]; iret
int 0x7c -> 0000:0ff9   small service in fc0 block (TBD)
int 0x88 -> 0000:4ffc   BRK88 status service (already HLE'd, patch 0023)
int 0x92 -> 0000:0fe3   flag service, disassembled below
int 0xb6 -> 0000:1681   small service in 1680 block (TBD)
int 0xfd -> 0000:28ac   BRKFD event service (already HLE'd, patch 0024)
```

Key disassembly (from `ram.bin`):

```
; int 0x92 handler - the 11.1% block, ~10 instructions straight line
0fe3: push ds; push bp; mov bp,0x0fe7; mov ds,bp
0fea: cmp al,0                ; al = caller argument
0fec: jne 0ff3
0fee: movb [0x11af],0         ; al==0: clear the flag
0ff3: mov al,[0x11af]         ; return flag in al
0ff6: pop bp; pop ds; iret

; feed/wait loop - the bb block core, entered at 0xbb55
bb55: call 0xbb6b             ; init: movw [0xa09a],0 ...
bb58: call 0xbb78             ; feed helper: programs V53 DMAC
bb5b: mov al,1
bb5d: int 0x92                ; read flag (al=1: no clear)
bb5f: cmp al,0
bb61: je 0xbb58               ; loop until hardware ISR sets [0x11af]
bb63: ret

bb64: pusha; mov al,0; int 0x92; popa; ret    ; clear-flag wrapper

; feed helper tail (bb40 region): DMAC programming
bb41: mov dx,0xc038; mov al,0x10; out dx,al
bb47: mov dx,0xc039; mov al,0x00; out dx,al
bb4d: mov dx,0xfff6; mov al,0x11; out dx,al   ; V53 internal reg
bb53: popa; ret

; DMA-ready poll - the 5.3% block
36115: mov dx,0xc03b
36118: in al,dx
36119: test al,8
3611b: je 0x36115
```

Cadence: the `fe3` body and the `bb58` loop each execute ~1.32M times over 42
emulated seconds = 31.4 kHz, about one loop iteration per service event, i.e.
the wait usually succeeds after roughly one pass. The cost is not idle
spinning (the idle-skip recorder correctly never arms here because registers
and `[0x11af]` change per pass); the cost is interpreted decode/EA/prefetch
overhead of ~40+ instructions per event, 31,400 times per second, times the
whole call graph.

Why the existing tools cannot take this further:
- idle skip: iterations are not fixed points (flag transitions, DMAC state).
- fetch/data windows: already applied; they cut per-access cost, not
  per-instruction decode overhead.
- The remaining win is eliminating interpretation itself on these paths:
  exactly what `0023`/`0024` (service HLE) and `0032` (loop superblock) do.

---

## 2. Work item 1: sample-feed superblock HLE (patch `0040`)

### 2.1 Shape of the solution

Three cooperating pieces, smallest risk first. Each is independently gated
and independently removable; land them in this order.

**Piece 1 - `int 0x92` service HLE** (BRK88-class, smallest)
- Hook: `nec_interrupt(int_num == 0x92)` next to the existing BRK88/BRKFD
  intercepts at `nec.cpp:464`.
- Semantics (from disassembly): full interrupt entry/exit effects (push
  PSW/PS/IP exactly as `nec_interrupt` does today, then the handler's own
  `push ds/bp`, the flag read/clear at `0:0x0fe7*10h + 0x11af` wait -
  the handler sets `ds=0x0fe7`, so the flag's linear address is
  `0x0fe7*16 + 0x11af = 0x1101f`; confirm in phase A against observed writes), `pop`s, `iret`.
- Cycle model: two paths only (`al==0` clear path, `al!=0` read path);
  derive per-path totals from the interpreter cycle tables + prefetch reload
  cost, then verify with the shadow mode (2.3).
- Gate: OS v1.20 SHA1 gate (reuse `validate_mpc2000xl_brk88_handler`
  pattern: byte-compare the 22-byte handler at `0x0fe3` on first use, cache,
  re-validate after any `load_state`).

**Piece 2 - tick service HLEs `int 0x77` / `int 0xb6`** (same class)
- `int 0x77` body is 6 instructions (`mov ax,[0xb8a]`; `iret` wrapper).
  `int 0xb6` at `0x1681` to be disassembled in phase A; expected symmetric
  (tick write / compare). Same validation pattern as piece 1.

**Piece 3 - `bb58` loop-iteration superblock** (the 0032 pattern, main win)
- Hook: in `execute_run_mode` next to the divide-superblock check
  (`linear == 0x150a`): when `linear == 0xbb58` and the mode flag is on and
  the handler bytes validate, execute ONE loop iteration natively:
  1. `call bb78` effects: perform the helper's memory ops via the existing
     `data_read/write_*` helpers and its port writes via `io_write_byte`
     (same device side effects, same DMAC behavior - the emulated DMAC is
     untouched);
  2. `int 0x92` effects inline (piece 1's implementation reused as a
     function);
  3. the compare/branch: if flag clear, leave `ip` at `0xbb58` (loop
     continues; the interpreter loop-top interrupt dispatch is preserved,
     which is what keeps hardware-interrupt timing exact); if set, execute
     the `ret` effects (pop return address via the data helpers).
  4. Charge the exact per-path cycle total; update prefetch state exactly as
     the interpreter would (reuse the accounting approach validated in
     `0032`; its loop had the same "stay at head, charge per iteration"
     structure).
- The helper `bb78` must be fully disassembled in phase A (entry to ret,
  every branch). If it contains data-dependent branches, model each with its
  own cycle total, exactly as 0023 did for BRK88's branches.
- Anything unproved (unexpected byte pattern, unexpected mode, segment
  overrides in flight, pending `m_rep_params`, trap flag set) falls back to
  interpretation for that iteration. Fallback must be free of partial
  effects: validate everything before mutating any state.

### 2.1a Phase A result: `bb78` is a spin-wait, not DMAC programming

Disassembled from the playback RAM dump. The plan guessed the helper
programmed the DMAC; it does not:

```
bb78: push ax; push dx
bb7a: mov ax,0xffff
bb7d: mul ax                ; deliberate time-waster, no architectural effect
bb7f: pop dx; pop ax
bb81: decw [ds:-0x5f66]     ; primary countdown
bb85: je bb88
bb87: ret
bb88: decw [ds:-0x5f64]     ; secondary countdown
bb8c: jne bb91
bb8e: jmp 0xa9dc            ; timeout path
bb91: ret
```

(`bb92` onward is an ASCII hex-digit table, not code.) So the whole `bb58`
loop is a **bounded spin-wait**: burn time, decrement a counter, poll the
`int 0x92` flag that the `int 0x23` ISR sets, exit on flag or on timeout.
The DMAC programming seen at `bb41` belongs to a different entry path.

That is much better news than a DMAC service: it is an idle loop, and the
`0037` recorder already skips idle loops. It refuses this one for exactly one
reason - the countdown makes the writes non-net-zero.

### 2.1b Induction-variable extension: implemented, not yet arming

The natural extension is to allow an address that the iteration both reads and
writes with a constant delta (a countdown) to act as an *induction variable*:
excluded from read verification, and instead limiting the skip so the counter
never reaches the value that changes control flow. Iterations then advance it
by `delta * N` in one step. This preserves the existing exactness argument
because every skipped pass provably takes the branch the recorded pass took.

Implemented on top of `0037` (classification in `idle_close_recording`, bound
and advance in `idle_head_event`). Frozen PCM stayed bit-exact. It does not
arm yet: with head 2 pointed at `0xbb58`, `record_attempts` rises from 35,341
to 698,067 and `fail_netzero` to 664,728, so the loop is recorded but some
written address is still neither net-zero nor classifiable as an induction.
Next step is a diagnostic dump of the rejecting address in that path (which
address, old/new value, and whether it appears in the read set) - the same
technique that found the stack-slot dedup bug in the original recorder. The
work in progress is preserved in the session scratchpad.

**A real bug was found in the committed `0037` while doing this**:
`IDLE_HEAD_COUNT` is 3, but the dispatch in `execute_run_mode` only tests
`m_idle_heads[0]` and `m_idle_heads[1]`, so the third head never fires. It is
currently harmless (the third head is set to the DMA-ready poll, which the
recorder would refuse anyway) but it must be fixed with a loop over
`IDLE_HEAD_COUNT` before any third head is relied on, and that fix needs the
full acceptance battery because it changes which loops get recorded.

### 2.1c Second working session: the loop DOES spin, and the blocker is one stack slot

Cycle-delta measurement at the `0xbb58` head (`total_cycles()` between
consecutive arrivals, 4000 samples): **3975 are exactly 164 cycles**, ~20 are
741 (a periodic interrupt path). The loop spins constantly at a deterministic
164 cycles per pass - the earlier "flag is always set on first poll" reading
was wrong, and the iteration IS skippable in principle.

The recorder's rejection is down to exactly one word: stack slot `0x108ca`,
which alternates between `0xf283` and `0xf287` - values differing only in
bit 2, the V33 parity flag. It is the PSW pushed by `int 0x92`, and
`decw [countdown]` in `bb78` flips the result parity each pass.

Two fixes were implemented on top of the induction extension:
- multi-head dispatch bug fixed (committed `0037` only checks heads 0 and 1;
  the fix loops over `IDLE_HEAD_COUNT` - fold into `0037` regardless);
- per-head **iteration period**: when a period-1 close fails cleanly on write
  accounting, retry recording across two passes, over which a per-pass parity
  alternation should be net-zero and the countdown a delta -2 induction.

Measured result: period-2 recordings STILL close with `old=f287 now=f283`, so
the alternation is not strictly per-pass and the simple parity model is
wrong. Rare `f293/f297` variants exist too. The true period is unknown until
the write SEQUENCE on `0x108ca` within one recording is logged.

**Precise next diagnostic**: log `(visit, old, new)` for every write to the
failing address during the first ~10 recordings at head 2, then either fix
the period logic or generalize the induction class. Work-in-progress code is
preserved in `results/diagnostics/induction-wip-nec.{cpp,h}` and the session
scratchpad; it builds cleanly, keeps frozen PCM bit-exact, and only fails to
arm the third head.

Cost warning: the period retry thrashes when it cannot arm (~700k record
attempts over the fixture, 843% average speed versus the 1077% baseline in
that diagnostic build), so the retry needs a per-head failure cooldown before
this ships.

### 2.2 Phase A - characterization (half a day, no emulator changes)

All commands runnable today; record outputs into
`results/diagnostics/feed-hle-characterization/`:

1. Disassemble the complete call graph: `bb55-bbbf`, `bb6b`, `bb78-...`,
   `fe3-ff8`, `fd4-...` (int 0x23 ISR), `ff9-...` (int 0x7c), `1681`,
   `169b`, plus the uncharacterized `1b180`/`1acc0`/`302c0`/`37e00` regions:
   `scratchpad/disasm-hot.sh <addr> <len> ram.bin`.
2. Identify the `int 0x23` source: add a temporary log in `external_int()`
   printing vector + IRR source when the vectored address lands in
   `0x0fc0-0x1000` (one diagnostic build; the pattern exists from this
   session's probes). Expected: DMAC terminal count or DSP DRQ3 - confirms
   what "the flag" means and when it is set.
3. Instrument per-invocation cycle totals: reuse the PC histogram plus a
   temporary counter keyed on `PC==0xbb58` measuring icount deltas between
   loop-head arrivals, histogrammed. This yields the ground-truth per-path
   cycle totals the HLE must reproduce.
4. Extract the exact byte images of every routine to be HLE'd (validation
   constants for the ROM/RAM gates).
5. Verify the flag address arithmetic (`ds=0x0fe7` base) against a memory
   watchpoint or the recorder's write log.

### 2.3 Phase B - shadow validation mode (the key de-risking tool, ~1 day)

Build `MPC_V53_FEED_MODE=shadow` before attempting `hle`:
- On every superblock/service entry, snapshot CPU state; run the
  INTERPRETER as today; at exit, ALSO run the HLE implementation against the
  snapshot in a scratch state copy; compare: full register file, flags,
  segment regs, ip, prefetch count, every memory write (record via the
  existing recorder hooks), every IO write (sequence-exact), and the cycle
  total. Log any divergence with full context; count agreements.
- Acceptance to leave shadow mode: zero divergences over the full fixture
  battery (boot + Logic playback + MIDI input fixture + forced rare branches)
  with at least 10M shadow-checked invocations.
- This converts the hardest part of 0023-style work (cycle/effect exactness)
  from "derive and hope, then debug PCM diffs" into a direct differential
  test with named divergences. The session's PCM-diff debugging of the panel
  batching is exactly the pain this avoids.

### 2.4 Phase C - implementation and gates (1-2 days)

- Implement pieces 1-3 behind `MAME_MPC_V53_FEED_HLE` (raw) /
  `MPC_V53_FEED_MODE=accurate|shadow|hle` (launcher), default `accurate`.
- Ship order: piece 1 alone -> full gates -> piece 2 -> gates -> piece 3 ->
  gates. Do not combine untested pieces; a divergence must name its piece.
- Package as patch `0040` after all three pass; fast preset gets
  `MPC_V53_FEED_MODE=hle` only after the live gate and ABBA.

Expected return: the fc0+bb blocks are ~30% of remaining guest instructions;
interpretation overhead dominates them. Conservatively +12-20% average speed.

---

## 3. Work item 2: panel batching - SECOND ATTEMPT FAILED, cause now exact

**Status after the implementation attempt on 2026-08-14: not viable in this
configuration. The serial hypothesis below was wrong; the real blocker is the
event counter.** Keep this section for the corrected analysis; do not
re-attempt without addressing 3.0.

### 3.0 What the second attempt established

Measured runtime state disproves the serial hypothesis:

```
SMH=0c SML=4f txcnt=0 rxcnt=0 txbuf=0 interval_half=64 rx_starts=0
```

- `SML & 3 == 3` selects prescale 64, so a serial edge falls every **64**
  machine cycles, not every cycle as previously recorded.
- `SML & 3 != 0` means asynchronous mode, and the driver never binds the
  panel's `rxd_func()`, so RXD is the unbound constant 1. The start-bit test
  `(m_rxs & 0xc000) != 0x4000` can never pass: `rx_starts=0` over a full
  fixture. The receive half is inert.
- Patch `0022` already drives `update_sio()` with coalesced counts, and
  `update_sio` is exact for a given total, so serial deferral only changes
  batch granularity.

The attempt added every timer/serial special-register flush hook including
`upd7810_write_TXB()` (the hook genuinely missing the first time), a
one-cycle bound while `txcnt>0 || txbuf!=0 || rxcnt>0`, and a permanent
kill-switch if a receive ever starts. Frozen PCM still diverged.

Bisection with the `MAME_MPC_PANEL_TIMER_BATCH=<cap>` bound cap:

| cap | frozen PCM |
|---|---|
| 2, 3, 4 | exact `a65077eb...` |
| 6 and above | diverges |

Isolating the event counter (forcing bound 1 only for the ECNT branch,
everything else batched and uncapped) restored bit-exact PCM. **The ECNT
bound is the defect**, and its 4-cycle increment period is exactly the
observed cap-4/cap-6 boundary.

The panel runs `ETMM=0x0c`: free-running internal clock, ECNT incrementing
every `12/3 = 4` machine cycles, clear-on-`ETM1`-match. The attempted bound
was `min(u16(ETM0-ECNT), u16(ETM1-ECNT)) * 4 - OVCE`, the distance to the next
`IRR`/CO0/CO1 event. Something in the increment path is observable beyond
those matches, or `ETM0`/`ETM1` move without passing a hooked write. The value
dump that would settle it segfaulted in its own scaffolding (a compound-literal
array in the probe) and was not retried.

Consequence: with ECNT active at a 4-cycle period, an exact bound of 4 cycles
is shorter than the average instruction, so batching yields nothing. **Panel
timer batching is dead unless the ECNT bound defect is found**, and even then
the win depends on `ETM0`/`ETM1` sitting far from `ECNT` in practice.

Next step if resumed: dump `ECNT`/`ETM0`/`ETM1`/`OVCE`/`ETMM` at bound
computation using plain scalar `fprintf` arguments, and check whether
`upd7810_co0_output_change()`/`co1` are connected in the MPC driver - if the
CO pins are wired, every match is observable through a second path.

Reducing panel cost is better approached by extending the `0019` event-driven
pattern to the timer F/F, not by cycle batching. The uPD78C10 remains about
13% of host cycles.

### 3.1 (superseded) Original serial-blocker analysis

### 3.1 What actually blocked timer batching (from this session's bisection)

The reverted deficit/flush design was exact for timers 0/1, the coalesced
timer F/F, the event counter (`ETMM=0x0c` free-run) and the ADC (once
per-conversion sampling instants were bounded). PCM still diverged because
the serial engine runs off the F/F at one edge per machine cycle
(`interval/2 == 1` at the panel's `SMH/SML`), and:

1. `TXB` writes start transmissions between deferred edges (reordering);
2. while receive is enabled, every edge samples `rxd_func()` hunting for a
   start bit, so a deferred window samples the line at the wrong times when
   the V53 changes it.

Bisection evidence: `cap=2` bit-exact, `cap=8` diverges - confirming the
per-edge serial engine is the only sub-instruction-granularity observer.

### 3.2 The fix that makes deferral exact

Idle serial edges are state no-ops: `sio_output` with `txcnt==0 && txbuf==0`
returns; `sio_input` with `rxcnt==0` and line high does not change state.
Batched no-op edges are therefore exact **within a slice**, because the rxd
line latch can only change from the V53 side, and the V53 only runs in its
own slices. The two leaks close with:

1. **Serial-register hooks** (missing from the reverted attempt): flush +
   bound-invalidate before `MOV_TXB_A` and any other TXB/RXB-touching opcode
   (enumerate via `grep 'TXB\|RXB' upd7810_opcodes.cpp`), exactly like the
   existing TMM/ETM hooks. A transmission then starts at an exact cycle.
2. **Flush-then-latch on the rxd line**: in the panel's rxd line setter
   (driver callback path `v53 txd -> panel rxd`), flush the panel's pending
   timer debt BEFORE latching the new line level. Deferred edges then sample
   the OLD level for cycle-times before the change, and the flush leaves the
   panel cycle-current when the new level lands: start-bit detection timing
   becomes exact. This is the standard catch-up-on-external-input pattern.
3. **Busy-serial bound**: while `txcnt>0 || rxcnt>0 || txbuf!=0`, the
   observable-event bound is 1 (no deferral). Serial traffic is tiny - the
   0022 TXD gate measured 14,320 edges over an entire boot/load/play run -
   so this costs nothing.

### 3.3 Reimplementation notes (the reverted code's exact lessons)

Reimplement the deficit/flush design as before (the design is fully
documented in `mpc2000xl-performance-optimization-plan.md` and this file);
the five pitfalls already paid for:

- net-zero write accounting must dedup by first write per address (stack
  slot re-pushed by every call);
- `timers_flush()` must recompute the bound; sr-write hooks must ALSO
  invalidate (`m_timer_next_event = 0`) after the write;
- the ADC needs `bound=1` while `PANM != ANM` or a sample is pending
  (`m_shdone == 0`), else `m_adtot - m_adcnt + 1`;
- the event counter bound is `min(u16 distance to ETM0, to ETM1) * 4 - OVCE`
  (u16 wrap, 0 -> 65536), gated to free-run mode `ETMM&3==0`;
- diagnostics must not sit after early returns (the mean_bound=0 trap).

Add a `MAME_MPC_PANEL_TIMER_BATCH=<cap>` bound-cap knob permanently; it is
the bisection tool that found the serial engine and will find any residual
observer.

### 3.4 Gates

The panel work has a sharper gate than PCM: the preserved panel TXD trace
comparison (`results/diagnostics/panel-timer-coalesced-txd-0vMqPy` flow,
14,320 edges bit-for-bit) plus the MIDI input fixture. Battery: TXD trace,
frozen PCM, key-on ticks, live underruns, ABBA. Package as patch `0039`,
`MPC_PANEL_TIMER_MODE=batch` as a third mode beside
`accurate|coalesced`, fast preset opt-in after gates.

Expected return: uPD78C10 is ~13% of host cycles; the per-instruction
`handle_timers` + `take_irq` bookkeeping is most of it. +5-9% average speed.

---

## 4. Sequencing and effort

| Step | What | Effort | Expected gain | Cumulative estimate |
|---|---|---|---|---|
| 0 | Phase A characterization (2.2) | 0.5 day | evidence | 1077% |
| 1 | ~~Panel serial + batching~~ **failed, see 3.0** | done | 0% | 1077% |
| 2 | Shadow mode (2.3) | 1 day | tooling | - |
| 3 | `int 0x92`/`0x77`/`0xb6` HLEs | 0.5 day | +2-4% | ~1160-1210% |
| 4 | `bb58` superblock | 1-2 days | +10-16% | ~1280-1400% |
| 5 | Secondary regions (`1b180`, `1acc0`, `302c0`, `37e00`) - characterize, then HLE the top one or two by the same pattern | 1-2 days | +5-10% | ~1350-1500% |

If step 5 lands short of 1500%, the remaining known reserves are: the
`0x36115` DMA-poll (needs a device-cooperative completion hint from the V53
DMAC - deferred because it couples devices), PGO retraining after each
patch (the profile goes stale as hot paths move; retrain at step 4), and the
scheduler/attotime layer (~6%, never yet attacked).

Sequencing rationale: panel work first because it is self-contained, its
gates are the strongest (TXD trace), and it de-risks the machine while the
shadow tooling is built; the superblock lands with shadow-mode proof rather
than PCM-diff archaeology.

---

## 5. Risk register

| Risk | Mitigation |
|---|---|
| `bb78` helper turns out large or self-modifying | Phase A disassembly first; HLE only validated byte images; per-iteration fallback to interpreter is always available |
| Cycle model wrong in rare branch | Shadow mode counts divergences before anything ships; forced-branch fixtures as in 0024 |
| `int 0x23` ISR interacts mid-loop | The superblock keeps `ip` at the loop head between iterations, so hardware interrupt dispatch points are unchanged by construction |
| Panel rxd flush reentrancy (flush called from V53 slice) | Flush only drains the panel's own accumulated debt and recomputes bounds; it runs no panel instructions; audit `timers_flush` for reentrancy safety, add an assert |
| PGO profile staleness after new patches | Retrain via `build-mame-pgo.sh` after each landed patch; the flags stamp forces clean rebuilds |
| Accumulated stack risk | Every piece independently gated and removable; ship order fixed; the full battery (section 6) between pieces |

## 6. Acceptance battery (unchanged, applies to every piece)

1. Frozen 48 kHz all-output PCM == `a65077eb074df267...` with the feature off
   AND on.
2. Panel TXD trace bit-identical (for any panel-touching change).
3. DSP key-on ticks identical (`compare-mpc-keyon-timing.py`).
4. Live 44.1 kHz/q32 fast preset: zero playback-window underruns.
5. Interleaved ABBA (>= 8 runs) on quiet deployment CPUs; complete-separation
   or explicitly-reported-as-noise.
6. Full 39/40-patch stack applies and reverses cleanly; official binary
   rebuilt via `build-mame-pgo.sh`; PCM re-verified on that binary.
