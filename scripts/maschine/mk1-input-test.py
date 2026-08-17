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
import mk1_encoders as E                                    # noqa: E402
import mk1_leds as L                                        # noqa: E402


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ANIM = _load("anim", "mk1-boot-animation.py")
HUB = _load("hub", "maschine-hub.py")

HOLD_LEVEL = 0x38          # sustained, not the 0x7F peak - see mk1_leds
BUTTON_NAMES = HUB.control_map_buttons()          # 42 entries, index 8 None
WIRE_TO_LOGICAL = HUB.ENCODER_WIRE_TO_LOGICAL
# cabl's threshold is 200. On this unit the pads report idle and crosstalk
# values up to 255 - pressing one pad shows its neighbours at 200-250 - so
# 200 turns resting noise into a stream of phantom hits. Real strikes read
# 512 upwards.
PAD_THRESHOLD = int(os.environ.get("MPC_MK1_PAD_THRESHOLD", "420"))

# Pad rows are inverted between the input report and the LED table: pressing
# the bottom row lit the top row, with left-right correct. Which of the two
# is "upside down" in absolute terms does not matter - what matters is that
# a pad lights itself - so the input index is mapped to the LED index by
# flipping the row and keeping the column.
def pad_input_to_led(pad):
    col, row = (pad - 1) % 4, (pad - 1) // 4
    return (3 - row) * 4 + col + 1

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


def bars_frame(values, moved, first=0, count=4):
    """Four big bars for the four knobs physically above this screen.

    This is the whole point of the layout: knobs 1-4 sit under the LEFT
    screen and 5-8 under the RIGHT, so drawing four bars per screen makes
    the check spatial - turn the knob directly above a bar and that bar
    should move. An eleven-bar strip crammed onto one screen proves the
    decoder works but says nothing about which knob is which, which is the
    only thing still unverified.

    Each bar carries its own number in tick marks along the top, so a bar
    can be identified even if the order turns out to be wrong.
    """
    lit = {}
    W, H = ANIM.W, ANIM.H
    slot = W // count
    for i in range(count):
        idx = first + i
        v = values[idx] if idx < len(values) else 0
        x0 = i * slot + 4
        wide = slot - 10
        active = idx in moved

        # Tick marks: i+1 blocks along the top edge, so the bar is labelled
        # on the panel rather than in my terminal.
        for t in range(i + 1):
            for x in range(x0 + t * 7, x0 + t * 7 + 5):
                for y in (1, 2, 3):
                    ANIM.add(lit, x, y, 0x1F)

        # Frame the bar so an empty one is still visible.
        for x in range(x0, x0 + wide):
            ANIM.add(lit, x, H - 1, 0x14)
            ANIM.add(lit, x, 7, 0x0A)
        for y in range(7, H):
            ANIM.add(lit, x0, y, 0x0A)
            ANIM.add(lit, x0 + wide - 1, y, 0x0A)

        # Absolute angle 0..999 as height, filled solid.
        h = int((v / float(E.FULL_TURN)) * (H - 12))
        level = 0x1F if active else 0x15
        for x in range(x0 + 1, x0 + wide - 1):
            for y in range(H - 2, H - 2 - h, -1):
                ANIM.add(lit, x, y, level)
    return ANIM.pack_sparse(lit)


def masters_frame(values, moved):
    """The three master knobs, drawn the same way on demand."""
    return bars_frame(values, moved, first=8, count=3)


