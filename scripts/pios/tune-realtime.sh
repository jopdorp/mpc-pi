#!/bin/bash
# Make the appliance behave like an instrument, not a computer.
#
# "Stable" here does not mean "usually fine". One xrun in a take ruins the
# take, so the target is bounded worst-case scheduling latency, and
# verify.sh measures it rather than trusting this script.
#
# Every setting below is a specific defence against a specific source of
# jitter. Where a setting is a trade, the trade is named.
#
#   sudo ./tune-realtime.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
BOOT="/boot/firmware"; [ -d "$BOOT" ] || BOOT="/boot"
log() { printf '\n== %s\n' "$*"; }

log "cpu frequency"
# Frequency scaling is a latency source twice over: the governor's own
# sampling work, and the transition itself. An instrument would rather
# burn watts than miss a deadline.
apt-get install -y --no-install-recommends cpufrequtils >/dev/null 2>&1 || true
echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
	[ -w "$c" ] && echo performance > "$c" 2>/dev/null || true
done
systemctl enable cpufrequtils >/dev/null 2>&1 || true

# Our own unit as well, because the package's did not survive a reboot:
# the board came back on "ondemand" at 1.8GHz instead of 2.4GHz. That is
# a quarter of the clock missing, and worse for a tail than for a mean -
# every frequency transition is itself a stall, so an instrument pays
# twice for scaling it never wanted.
#
# The same unit pins /dev/cpu_dma_latency to 0 for as long as it runs.
# Writing the file is not enough: the constraint lives only while the fd
# is open, which is why cyclictest opens it and why holding it is a
# service rather than a setting. Deep idle states cost microseconds to
# leave, and a core that idles between 726us callbacks takes that hit
# every single period.
cat > /usr/local/sbin/mpcpi-latency-hold <<'HOLD'
#!/usr/bin/env python3
"""Hold the CPU out of deep idle, and the governor at performance."""
import os
import time

for cpu in range(os.cpu_count() or 4):
    path = "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor" % cpu
    try:
        with open(path, "w") as f:
            f.write("performance")
    except OSError:
        pass

# The constraint is released when this descriptor closes, so the process
# must stay alive. It costs nothing while it sleeps.
try:
    fd = os.open("/dev/cpu_dma_latency", os.O_WRONLY)
    os.write(fd, b"\x00\x00\x00\x00")
except OSError:
    fd = None

while True:
    time.sleep(3600)
HOLD
chmod 0755 /usr/local/sbin/mpcpi-latency-hold
cat > /etc/systemd/system/mpcpi-latency-hold.service <<'UNIT'
[Unit]
Description=Pin the governor and hold the CPU out of deep idle
After=basic.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/mpcpi-latency-hold
Restart=always
CPUAffinity=0

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now mpcpi-latency-hold >/dev/null 2>&1 || true
echo "  governor: performance, pinned by mpcpi-latency-hold"

log "kernel cmdline"
CMD="$BOOT/cmdline.txt"
# Strip each key before setting it, never append-if-absent. The old
# add_cmd tested for the exact string, so once the isolation widened
# from two cores to three this file would have appended isolcpus=2-3
# next to the isolcpus=1-3 already there - two values for one key on one
# command line, with the kernel taking whichever it parsed last. A
# tuning script that can silently un-tune the board is worse than none.
#
# Cores 1-3 are the audio side: PipeWire's data loop alone on 1, the
# graph's workers on 2-3. Core 0 keeps every interrupt and the whole of
# userspace - which is also why the audio interrupt is moved off it
# afterwards, see mpcpi-irq-affinity.
#
# nohz_full stops the scheduler tick on those cores and rcu_nocbs moves
# RCU callback work off them; without both, isolcpus still leaves
# periodic interruptions that show up as occasional long cycles.
WANT="isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3 irqaffinity=0 threadirqs audit=0"
line=$(tr -d '\n' < "$CMD")
for key in isolcpus nohz_full rcu_nocbs irqaffinity threadirqs audit; do
	line=$(printf '%s' "$line" | sed -E "s/(^| )$key(=[^ ]*)?//g")
