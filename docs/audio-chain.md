# The audio chain, stage by stage, and where the gap is made

Every sample the player hears crosses these stages. This document names each
one, the file and function that implements it, what can inject silence there,
and how to measure that stage in isolation. It exists because an entire evening
was spent moving settings around without knowing which stage was failing.

## The chain

| # | Stage | Where | Can it inject silence? |
|---|-------|-------|------------------------|
| 1 | Emulation produces samples | MAME device sound handlers | No - measured clean by `-wavwrite` |
| 2 | Sound manager gathers a host update | `src/emu/sound.cpp`, cadence from patch 0034 | No |
| 3 | OSD sink receives the update | `sound_pipewire::stream_sink_update()` | No - it only pushes |
| 4 | Producer ring, write side | `sound_module::abuffer::push()`, `sound_module.h/.cpp` | Overrun drops OLD audio, not silence |
| 5 | Emulation is paced | `sound_pipewire::main_update()` | No, but it can stall the whole emulator |
| 6 | PipeWire calls back for a cycle | `stream_sink_event_process()` | **YES - three ways, below** |
| 7 | Producer ring, read side | `abuffer::get()` | No - on shortfall it REPEATS THE LAST SAMPLE |
| 8 | Buffer is queued to the server | `pw_stream_queue_buffer()` | Not queueing = silence for that cycle |
| 9 | Server mixes the stream into the sink | PipeWire graph | A stream with no data contributes silence |
| 10 | ALSA sink writes to the device | `alsa_output.*` node, `api.alsa.*` props | Underrun = xrun, and it is counted |
| 11 | usb-audio driver, URBs | `snd-usb-audio` | Missed URB = audible, counted as xrun |
| 12 | The device converts | TI PCM2900C, USB 1.1 full speed | Its own clock, 1ms frames |

## Stage 6 is where the silence is made

Three distinct ways, all in `stream_sink_event_process()`:

**a. No buffer to fill.**

    pw_buffer *buffer = pw_stream_dequeue_buffer(stream->m_stream);
    if(!buffer)
        return;                      // cycle produces NOTHING

Nothing recorded it: `abuffer::get()` is never reached so MAME's underrun
counter does not move, ALSA was fed on time so there is no xrun, and pw-top
shows nothing. Cause: `pw_stream_connect()` was called with the format param
alone and no `SPA_PARAM_Buffers`, leaving the pool at PipeWire's default.
Patch 0045 requests `MAME_PIPEWIRE_BUFFERS` (default 8) and counts every
occurrence. After that change the counter reads **0**.

**b. Prebuffering emits a whole buffer of zeros.**

    if (m_prebuffering && available < m_prebuffer_frames)
        memset(output, 0, ...);

and prebuffering was re-armed on ANY underrun, so a single late frame produced
several milliseconds of digital silence. That is why every measured gap was an
exact multiple of the buffer size. Patch 0045 re-arms only after
`MAME_PIPEWIRE_REARM_AFTER` consecutive short callbacks.

**c. The cushion is too shallow to absorb jitter.** It was `requested +
m_producer_frames` - 96 frames at q64, 2.2ms. Now `MAME_PIPEWIRE_PREBUFFER_QUANTA`
quanta. Measured dropouts against depth: 69 at 96 frames, 35 at 256, 21 at 512 -
each doubling halves them, which is mitigation, not a cure.

## How to measure each stage

**Stage 1, the emulator alone.** `-sound none -wavwrite out.wav`. No PipeWire in
the path at all. Result on the appliance: peak 23317, **0 mid-signal clicks, 0
cadence-multiple gaps** - the emulator's own mix is clean.

**Stage 6-8, what MAME hands the server.** `MAME_PIPEWIRE_CAPTURE_WAV=/path`
records exactly the bytes written into each `pw_buffer`. Note it is flushed when
the stream closes, so MAME must exit cleanly - MAME ignores SIGTERM, so a
`systemctl stop` gives you nothing. Use an autoboot Lua that calls
`manager.machine:exit()`.

