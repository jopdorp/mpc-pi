#!/usr/bin/env python3
"""Maschine MK1 bring-up: check the things that are unverified, in order.

Everything this project knows about the MK1 was read out of other
people's source, mostly shaduzlabs/cabl. None of it has met the hardware.
This script exists so the first session with the device is a checklist
rather than improvisation, and so each unknown is isolated - a display
that stays dark should not be confusable with a backlight that was never
lit, which is exactly the confusion that would have happened before the
LED block was implemented.

Order matters. Each stage depends only on stages before it:

  1. present    - is it on the bus, and who owns it
  2. claim      - can we take the interfaces from the kernel
  3. leds       - LED block writes at all (this is where cabl issue #10
                  died with EBUSY, and it is the cheapest possible write)
  4. backlight  - screens light up, proving LED indices are right
  5. display    - a gradient, which answers the polarity question
  6. input      - press things, see them decoded

Run stages individually while debugging:
    mk1-bringup.py present
    mk1-bringup.py leds
    mk1-bringup.py all
"""
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mk1_leds as L  # noqa: E402

VENDOR, PRODUCT = 0x17CC, 0x0808


def hdr(t):
    print("\n== %s" % t)


def ok(t):
    print("  OK    %s" % t)


def bad(t):
    print("  FAIL  %s" % t)


def note(t):
    print("        %s" % t)


def stage_present():
    """On the bus, and not held by the kernel."""
    hdr("present")
    import glob
    import os

    found = []
    for d in glob.glob("/sys/bus/usb/devices/*"):
        try:
            with open(os.path.join(d, "idVendor")) as f:
                v = f.read().strip()
            with open(os.path.join(d, "idProduct")) as f:
                p = f.read().strip()
        except OSError:
            continue
        if (v, p) == ("17cc", "0808"):
            found.append(d)
    if not found:
        bad("17cc:0808 not on the bus - is it plugged in and powered?")
        return False
    ok("17cc:0808 present (%s)" % ", ".join(os.path.basename(f) for f in found))

    # Who owns the interfaces. This is the EBUSY that killed cabl #10.
    held = []
    for dev in found:
        for iface in glob.glob(dev + ":*"):
            drv = os.path.join(iface, "driver")
            if os.path.islink(drv):
                held.append((os.path.basename(iface),
                             os.path.basename(os.readlink(drv))))
    if held:
        for iface, drv in held:
            if drv == "usbfs":
                ok("%s held by usbfs (that is us)" % iface)
            else:
                bad("%s is held by the kernel driver %r" % (iface, drv))
                note("this is the errno=16 EBUSY in cabl issue #10.")
                note("fix: modprobe.d/blacklist-caiaq.conf + "
                     "udev/71-maschine-mk1.rules, then replug")
        if any(d != "usbfs" for _, d in held):
            return False
    else:
        ok("no kernel driver holds any interface")
    return True


def open_device():
    import usb.core

    dev = usb.core.find(idVendor=VENDOR, idProduct=PRODUCT)
    if dev is None:
        raise SystemExit("device not found")
    return dev


def stage_claim():
    hdr("claim")
    import usb.core

    dev = open_device()
    # Detach EVERY interface, not just 0. caiaq binds per interface, and
    # detaching only interface 0 leaves a later claim failing as EBUSY -
    # which reads like a permissions problem and is not.
    detached = []
    try:
        cfg = dev.get_active_configuration()
    except usb.core.USBError as e:
        bad("cannot read configuration: %s" % e)
        note("if this is a permissions error, the udev rule is not applied")
        return None
    for iface in cfg:
        n = iface.bInterfaceNumber
        try:
            if dev.is_kernel_driver_active(n):
                dev.detach_kernel_driver(n)
                detached.append(n)
        except (usb.core.USBError, NotImplementedError):
            pass
    if detached:
        ok("detached kernel driver from interface(s) %s" %
           ",".join(str(n) for n in detached))
    else:
        ok("no kernel driver to detach")
    ok("%d interface(s) on the active configuration" % cfg.bNumInterfaces)
    return dev


