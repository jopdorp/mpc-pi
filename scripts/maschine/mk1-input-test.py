#!/usr/bin/env python3
"""Live input monitor for the Maschine MK1 - buttons, knobs and pads.

Built to be self-verifying rather than to print a log. Press a button and
that button's own lamp lights; hit a pad and that pad lights; turn a knob
and that knob's own bar moves on the left screen. If a mapping is wrong,
the wrong lamp lights or the wrong bar moves, and you see it on the panel
without reading a terminal.

That matters because the decoder tables were taken from cabl's source and
two of them are known to be surprising:

  * The button bitfield is 42 wide across six bytes, with bit 8 unused. An
    earlier version closed that gap and shifted every button from Rec
    onwards by one, so Shift pressed Grid.
  * The eleven encoders are NOT reported in panel order. cabl remaps every
    wire slot, so wire slot 8 is display knob 1. Passing the wire index
    through means every knob drives someone else's parameter - which is
    invisible until you turn one and watch what moves.

Usage:
    mk1-input-test.py [seconds]        default 120
"""
import importlib.util
import math
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mk1_leds as L                                        # noqa: E402


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ANIM = _load("anim", "mk1-boot-animation.py")
HUB = _load("hub", "maschine-hub.py")

BUTTON_NAMES = HUB.control_map_buttons()          # 42 entries, index 8 None
WIRE_TO_LOGICAL = HUB.ENCODER_WIRE_TO_LOGICAL
PAD_THRESHOLD = HUB.Mk1.PAD_THRESHOLD

# Our button names are lower_snake; the LED table uses CamelCase. Map the
# ones that have a lamp so a press can light itself.
BUTTON_LAMP = {
    "mute": "Mute", "solo": "Solo", "select": "Select",
    "duplicate": "Duplicate", "navigate": "Navigate", "keyboard": "Keyboard",
    "pattern": "Pattern", "scene": "Scene", "rec": "Rec", "erase": "Erase",
    "shift": "Shift", "grid": "Grid", "loop": "Loop", "play": "Play",
    "note_repeat": "NoteRepeat", "sampling": "Sampling", "step": "Step",
    "control": "Control", "browse": "Browse", "snap": "Snap",
    "auto_write": "AutoWrite", "transport_left": "TransportLeft",
    "transport_right": "TransportRight", "browse_left": "BrowseLeft",
    "browse_right": "BrowseRight",
    "group_a": "GroupA", "group_b": "GroupB", "group_c": "GroupC",
    "group_d": "GroupD", "group_e": "GroupE", "group_f": "GroupF",
    "group_g": "GroupG", "group_h": "GroupH",
    "display1": "DisplayButton1", "display2": "DisplayButton2",
    "display3": "DisplayButton3", "display4": "DisplayButton4",
    "display5": "DisplayButton5", "display6": "DisplayButton6",
    "display7": "DisplayButton7", "display8": "DisplayButton8",
}

KNOB_LABEL = ["k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8",
              "VOL", "TEMPO", "SWING"]


def bars_frame(values, moved):
    """Eleven vertical bars, one per logical encoder.

    Bar 1 is display knob 1, bar 9-11 are VOLUME/TEMPO/SWING. Turning the
    leftmost knob must move the leftmost bar; anything else is a mapping
    error you can see at a glance.
    """
    lit = {}
    W, H = ANIM.W, ANIM.H
    n = len(values)
    slot = W // n
    for i, v in enumerate(values):
        x0 = i * slot + 2
        wide = slot - 4
        # Absolute position, 16-bit, scaled to the panel height.
        h = int((v / 65535.0) * (H - 12))
        level = 0x1F if i in moved else 0x12
        for x in range(x0, x0 + wide):
            # baseline so every bar is visible even at zero
            ANIM.add(lit, x, H - 2, 0x0C)
            for y in range(H - 3, H - 3 - h, -1):
                ANIM.add(lit, x, y, level)
        # A tick above a bar that just moved, so the eye finds it.
        if i in moved:
            for x in range(x0, x0 + wide):
                ANIM.add(lit, x, 1, 0x1F)
                ANIM.add(lit, x, 2, 0x1F)
    return ANIM.pack_sparse(lit)


def pads_frame(pressures):
    """The 4x4 grid, drawn as filled cells with pressure as height."""
    lit = {}
    W, H = ANIM.W, ANIM.H
    cw, ch = W // 4, H // 4
    for pad, p in pressures.items():
        col, row = (pad - 1) % 4, (pad - 1) // 4
        x0 = col * cw + 3
        y0 = (3 - row) * ch + 2
        if p <= 0:
            for x in range(x0, x0 + cw - 6):
                ANIM.add(lit, x, y0 + ch - 5, 0x0A)
            continue
        fill = max(1, int((p / 4095.0) * (ch - 6)))
        level = 0x1F if p > PAD_THRESHOLD else 0x10
        for x in range(x0, x0 + cw - 6):
            for y in range(y0 + ch - 5, y0 + ch - 5 - fill, -1):
                ANIM.add(lit, x, y, level)
    return ANIM.pack_sparse(lit)


