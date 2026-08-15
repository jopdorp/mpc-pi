#!/usr/bin/env python3
"""The single owner of the Maschine: both screens and all input.

One process holds the USB device because two cannot. It:

  * pushes /dev/shm/mpc-lcd to screen L and /dev/shm/daw-ui to screen R,
  * reads pads, buttons and encoders,
  * and routes each event by `control_map`: MPC-bound events become MIDI
    on the emulator's virmidi port, DAW-bound events become command lines
    on daw-ctl's FIFO.

Routing is a pure function of (control, shift, held mode) so it is
testable without hardware:  maschine-hub.py --self-test
"""
import argparse
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import control_map                                        # noqa: E402

EP_PADS = 0x84
EP_CTRL = 0x81
MK1_VENDOR = 0x17CC

LCD_L = "/dev/shm/mpc-lcd"
LCD_R = "/dev/shm/daw-ui"
FIFO = "/run/daw-ctl.fifo"

# Which mode each hold-button enters, from the control map.
HOLD_MODES = {v["button"]: k for k, v in control_map.MODES.items()
              if v.get("button")}


class Router:
    """Turns a control event into either MIDI bytes or a daw-ctl line."""

    def __init__(self, lanes=None, strips=None):
        self.lanes = lanes or ["GTR1", "GTR2", "MIC", "AUX"]
        self.strips = strips or ["MPC", "GTR1", "GTR2", "MIC",
                                 "LOOP", "VERB", "DLY", "AUX"]
        self.shift = False
        self.held = None          # a mode button currently held
        self.pinned = None        # a latched mode
        self.page = "LOOP"

    @property
    def mode(self):
        return self.held or self.pinned or control_map.DEFAULT_MODE

    # --- buttons ---

    def button(self, name, down):
        """Returns a list of (kind, payload); kind is 'midi' or 'cmd'."""
        if name == "shift":
            self.shift = down
            return []

        if name in HOLD_MODES:
            # Hold enters the mode; release leaves it, unless it was
            # pinned while held. PIN is Button 1 pressed during the hold.
            if down:
                self.held = HOLD_MODES[name]
            else:
                if self.pinned == self.held:
                    pass                       # stays latched
                self.held = None
            return [("cmd", "mode %s" % self.mode)]

        if name == control_map.PIN_BUTTON and self.held:
            self.pinned = None if self.pinned == self.held else self.held
            return [("cmd", "mode %s" % self.mode)]

        if not down:
            return []

        # Page selection: Group E-H.
        target = control_map.GROUPS.get(name)
        if target and target.startswith("daw:page:"):
            self.page = target.split(":")[-1]
            return [("cmd", "page %s" % self.page)]
        if target and target.startswith("mpc:"):
            return [("midi", target)]

        # Screen R's four buttons are contextual.
        if name.startswith("display"):
            idx = int(name[-1]) - 1
            if idx < 4:
                left = control_map.BUTTONS_LEFT.get(name)
                if left:
                    key = left[1] if self.shift else left[0]
                    return [("midi", key)] if key else []
            labels = control_map.BUTTONS_RIGHT_BY_PAGE.get(
                self.page, ("", "", "", ""))
            label = labels[idx - 4]
            return [("cmd", "button %s %s" % (self.page, label))]

        # Transport and the pad-section buttons.
        tr = control_map.TRANSPORT.get(name)
        if tr:
            key = tr[1] if self.shift else tr[0]
            return [("midi", key)] if key and key != "modifier" else []
        sec = control_map.PAD_SECTION.get(name)
        if sec and sec.startswith("mpc:"):
            return [("midi", sec)]
        return []

    # --- pads ---

    def pad(self, index, velocity):
        """Pad 0..15, velocity 0..127 (0 = release)."""
        if self.shift:
            target = control_map.SHIFT_PADS.get(index + 1)
            if target:
                kind = "midi" if target.startswith("mpc:") else "cmd"
                return [(kind, target if kind == "midi"
                         else "action %s" % target.split(":", 1)[1])]
            return []
        mode = self.mode
        if mode == "MPC":
            return [("midi", "pad:%d:%d" % (index, velocity))]
        if not velocity:
            return []
        # The grid reads as four columns of four: column = lane.
        col, row = index % 4, index // 4
        lane = self.lanes[col] if col < len(self.lanes) else None
        if lane is None:
            return []
        if mode == "LOOP":
            verb = control_map.LOOP_PAD_ROWS[min(row, 3)].lower()
            return [("cmd", "%s %s" % (verb, lane))]
        if mode in ("MUTE", "SOLO"):
            name = self.strips[index] if index < len(self.strips) else None
            return [("cmd", "%s %s" % (mode.lower(), name))] if name else []
        return []

    # --- encoders ---

    def knob(self, index, delta):
        """Knob 0..7 across both screens; 0-3 are the MPC's, 4-7 the DAW's."""
        if index < 4:
            return [("midi", control_map.KNOBS_LEFT[index])]
        col = index - 4
        if self.page in ("MIX", "LOOP"):
            strip = self.strips[col] if col < len(self.strips) else None
            if strip:
                return [("cmd", "knob %s %s %+d" % (self.page, strip, delta))]
        return [("cmd", "knob %s %d %+d" % (self.page, col, delta))]