done
printf '%s %s\n' "$line" "$WANT" | tr -s ' ' > "$CMD"
echo "  cmdline: $WANT"

log "units that never finish"
# Boot did not complete. `systemd-analyze` answered "Bootup is not yet
# finished" on a board that had been up for an hour and three quarters,
# and `systemctl list-jobs` showed why: userconfig.service still
# RUNNING, with multi-user.target, cloud-init.target, cloud-final and
# graphical.target all queued behind it.
#
# userconfig is Raspberry Pi OS's first-boot account setup. It waits on
# a console that an appliance never answers, so it waits forever. Every
# ssh session all day printed its banner - "SSH may not work until a
# valid user has been set up" - which states the problem exactly, and
# which was filtered out as noise every single time.
#
# systemd-networkd-wait-online is the second one, burning 2min 388ms
# before timing out. This board netboots: the kernel brings the
# interface up for the NFS root before userspace starts, so there is
# nothing to wait for. It is also why network-online.target never
# activates, which silently swallowed the netconsole unit until that
# was ordered After=basic.target instead.
#
# cloud-init has no role on a fixed-function instrument and costs
# 4.5 seconds.
systemctl disable --now userconfig.service >/dev/null 2>&1 || true
systemctl mask userconfig.service >/dev/null 2>&1 || true
systemctl disable --now systemd-networkd-wait-online.service >/dev/null 2>&1 || true
systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true
for u in cloud-init cloud-init-main cloud-init-local cloud-config cloud-final; do
	systemctl disable --now "$u.service" >/dev/null 2>&1 || true
done
echo "  userconfig, networkd-wait-online and cloud-init disabled"

log "swap and memory"
# Swap is unbounded latency. An instrument that swaps has already failed.
systemctl disable --now dphys-swapfile >/dev/null 2>&1 || true
swapoff -a 2>/dev/null || true
sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=0/' /etc/dphys-swapfile 2>/dev/null || true
cat > /etc/sysctl.d/95-mpcpi-rt.conf <<'EOF'
# Transparent hugepages compact memory in the background, which is a
# multi-millisecond stall at exactly the wrong moment.
vm.swappiness = 0
# Let the audio processes lock what they need.
vm.max_map_count = 262144
# Do not let dirty page writeback build into a burst that stalls a core.
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
# The RT throttle exists to stop a runaway RT task wedging the box. Ours
# is the whole point of the box, so give it the full slice minus a hair
# rather than disabling the safety net entirely.
kernel.sched_rt_runtime_us = 980000
EOF
sysctl --system >/dev/null 2>&1 || true
echo "  swap off, THP/dirty tuned, RT throttle 98%"

if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
	echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
fi

log "usb and power"
# USB autosuspend wakes devices mid-stream; on an audio interface or the
# Maschine that is an audible glitch.
cat > /etc/udev/rules.d/95-mpcpi-usb.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
EOF
echo "  usb autosuspend disabled"

log "pipewire"
# Quantum is the single biggest latency lever, and forcing it stops
# clients renegotiating it mid-session, which is itself a glitch.
install -d /etc/pipewire/pipewire.conf.d
cat > /etc/pipewire/pipewire.conf.d/95-mpcpi.conf <<'EOF'
context.properties = {
    # 44100, because the MPC2000XL is a 44.1kHz machine and always was.
    # A 48k graph puts a resampler in front of every emulator channel -
    # CPU we are trying to save and latency we are trying to remove, to
    # convert audio that started at 44.1 back toward 44.1 at the DAC.
    # allowed-rates keeps a client from renegotiating the graph to 48k
    # mid-session, which is a glitch and a silent resampler both.
    default.clock.rate          = 44100
    default.clock.allowed-rates = [ 44100 ]
    # 32 samples, 725us, and nothing else. Quantum 48 existed as a
    # fallback while 32 looked unreachable; every reason for it has
    # since been measured away:
    #
    #   * the "delivery defects at 32" were a measurement artifact -
    #     the emulator's audio summed onto the test tone's channels;
    #   * the "sessions die at 32" was a kernel panic in the DAC-less
    #     I2S card, now disabled at the overlay;
    #   * the ~1ms DMA service floor belonged to that same phantom card
    #     and left the graph with it.
    #
    # What remains is the measurement that matters: the FULL desk - 27
    # inserts, sixteen tracks armed, all eight MPC individual-out tracks
    # active, emulator live - at quantum 32, with Ardour's own xrun
    # counter reading +0 across eleven consecutive reports and the
    # driver logging zero errors in every window.
    #
    # Pinning min and max to 32 as well, so no client can renegotiate
    # the graph out from under the instrument mid-take.
    default.clock.quantum       = 32
    default.clock.min-quantum   = 32
    default.clock.max-quantum   = 32
}
context.modules = [
    { name = libpipewire-module-rt
      args = {
          nice.level    = -19
          rt.prio       = 88
          rt.time.soft  = -1
          rt.time.hard  = -1
      }
      flags = [ ifexists nofail ]
    }
]
EOF
echo "  44.1k, quantum 32 fixed, RT prio 88"

