# System placement: everything measured, and the plan it implies

Written after six single-variable experiments in a row failed to move a
defect rate. That is the signal to stop guessing and put every number
already collected in one place, because when six educated guesses miss,
the fault is in the model, not in the next guess.

Everything below was measured on the board. Nothing here is estimated.

## The machine

Pi 5, four Cortex-A76 at 2.4GHz, governor pinned to `performance`,
`/dev/cpu_dma_latency` held at 0. Kernel 6.12.103-mpcpi-rt+ (PREEMPT_RT,
16K pages). Command line:

    isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3 irqaffinity=0 threadirqs

`isolcpus` removes 1-3 from every process's default affinity mask, so
**core 0 is the only core an ordinary task may use unless placed**. In
the development setup the root filesystem is NFS over `eth0`; the
appliance's own recordings therefore also travel over that link.

## Threads (measured, quantum 48, empty graph, 20s window)

| thread | policy | prio | core | CPU% | vol/s | invol/s |
|---|---|---|---|---|---|---|
| `AudioEngine` (pipewire-jack data loop) | FIFO | 85 | 3 | 6.6 | **0** | **1952** |
| `RT-main-(nil)` (Ardour graph) | FIFO | 77 | 3 | 11.7 | 976 | 309 |
| `RT-1-(nil)` (Ardour graph) | FIFO | 77 | 2 | 11.6 | 976 | 309 |
| `midiUI` | FIFO | 75 | 2-3 | ~0 | | |
| `butler`, `IO-*`, `LV2Worker`×8, `PeakFileBuilder`×2, `Analyzer`, `TriggerBox`, `DeviceList`, `EngineWatchdog` | OTHER | - | **2-3** | low | | |
| `pw-` ×2 (client loops) | OTHER | - | 2-3 | ~0 | | |
| emulator (`mpc`) | RR | 20 | 3 | **11.8** | | |

Two things in that table are load-bearing and neither was designed:

1. **`taskset -c 2-3` puts the WHOLE Ardour process there**, so the
   butler and every worker share the two cores reserved for realtime
   DSP. They cannot preempt FIFO 77, but they take locks, allocate, and
   keep more than one task runnable per core - which is exactly the
   condition `nohz_full` needs absent to stop the tick. Measured
   confirmation: core 2 took 121,000 timer ticks against core 3's 101.
2. **Core 3 carries three realtime threads** (85, 77, and the emulator
   at RR 20) while core 2 carries one plus all the housekeeping.

## Interrupts (measured rates, not cumulative totals)

| IRQ | source | rate | core | prio |
|---|---|---|---|---|
| 34 | `1000480000.usb` (dwc2 gadget) | **7,979/s** | 0 | 50 → 60 |
| 141 | `dw_axi_dmac_platform` (I2S DMA) | 1,842/s interrupt-driven | 1 | 95 |
| 107 | `eth0` | high, bursty | **0** | 50 |
| 13 | `arch_timer` | 3.3M cum. on 0 and 1 | per-cpu | - |

The gadget's 7,979/s is one interrupt per 125µs USB microframe - set by
`p_hs_bint=1`, **independent of channel count**. This killed the
"fewer channels" theory: 18 → 6 changed neither this rate nor the
defect rate. (An earlier "2,900/s" in these notes was a cumulative
total divided by uptime, quoted as a rate. It was wrong.)

## The defect, and everything that did not fix it

Delivered audio is judged by recording the gadget stream on the host
and checking the waveform (`check-continuity.py`): a 441Hz sine cannot
contain a step steeper than its own slope, nor four equal samples.

| condition | defects/s |
|---|---|
| tone only, **no session** | **0** |
| tone + armed session, 18ch | ~10 |
| tone + armed session, 6ch | ~11 |
| tone + armed session, req_number 8 | 9.9 |
| tone + armed session, gadget headroom 256 | 13.1 |
| tone + armed session, tone player at FIFO 70 on core 2 | 10.0 |

Meanwhile **Ardour's own xrun counter reads 0** through every one of
those runs, and the timer-clock driver is never late. The graph is
fine. The defect is downstream of it and upstream of the host.

Six levers, all on the USB service path, all null. The rate does not
respond to anything about USB. It responds to exactly one thing:
**whether a session is loaded and recording.**

## What that leaves, by elimination

The failing configuration differs from the clean one in these ways, and
only these:

1. Ardour's DSP runs (but its own counter says it never misses).
2. The emulator runs on core 3 (11.8% of a core, RR 20).
3. **The butler writes sixteen tracks of audio to an NFS home** - over
   the same `eth0` whose interrupt lands on core 0.
4. Ardour's non-realtime threads occupy cores 2-3.

Item 3 is the one never tested, and it completes a mechanism that fits
every observation:

    butler writes  ->  NFS RPC  ->  eth0 IRQ + softirq on core 0
                                        |
                     dwc2 IRQ (7,979/s) also on core 0, prio 60
                                        |
                     gadget misses microframe deadlines
                                        |
                     defects in delivered audio, while Ardour,
                     which finished its DSP on time, reports zero

It explains why the rate is immune to channel count, URB depth and
headroom - all of those are downstream of an interrupt that arrived
late. It explains why the tone player's priority is irrelevant - the
tone is not what is late. It explains why moving dwc2 to core 1 at
FIFO 90 made things *worse* (it then preempted the PipeWire data loop
that feeds the gadget, on the core that loop owns) while core 0 at
FIFO 60 helped only marginally (still behind the same softirq work).

## The plan

Ordered by confidence, each with the observation it is derived from.

**1. Take recording off the network.** The appliance is meant to write
to local storage; NFS is a development artifact. Point the session's
audio directory at local storage and re-measure. If the defect rate
collapses, the mechanism above is confirmed and the production
appliance never had this problem. *Cost: nothing. This is what the
shipped device does anyway.*

**2. Give the gadget interrupt a core that is neither core 0 nor
contended.** Core 1 at a priority **below** PipeWire's data loop (88) -
80, not 90. Never tested: 90 was tried (preempts the loop) and core 0
was tried (queued behind NFS). Core 1 at 80 is the untested cell that
both failures point at.

**3. Move Ardour's non-realtime threads off the DSP cores.**
`pin-threads.sh` exists and was measured as "no effect" - but that
measurement was taken when the xrun metric was `pw-top`'s client ERR
column, since retired as meaningless. It is worth re-running against
the waveform. Butler on core 0 also puts the NFS writer next to the
NFS interrupt, which is where it belongs.

**4. Separate the three realtime threads.** Core 3 currently holds the
dispatcher (85), a worker (77) and the emulator (RR 20). With the
butler moved away, the natural map is:

    core 0   housekeeping, eth0/NFS, butler and workers
    core 1   PipeWire data loop (88), I2S IRQ (95), gadget IRQ (80)
    core 2   Ardour RT-main + AudioEngine dispatcher
    core 3   Ardour RT-1 + emulator (RR 20, below both)

**5. Only then** revisit URB depth, headroom, and period counts. Every
one of them measured null while the interrupt was late; none of them
can be judged until it is not.

## Method note

Two metrics in this document's history turned out to be lies, and both
cost days:

- `pw-top`'s **client** ERR column counts something that is not a
  dropout: the emulator's nodes accrued 1,600/s while its own underrun
  instrumentation stayed silent and the audio was provably clean.
- A **cumulative interrupt total divided by uptime** was quoted as a
  rate and used to argue that channel count drove interrupt load.

The metrics that have never lied: the producer's own underrun
statistics, Ardour's `get_xrun_count`, the driver row's ERR, and the
recorded waveform. Prefer them, in that order.