**Stage 9-12, what the DAC receives.** Record the sink's MONITOR ports with a
node that has autoconnect disabled, then link explicitly:

    pw-record --properties '{ node.name = "monprobe", node.autoconnect = false }' \
        --channels 2 --rate 44100 /tmp/mon.wav &
    pw-link alsa_output.<device>:monitor_FL monprobe:input_FL
    pw-link alsa_output.<device>:monitor_FR monprobe:input_FR

Count only silence that INTERRUPTS SOUNDING AUDIO - a run of zeros with loud
samples on both sides - and normalise by seconds of sounding audio, because
captures differ in how much of them is musical silence between hits.

## Metrics that lie, and are not to be used

- **`pw-top`'s client ERR column is not a dropout counter.** Recorded already in
  docs/system-placement.md after it cost days: "the emulator's nodes accrued
  1,600/s while its own underrun instrumentation stayed silent and the audio was
  provably clean". It cost another evening here.
- **`pw-record --target <node>` does not record that node**; it records the
  default source. On this appliance that is the codec's microphone, which
  returned peak≈21000 with nothing playing.
- **Raw dropout counts across runs.** Normalise per second of sounding audio, or
  a capture that happens to contain more music will look worse.
- **An empty capture reads as "0 dropouts".** Always print peak and frame count
  alongside; `scripts/diagnostics/probe-mpc-audio.sh` refuses to report a number
  when nothing is linked, for this reason.

## THE DEFECT: the ring runs dry and MAME hides it by repeating samples

Found by ear, after an evening of instrumentation that could not see it.

Two recordings from a single run, played back by the user:

    /tmp/mame-internal.wav   MAME's own mixer via -wavwrite   CLEAN
    /tmp/graph-output.wav    the same audio at :speaker       CRACKLES

So the emulator computes correct samples and the damage is entirely in the
handoff. And the mechanism is not silence at all - which is why every
zero-hunting measurement in this document reported "0 dropouts" while the
player heard a mess.