log "irq affinity"
# Best effort now, and persisted for boot. The helper is a real file
# rather than a heredoc so it can be read, diffed and run on its own -
# it is the change most likely to need re-measuring.
install -m 0755 "$(dirname "$0")/mpcpi-irq-affinity" \
    /usr/local/sbin/mpcpi-irq-affinity
chmod 0755 /usr/local/sbin/mpcpi-irq-affinity
cat > /etc/systemd/system/mpcpi-irq-affinity.service <<'EOF'
[Unit]
Description=Give the audio interrupt its own core and priority
# NOT After=multi-user.target: this unit is WantedBy that same target, so
# ordering after it is a deadlock - the job sits queued forever and
# `is-enabled` cheerfully reports "enabled" while nothing has ever run.
# basic.target is late enough that the devices exist and early enough
# that it actually fires.
After=basic.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mpcpi-irq-affinity
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now mpcpi-irq-affinity.service >/dev/null 2>&1 || true
echo "  audio IRQ alone on core 1 at prio 95; everything else on core 0"

echo
echo "Reboot required for cmdline changes. Then measure, do not assume:"
echo "  sudo ./verify.sh"

log "ardour: threads and cores"
# isolcpus=2-3 removes those cores from every process's default affinity
# mask, so nproc reports 2 on a four-core board and Ardour ran entirely
# on cores 0-1 - the housekeeping cores that carry every device IRQ -
# while the two cores isolated FOR audio sat idle. Isolation keeps things
# out; it does not put anything in.
#
# Measured on the shipped session at quantum 48, changing only affinity:
#   cores 0-1   943us  B/Q 0.87      (what it was doing)
#   cores 1-3   799us  B/Q 0.73
#   cores 2-3   761us  B/Q 0.70
#
# And thread count is not "more is better". Two DSP threads on two cores
# is the best of 2/3/4; three and four both regress, because the extra
# threads contend for the same two cores and each handoff is a
# synchronisation point inside the callback:
#   threads=2  q48 B/Q 0.74     threads=3  q48 over     threads=4  q48 0.91
install -d /home/mpc/.config/ardour8
cat > /home/mpc/.config/ardour8/config <<'ACFG'
<?xml version="1.0" encoding="UTF-8"?>
<Ardour version="8.0.0">
  <Config>
    <Option name="processor-usage" value="2"/>
    <Option name="plugins-stop-with-transport" value="0"/>
  </Config>
</Ardour>
ACFG
chown -R mpc:mpc /home/mpc/.config/ardour8 2>/dev/null || true
echo "  processor-usage=2; run Ardour with taskset -c 2-3"

log "audio on the isolated cores"
# isolcpus reserves cores 2-3, but reservation only keeps things OUT:
# nothing lands there unless placed. Measured before this existed: the
# graph's RT data loops sat on cores 0-1 with every device IRQ and the
# whole of userspace, the isolated cores idled, and a 29-plugin session
# logged 15 xruns in 30 seconds while cyclictest on the empty core 3
# reported a flawless 13us. The tuning was real; the audio just was not
# where the tuning was.
for u in pipewire wireplumber; do
	install -d "/etc/systemd/user/$u.service.d"
	cat > "/etc/systemd/user/$u.service.d/mpcpi-affinity.conf" <<'UNIT'
