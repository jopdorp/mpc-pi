# MPC2000XL event-driven panel UART

## Current implementation

Patch `0019-mpc2000xl-event-driven-panel-uart.patch` replaces the MPC2000XL's
idle 2 MHz front-panel UART scheduling load with causal, event-driven receive
clocking. The original periodic implementation remains available as the
accuracy fallback.

The panel is the uPD78C10 controller that scans pads, buttons, the data wheel
and variation slider. It is not the LCD or the sound DSP. Its TX line feeds the
V53's internal i8251-compatible SCU at 31.25 kbaud with 64x oversampling. The
old driver therefore created two million global scheduler deadlines per
emulated second even while the line was idle.

Event mode analytically advances dormant BRC phase, wakes at the next UART
sample that can change state, and synchronizes panel TX transitions at the
panel CPU's local emulated time. The scheduler also honors a causal timer
boundary inserted by a device that ran earlier in the current timeslice.

The project launcher selects event mode by default for MPC2000XL. Use the
fallback explicitly with:

```bash
MPC_PANEL_MODE=accurate scripts/run-mpc.sh mpc2000xl 32 [MAME options]
```

Standalone MAME defaults to the original path unless
`MAME_MPC_PANEL_EVENT_DRIVEN=1` is set. MPC60 and MPC3000 are unchanged.
PipeWire quantum remains 32 frames and the MAME sound-update cadence remains
16 samples.

## Functional and timing validation

The accurate fallback still produces the canonical Logic-project PCM:

```text
22f76ffaaedc4364b8279a79672a07a35f93997f180b8665e9ef3a576ae176a9
```

Two complete event-mode renders were byte-identical to each other, with SHA:

```text
4673f386a97c26d716b4818ad5de0085b03c932e005c400591fa46ff116f6d98
```

The complete panel receive trace contained the same 1,426 bytes in the same
order. Relative to a periodic control using the same causal CPU order, event
mode's RX-ready timestamps had 0.281 us median offset, 0.5 us p95 absolute
offset and a 0.5 us worst absolute offset: one original BRC edge.

The Logic image's active `LT-BEAT2` sequence is 86.0 BPM at 96 PPQN, not the
file's overridden 120.0 master tempo. At 48 kHz this is 348.837209 samples per
sequencer tick. A DSP key-on trace matched 86 events across 53 tick positions:

- event identity, order, voice channel, sample address and simultaneous-event
  grouping were identical in accurate and event modes;
- after one constant start offset was removed, accurate mode's theoretical
  grid error was 15.43 samples median absolute, 36.82 samples p95 and 49.05
  samples / 1.022 ms worst;
- event mode measured 15.98 samples median absolute, 33.10 samples p95 and
  41.92 samples / 0.873 ms worst;
- event versus accurate mode differed by at most 40.75 samples / 0.849 ms
  after each mode's constant offset was removed.

The speed path therefore preserves sequence content and stays inside the
existing firmware/emulation timing envelope; it did not worsen p95 or
worst-case theoretical event timing in this trace. This metric concerns sample
trigger instants. Once triggered, sample playback remains on the continuous DSP
audio clock and does not inherit panel or sequencer event jitter.

The repeatable comparator is
`scripts/diagnostics/compare-mpc-keyon-timing.py`. Its expected-event input is
produced by `scripts/diagnostics/dump-mpc2000xl-all.cpp`; traces are temporary
diagnostic builds that log `control_w()` DSP key-ons at a 48 MHz timestamp.

Key artifacts:

- `results/diagnostics/mpc-panel-optional-accurate-pcm-j4k3rq`
- `results/diagnostics/mpc-panel-optional-event-final-pcm-cRUvVC`
- `results/diagnostics/mpc-panel-causal-logic-rx-oslog-U5tr2F`
- `results/diagnostics/mpc-panel-causal-periodic-logic-rx-gWGQF4`
- `results/diagnostics/mpc-keyon-theoretical-tsrzqZ`

A final interactive A/B used the Logic project with the PipeWire graph forced
to 32 frames, MAME scheduled on performance cores 1-4, the full OpenGL panel
layout, and an MPD18 connected to MAME's MIDI input. Event mode played
correctly, panel and pad interaction remained responsive, and produced fewer
audible xruns than the accurate-mode control. Earlier apparent slow panel
response was not reproducible after removing the confounding 1024-frame
PipeWire graph and slow-core pinning.

## Performance

A matched release-binary comparison on CPU 20, with the same complete
42.9-second Logic workload and no buffer/cadence changes, measured:

| Metric | Accurate | Event | Change |
| --- | ---: | ---: | ---: |
| Task clock | 38,626.43 ms | 30,480.71 ms | -21.09% |
| CPU cycles | 92.60 billion | 72.49 billion | -21.71% |
| Instructions | 262.10 billion | 208.11 billion | -20.60% |
| Average emulation speed | 116.36% | 149.65% | +28.61% |

Artifact: `results/diagnostics/mpc-panel-final-matched-perf-IjrZj4`.

These measurements were taken while the workstation could have unrelated
interactive load. Retired instructions are the most workload-stable comparison;
task time, cycles and throughput nevertheless agree closely.

## Remaining work

- Profile event mode again to select the next MPC-specific hotspot.
- Keep the timing comparator when changing scheduler or device interleaving;
  WAV hashes alone cannot distinguish a constant phase change from jitter.
