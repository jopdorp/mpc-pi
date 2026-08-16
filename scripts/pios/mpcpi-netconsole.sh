#!/bin/sh
# Ship the kernel console to the development host, from boot.
#
# The board panics. Four times in one day it rebooted with no
# explanation, because the panic message goes to a console nobody was
# reading: the serial port is not wired, the systemd journal cannot
# outlive the kernel that is dying, and /var/log is on an NFS root whose
# writes stop at the same instant.
#
# netconsole solves it by pushing each printk out as a UDP datagram
# before the machine goes. It caught the one that mattered:
#
#   dma dma2chan2: BUG: dma2chan2, IRQ with no descriptors
#   Unable to handle kernel paging request at deaddeaddeaddead
#   ... axi_desc_get / dw_axi_dma_set_hw_desc / snd_pcm_do_start
#   Kernel panic - not syncing: Oops: Fatal exception in interrupt
#
# and then a LATER crash was lost, because it had been armed by hand and
# a reboot took it with it. Hence this file: armed at boot, every boot.
#
# The receiver is any UDP listener on the host. nc -u is NOT suitable -
# it latches onto the first sender's port and goes deaf afterwards,
# which looks exactly like a silent channel. Use:
#
#   python3 -c 'import socket;s=socket.socket(2,2);s.bind(("0.0.0.0",6667))
#   f=open("netconsole.log","ab",0)
#   while 1: f.write(s.recv(65535))'
#
# Verify with a positive control before trusting it - an alert-level
# message is what a panic looks like:
#
#   printf '<1>test\n' > /dev/kmsg
set -eu

TARGET_IP="${MPCPI_NETCONSOLE_IP:-192.168.7.1}"
TARGET_PORT="${MPCPI_NETCONSOLE_PORT:-6667}"
TARGET_MAC="${MPCPI_NETCONSOLE_MAC:-}"
IFACE="${MPCPI_NETCONSOLE_IFACE:-eth0}"

SRC_IP=$(ip -4 -br addr show "$IFACE" 2>/dev/null |
	awk '{print $3}' | cut -d/ -f1)
[ -n "$SRC_IP" ] || { echo "netconsole: $IFACE has no address" >&2; exit 0; }

# The MAC of the next hop. On a direct link that is the host itself;
# ping first so the neighbour table has it, because netconsole needs a
# literal MAC and will not resolve one.
if [ -z "$TARGET_MAC" ]; then
	ping -c1 -W2 "$TARGET_IP" >/dev/null 2>&1 || true
	TARGET_MAC=$(ip neigh show "$TARGET_IP" 2>/dev/null |
		awk '/lladdr/ {print $5; exit}')
fi
[ -n "$TARGET_MAC" ] || {
	echo "netconsole: no MAC for $TARGET_IP; set MPCPI_NETCONSOLE_MAC" >&2
	exit 0
}

rmmod netconsole 2>/dev/null || true
modprobe netconsole \
	"netconsole=6665@$SRC_IP/$IFACE,$TARGET_PORT@$TARGET_IP/$TARGET_MAC"

# Everything, including the debug levels a DMA driver complains at
# before it dies.
dmesg -n 8 2>/dev/null || true
echo "netconsole: $SRC_IP -> $TARGET_IP:$TARGET_PORT ($TARGET_MAC)"
