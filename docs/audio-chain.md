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

## Where it stands

Stage 6a is closed (dropped cycles now 0). 6b and 6c are mitigated and
configurable. The emulator (stage 1) is clean, the device (stages 10-12) reports
zero xruns, and holes were still reaching the DAC at ~20/s of sounding audio
with every MAME zero-writing path disabled - which places what remains between
stage 8 and stage 10, in the server's mixing of a late stream.

The next measurement is the one this document was written to make possible: a
single run capturing `MAME_PIPEWIRE_CAPTURE_WAV` and the sink monitor together,
with the sequencer playing so there is continuous audio to compare. If the two
differ, the loss is in the server; if they match, MAME is queueing late and the
mixer is substituting silence, which is visible as a gap between the callback
timestamp and the graph cycle it belongs to.
