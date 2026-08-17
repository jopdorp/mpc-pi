# Why the appliance cannot run below a 1024-frame quantum yet

The Raspberry Pi appliance plays cleanly at a 1024-frame quantum (23 ms) and
glitches at anything smaller. The development host runs the same emulator, the
same patches and the same interface at 32 frames. This is what the difference
actually is, measured rather than argued, because a whole evening was lost to
plausible explanations that measurement then refuted.

## The instrument's own account

`MAME_PIPEWIRE_STATS=1` makes the PipeWire module report. With `-throttle`:

    PipeWire: late main audio update: gap_us=9970,  queued=32, update=56037
    PipeWire: late main audio update: gap_us=10980, queued=64, update=56054
    PipeWire: late main audio update: gap_us=11184, queued=0,  update=56071

The update counter advances by 17 between reports, so the cadence patch is doing
its job: seventeen 32-frame updates is 544 frames, about 11 ms of audio, which
is the correct average rate. But all seventeen arrive **together**, and then
nothing for ~10.9 ms. 10.9 ms is 91.7 Hz - the mpc2000xl's emulated frame
period. MAME emulates one machine frame, emits that frame's audio in a burst,
and sleeps to the next frame boundary.

The average production rate is right. The distribution is frame-shaped.

## Why that breaks a small quantum

The output cushion is sized in
`0011-pipewire-keep-one-producer-update-of-margin.patch` as

    m_prebuffer_frames = max(m_prebuffer_frames, requested + m_producer_frames)

one graph quantum plus one producer update. `m_producer_frames` is the SIZE of
a write, never the INTERVAL between writes. At a 64-frame quantum with a
32-frame cadence that is 96 frames of cushion - 2.2 ms - against a burst gap of
~485 frames. The consumer drains the ring, underruns, and the callback then
re-arms prebuffering:

    if (m_prebuffering && available < m_prebuffer_frames)
        memset(output, 0, ...);          // silence while refilling
    else {
        m_buffer.get(output, requested);
        if (underruns changed)
            m_prebuffering = true;       // re-arm
    }

so it emits silence until the producer's next burst. The captured audio shows
exactly that cycle: ~128 valid samples followed by ~1536 zeros, a 7.7% duty
cycle matching the 7.6% non-zero measured in the capture.

True dropouts - silence interrupting SOUNDING audio, counted by
`scripts/diagnostics/probe-mpc-audio.sh`, not musical silence:

| quantum | cadence | cushion | true dropouts |
|---------|---------|---------|---------------|
| 64      | 32      | 96      | 102 (11.2/s)  |
| 512     | 512     | 1024    | 28            |
| 1024    | 1024    | 2048    | **0**         |

q1024 works only because the quantum finally exceeds one emulated frame. It is
a retreat, not a solution: 23 ms is unusable for playing.

## The actual blocker: pacing starves the emulator

`-nothrottle` with `MAME_PIPEWIRE_AUDIO_CLOCK=1` is how the host runs, and it is
the right shape - MAME never sleeps in frame chunks, the audio buffer paces it,
and writes spread evenly. On this board it does not work, and the reason is NOT
that pacing fails to engage. It engages, and then over-waits:

    PipeWire: audio clock: generated=256032, queued=32, wall_us=98787579
    PipeWire: audio clock: generated=272032, queued=64, wall_us=104988636

+16000 frames in 6.20 s of wall clock. 16000 frames is 0.363 s of audio, so the
emulator is generating at **6% of realtime** while pacing is active. Unthrottled
it simultaneously pins its core at 100% CPU with 98 ms dropouts.

So the pacing wait in
`0004-pipewire-audio-clock-and-low-latency-buffer.patch` /
`0009-pipewire-use-primary-output-as-audio-clock.patch` is wrong on this target.
Fixing it is the path to a small quantum. Deepening the prebuffer is not: it
would convert dropouts into 23 ms of latency sitting in front of the DAC - the
same latency as q1024, only hidden.

