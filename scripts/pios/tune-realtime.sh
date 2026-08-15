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
echo "  governor: performance on all cores"

log "kernel cmdline"
CMD="$BOOT/cmdline.txt"
add_cmd() {
	grep -qw -- "$1" "$CMD" 2>/dev/null || {
		sed -i "s/\$/ $1/" "$CMD"; echo "  + $1"; }
}
# Cores 2-3 belong to the emulator and the audio graph.
add_cmd "isolcpus=2-3"
# nohz_full stops the scheduler tick on those cores; rcu_nocbs moves RCU
# callback work off them. Without these, isolcpus still leaves periodic
# interruptions that show up as occasional long cycles.
add_cmd "nohz_full=2-3"
add_cmd "rcu_nocbs=2-3"
# Push device interrupts to the housekeeping cores so an SD or USB IRQ
# cannot land on an audio core mid-buffer.
add_cmd "irqaffinity=0-1"
add_cmd "threadirqs"
# The Pi's default is fine, but say it: no lazy page faults under RT.
add_cmd "audit=0"

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
    default.clock.rate          = 48000
    default.clock.quantum       = 256
    default.clock.min-quantum   = 32
    default.clock.max-quantum   = 1024
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
echo "  48k, quantum 256 (min 32), RT prio 88"

log "irq affinity"
# Best effort now, and persisted for boot. i2s and xhci are the two that
# matter: the audio path and the controller.
cat > /usr/local/sbin/mpcpi-irq-affinity <<'EOF'
#!/bin/sh
# Keep device interrupts on cores 0-1, away from the audio cores.
for irq in $(awk -F: '/i2s|xhci|mmc|eth/ {gsub(/ /,"",$1); print $1}' /proc/interrupts); do
	echo 3 > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
done
EOF
chmod 0755 /usr/local/sbin/mpcpi-irq-affinity
cat > /etc/systemd/system/mpcpi-irq-affinity.service <<'EOF'
[Unit]
Description=Pin device IRQs away from the audio cores
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mpcpi-irq-affinity
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now mpcpi-irq-affinity.service >/dev/null 2>&1 || true
echo "  IRQs pinned to cores 0-1"

echo
echo "Reboot required for cmdline changes. Then measure, do not assume:"
echo "  sudo ./verify.sh"
