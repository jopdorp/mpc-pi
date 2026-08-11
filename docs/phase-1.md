# Phase 1: MAME baseline

This repository builds a focused MAME binary containing the MPC2000XL, MPC3000, MPC60, and MPC60 SCSI drivers. The tested source revision is MAME commit `f8c55f4cdad70fa5b7dfae9a26a15114aea70f9a` (MAME 0.289, 2026-08-10).

All four drivers are currently marked `MACHINE_NOT_WORKING` upstream. MPC60 is also marked `MACHINE_IMPERFECT_SOUND`. Passing the build and metadata tests therefore proves that the drivers are present and executable; it does not prove that an MPC boots or behaves correctly.

The first host result is recorded in [PC baseline: 2026-08-10](results/2026-08-10-pc-baseline.md).

## Build

On Debian or Ubuntu, install MAME's documented build prerequisites first. Qt 6 is optional for this project because the build explicitly disables the Qt debugger.

```bash
./scripts/bootstrap-mame.sh
./scripts/build-mame.sh
```

The build defaults to four parallel jobs. MAME's C++ translation units can use
several gigabytes each; a 16-way rebuild exhausted memory on the 64 GiB test
host. Raise the job count only when memory headroom has been verified:

```bash
MAME_JOBS=8 ./scripts/build-mame.sh
```

The scripts explicitly set `DEBUG=0`. This matters on shells that already export a variable named `DEBUG`, because MAME otherwise silently builds a debug binary named `mpcd` rather than the release binary `mpc`.

The build temporarily applies the repository's MAME compatibility patches and removes them after compilation, keeping the pinned checkout clean. They cover the HD61830 startup guard, Akai DSP voice-state reset, PipeWire audio-clock pacing, and startup-warning automation.

## ROM audit

Do not commit or distribute copyrighted Akai firmware. Put your own legitimate dumps in `roms/` using MAME's usual ZIP layout, then run:

```bash
./scripts/test-mame.sh
./scripts/test-mame.sh --require-roms
```

The first command validates the binary and writes exact ROM manifests under `results/rom-manifests/`. The selected firmware is MPC2000XL 1.20, MPC3000 Vailixi 3.50, and MPC60 SCSI 2.14. The second command additionally fails unless all three selected BIOSes launch successfully.

## First boot and latency settings

After the audit passes, launch the MPC2000XL with a 48-frame native PipeWire period:

```bash
./scripts/run-mpc.sh mpc2000xl 48
```

The launcher selects native PipeWire at 48 kHz. The period sweep is:

| Argument | PipeWire period |
| ---: | ---: |
| `128` | 2.67 ms |
| `64` | 1.33 ms |
| `48` | 1.00 ms |
| `32` | 0.67 ms |

The patched PipeWire path uses a 4 ms prebuffer and makes the audio consumer
the master clock at normal playback speed. Validate it with:

```bash
./scripts/diagnostics/test-mpc2000xl-timing.sh
```

The requested buffer is not end-to-end pad latency. Physical impact-to-analog-output measurement remains necessary because USB polling, pad scanning, emulation, audio scheduling, and the DAC all add delay.