def self_test():
    r = Router()
    # A page button changes the page and says so.
    assert r.button("group_f", True) == [("cmd", "page MIX")]
    assert r.page == "MIX"

    # Transport goes to the MPC, not to Ardour, and SHIFT reaches the
    # bar-level move the MPC prints on the same key.
    assert r.button("play", True) == [("midi", "mpc:play")]
    r.button("shift", True)
    assert r.button("play", True) == [("midi", "mpc:play_start")]
    r.button("shift", False)

    # Holding PAD MODE is the mode; releasing returns to MPC pads.
    assert r.mode == "MPC"
    r.button("pad_mode", True)
    assert r.mode == "LOOP"
    # column = lane, row = verb
    assert r.pad(0, 100) == [("cmd", "rec GTR1")]
    assert r.pad(6, 100) == [("cmd", "play MIC")]
    r.button("pad_mode", False)
    assert r.mode == "MPC"
    # and now the same pad plays the instrument instead
    assert r.pad(0, 100) == [("midi", "pad:0:100")]

    # PIN latches the held mode so it survives release.
    r.button("pad_mode", True)
    r.button(control_map.PIN_BUTTON, True)
    r.button("pad_mode", False)
    assert r.mode == "LOOP", "PIN should have latched the mode"

    # Knobs 1-4 drive the MPC, 5-8 the DAW page's strips.
    assert r.knob(0, 1) == [("midi", "mpc:data_wheel")]
    r.page = "MIX"
    assert r.knob(4, -2) == [("cmd", "knob MIX MPC -2")]

    # The MPC's printed shift-pad functions stay true.
    r.button("shift", True)
    assert r.pad(0, 100) == [("midi", "mpc:undo")]
    assert r.pad(4, 100) == [("cmd", "action quantize")]
    print("maschine-hub self-test PASS: routing verified for buttons, "
          "pads, knobs, shift and hold-modes")


class Mk1:
    """The USB side: one owner for both screens and all input.

    Report formats come from cabl (see docs/maschine-mk1-display-protocol.md):
    endpoint 0x84 carries pads, 0x81 carries buttons and encoders with the
    first byte selecting which. Pads report 12-bit pressure continuously
    rather than note on/off, so a hit is a threshold crossing and velocity
    is taken from the leading edge.
    """

    VENDOR, PRODUCT = 0x17CC, 0x0808
    PAD_THRESHOLD = 200

    def __init__(self):
        import usb.core                                   # noqa: F401
        import usb.util                                   # noqa: F401
        self.usb = usb
        self.dev = usb.core.find(idVendor=self.VENDOR, idProduct=self.PRODUCT)
        if self.dev is None:
            raise RuntimeError("no Maschine MK1 (17cc:0808) found")
        if self.dev.is_kernel_driver_active(0):
            self.dev.detach_kernel_driver(0)
        self.dev.set_configuration()
        self.pad_state = [0] * 16
        self.buttons = 0
        self.encoders = [None] * 11
        self.frames = {}

    # --- output ---

    def push_screen(self, index, mpcl_path, packer):
        """Send a screen if its frame changed. The USB write is the
        expensive part, so an unchanged frame is skipped entirely."""
        try:
            with open(mpcl_path, "rb") as f:
                data = f.read()
        except OSError:
            return False
        if len(data) < 16 or data[:4] != b"MPCL":
            return False
        if self.frames.get(index) == data:
            return False
        self.frames[index] = data
        w = int.from_bytes(data[8:10], "little")
        h = int.from_bytes(data[10:12], "little")
        packer(self.dev, index, data[16:], w, h)
        return True

    # --- input ---

    def poll(self, router, timeout=4):
        """Read whatever is pending and return routed events."""
        events = []
        try:
            data = self.dev.read(EP_PADS, 64, timeout=timeout)
            events += self._pads(data, router)
        except Exception:
            pass
        try:
            data = self.dev.read(EP_CTRL, 64, timeout=timeout)
            events += self._ctrl(data, router)
        except Exception:
            pass
        return events

    def _pads(self, data, router):
        out = []
        for i in range(1, len(data) - 1, 2):
            hi, lo = data[i], data[i + 1]
            pad = (hi & 0xF0) >> 4
            pressure = ((hi & 0x0F) << 8) | lo
            if pad > 15:
                continue
            was = self.pad_state[pad]
            self.pad_state[pad] = pressure
            if pressure > self.PAD_THRESHOLD and was <= self.PAD_THRESHOLD:
                # Velocity from the leading edge: the stream is pressure,
                # not note-on, so the first crossing is the hit.
                out += router.pad(pad, min(127, pressure >> 5))
            elif pressure <= self.PAD_THRESHOLD and was > self.PAD_THRESHOLD:
                out += router.pad(pad, 0)
        return out

    def _ctrl(self, data, router):
        if not data:
            return []
        kind = data[0]
        out = []
        if kind == 0x04:
            # Button bitfield. Byte 6 bit 6 gates validity, per cabl.
            if len(data) > 6 and not (data[6] & 0x40):
                return []
            bits = int.from_bytes(bytes(data[1:6]), "little")
            changed = bits ^ self.buttons
            self.buttons = bits
            for pos, name in enumerate(control_map_buttons()):
                if name and (changed >> pos) & 1:
                    out += router.button(name, bool((bits >> pos) & 1))
        elif kind == 0x02:
            # Eleven absolute encoders, 16-bit each. They are endless
            # pots rather than quadrature, so a delta is a wrapped
            # difference and we never need a pickup mode.
            for i in range(11):
                off = 1 + i * 2
                if off + 1 >= len(data):
                    break
                val = (data[off] << 8) | data[off + 1]
                prev = self.encoders[i]
                self.encoders[i] = val
                if prev is None or val == prev:
                    continue
                delta = val - prev
                if delta > 32768:
                    delta -= 65536
                elif delta < -32768:
                    delta += 65536
                out += router.knob(i, delta)
        return out


