# Host latency tuning

Everything here is outside the emulator. Once the emulated machine and its
audio path are tight, the remaining input-to-sound delay is dominated by host
behaviour, and some of it costs more than anything left inside MAME.

## The chain, end to end

A pad hit on an external controller reaches the speakers through these stages.

| Stage | Cost | Where it is controlled |
|---|---|---|
| Controller scan and USB transmission | ~1-3 ms | device firmware; not tunable |
| Kernel USB/ALSA delivery | ~0.1-1 ms | host, see below |
| **CPU wake from deep idle** | **up to 310 us** | **host, see below** |
| MAME MIDI input poll | 1500 Hz stock, up to 0.67 ms | `MAME_MPC_MIDI_POLL_HZ` (patch 0043) |
| Panel-link injection | ~0 | already synchronous (patch 0020) |
| Firmware pad handling | emulated, compressed by emulation speed | - |
| DSP DMA pacing | one word per 64 DSP clocks | `MAME_MPC_DSP_DMA_TURBO` (patch 0043) |
| Sound update cadence | 0.36 ms at 16 frames | `MPC_SOUND_UPDATES_PER_QUANTUM` (patch 0034) |
| PipeWire quantum plus margin | ~1.1 ms at 32/44100 | launcher forces the graph |
| DAC | ~1 ms | hardware |

## CPU idle states

This is the largest host-side item and it is easy to miss. Measured on the
development machine (Core Ultra 7 155H):

```
$ for s in /sys/devices/system/cpu/cpu0/cpuidle/state*/; do \
      printf "%s exit=%sus\n" "$(cat $s/name)" "$(cat $s/latency)"; done
POLL exit=0us
C1E  exit=1us
C6   exit=140us
C10  exit=310us
```

A core that has dropped into C10 between events needs 310 us to come back,
which lands directly in the input path and in the audio callback's deadline.

The per-process fix is to hold `/dev/cpu_dma_latency` open with a value of 0
for as long as the session runs; the kernel then keeps the cores out of any
state whose exit latency exceeds that. `scripts/run-mpc2000xl-turbo.sh` does
this automatically **if the device is writable**, and prints a notice if it is
not. The device is root-only by default:

```
crw------- 1 root root 10, 260 /dev/cpu_dma_latency
```

Grant access once, persistently, with a udev rule:

```bash
sudo tee /etc/udev/rules.d/99-cpu-dma-latency.rules >/dev/null <<'EOF'
KERNEL=="cpu_dma_latency", GROUP="audio", MODE="0660"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger /dev/cpu_dma_latency
# make sure your user is in the audio group, then log out and back in
sudo usermod -aG audio "$USER"
```

Verify with `ls -l /dev/cpu_dma_latency` and by launching the turbo preset,
which reports `CPU deep idle: held off through /dev/cpu_dma_latency`.

The blunt alternative disables the deep states globally until reboot:

```bash
sudo cpupower idle-set -D 0
```

That costs idle power across the whole machine, so the per-session hold is
preferable.

## CPU governor

`powersave` is the default on many distributions and ramps more slowly out of
idle. For a latency-led session:

```bash
sudo cpupower frequency-set -g performance
```

Check the current setting with:

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
```

## Things already in good shape

Worth checking, but they were already correct on the development machine:

- **USB autosuspend.** `/sys/bus/usb/devices/*/power/control` reading `on`
  means the device is never suspended, so there is no wake delay. `auto`
  would be worth changing for a controller you play.
- **Realtime limits.** `ulimit -r` reporting 95 means the launcher can take
  the `SCHED_RR` priority it asks for. If it reports 0, add an
  `/etc/security/limits.d` entry granting `rtprio` to your user or the audio
  group.
- **PipeWire graph.** The launcher forces quantum and rate for the session and
  restores the previous settings on exit, so no persistent configuration is
  needed.

## What is not worth changing

- **Threaded IRQs** (`threadirqs` on the kernel command line) only help if you
  then raise the priority of the specific USB interrupt thread, and the
  default hardirq path is already fast. Measure before adopting it.
- **Polling MIDI faster than the device sends.** A USB MIDI controller
  produces a message when a pad is struck; polling far above that rate only
  burns CPU. 8000 Hz already reduces the emulator's contribution to 0.125 ms,
  well under the device's own scan interval.
