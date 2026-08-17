> **READ FIRST — every measurement below is suspect (2026-08-17).**
>
> The board was found running the **stock Pi OS kernel**, not the
> PREEMPT_RT build: `uname -v` = `#1 SMP PREEMPT Debian 1:6.18.34-1+rpt1`,
> and `/sys/kernel/realtime` absent. `linux-image-6.18.34+rpt-rpi-2712`
> is installed, and it writes `kernel_2712.img` — the exact filename
> `build-rt-kernel.sh` uses. An apt upgrade overwrote our kernel with the
> stock one. The RT modules were still sitting in
> `/lib/modules/6.12.103-mpcpi-rt+`, unused.
>
> Separately, `/proc/cmdline` read `isolcpus=2-3 threadirqs` — no
> `nohz_full`, no `rcu_nocbs`, no `irqaffinity=0`, no `audit=0`, and
> **core 1 not isolated**, which is the core the audio interrupt is
> pinned to. A netbooting Pi reads `cmdline.txt` over TFTP, so the line
> `tune-realtime.sh` wrote to the board's own `/boot/firmware` was never
> used. That hardcoded TFTP line dates to the netboot script's first
> commit, so it applied for the whole life of the netboot rig.
>
> How much of the work below ran on RT is not yet known. What is known:
> the unexplained xrun tail, and `mpcpi-irq-affinity`'s recorded null
> result, were both measured against isolation that was not in effect.
> Both need re-measuring on a verified RT kernel before their conclusions
> mean anything. Fixed in `board/rpi5/cmdline-tuning` and
> `mpcpi-netboot kernel rt`; see `board/rpi5/cmdline-tuning.md`.

# System placement: everything measured, and what it turned out to mean

Written after six single-variable experiments in a row failed to move a
defect rate. That was the right moment to stop guessing and collect
every number in one place - and doing so found the answer, though not
the one this document first proposed: **the defect was in the
measurement, not in the machine.** The wrong hypothesis is left standing
below, marked, because the path to catching it is the useful part.

Everything below was measured on the board. Nothing here is estimated.

**Bottom line: quantum 32 is met.** Ardour's own xrun counter reads zero
across a ten-minute armed soak with every insert running and the
emulator live; the delivered USB audio is sample-exact over 76 seconds
under the same load. See "What it actually was".

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

## The "defect", and everything that did not fix it

**Read the next section before believing this table.** Every number in
it turned out to be a measurement artifact. It is kept because the
shape of it - six levers, no movement - is what should have prompted
suspicion of the instrument far sooner than it did.

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

## What it actually was: the measurement

**The delivery problem did not exist.** The table above is an artifact,
and the mechanism this document originally proposed - butler NFS writes
delaying the gadget interrupt - was wrong. Both are recorded here
rather than deleted, because the way this went wrong is the useful
part.

Nothing routes the 22-channel map yet, so PipeWire connects every
source it sees to the first available channels. `pw-link -l` on the
running board showed **44 links** from the emulator's `:speaker`,
`:outputs` and floppy-sound nodes into the same gadget channels the
441Hz measurement tone was playing into. The analyser was reading MPC
music summed with a sine and correctly reporting that it is not a sine.

That single artifact explains every null result at once:

- immune to channel count, URB depth, headroom, interrupt placement and
  the tone player's priority - none of those change what is *mixed*
  onto the channel;
- clean whenever no session was loaded - because then no emulator was
  running to mix in;
- one capture read peak 1.000 full-scale (clipping), which is what a
  sum of two sources does and what finally gave it away.

The control: same load, emulator confirmed running on core 3, its 44
links cut so the tone was alone on the wire.

    76 seconds, quantum 32, peak 0.275fs (the tone's own level)
    discontinuities = 0    flat-gaps = 0    rate = 0.00/s

**Quantum 32 delivers clean audio over USB under full emulator load.**
Together with the graph result - Ardour's own xrun counter at zero
across a ten-minute armed soak with every insert running - quantum 32
is met on both sides.

## What still needs doing

1. **Route the 22-channel map.** MPC master to 1-2, MPC individual outs
   to 3-10, DAW master to 11-12, DAW stems to 13-20, ADC direct to
   21-22. Right now everything piles onto the first pair, which is not
   only wrong for the product, it is what made this measurement lie.
2. **Re-measure period depth** down toward 2. Every earlier reading was
   taken through the artifact and means nothing.
3. The placement items below are unproven, not wrong - they were never
   tested, because the thing they were meant to fix was not real.
   Revisit only if a genuine defect appears.

## Method note

Two metrics in this document's history turned out to be lies, and both
cost days:

- `pw-top`'s **client** ERR column counts something that is not a
  dropout: the emulator's nodes accrued 1,600/s while its own underrun
  instrumentation stayed silent and the audio was provably clean.
- A **cumulative interrupt total divided by uptime** was quoted as a
  rate and used to argue that channel count drove interrupt load.

- The **recorded waveform** was believed to be the ground truth that
  could not lie, and in a sense it did not: it faithfully reported that
  the signal was not a sine. What lied was the assumption that the
  channel carried only the test tone. A waveform test is only as good
  as the knowledge of what is routed into it - so check the routing,
  and check the peak level, before trusting the verdict.

The metrics that have held up: the producer's own underrun statistics,
Ardour's `get_xrun_count`, the driver row's ERR, and the recorded
waveform *with its routing verified*. Prefer them, in that order.

The general lesson, which cost most of a day twice over: when many
independent levers all fail to move a number, stop pulling levers and
suspect the number.

## External USB audio interfaces (2026-08-17)

Class-compliant USB audio works with nothing added: `CONFIG_SND_USB_AUDIO=m`
is already in the RT kernel and `snd-usb-audio` enumerates the device on
plug-in. A TI PCM2900C codec came up unprompted as ALSA card 3, full speed,
S16_LE stereo at 32000/44100/48000.

What needed adding was a rule to stop it taking over. The appliance's clock
is a null-audio-sink at a fixed 32-frame quantum and everything else
follows it; a USB interface arrives with an ordinary driver priority and can
win the election, reclocking the entire graph to whatever it can manage.
For a full-speed codec that is nowhere near 32 frames, so the instrument's
latency would come to depend on what someone happened to plug in.

`etc/wireplumber/wireplumber.conf.d/94-mpcpi-external-usb-audio.rules`
allows it, keeps it unsuspended, pins it to driver priority 50, and puts it
in a different `node.group` - driver election is per group, so group
membership is what would let it compete at all. It also gives it a
256-frame period rather than the appliance's 32: forcing 32 on an interface
that cannot meet it produces continuous xruns that look like a fault in the
appliance rather than a mismatch with the accessory.

The match is written against the device's NODES, not the device. Node
properties inside a device rule do nothing - a trap this project has
already paid for once, when a `disable-tsched` fix sat in a device rule and
every measurement for days ran on 1024-frame timer periods.
