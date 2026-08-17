# board/rpi5/cmdline-tuning

The kernel command-line tuning, in ONE place, because it was in two and
they disagreed for the entire life of the netboot script.

`tune-realtime.sh` wrote the full line to the board's own
`/boot/firmware/cmdline.txt`. But a netbooting Pi reads `cmdline.txt`
over TFTP, not from its root, and `mpcpi-netboot` composed its own
thinner line - hardcoded in the netboot script's first commit, 95c47de.

So on every netbooted boot the board actually ran:

    isolcpus=2-3 threadirqs

and never `nohz_full`, `rcu_nocbs`, `irqaffinity=0` or `audit=0`. Worse,
`isolcpus=2-3` leaves **core 1 unisolated** - the core
`mpcpi-irq-affinity` pins the audio interrupt to at priority 95. That
script's own header records that it "did not fix anything, and is kept
because it is right, not because it worked". It could not work: it was
pinning audio to a core ordinary userspace was free to run on.

Both consumers now read this file, so the development rig boots what the
appliance boots.

## Why these keys

- `isolcpus=1-3` - cores 1-3 are the audio side: PipeWire's data loop
  alone on 1, the graph's workers on 2-3. Core 0 keeps every interrupt
  and the whole of userspace.
- `nohz_full=1-3` - stops the scheduler tick on those cores.
- `rcu_nocbs=1-3` - moves RCU callback work off them. Without both,
  isolcpus still leaves periodic interruptions that show up as
  occasional long cycles.
- `irqaffinity=0` - every interrupt to core 0 by default;
  `mpcpi-irq-affinity` then moves the audio one to core 1 deliberately.
- `threadirqs` - makes each handler a task, so the audio one can be
  given a realtime priority above PipeWire's data loop.
- `audit=0` - the audit subsystem costs syscall-path work for a box that
  has no audit policy.

## Netboot caveat, untested as of writing

On netboot, `isolcpus=1-3` puts the NFS root's traffic, sshd, and all of
userspace on core 0 alone. A local SD root is far lighter on core 0 than
a network one, so the dev rig is the harsher case, not the gentler one -
and an earlier watchdog reboot in this project came from starving core 0.
If a netbooted board becomes unstable, that is the first suspect. The
TFTP `cmdline.txt` lives on the HOST, so recovery does not need the
board: edit it and reboot.