def stage_leds(dev, hold=1.5):
    """Cheapest possible write. If this fails, nothing else will work."""
    hdr("leds")
    import usb.core

    bank = L.LedBank()

    def write(ep, data):
        dev.write(ep, data, timeout=1000)

    try:
        bank.all(L.OFF)
        n = bank.flush(write, force=True)
        ok("wrote %d LED block(s), 33 bytes each" % n)
    except usb.core.USBError as e:
        bad("LED write failed: %s" % e)
        note("errno 16 / EBUSY here means the kernel still holds it")
        return False

    # Walk the groups so a wrong index shows up as the wrong light.
    for name in ("Play", "Rec", "Shift", "GroupA"):
        bank.all(L.OFF)
        bank.set(name, L.BRIGHT)
        bank.flush(write, force=True)
        print("        lit: %-8s (index %2d) - confirm on the panel"
              % (name, L.LED_INDEX[name]))
        time.sleep(hold)

    # Pads one at a time, in PHYSICAL order. If the panel lights them in
    # mirrored rows, the wire order in LED_ORDER is wrong.
    print("        pads 1..16 in physical order; rows must run "
          "left-to-right")
    for i in range(1, 17):
        bank.all(L.OFF)
        bank.set_pad(i, L.BRIGHT)
        bank.flush(write, force=True)
        time.sleep(0.12)
    bank.all(L.OFF)
    bank.flush(write, force=True)
    ok("LED sweep done")
    return True


def stage_backlight(dev):
    """Proves the LED indices are right, and makes the screens usable."""
    hdr("backlight")
    bank = L.LedBank()
    bank.all(L.OFF)
    bank.backlight(L.BACKLIGHT_DEFAULT)
    bank.flush(lambda ep, d: dev.write(ep, d, timeout=1000), force=True)
    ok("DisplayBacklight (index %d) = 0x%02X"
       % (L.LED_INDEX["DisplayBacklight"], L.BACKLIGHT_DEFAULT))
    note("both screens should now be lit - dark but glowing, not black")
    note("if they are still black, the LED index table is wrong")
    return True


def stage_input(dev, seconds=20):
    hdr("input")
    import usb.core

    # cabl sends this before reading. No source shows input arriving
    # without it, so its absence is the first thing to suspect if this
    # stage times out.
    try:
        dev.write(L.EP_OUT, bytes(L.INIT_HANDSHAKE), timeout=1000)
        ok("init handshake {0x0B,0xFF,0x02,0x05} accepted")
    except usb.core.USBError as e:
        bad("init handshake failed: %s" % e)

    print("        press pads, buttons, turn knobs (%ds)..." % seconds)
    end = time.time() + seconds
    seen = {"pads": 0, "ctrl": 0}
    while time.time() < end:
        for ep, key in ((0x84, "pads"), (0x81, "ctrl")):
            try:
                data = dev.read(ep, 64, timeout=100)
            except usb.core.USBError:
                continue
            seen[key] += 1
            if seen[key] <= 3:
                print("        ep 0x%02X: %s"
                      % (ep, " ".join("%02X" % b for b in data[:16])))
    for key, ep in (("pads", 0x84), ("ctrl", 0x81)):
        if seen[key]:
            ok("endpoint 0x%02X delivered %d reports" % (ep, seen[key]))
        else:
            bad("endpoint 0x%02X delivered nothing" % ep)
            note("suspect the init handshake, or the kernel driver")
    return all(seen.values())


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if not stage_present():
        return 1
    if what == "present":
        return 0
    dev = stage_claim()
    if dev is None:
        return 1
    if what == "claim":
        return 0
    if what in ("all", "leds"):
        if not stage_leds(dev):
            return 1
    if what in ("all", "backlight", "leds"):
        stage_backlight(dev)
    if what in ("all", "input"):
        stage_input(dev)
    print("\nRecord what the panel actually did in "
          "docs/maschine-mk1-display-protocol.md - especially display "
          "polarity, which two sources disagree on.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