def main():
    seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 120
    s = ANIM.Screens()
    s.backlight(0x7F)
    for i in (0, 1):
        s.init_display(i)
    bank = L.LedBank()
    bank.all(L.OFF)
    bank.backlight(0x7F)
    bank.flush(lambda ep, d: s._led(ep, d), force=True)

    buttons = 0
    encoders = [None] * 11
    enc_values = [0] * 11
    pad_state = {p: 0 for p in range(1, 17)}
    moved = {}
    seen_buttons = set()
    seen_knobs = set()
    seen_pads = set()

    print("Monitoring for %ds. Press buttons, turn knobs, hit pads." % seconds)
    print("Each press should light THAT control's own lamp; each knob should")
    print("move ITS OWN bar on the left screen. Report anything mismatched.\n")

    end = time.time() + seconds
    last_draw = 0.0
    while time.time() < end:
        # Reading is also what keeps output flowing: this device refuses
        # writes while input is queued.
        for ep in (0x81, 0x84):
            try:
                data = s.dev.read(ep, 512, timeout=4)
            except s.core.USBError:
                continue

            if ep == 0x84:
                for i in range(1, min(63, len(data) - 1), 2):
                    hi, lo = data[i], data[i + 1]
                    pad = ((hi & 0xF0) >> 4) + 1
                    pressure = ((hi & 0x0F) << 8) | lo
                    if not 1 <= pad <= 16:
                        continue
                    was = pad_state[pad]
                    pad_state[pad] = pressure
                    if pressure > PAD_THRESHOLD >= was:
                        print("PAD  %2d   pressure %4d" % (pad, pressure))
                        seen_pads.add(pad)
                        bank.set_pad(pad, L.BRIGHT)
                    elif pressure <= PAD_THRESHOLD < was:
                        bank.set_pad(pad, L.OFF)
                continue

            if not len(data):
                continue
            if data[0] == 0x04:
                if len(data) > 6 and not (data[6] & 0x40):
                    continue
                bits = int.from_bytes(bytes(data[1:7]), "little")
                changed = bits ^ buttons
                buttons = bits
                for pos in range(42):
                    if not (changed >> pos) & 1:
                        continue
                    name = BUTTON_NAMES[pos] if pos < len(BUTTON_NAMES) else None
                    down = bool((bits >> pos) & 1)
                    if name is None:
                        print("BIT  %2d   %s  <-- UNMAPPED (bit 8 is unused)"
                              % (pos, "down" if down else "up"))
                        continue
                    print("BTN  bit %2d  %-16s %s" %
                          (pos, name, "DOWN" if down else "up"))
                    if down:
                        seen_buttons.add(name)
                    lamp = BUTTON_LAMP.get(name)
                    if lamp:
                        bank.set(lamp, L.BRIGHT if down else L.OFF)
            elif data[0] == 0x02:
                for wire in range(11):
                    off = 1 + wire * 2
                    if off + 1 >= len(data):
                        break
                    val = (data[off] << 8) | data[off + 1]
                    prev = encoders[wire]
                    encoders[wire] = val
                    if prev is None or val == prev:
                        continue
                    delta = val - prev
                    if delta > 32768:
                        delta -= 65536
                    elif delta < -32768:
                        delta += 65536
                    logical = WIRE_TO_LOGICAL[wire]
                    enc_values[logical] = val
                    moved[logical] = time.time()
                    seen_knobs.add(logical)
                    print("KNOB wire %2d -> logical %2d (%-5s) %+5d  raw %5d"
                          % (wire, logical, KNOB_LABEL[logical], delta, val))

        now = time.time()
        if now - last_draw > 0.14:
            last_draw = now
            recent = {i for i, t in moved.items() if now - t < 0.8}
            s.drain()
            s.send(0, bars_frame(enc_values, recent))
            s.send(1, pads_frame(pad_state))
            bank.flush(lambda ep, d: s._led(ep, d))

    print("\n--- coverage ---")
    print("buttons seen : %d of 41 mappable" % len(seen_buttons))
    unseen = [n for n in BUTTON_NAMES if n and n not in seen_buttons]
    if unseen:
        print("  not pressed: %s" % " ".join(unseen))
    print("knobs seen   : %s" % (" ".join(KNOB_LABEL[i]
                                          for i in sorted(seen_knobs)) or "none"))
    print("pads seen    : %s" % (" ".join(str(p) for p in sorted(seen_pads))
                                 or "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