[Service]
# Core 1 alone: the data-loop is one RT thread and wants one quiet core
# to itself. Sharing 2-3 with Ardour's two DSP workers put three RT
# threads on two cores, which showed up as a tail - mean B/Q 0.78 at
# quantum 32 while xruns ran at 15/s.
CPUAffinity=1
UNIT
done
echo "  pipewire + wireplumber pinned to core 1 (user units)"

log "jack clients get realtime too"
# PipeWire's own loops had RT 88 while every pipewire-jack client ran
# its data loop - the thread the process callback lives in - at
# SCHED_OTHER, because Debian's jack.conf loads no module-rt. Ardour's
# AudioEngine thread asks for RT itself and got 83; the pw- threads
# feeding it did not, and they are where the deadline actually lands.
install -d /etc/pipewire/jack.conf.d
cat > /etc/pipewire/jack.conf.d/95-mpcpi-rt.conf <<'EOF2'
context.modules = [
    { name = libpipewire-module-rt
      args = { nice.level = -19 rt.prio = 85 rt.time.soft = -1 rt.time.hard = -1 }
      flags = [ ifexists nofail ]
    }
]
EOF2
echo "  module-rt in jack.conf.d (prio 85)"

log "i2s card as the appliance sink"
# The PCM5102A is on ALSA device 1 (the PCM1808 ADC is device 0), and
# ALSA Card Profile builds no output profile for a simple-card shaped
# that way: the card offered exactly two profiles, "off" and
# "input:stereo-fallback", so the DAC had no PipeWire node and the
# instrument had no sink at all. With no sink the graph has no clock,
# nothing processes, and every DSP measurement reads a truthful,
# useless 0.0%.
#
# use-acp=false skips profile inference and exposes each PCM directly,
# which is what a fixed-function board wants anyway - there is nothing
# to infer, the hardware is known and soldered.
install -d /etc/wireplumber/wireplumber.conf.d

# ---------------------------------------------------------------------
# The audio graph's shape, in four fragments. All four are required and
# each one is here because its absence was measured.
#
# There is NO hardware clock on this appliance. The I2S card is disabled
# in config.txt (no DAC is wired, and the overlay's DMA driver panics
# the kernel), so the only real device is the USB gadget - and a gadget
# must not drive, because its cycle follows whatever the connected
# computer does. Measured: with the gadget as driver, Ardour ran at
# 362-1037% load. So the graph is clocked by a timer.
# ---------------------------------------------------------------------

# 1. The clock. A null sink, driven by PipeWire's own timer on the RT
#    kernel with the CPU held out of deep idle. It never touches
#    hardware, so it cannot underrun and cannot be taken down by a
#    device error. priority.session keeps it the DEFAULT sink too,
#    which matters more than it sounds: PipeWire connects any stream
#    with no explicit route to the default sink's first free channels,
#    and when that was the gadget, 44 links from the emulator piled onto
#    the channels a measurement was using and produced a day of phantom
#    defects. Strays now land on a node that goes nowhere.
install -d /etc/pipewire/pipewire.conf.d
cat > /etc/pipewire/pipewire.conf.d/95-mpcpi-clock.conf <<'PWCLK'
context.objects = [
  { factory = adapter
    args = {
        factory.name     = support.null-audio-sink
        node.name        = "mpcpi-clock"
        node.description = "MPC-Pi graph clock"
        media.class      = "Audio/Sink"
        audio.position   = [ FL FR ]
        audio.rate       = 44100
        priority.driver  = 5000
        priority.session = 2000
        node.group       = "mpcpi-audio"
        node.always-process = true
        monitor.channel-volumes = false
    }
  }
]
PWCLK