`src/osd/modules/sound/sound_module.cpp:50` - `abuffer::get()`:

    void sound_module::abuffer::get(int16_t *data, uint32_t samples) noexcept
    {
        ...
        // on underrun, fill buffer with last sample to prevent audible pop
        if(!m_used_buffers) {
            m_delta2 += samples - pos;
            m_underruns++;                                    // line 59
            while(pos != samples) {
                std::memmove(data, m_last_sample.data(),      // line 61
                             m_channels * sizeof(int16_t));

When the ring is short this does not write zeros - it REPEATS THE LAST SAMPLE,
deliberately, to avoid a pop. A repeated sample is not silence, it is a buzz,
and no detector looking for runs of zeros can see it. `m_last_sample` is
maintained on the write side at `sound_module.cpp:145`.

**Measured rate: 6,632 underruns in 10 seconds - 663 per second.** At a
64-frame quantum the graph asks 689 times a second, so the ring is short on
essentially EVERY cycle. This is not jitter and not a rare miss: the consumer is
continuously ahead of the producer, and MAME masks it sample by sample.

The counter is MAME's own, already exposed, and needs no capture and no ears:

    journalctl -u mpcpi-emulator | grep -o "underruns=[0-9]*"

with `MAME_PIPEWIRE_STATS=1`. Clean is ~0. Anything in the hundreds per second
is the crackle, directly.

### The lines that matter

| What | Where |
|------|-------|
| Producer writes into the ring | `pipewire_sound.cpp:1108` (`stream_sink_update` -> `m_buffer.push`) |
| Ring write side, keeps `m_last_sample` | `sound_module.cpp:137-145` |
| Consumer callback | `pipewire_sound.cpp:724` (`stream_sink_event_process`) |
| Consumer takes frames | `pipewire_sound.cpp:815` (`m_buffer.get(output, wanted)`) |
| **The masking** | `sound_module.cpp:50-63` (`abuffer::get`, underrun branch) |
| Pacing that should keep the producer ahead | `pipewire_sound.cpp:1160,1237` (`main_update`, the wait loop) |

The producer writes on EMULATED time and the consumer drains on REAL time, so if
the emulator runs even marginally below realtime the ring can never stay ahead,
and every cushion added downstream only delays the first underrun rather than
preventing the next 663.

### What this retires

Every "0 dropouts" result in the sections above measured the wrong thing. The
cushion sweep (69/35/21) counted zeros that came from the prebuffer memset, not
from the actual defect. Use underruns per second from here on.

## Confirmed by ear, stage by stage

Every step below was judged by listening, not by a counter, after counters had
misled this investigation repeatedly.

| What was played | Result |
|-----------------|--------|
| MAME's mixer output (`-wavwrite`) | CLEAN |
| That same file through the Pi's own DAC | CLEAN |
| `pw-play` of it WHILE MAME ran, same graph/device/quantum | CLEAN - both audible at once, MAME crackling beside it |
| The bytes MAME hands PipeWire (`MAME_PIPEWIRE_CAPTURE_WAV`) | CRACKLES |

Nothing shared can be at fault when two streams sharing all of it behave
differently in the same instant. The corruption is inside MAME, between its
mixer and the buffer it queues.

The mechanism is `abuffer::get()` padding with the last sample - a buzz, not
silence, which is why every zero-hunting measurement here reported success while
the player heard a mess. The capture of the handover contains 146 such runs.

Cushion depth reduces the rate without curing it:

| cushion | underruns/s |
|---------|-------------|
| 4 quanta (256 frames) | 257 |
| 8 quanta (512) | 256 |
| 32 quanta (2048, 46ms) | 56 |

A 46ms cushion cannot be drained 56 times a second by jitter, so something is
actively preventing it from staying filled. The pacing loop is the suspect: it
is already proven not to sleep (it spun a whole core while producing 5.9% of
realtime before being bounded), and it is the only code that deliberately holds
the producer back.

Note also that unthrottled runs report ZERO underruns and still crackle, so
there are likely two mechanisms, not one - the underruns are real damage in the
throttled case, and something else is wrong when the emulator free-runs.

### To get the handover capture

`MAME_PIPEWIRE_CAPTURE_WAV` is written by `write_capture()`, which is only
called from `stream_close()`. MAME ignores SIGTERM, so `systemctl stop` never
produces the file. Use `-seconds_to_run N`, which exits cleanly on its own.

## THE ROOT CAUSE: MAME's audio threads run at the emulation thread's priority

Everything above is a symptom. The cause is in the scheduler, and it is one
line in the launcher.

`scripts/run-mpc.sh` starts MAME as

    exec taskset --cpu-list 3 nice -n .. chrt --rr 20 env .. mpc ..

`chrt` sets the policy of the PROCESS, so every thread MAME creates inherits
SCHED_RR 20, and `taskset` pins them all to one core. Three of those threads
matter:

| thread | what it does |
|--------|--------------|
| emulation thread | runs the machine, ~17% of core 3, runnable almost always |
| effects thread | `sound_manager::run_effects()` - **this** calls `sound_stream_sink_update()`, so it is the audio producer |
| `thread-loop` | PipeWire's client loop - fills and queues the buffers |

**Under SCHED_RR a thread that wakes at EQUAL priority does not preempt the
running one.** It goes to the tail of that priority's runqueue and waits for the
running thread to block or to exhaust its timeslice, and
`/proc/sys/kernel/sched_rr_timeslice_ms` is **100** on this kernel. The
emulation thread almost never blocks, so both audio threads ran only when it
happened to.

`/proc/<tid>/schedstat`, deltas over 10 seconds, all three on core 3 at RR 20:

    tid   comm           ran      waited on runqueue
    873   mpc (emu)   1127.5 ms        0.3 ms
    876   thread-loop   50.9 ms      532.5 ms
    878   mpc (fx)      12.2 ms     1013.3 ms

The consequence is not jitter. It is **loss**: the effects thread handed over
about a tenth of the audio the machine generated, and the rest was never handed
over at all.

### The fix, and what it moved

`board/rpi5/rootfs_overlay/usr/bin/mpc-audio-thread-priority.sh` raises every
MAME thread except the emulation thread to SCHED_FIFO 60, from the unit's
`ExecStartPost`. Audio produced per wall second, as a fraction of realtime,
measured from MAME's own update counters (`mpcpi-realtime-ratio.sh`):

| configuration | realtime | underruns |
|---------------|----------|-----------|
| all threads SCHED_RR 20 | **9.7%** | hundreds/s |
| audio threads SCHED_FIFO 60 | **101.6%** | - |
| settled, audio clock + `-nothrottle` | **99.8%** | **0**, overruns 0, cushion 2112 frames |

At a **64-frame quantum**. And in the codec monitor capture, the defect
signature disappears - held non-zero runs of 513, 449 and 385 frames (one
emulated frame each, 16/14/5 occurrences) become fifteen runs of unrelated
lengths, 5.08% of the stream down to 0.64%:

    before   57 held runs >=48 frames   lengths 513x16, 449x14, 385x5
    after    15 held runs >=48 frames   no repeated length

Responsiveness moved with it: pads driven at a fixed 125 ms interval came back
at a 423 ms median interval before, 106 ms after.

### Why this hid for so long

- **`-wavwrite` was always clean.** It is written by `streams_update()` on the
  EMULATION thread, upstream of the effects thread, so it never saw the loss.
  Every "the emulator's own mix is clean" result above is true and irrelevant.
- **`pw-play` next to MAME was clean.** Of course - `pw-play`'s threads are not
  pinned behind a SCHED_RR emulation thread. That experiment correctly exonerated
  the graph, the sink, the device and the quantum, and pointed inside MAME. It
  just could not point at *which thread*.
- **Every buffer knob half-worked.** Deeper cushions delay the first shortfall,
  which is why each doubling roughly halved the count, and why nothing ever
  reached zero.
- **Underrun counts undercounted.** Once the prebuffer path re-arms it emits
  `memset(0)` buffers, which are not counted as underruns. A monitor capture of
  the broken state was 84% digital silence with the underrun counter reporting a
  few dozen per second.

### The measurement to use

    mpcpi-realtime-ratio.sh 30      # % of realtime the producer actually delivers

Anything below ~99% means audio is being dropped before it ever reaches
PipeWire, and no amount of buffer tuning will help. Check thread priorities
first:

    ps -L -o tid,comm,cls,rtprio,psr,pcpu -p $(pgrep -x mpc)

The emulation thread should be the ONLY `RR 20` row.

## The residual: occasional crackle with Ardour in the graph

Not the old fault returning. The producer is not starving - realtime holds at
98.7% and MAME's own underrun counter stays at 0. What moves is the DEVICE's
xrun count, and only when Ardour is running:

| configuration | realtime | underruns | codec xruns / 25s |
|---|---|---|---|
| MPC only, cushion 2.9ms | 98.7% | 0 | flat |
| + Ardour, cushion 2.9ms | 98.7% | 0 | flat |
| + Ardour, cushion 1.45ms | 98.7% | 0 | +2 |
| + Ardour, cushion 46ms (old) | 98.7% | 0 | +2 |
| Ardour starting | - | 0 | **+148 in one burst** |

So it is audible but rare, it is downstream of MAME, and it tracks Ardour's
presence rather than any buffer depth.

**Leading suspect: priority and pinning, again.** That is what every audio fault
on this appliance has turned out to be, and the placement is not obviously right:

    core 1   PipeWire data-loop.0     SCHED_FIFO 88
    core 2   Ardour RT-main           SCHED_FIFO 77, ~52% of the core
             Ardour AudioEngine       SCHED_FIFO 85
    core 3   MAME emulation thread    SCHED_RR   20
             MAME effects thread      SCHED_FIFO 60
             MAME thread-loop         SCHED_FIFO 60

Ardour's AudioEngine at FIFO 85 is three below PipeWire's data loop and on a
different core, which should be safe - but "should be safe" is exactly the
reasoning that hid the SCHED_RR fault for weeks. What has NOT been measured
here is the runqueue delay of PipeWire's own data loop and of Ardour's engine
thread, only MAME's. `/proc/<tid>/schedstat` on data-loop.0 while Ardour runs is
the next measurement, and the burst of 148 xruns at Ardour STARTUP - when it is
instantiating 27 plugin inserts - suggests a transient overrun rather than a
steady-state one.

Also unmeasured: whether the two are contending below the scheduler, on memory
bandwidth or the USB host controller, which no priority change would fix.

### Still open

- `patches/mame/0046-sound-raise-the-effects-thread-above-emulation.patch` is the
  durable version - it raises the thread where it is created, so no post-start
  `chrt` and no guessing which thread is which. **Written and compile-checked in
  isolation, NOT yet built into the appliance binary.** Until it is, the
  `ExecStartPost` helper is what does the work, and the two are harmless
  together (the helper finds the thread already above the emulation thread and
  leaves it there).
- MAME **segfaults on exit** (status 139) when `-seconds_to_run` ends a run with
  `MAME_PIPEWIRE_CAPTURE_WAV` set. `write_capture()` is called from
  `stream_close()`, so the handover capture is never flushed and that
  measurement is currently unavailable. It does not affect normal operation -
  the appliance never exits that way - but it blocks the one control that would
  settle the residual below.
- `sched_rr_timeslice_ms=100` remains a loaded gun for anything else that ends
  up sharing a priority on a pinned core.
- The remaining ~1.3/s of long held runs in the capture have no repeated length
  and are most likely material, not mechanism - not yet proven against a
  `-wavwrite` control from the same run.

## What each plugin costs

Asked whether lighter or built-in Ardour plugins would buy headroom. Guessing
had already been wrong twice, so: `scripts/daw/bench-plugins.lua`, one track,
plugins added four at a time with a noise generator at the head of the chain,
CPU seconds from `/proc/self/stat` rather than `AudioEngine:get_dsp_load()` -
which reports 0.00% while the process visibly burns a core, because PipeWire
drives the graph and not Ardour.

Percent of one core, per instance:

| plugin                     | each  | in the desk | total |
|----------------------------|-------|-------------|-------|
| lsp mb_compressor_stereo   | 5.04  | x1          |  5.04 |
| dragonfly-reverb           | 2.75  | x1          |  2.75 |
| guitarix gx_amp_stereo     | 2.29  | x2          |  4.58 |
| lsp para_equalizer_x16     | 1.46  | x7          | 10.22 |
| lsp limiter_stereo         | 0.46  | x1          |  0.46 |
| lsp sc_compressor_stereo   | 0.37  | x2          |  0.74 |
| guitarix gx_cabinet        | 0.33  | x2          |  0.66 |
| guitarix gxts9             | 0.21  | x2          |  0.42 |
| ardour a-delay             | 0.17  | x1          |  0.17 |
|                            |       | **19**      | **25.04** |

Candidates priced but not installed: `a-eq` 0.33, `a-comp#stereo` 0.50,
`a-reverb` read -0.58, which is not a negative cost - it is below the noise
floor. Anything under about 0.5 here is "cheap", not a number.

Two results that contradict the reasoning they replaced:

  * **The guitar plugins are not the cheap ones.** gx_amp_stereo is the second
    most expensive per instance in the whole desk.
  * **LSP is not uniformly heavy.** sc_compressor_stereo, at 0.37, is cheaper
    than Ardour's own a-comp. It is the MULTIBAND compressor that costs 5%, and
    the sixteen-band parametric that costs 1.46 x7. Swapping LSP for a-* as a
    family would make one strip slower.

The two measurements agree, which is why the model is worth trusting. At
quantum 64 / 44100 a period is 1451us. Ardour with no plugins measured 231us
(16% of a period); the bench says these 19 plugins cost 25% of a core; and
pw-top reads Ardour at 595us BUSY, B/Q 0.41. 16 + 25 = 41.

Codec xruns over 40s with this desk running: **0**.

### Round two: pricing the replacements

Same harness, empty manifest, COPIES 8 instead of 4.

| candidate                  | each  | replaces               | was  |
|----------------------------|-------|------------------------|------|
| ardour a-eq                | 0.33 / 0.65 | lsp para_equalizer_x16 | 1.46 |
| zamaudio ZaMultiCompX2     | 0.65  | lsp mb_compressor      | 5.04 |
| **dragonfly ROOM**         | 0.15  | **dragonfly HALL**     | 2.75 |
| ardour a-reverb            | 0.15  |                        |      |
| zamaudio ZamVerb           | 0.29  |                        |      |
| guitarix gx_mbcompressor   | 3.65  | (no better)            |      |
| lsp mb_dyna_processor      | 4.77  | (no better)            |      |

The reverb result is the one worth knowing. The plugin costing 2.75% is
Dragonfly HALL; Dragonfly ROOM is the same developer and the same family at
0.15, so this is not the usual trade of character for cycles.

READ THE SMALL NUMBERS AS AN ORDERING, NOT AS MAGNITUDES. a-eq measured 0.33 in
the first run and 0.65 in the second, gx_reverb_stereo read -0.71, and a
negative cost is not a thing. The harness accumulates plugins and diffs CPU
time, so drift lands in whatever is measured next. Anything under about 1% is
"cheap"; the ordering holds, the digits do not.

Which is why the swap was judged end to end instead. Same desk, same quantum,
plugins swapped:

    before   595us BUSY   B/Q 0.41   xruns 0 / 40s
    after    465us BUSY   B/Q 0.32   xruns 0 / 40s

130us, a 22% cut in Ardour's per-period work. The bench predicted about 216us,
so it over-promised by a third - another reason to trust the graph over the
harness.

What is left is mostly gx_amp_stereo at 2.29 x2, and that one is the guitar
sound rather than a tax on it.

## The mixer was never reachable from the panel

Two faults, both silent, both of which read as "Ardour ignores the knobs".

**1. The OSC surface was never enabled.** Ardour's control protocols default to
inactive. Nothing in this project turned OSC on, the Lua API of this build
exposes no way to (`ARDOUR.ControlProtocolManager` does not exist), and setting
`active="1"` in the session file does not do it either. luasession never writes
a user config, so `~/.config/ardour8/` existed with no `config` in it and every
surface stayed at its default. Nothing listened on 3819.

**2. The OSC encoder padded aligned strings by a whole extra word.**

    _pad(b) = b + b"\0" * (4 - len(b) % 4)

When the input is already a multiple of four this adds 4 bytes instead of 0.
Callers pass the string WITH its mandatory null, so an 11-character address
arrives as 12 bytes - aligned - and came back 16. A two-argument type tag,
",if" plus its null, is 4 and came back 8.

`/strip/gain` is eleven characters and takes two arguments, so it was wrong
twice. liblo, which Ardour parses with, drops a malformed packet without a
word. The send succeeded, because a UDP send always succeeds.

Only lengths of 3 mod 4 were affected, and the self-test's two vectors - "/x"
and "/abc" - are not. Worse, the test asserted the bug was correct, with a
comment explaining that an aligned string "still takes a whole extra pad word".
The specification had been written from the defect.

Verified end to end after both fixes: `gain LOOP1 -6.5` on the FIFO, then
`/save_state`, then the session on disk reads

    <Controllable name="gaincontrol" ... value="0.47315126657485962"/>

which is -6.50 dB.