def control_map_buttons():
    """Bit order for the button report, from the input bridge."""
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "mk1in", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "mpc-mk1-input.py"))
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return m.MK1_BUTTONS
    except Exception:
        return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fifo", default=FIFO)
    ap.add_argument("--midi", default="/dev/snd/midiC1D0")
    ap.add_argument("--left", default=LCD_L)
    ap.add_argument("--right", default=LCD_R)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--no-usb", action="store_true",
                    help="route only, do not open the controller")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.no_usb:
        print("routing only; no controller opened")
        return 0

    router = Router()
    try:
        mk1 = Mk1()
    except Exception as exc:
        print("maschine-hub: %s" % exc, file=sys.stderr)
        return 1

    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "disp", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "mpc-mk1-display.py"))
    disp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(disp)

    def packer(dev, index, px, w, h):
        frame = disp.pack_display(w, h, px)
        # The display bridge owns the wire format; reuse it rather than
        # duplicating the chunking here, so a protocol fix lands once.
        saved = disp.Mk1Usb.__new__(disp.Mk1Usb)
        saved.dev, saved.d = dev, index << 1
        saved._w = disp.Mk1Usb._w.__get__(saved)
        disp.Mk1Usb.send_frame(saved, frame)

    fifo = None
    if os.path.exists(args.fifo):
        fifo = os.open(args.fifo, os.O_WRONLY | os.O_NONBLOCK)

    midi = None
    try:
        midi = open(args.midi, "wb", buffering=0)
    except OSError:
        print("maschine-hub: no MIDI port at %s" % args.midi, file=sys.stderr)

    while True:
        for events in (mk1.poll(router),):
            for kind, payload in events:
                if kind == "cmd" and fifo is not None:
                    os.write(fifo, (payload + "\n").encode())
                elif kind == "midi" and midi is not None:
                    midi.write(encode_midi(payload))
        mk1.push_screen(0, args.left, packer)
        mk1.push_screen(1, args.right, packer)
        time.sleep(0.002)


def encode_midi(target):
    """Turn a routed MIDI target into bytes for the emulator's port."""
    if target.startswith("pad:"):
        _, pad, vel = target.split(":")
        note = 36 + int(pad)
        vel = int(vel)
        return bytes([0x90 if vel else 0x80, note, vel])
    # Panel keys ride notes 52..97, matching the emulator's injection.
    name = target.split(":", 1)[1] if ":" in target else target
    codes = control_map_keycodes()
    code = codes.get(name)
    if code is None:
        return b""
    return bytes([0x90, 52 + code - 1, 100])


def control_map_keycodes():
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "mk1in", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "mpc-mk1-input.py"))
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return m.KEY
    except Exception:
        return {}


if __name__ == "__main__":
    sys.exit(main() or 0)