## What was ruled out, so nobody re-runs it

Each of these was measured and is not the cause: the codec's ALSA buffers; the
sample rate; the graph quantum on its own; the emulator's CPU (13-16% of one
core); MAME's own underflow counters (zero); PipeWire's realtime priority
(raising data-loop.0 to SCHED_FIFO 88 changed nothing); PipeWire's core
placement (moving it to isolated core 1 changed nothing); the Maschine's USB
traffic and its 1637 interrupts/second; the codec's IRQ placement and priority
(moving IRQ 137 and its thread to an idle isolated core changed nothing);
duplicate emulator instances (there is exactly one); whether the patched binary
was in use (all 17 gates are compiled in and MAME logs them active); timer
resolution (a 1 ms sleep takes 1.097 ms on this RT kernel); and NFS (the root is
on SD).

## Two constraints worth not rediscovering

`api.alsa.disable-tsched = true` makes PipeWire follow the device's period
interrupts, and then **the quantum must not exceed period-size**. Quantum 1024
against a 512-frame period does not degrade - it stops the graph dead, every
node reporting `QUANT 0 / RATE 0`, and the appliance goes silent with nothing
logging an error.

`api.alsa.headroom` must stay well under `period-size x period-num`. At 128 x 3
with headroom 256, PipeWire had 128 usable frames out of 384.

## Correction: pw-top's client ERR column is not a dropout counter

Most of the numbers in the sections above are `pw-top`'s ERR column on the
emulator's node, and docs/system-placement.md already records - from an earlier
investigation that cost days - that this column counts something which is not a
dropout: "the emulator's nodes accrued 1,600/s while its own underrun
instrumentation stayed silent and the audio was provably clean". That document
was not read until late in the evening. Treat every ERR figure here as
suspect and use the capture below instead.

## The measurement that does hold: capture the codec's monitor ports

Record what the DAC actually receives, with an autoconnect-disabled node
explicitly linked to `alsa_output.<device>:monitor_FL/FR`, and count only
silence that interrupts SOUNDING audio. On the appliance at q64 that gives

    7.81s captured, 69 dropouts, EVERY ONE exactly 64 samples

One graph quantum each, ~9 per second, while ALSA xruns were zero and the
emulator ran above realtime at 15% of a core. Neither end is failing: the
callback is handed a cycle with nothing ready and emits a buffer of silence.

Depth helps but does not cure, which is how we know it is not jitter:

| output cushion        | dropouts |
|-----------------------|----------|
| 96 frames (2.2ms)     | 69       |
| 256 frames (5.8ms)    | 35       |
| 512 frames (11.6ms)   | 21       |

Each doubling halves them. That is the same latency-for-dropouts trade as
raising the quantum, not a fix. Aligning the producer cadence to exactly one
quantum (MPC_SOUND_UPDATES_PER_QUANTUM=1) roughly halves the rate again, per
second of sounding audio - counts must be normalised that way, because captures
differ in how much of them is silence between pad hits.

What remains unexplained: why the producer misses a discrete cycle ~9 times a
second while running above realtime on an idle core. The next measurement is
inside MAME - instrument stream_sink_update to record the wall-clock interval
between writes and correlate it with the callback that found the ring empty.

## Measuring this again

    # true dropouts, not musical silence
    scripts/diagnostics/probe-mpc-audio.sh 8

    # MAME's own view: burst gaps and the realtime ratio
    systemctl edit mpcpi-emulator   # Environment=MAME_PIPEWIRE_STATS=1
    journalctl -u mpcpi-emulator -f | grep -E "late main audio|audio clock:"

The realtime ratio from consecutive `audio clock:` lines - generated frames
divided by 44100 x elapsed wall seconds - is the single number that says whether
the emulator is keeping up. It only appears while the audio clock is the timing
master; with `MAME_TIMING_MASTER=video` there is no pacing and no report.
