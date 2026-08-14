# Raspberry Pi 5 appliance build

A Buildroot external tree that produces an SD image running the emulator as
an appliance: no desktop, no X11, audio out through a PCM5102A DAC and in
through a PCM1808 ADC, and the panel LCD delivered to a Maschine MK1 over USB.

## Status

The tree is complete and the device-tree overlay compiles, but **no image has
been built yet and nothing has run on hardware**. Treat every section below as
the intended design rather than verified behaviour. The specific things most
likely to need work are listed under "Known unknowns".

## Layout

The external tree lives at the repository root so the patch stack is directly
reachable from the package:

```
external.desc                       BR2_EXTERNAL name MPC_PI
Config.in, external.mk              package registration
configs/mpcpi_rpi5_defconfig        the build configuration
board/rpi5/config.txt               boot configuration and overlays
board/rpi5/cmdline.txt              isolated cores for the emulation thread
board/rpi5/overlays/                mpc-audio-overlay.dts
board/rpi5/post-image.sh            compiles the overlay, stages boot files
board/rpi5/rootfs_overlay/          init script and launcher
package/mame-mpc/                   MAME, cross compiled, with the stack applied
package/mpc-mk1-display/            the MK1 USB display daemon
```

## Building

```bash
git clone https://gitlab.com/buildroot.org/buildroot.git
cd buildroot
make BR2_EXTERNAL=/path/to/mpc-pi mpcpi_rpi5_defconfig
make
```

The image lands in `output/images/sdcard.img`.

## Audio hardware

Both codecs are "dumb": the PCM5102A is strapped by pins and the PCM1808 has
no register map at all, so only the DAC has a driver (`ti,pcm5102a`) and the
ADC is represented by the generic dummy receiver (`linux,spdif-dir`). They
share one I2S bus with the Pi as clock producer, which is what allows playback
and capture at the same rate.

Wiring the overlay assumes, on the Pi 5 40-pin header:

| Pin | Signal | To |
|---|---|---|
| GPIO18 | BCLK | PCM5102 BCK, PCM1808 BCK |
| GPIO19 | LRCLK | PCM5102 LRCK, PCM1808 LRC |
| GPIO21 | DOUT | PCM5102 DIN (playback) |
| GPIO20 | DIN | PCM1808 DOUT (capture) |

The PCM1808 must be strapped to slave mode so it takes the Pi's clocks rather
than driving them.

## Why these settings

**`-ffp-contract=off` is mandatory,** not a preference. The DSP mixes in
float, and allowing the compiler to contract multiply-add pairs changes the
rendered PCM. On the desktop that difference is caught immediately by the
reference render; on the appliance nothing would catch it, so the flag is
pinned in the package.

**PipeWire is required, not optional.** The audio-clock pacing that keeps the
emulator in step with the output is implemented against PipeWire by patches
0004, 0009 and 0011. An ALSA-only image would build and run but would not
have the pacing the whole latency design rests on.

**Cores 2-3 are isolated** in `cmdline.txt` and the launcher pins the emulator
to them, mirroring the desktop measurements which are all taken on isolated
cores.

**The launcher holds `/dev/cpu_dma_latency`.** Deep CPU idle states cost more
wake latency than anything remaining inside the emulator; see
[`host-latency-tuning.md`](host-latency-tuning.md).

## Known unknowns

These are the parts most likely to need iteration, in the order they will
probably bite:

1. **The MAME cross build.** MAME's genie build system wants host tools as
   well as target ones, and `CROSS_BUILD=1` with the overrides in
   `package/mame-mpc/mame-mpc.mk` is the documented shape but has not been
   exercised here. Expect to adjust `OVERRIDE_*`, the Python detection, and
   possibly to add a `host-mame` step for the build-time generators.
2. **The two-DAI-link overlay.** Playback and capture are expressed as two
   `simple-audio-card` links sharing one I2S controller. The overlay compiles,
   but whether the RP1 I2S driver accepts a shared controller across two links
   is unverified; the fallback is a single link with both codecs attached, the
   shape `hifiberry-dacplusadc` uses.
3. **No profile-guided optimisation.** The desktop build gains a large amount
   from PGO, and the profile is x86 and useless here. Either train on target
   or accept the loss initially.
4. **Cortex-A76 is not the A53 the optimisation work assumed.** Patches 0036,
   0038 and 0041 were held back as A53 candidates precisely because
   out-of-order cores hide their benefit. The A76 is out of order, so it may
   behave more like the development desktop. Re-measure before enabling them.
5. **The kernel commit** is inherited from a neighbouring project's working
   Pi 5 build rather than chosen here.

## First bring-up steps

1. Build the image and boot with a serial console on `ttyAMA0`.
2. Check the sound card appears: `aplay -l` should list `mpc-audio`.
3. `speaker-test -D hw:0 -c 2` for the DAC, `arecord -D hw:0 -f S32_LE -c 2`
   for the ADC.
4. Run `/usr/bin/mpc-start.sh` by hand before trusting the init script.
5. Attach the MK1 and start `mpc-mk1-display /dev/shm/mpc-lcd --usb`.
