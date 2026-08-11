# MPC2000XL panel-link optimization handoff

## Parked state

- Branch: `fix/mpc-audio-timing`
- Last implementation commit: `a3a55b4 Cache exact scheduler cycle divisors`
- Repository was clean before this handoff was added.
- Installed `.cache/mame/mpc` is the tested patch-0018 binary.
- Keep PipeWire quantum/buffer at 32 frames and MAME sound cadence at 16
  samples. Do not change those while optimizing the emulator.
- No emulator or profiler processes were left running.

## Root cause found

The MPC2000XL V53 baud-rate counter generates a 2 MHz clock for the internal
front-panel UART: 31.25 kbaud with 64x oversampling. This is neither the LCD
refresh nor either CPU clock. It creates two million global scheduler deadlines
per emulated second and is the main reason `device_scheduler::timeslice()` is
about 35 percent of the profile.

The panel uPD78C10 scans pads, buttons, the wheel and the variation slider, then
sends status bytes to the V53 SCU. The current driver connects only panel TX to
V53 RX. In a 42-second Logic-project trace, the accurate implementation ran
about 84 million BRC callbacks to receive 1,426 useful characters.

## Results worth retaining

An MPC-only direct BRC callback preserved every 0.5 us deadline and produced
the exact reference PCM SHA-256
`22f76ffaaedc4364b8279a79672a07a35f93997f180b8665e9ef3a576ae176a9`.
Interleaved release A/B measurement:

- task time: +0.005 percent
- cycles: -0.417 percent
- instructions: -1.043 percent

Artifact: `results/diagnostics/mpc-v53-direct-brc-abba-E13Vvr`.

This was deliberately not landed: it adds machinery but leaves the dominant
2 MHz scheduling cadence intact.

## Rejected event-bus prototypes

All of these were deterministic unless noted, but none matched the reference
PCM or its event spacing, so none should be committed:

- Decode and inject a character immediately at the stop bit.
- Decode with a 31.25 kHz driver heartbeat.
- Schedule receipt 304 us after the start bit. This version was not
  deterministic because the main CPU could reach the event before the panel
  CPU had decoded all bits.
- Schedule receipt 16 us after the decoded stop bit. Deterministic, but changed
  musical event spacing.
- Batch the real i8251 receive clocks at panel transitions and schedule receive
  completion from the remaining i8251 clock count. Deterministic, but changed
  event spacing.
- Combine that batched receiver with a driver-level 31.25 kHz heartbeat. Its
  phase began at machine time zero rather than V53 BRC enable and correspondence
  became worse.

Relevant artifacts:

- `results/diagnostics/mpc-panel-character-bridge-pcm-7XGyA1`
- `results/diagnostics/mpc-panel-event-304us-pcm-K4kyAw`
- `results/diagnostics/mpc-panel-event-stop16us-pcm-e9oYsE`
- `results/diagnostics/mpc-panel-batched-brc-pcm-79Sypg`
- `results/diagnostics/mpc-panel-bit-quantum-batched-brc-pcm-2FBFH4`

The measured accurate path showed panel TX write-to-V53 receive varying with
transmitter occupancy, while actual start-bit-to-receive timing clustered
around 299.47, 302.47 and 304.47 us. The variation comes from cross-CPU
scheduling/local-time phase, so a guessed fixed delay is not acceptable.

## Next candidate, not yet built or tested

Temporary source tree: `/tmp/mpc-mame-patch-stack-2hIyCX`.

The last edit, made immediately before parking, moves the reduced cadence into
the V53 BRC itself so it starts at the original BRC-enable time and preserves
the exact 0.5 us phase. It schedules one callback every 32 BRC ticks (16 us),
and each callback advances all 32 real i8251 clocks. Panel TX transitions also
advance the same phase-tracked receiver before changing RXD. This should reduce
global scheduler cadence 32x while keeping the real i8251 framing and status
logic.

This candidate has **not been built or run**. Resume with:

1. Build `/tmp/mpc-mame-patch-stack-2hIyCX/mpcd` with the same make arguments
   used in this session.
2. Run two deterministic Logic-project renders.
3. Require both renders to match each other and the reference SHA above.
4. If exact, run release ABBA and a cycle profile before turning it into patch
   0019.
5. If not exact, test phase-correct BRC batch sizes 16, 8, 4 and 2 ticks to find
   the lowest scheduler cadence that remains bit-exact. Do not relax the PCM,
   audio-jitter, MIDI-timing or panel-input latency gates.

The eventual speed path should remain explicitly MPC2000XL-opt-in, with the
original bit-clock implementation available as the accuracy fallback.