# 2. One scheduling group. PipeWire elects a driver PER GROUP, so
#    without this the null sink drives only itself while every hardware
#    node forms its own island - which is exactly what happened, and
#    looked like the clock simply being ignored.
cat > /etc/wireplumber/wireplumber.conf.d/97-mpcpi-driver.conf <<'WPGRP'
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_.*" } ]
    actions = { update-props = {
        node.group = "mpcpi-audio"
        priority.driver = 100
    } }
  }
]
WPGRP

# 3. The gadget: interrupt-driven, one hardware period per graph cycle.
#    PipeWire's default is timer scheduling - a large buffer polled on a
#    guess about the DMA pointer - and below a 128-frame quantum that
#    guess stops being good enough. Measured on the bare sink, errors
#    per 10s: 209..614 timer-scheduled against 46..60 interrupt-driven.
#    f_uac2's pointer advances every 125us microframe, so a 32-frame
#    period suits it.
#
#    period-num 2 requires patches/kernel/0001, which lowers u_audio.c's
#    MIN_PERIODS from 4 to 2. Stock, the gadget silently returns a
#    four-period buffer whatever is asked for - measured by requesting
#    and reading hw_params back with the device open: 32/2 -> 128,
#    32/3 -> 128, 64/2 -> 256, 128/2 -> 512. It is a hardcoded constant
#    in the driver, not a hardware limit, and the real constraint a few
#    lines below it (period_bytes_min * periods_min = 2 * max_psize,
#    the two-USB-packet floor) is preserved by the change. With the
#    patch the board-side buffer at quantum 32 is 64 frames instead of
#    128, and the MEASURED fill - which is what latency actually is -
#    drops from 96 frames (2.18ms) to 64 (1.45ms).
#
#    Settled at 4, which is the depth every clean result on this board
#    was obtained at: the ten-minute armed soak with Ardour's own xrun
#    counter at +0 across eleven reports, and the sample-exact 76-second
#    USB capture, both ran on a stock four-period gadget. Two periods
#    measured 22 defects in 60 seconds under the same load and never got
#    a matched control of its own (the gadget returned EIO partway
#    through every attempt), so the shallower buffer buys 0.73ms against
#    a known-good configuration and an unproven one. Not a trade worth
#    taking for an instrument.
#
#    The kernel patch stays in the tree regardless: it removes an
#    arbitrary limit, and the DAC path - once converters are wired - is
#    where a shallower buffer is actually likely to pay. I2S has one
#    clock and a fixed sample cadence, with none of USB's packetisation
#    or two-clock reconciliation.
cat > /etc/wireplumber/wireplumber.conf.d/99-mpcpi-usb-sched.conf <<'WPUSB'
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_output.platform-1000480000.usb.*" }
      { node.name = "~alsa_input.platform-1000480000.usb.*" }
    ]
    actions = {
      update-props = {
        api.alsa.disable-tsched = true
        api.alsa.period-size = 32
        api.alsa.period-num = 4
        api.alsa.headroom = 0
        node.pause-on-idle = false
        session.suspend-timeout-seconds = 0
      }
    }
  }
]
WPUSB

# 4. Never suspend an audio node. PipeWire suspends idle sinks; a
#    suspended node is not in the graph, and for an instrument the
#    resume is an audible click and a latency change.
cat > /etc/wireplumber/wireplumber.conf.d/96-mpcpi-nosuspend.conf <<'WPSUS'
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_.*" } ]
    actions = { update-props = {
        node.pause-on-idle = false
        session.suspend-timeout-seconds = 0
    } }
  }
]
WPSUS
# WirePlumber remembers a manually chosen default sink in its state
# directory and that choice outranks priority.session forever after. A
# single `wpctl set-default` during bring-up therefore pins the graph's
# default to whatever was convenient that day - here it survived a
# reboot and kept pointing at the gadget, so unrouted streams would
# still have landed on the wire to the computer. Clear the state and let
# the configuration decide.
rm -f /home/mpc/.local/state/wireplumber/default-nodes
echo "  cleared wireplumber's remembered default sink"

echo "  graph: timer clock drives, gadget follows at 32-frame periods"
echo "  wireplumber rules: PCMs direct, no suspend, DAC drives the graph"
