# Boot time

Target: **2 seconds** from power to a playable instrument, on SD card,
excluding anything that only happens on a development rig.

## Where it stands

| | netboot (measured) | SD (not yet measurable) |
|---|---|---|
| kernel | 6.12 s | ~0.2 s + local root mount |
| userspace | 6.24 s | unknown, see below |
| total | **12.35 s** | unknown |

From *never completing at all* — `userconfig.service` sat queued forever
waiting on a console an appliance has no one to answer — to 12.35 s.

## The measurement medium dominates the measurement

This is the finding that matters, and it invalidates most of the
remaining tuning work until it is addressed.

```
[0.229076] nfs4flexfilelayout_init: NFSv4 Flexfile Layout Driver Registering
[3.809572] macb 1f00100000.ethernet eth0: Link is Up - 1Gbps/Full
[5.927653] VFS: Mounted root (nfs filesystem) on device 0:19
[5.934240] Run /sbin/init as init process
```

**5.93 of the 6.12 s kernel phase is netboot**: 3.81 s waiting for
ethernet autonegotiation, then 2.12 s mounting the root over NFS. The
kernel itself is finished long before; it is idling on a root
filesystem that has to arrive over a wire.

It does not stop at init. Userspace needs 1.49 s to reach `system.slice`
— before a single service starts — because every systemd unit file,
every binary, and every shared object is a network round trip. The same
tax is spread across the whole critical chain:

```
multi-user.target @5.309s
└─ssh.service @4.575s +732ms
  └─network.target @4.559s
    └─systemd-networkd.service @4.092s +466ms
      └─systemd-udevd.service @3.548s +539ms
        └─systemd-tmpfiles-setup-dev.service @3.358s +157ms
          └─systemd-tmpfiles-setup-dev-early.service @2.581s +742ms
            └─kmod-static-nodes.service @2.359s +199ms
              └─systemd-journald.socket @2.153s
                └─system.slice @1.494s
```

Every unit on that chain is a systemd essential doing ordinary work. The
742 ms in `tmpfiles-setup-dev-early` is not 742 ms of computation; it is
file I/O over NFS. None of these numbers transfer to a card.

**So: the 2 s target cannot be pursued on netboot.** Not "will be
harder" — cannot be measured. The next real step is a card image.

## Measurement traps found the hard way

- **`user@0.service` is not boot cost.** It sits at the top of
  `systemd-analyze blame` at 1.09 s and starts at monotonic 11.26 s —
  after boot completes. It is the *root ssh login used to take the
  measurement*. Nobody logs into the shipped appliance, so it does not
  exist there. Read the monotonic timestamp, not the blame position.
- **"Bootup is not yet finished" reads as a missing measurement.** It is
  not; it means a job is still queued, which is how `userconfig.service`
  hid. `verify.sh` now fails on that string and prints the queued jobs.
- **The blame list is not the critical chain.** Slow units that nothing
  waits on cost nothing.

## What was actually removed

Unit policy lives in `scripts/pios/mpcpi-appliance.preset`, applied by
`tune-realtime.sh`. A preset rather than a list of `systemctl mask`
calls: it states policy for units that are not installed yet, and dpkg
consults it when a package later installs a service.

It is applied unit-by-unit from its own directives, deliberately **not**
with `systemctl preset-all` — for units no preset file mentions, systemd
falls back to its compiled-in default of `enable`, and on a box being
stripped, a command whose fallback is "switch it on" is the wrong
instrument.

Removed: `userconfig`, both `*-wait-online`, NetworkManager and the
`rpi-usb-gadget-ics` unit that kept pulling it back, wpa_supplicant,
ModemManager, avahi, bluetooth/hciuart/rfkill, cloud-init's five units,
udisks2, packagekit, console-setup, keyboard-setup, triggerhappy,
rpi-eeprom-update, sshswitch, cron, and the apt/man-db/e2scrub/fstrim
timers. Radios are also cut at the firmware level by `disable-wifi` and
`disable-bt` in `config.txt`, which is what actually saves the 1.59 s
regulatory-database load and 0.81 s of Bluetooth core init.

## Kept, with reasons

- **`systemd-hostnamed`** — looks like a free 660 ms and is not. Masking
  it moved `ssh.service` from 1.1 s to 4.1 s: a net loss of 2.5 s.
- **`systemd-logind`** — `user@1001`, the audio session where PipeWire
  lives, depends on it.
- **`polkit`** — static, so maskable but not disableable, and
  dbus-activated rather than boot-ordered. Not on the critical chain, so
  masking buys nothing and risks every privileged D-Bus call.
- **`rpcbind`, `nfs-blkmap`** — netboot only. Pure overhead on the
  shipped image; disabling them here breaks the development rig's root.

## Next

1. Build a card image. No path in the repo produces one yet — this is
   the blocking piece of work, not a follow-up.
2. Re-measure everything above on it. Expect the kernel phase and the
   1.49 s pre-`system.slice` gap to mostly disappear.
3. Only then decide whether `ssh.service` (732 ms, on the chain) is
   worth socket-activating. On a card it may not be.
4. Consider what "booted" should mean. `multi-user.target` is a
   systemd milestone, not a musical one. The number a player cares
   about is *time until the instrument makes sound*, which is
   `user@1001` plus PipeWire plus the emulator — and that is the metric
   the 2 s target should be judged against.
