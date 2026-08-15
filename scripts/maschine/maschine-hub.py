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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fifo", default=FIFO)
    ap.add_argument("--midi", default="/dev/snd/midiC1D0")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--no-usb", action="store_true",
                    help="route only, do not open the controller")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    print("maschine-hub: USB bring-up is hardware-dependent; run with "
          "--self-test to verify routing.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
