#!/usr/bin/env python3
"""Maschine MK1 display bring-up, in stages that isolate each unknown.

Nothing has ever been drawn on these screens. Three things could be
wrong at once - the init sequence, the 21x502+338 chunking, and the
5-bpp pixel packing - and a garbled screen looks the same for all three.
So the stages are ordered so that each one only depends on what the
previous stage already proved:

  fill      every byte 0xFF, then 0x00. A uniform frame is uniform under
            ANY packing, so this tests init and chunking alone. If the
            screen goes bright then dark, transport works and packing is
            the only thing left to doubt.
  split     left half bright, right half dark. Tests horizontal
            addressing without depending on grey levels.
  gradient  0 to 31 across the width. Tests the levels, and answers the
            polarity question two sources disagree on: cabl stores the
            complement of the level, Macchina does not.

Usage:
    mk1-screen-test.py [fill|split|gradient|all] [display]
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mk1_leds as L                                       # noqa: E402

EP_DISPLAY = 0x08

# Contrast register value, chosen by looking at the panel: 0x10.
#
# cabl's init ends with 0x25 and that is too dark on this unit. Values
# above roughly 0x20 crush the ramp toward black; 0x2A and 0x32 were both
# rejected outright.
#
# Do not try to refine this with side-by-side A/B tests. Fourteen rounds
# were run and the method does not work here: the two screens sit at
# different angles to the player, these STN panels shift enormously with
# angle, and the same value read better or worse purely by which side it
# was on. Swapping sides was supposed to control for that, and the results
# still came back ambiguous.
#
# It is a matter of taste and seating position, so it is configurable
# rather than derived. Override with MPC_MK1_CONTRAST.
CONTRAST_DEFAULT = int(os.environ.get("MPC_MK1_CONTRAST", "0x10"), 0) & 0x3F
DISPLAY_W, DISPLAY_H = 255, 64
ROW_BYTES = 170                      # 85 triples x 2 bytes
FRAME_BYTES = 21 * 502 + 338         # 10880 = DISPLAY_H * ROW_BYTES
assert FRAME_BYTES == DISPLAY_H * ROW_BYTES


class Mk1Screens:
    def __init__(self):
        import usb.core
        import usb.util
        self.core = usb.core
        self.util = usb.util
        self.dev = usb.core.find(idVendor=0x17CC, idProduct=0x0808)
        if self.dev is None:
            raise SystemExit("no Maschine MK1 (17cc:0808) found")
        for n in (0,):
            try:
                if self.dev.is_kernel_driver_active(n):
                    self.dev.detach_kernel_driver(n)
            except (usb.core.USBError, NotImplementedError):
                pass
        self._open()
        self.ok = 0
        self.retries = 0

    def _open(self):
        """Configure, claim, and switch to altsetting 1.

        Deliberately tolerant, because this device's state depends on what
        the last process left behind. Observed both ways in one session:
        set_configuration() succeeding and then failing with
        LIBUSB_ERROR_OTHER on the next run, and set_interface_altsetting()
        failing with the same error when set_configuration() was skipped.
        Neither error names a cause. A device reset clears whatever it is,
        so the whole sequence is simply retried after one.
        """
        usb = self.core
        for attempt in (0, 1):
            if attempt:
                # NOT dev.reset(). Resetting this device is implicated in
                # it dropping off the bus entirely - repeated "device
                # descriptor read/64, error -110" followed by USB
                # disconnect, recoverable only by unplugging the cable.
                # Releasing and re-claiming the interface is the gentler
                # retry, and it is enough for the state this hits.
                print("  retrying: release and re-claim interface 0")
                try:
                    self.util.release_interface(self.dev, 0)
                except usb.USBError:
                    pass
                time.sleep(0.5)
                # Re-enumeration is not instant. Poll rather than
                # sleeping a guessed interval - 1.2s was not enough and
                # produced "device vanished after reset", which reads as
                # a hardware fault rather than an impatient host.
                self.dev = None
                deadline = time.time() + 10
                while time.time() < deadline:
                    time.sleep(0.4)
                    self.dev = usb.find(idVendor=0x17CC, idProduct=0x0808)
                    if self.dev is not None:
                        break
                if self.dev is None:
                    raise SystemExit(
                        "device did not come back within 10s of a reset")
                print("  device re-enumerated")
            try:
                self.dev.set_configuration()
            except usb.USBError:
                pass                      # already configured
            try:
                self.util.claim_interface(self.dev, 0)
            except usb.USBError:
                pass
            try:
                # MANDATORY. In the default altsetting 0 the display
                # endpoint 0x08 does not exist and writes fail EIO.
                self.dev.set_interface_altsetting(
                    interface=0, alternate_setting=L.ALTSETTING)
                return
            except usb.USBError as e:
                last = e
        raise SystemExit("cannot select altsetting %d: %s"
                         % (L.ALTSETTING, last))

    def drain(self):
        """The device refuses output while input is queued."""
        for ep in L.IN_ENDPOINTS:
            for _ in range(8):
                try:
                    self.dev.read(ep, 512, timeout=3)
                except self.core.USBError:
                    break

    def w(self, ep, data, tries=80):
        """Write with drain and retry.

        Roughly half of all writes time out even after draining. A
        timeout means the transfer did not happen, so retrying cannot
        duplicate data - which is what makes this safe for frame chunks,
        where a duplicate would corrupt the frame.
        """
        for attempt in range(tries):
            self.drain()
            try:
                self.dev.write(ep, data, timeout=250)
                self.ok += 1
                self.retries += attempt
                return True
            except self.core.USBError:
                continue
        raise RuntimeError("write to ep 0x%02X failed after %d attempts"
                           % (ep, tries))

    def backlight(self, value=L.BACKLIGHT_DEFAULT):
        bank = L.LedBank()
        bank.all(L.OFF)
        bank.backlight(value)
        bank.flush(lambda ep, data: self.w(ep, data), force=True)

    def init_display(self, index):
        """The COMPLETE sequence from cabl's initDisplay - all 22 commands.

        The protocol doc listed only the first 12, stopping at {d,00,01,31}.
        The omitted tail contains {d,00,01,0xAF}, which on this class of
        LCD controller is DISPLAY ON (0xAE being off). So every frame this
        project ever sent was correctly formatted and pushed into a panel
        that had never been switched on - writes succeeded, contrast swept
        the whole range, and nothing could possibly appear.
        """
        d = index << 1
        W = lambda *b: self.w(EP_DISPLAY, bytes((d,) + b))
        W(0x00, 0x01, 0x30)
        W(0x00, 0x04, 0xCA, 0x04, 0x0F, 0x00)
        time.sleep(0.02)
        W(0x00, 0x02, 0xBB, 0x00)
        W(0x00, 0x01, 0xD1)
        W(0x00, 0x01, 0x94)
        W(0x00, 0x03, 0x81, 0x1E, 0x02)
        time.sleep(0.02)
        W(0x00, 0x02, 0x20, 0x08)
        time.sleep(0.02)
        W(0x00, 0x02, 0x20, 0x0B)
        time.sleep(0.02)
        W(0x00, 0x01, 0xA6)              # normal (non-inverted) display
        W(0x00, 0x01, 0x31)
        # --- everything below was missing from the doc ---
        W(0x00, 0x04, 0x32, 0x00, 0x00, 0x05)
        W(0x00, 0x01, 0x34)
        W(0x00, 0x01, 0x30)
        W(0x00, 0x04, 0xBC, 0x00, 0x01, 0x02)
        W(0x00, 0x03, 0x75, 0x00, 0x3F)  # row window 0..63
        W(0x00, 0x03, 0x15, 0x00, 0x54)  # column window 0..84
        W(0x00, 0x01, 0x5C)
        W(0x00, 0x01, 0x25)
        time.sleep(0.02)
        W(0x00, 0x01, 0xAF)              # DISPLAY ON - the missing command
        time.sleep(0.02)
        W(0x00, 0x04, 0xBC, 0x02, 0x01, 0x01)
        W(0x00, 0x01, 0xA6)
        W(0x00, 0x03, 0x81, CONTRAST_DEFAULT, 0x02)

    def send_frame(self, index, frame):
        assert len(frame) == FRAME_BYTES, len(frame)
        d = index << 1
        self.w(EP_DISPLAY, bytes([d, 0x00, 0x03, 0x75, 0x00, 0x3F]))
        self.w(EP_DISPLAY, bytes([d, 0x00, 0x03, 0x15, 0x00, 0x54]))
        self.w(EP_DISPLAY, bytes([d, 0x01, 0xF7, 0x5C]) + frame[0:502])
        off = 502
        chunks = 1
        while off + 502 <= FRAME_BYTES - 338:
            self.w(EP_DISPLAY, bytes([d + 1, 0x01, 0xF6]) + frame[off:off + 502])
            off += 502
            chunks += 1
        self.w(EP_DISPLAY, bytes([d + 1, 0x01, 0x52]) + frame[off:FRAME_BYTES])
        chunks += 1
        return chunks


def pack(level_at):
    """Build a frame from a function (x, y) -> level 0..31."""
    out = bytearray(FRAME_BYTES)
    for y in range(DISPLAY_H):
        base = y * ROW_BYTES
        for x in range(DISPLAY_W):
            lit = level_at(x, y) & 0x1F
            bi = base + (x // 3) * 2
            block = x % 3
            # cabl GDisplayMaschineMK1: px0 -> byte0 bits 7..3,
            # px1 -> byte0 bits 2..0 + byte1 bits 7..6,
            # px2 -> byte1 bits 5..1.
            if block == 0:
                out[bi] = (out[bi] & 0x07) | (lit << 3)
            elif block == 1:
                out[bi] = (out[bi] & 0xF8) | (lit >> 2)
                out[bi + 1] = (out[bi + 1] & 0x3F) | ((lit & 0x03) << 6)
            else:
                out[bi + 1] = (out[bi + 1] & 0xC1) | (lit << 1)
    return bytes(out)


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    which = int(sys.argv[2]) if len(sys.argv) > 2 else 0

    s = Mk1Screens()
    print("altsetting %d, display %d" % (L.ALTSETTING, which))
    s.backlight()
    print("backlight on")
    s.init_display(which)
    print("display %d initialised" % which)

    def show(label, frame, hold=5):
        t0 = time.time()
        n = s.send_frame(which, frame)
        print("  %-28s %d chunks in %.1fs (writes ok=%d, retries=%d)"
              % (label, n, time.time() - t0, s.ok, s.retries), flush=True)
        time.sleep(hold)

    # Test patterns use DIM, not BRIGHT. This device is bus-powered and
    # a Pi 5 limits TOTAL USB current to 600mA unless
    # usb_max_current_enable=1 is set in config.txt. Driving 62 LEDs and
    # two backlights at 0x7F is a plausible way to brown out the very
    # device under test - which happened once, and cost a replug.
    if what in ("all", "fill"):
        # Uniform frames are uniform under ANY packing: this isolates
        # init and chunking from the pixel format entirely.
        show("FILL all bytes 0xFF", b"\xff" * FRAME_BYTES)
        show("FILL all bytes 0x00", b"\x00" * FRAME_BYTES)
        show("FILL 0xFF again", b"\xff" * FRAME_BYTES)
    if what in ("all", "split"):
        show("SPLIT left bright/right dark",
             pack(lambda x, y: 0x1F if x < DISPLAY_W // 2 else 0))
        show("SPLIT top bright/bottom dark",
             pack(lambda x, y: 0x1F if y < DISPLAY_H // 2 else 0))
    if what in ("all", "gradient"):
        show("GRADIENT dark left -> bright right",
             pack(lambda x, y: (x * 32) // DISPLAY_W), hold=8)
    print("\nwrites ok=%d, total retries=%d" % (s.ok, s.retries))
    print("Report what appeared: for FILL, uniform bright then uniform")
    print("dark proves init and chunking. For GRADIENT, which SIDE is")
    print("bright settles the polarity question (cabl inverts, Macchina")
    print("does not).")


if __name__ == "__main__":
    main()