def pads_frame(pressures):
    """The 4x4 grid, drawn as filled cells with pressure as height."""
    lit = {}
    W, H = ANIM.W, ANIM.H
    cw, ch = W // 4, H // 4
    for pad, p in pressures.items():
        led = pad_input_to_led(pad)
        col, row = (led - 1) % 4, (led - 1) // 4
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
    # Switch unsolicited reporting ON. Without this the device sends pads
    # and nothing else - which is exactly what the first run of this monitor
    # saw, and it looked like a broken button decoder rather than a missing
    # command.
    for _ in range(6):
        try:
            s.dev.write(L.EP_OUT, bytes(L.AUTO_MSG), timeout=300)
            print("AUTO_MSG sent: buttons and encoders enabled")
            break
        except s.core.USBError:
            s.drain()

    bank = L.LedBank()
    bank.all(L.OFF)
    bank.backlight(L.BACKLIGHT_DEFAULT)
    bank.flush(lambda ep, d: s._led(ep, d), force=True)

    buttons = 0
    tracker = E.EncoderTracker()
    enc_values = [0] * E.N_ENCODERS
    pad_state = {p: 0 for p in range(1, 17)}
    moved = {}
    seen_buttons = set()
    seen_knobs = set()
    seen_pads = set()

    print("Monitoring for %ds.\n" % seconds)
    print("LEFT screen  = four bars for the four knobs above it (1,2,3,4)")
    print("RIGHT screen = four bars for the four knobs above it (5,6,7,8)")
    print("Tick marks along the top of each bar are its number.\n")
    print("Turn the knob directly ABOVE a bar. If that bar moves, the map is")
    print("right. If a different one moves, tell me which bar moved for which")
    print("knob and I will reorder ERP_BYTES.\n")

    def handle(ep, data):
        """Decode one report. Returns True if a lamp changed."""
        nonlocal buttons
        dirty = False
        if ep == 0x84:
            for i in range(0, min(62, len(data) - 1), 2):
                lo, hi = data[i], data[i + 1]
                pad = ((hi & 0xF0) >> 4) + 1
                pressure = ((hi & 0x0F) << 8) | lo
                if not 1 <= pad <= 16:
                    continue
                was = pad_state[pad]
                pad_state[pad] = pressure
                if pressure > PAD_THRESHOLD >= was:
                    print("PAD  %2d   pressure %4d" % (pad, pressure))
                    seen_pads.add(pad)
                    bank.set_pad(pad_input_to_led(pad), HOLD_LEVEL)
                    dirty = True
                elif pressure <= PAD_THRESHOLD < was:
                    bank.set_pad(pad_input_to_led(pad), L.OFF)
                    dirty = True
            return dirty
        if not len(data):
            return False
        if data[0] == 0x04:
            if len(data) > 6 and not (data[6] & 0xC0):
                return False
            bits = int.from_bytes(bytes(data[1:7]), "little")
            changed = bits ^ buttons
            buttons = bits
            for pos in range(42):
                if not (changed >> pos) & 1:
                    continue
                name = BUTTON_NAMES[pos] if pos < len(BUTTON_NAMES) else None
                down = bool((bits >> pos) & 1)
                if name is None:
                    continue
                print("BTN  bit %2d  %-16s %s"
                      % (pos, name, "DOWN" if down else "up"))
                if down:
                    seen_buttons.add(name)
                lamp = BUTTON_LAMP.get(name)
                if lamp:
                    bank.set(lamp, HOLD_LEVEL if down else L.OFF)
                    dirty = True
        elif data[0] == 0x02:
            for logical, delta, pos in tracker.update(data):
                enc_values[logical] = pos
                moved[logical] = time.time()
                seen_knobs.add(logical)
                print("KNOB %-6s %+4d  -> position %3d/999"
                      % (E.NAMES[logical], delta, pos))
        return dirty

    def pump(rounds=1):
        """Read what is pending and DECODE it. Returns True if lamps changed.

        This is the drain, and it keeps what it reads. The device refuses
        output while input is queued, so frames cannot be sent without
        draining first - but an earlier version called a discarding drain
        here and silently ate every button and encoder report, which looked
        like a dead decoder. Draining and decoding are the same operation.
        """
        dirty = False
        for _ in range(rounds):
            got = False
            for ep in (0x81, 0x84):
                try:
                    data = s.dev.read(ep, 512, timeout=3)
                except s.core.USBError:
                    continue
                got = True
                dirty = handle(ep, data) or dirty
            if not got:
                break
        return dirty

    def send_pumped(index, frame):
        """Send a frame, emptying the input queue before EVERY chunk.

        Draining once per frame is not enough. A frame is 24 writes and the
        pad stream delivers a report every ~24ms, so the queue refills
        part-way through and the remaining chunks are accepted and silently
        discarded - the panel then shows nothing at all, with no error.
        Only mk1-screen-test.py ever displayed anything, and it is the only
        thing that drained before every single write.
        """
        d = index << 1
        def w(data):
            pump(rounds=1)
            s.w(data)
        w(bytes([d, 0x00, 0x03, 0x75, 0x00, 0x3F]))
        w(bytes([d, 0x00, 0x03, 0x15, 0x00, 0x54]))
        w(bytes([d, 0x01, 0xF7, 0x5C]) + frame[0:502])
        off = 502
        while off + 502 <= ANIM.FRAME_BYTES - 338:
            w(bytes([d + 1, 0x01, 0xF6]) + frame[off:off + 502])
            off += 502
        w(bytes([d + 1, 0x01, 0x52]) + frame[off:ANIM.FRAME_BYTES])

    end = time.time() + seconds
    last_draw = 0.0
    while time.time() < end:
        # Lamps first and immediately: two 33-byte writes, about a
        # millisecond, against ~50ms for a pair of screens.
        if pump(rounds=2):
            bank.flush(lambda ep, d: s._led(ep, d))

        now = time.time()
        if now - last_draw > 0.16:
            last_draw = now
            recent = {i for i, t in moved.items() if now - t < 0.8}
            # Empty the queue right before writing, decoding as we go. The
            # pad stream is continuous, so without this the queue is never
            # empty and every frame is accepted and thrown away by the
            # device - screens stay dark with no error anywhere.
            if pump(rounds=8):
                bank.flush(lambda ep, d: s._led(ep, d))
            send_pumped(0, bars_frame(enc_values, recent, first=0, count=4))
            send_pumped(1, bars_frame(enc_values, recent, first=4, count=4))

    print("\n--- coverage ---")
    print("buttons seen : %d of 41 mappable" % len(seen_buttons))
    unseen = [n for n in BUTTON_NAMES if n and n not in seen_buttons]
    if unseen:
        print("  not pressed: %s" % " ".join(unseen))
    print("knobs seen   : %s" % (" ".join(E.NAMES[i]
                                          for i in sorted(seen_knobs)) or "none"))
    print("pads seen    : %s" % (" ".join(str(p) for p in sorted(seen_pads))
                                 or "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
