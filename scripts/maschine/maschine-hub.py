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

import mk1_display                                          # noqa: E402

# The display bridge, loaded here rather than inside main(). It was a local of
# main(), which is fine for the packer defined there but invisible to Mk1's
# methods - init_panel failed with "name 'disp' is not defined" the moment it
# tried to initialise a panel. Its filename has a hyphen, so it cannot be a
# plain import.
import importlib.util as _ilu                               # noqa: E402
_spec = _ilu.spec_from_file_location(
    "disp", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "mpc-mk1-display.py"))
disp = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(disp)
import mk1_encoders                                      # noqa: E402
import mk1_leds                                          # noqa: E402

class _FrameFailed(Exception):
    """One frame could not be delivered. Transient on this device."""


# Screen refresh budget. A mixer readout does not need more, and the device
# cannot sustain more alongside its input stream.
FRAME_INTERVAL = float(os.environ.get("MPCPI_FRAME_INTERVAL", "0.1"))
# How many consecutive failed frames mean the controller is really gone. One
# is normal; a run of them is not.
FRAME_FAIL_LIMIT = int(os.environ.get("MPCPI_FRAME_FAIL_LIMIT", "12"))

MPC_SCREEN = 0        # left: the emulator's LCD
DAW_SCREEN = 1        # right: our own panel renderer

# Dark content on a light field, on both screens. Override with
# MPC_MK1_SCREEN_INVERT=0 to get light-on-dark back.
INVERT_SCREEN = os.environ.get("MPC_MK1_SCREEN_INVERT", "1") not in ("0", "", "no")

EP_PADS = 0x84
EP_CTRL = 0x81

# Superseded by mk1_encoders.ERP_BYTES, which carries the panel order in
# the byte map itself. Kept only because tests reference it as the record of
# what cabl's processEncoders switch claimed: a remap of eleven sequential
# wire slots. That model was wrong - the encoders are not sequential values
# at all - so the permutation described a layout that does not exist.
ENCODER_WIRE_TO_LOGICAL = (8, 4, 10, 7, 3, 9, 6, 2, 0, 5, 1)
MASTER_NAMES = ("volume", "tempo", "swing")
MK1_VENDOR = 0x17CC

LCD_L = "/dev/shm/mpc-lcd"
LCD_R = "/dev/shm/daw-ui"
FIFO = "/run/daw-ctl.fifo"
# The MPC's own panel lamps, exported by mpcpi-autoplay.lua from the outputs
# akai/mpc2000.cpp already drives. Machine state, not our guess at it.
LAMPS = os.environ.get("MPCPI_LAMP_PATH", "/dev/shm/mpc-lamps")

# MPC lamp -> Maschine LED, on the button that SENDS that key. A lamp anywhere
# else is a light that reports something you press somewhere else, which is
# worse than no light: FULL LEVEL moved from GRID to SELECT to F7 during this
# work, and the lamp has to move with it.
LAMP_TO_LED = {
    "after":          "NoteRepeat",
    "full_level":     "DisplayButton7",
    "sixteen_levels": "Grid",
    "record":         "Rec",
    "play":           "Play",
    "bank_a":         "GroupA",
    "bank_b":         "GroupB",
    "bank_c":         "GroupC",
    "bank_d":         "GroupD",
    "track_mute":     "Mute",
}


# Set MPCPI_HUB_TRACE=1 to log every dispatched event to stderr, which under
# systemd means the journal. Added because "the buttons do nothing" was
# diagnosed four times by reasoning about the code instead of looking: with no
# trace there is no way to tell a button that was never decoded from one that
# was decoded and delivered somewhere nothing was listening.
TRACE = bool(os.environ.get("MPCPI_HUB_TRACE"))


def _trace(kind, payload, sink):
    if TRACE:
        print("hub: %-4s %-24s -> %s" % (kind, payload, sink),
              file=sys.stderr, flush=True)


# Send a key RELEASE to the emulator, or only the press.
#
# Off by default, because the releases are what corrupt the panel stream.
# Measured, with the hub's own trace and the machine's lamp export merged on
# time - every key PRESS lands correctly, and releases are inconsistent:
#
#   47.684 DOWN play  48.000 UP play   -> 48.04 after=1   (a play release lit AFTER)
#   03.781 DOWN after 03.80  after=1                      (press: correct)
#   03.981 UP   after                  -> 04.01 after=0   (this release toggled)
#   59.780 UP   after                  -> nothing         (this one did not)
#
# Patch 0042 injects each key event as TWO bytes - 0x84 or 0x85, then the
# keycode - into the panel byte stream. Doubling the event rate is what exposes
# it: once the stream slips by a single byte a command is read as a keycode and
# a keycode as a command, which is exactly a press landing on the wrong key.
#
# Back ON by default: the framing is fixed. 0047 made a key event atomic so it
# cannot be split, and 0048 gave the panel queue room so whole messages are not
# dropped either - measured, zero drops since. Releases are needed again
# because SHIFT is a real MPC key now and a key that is never released is a
# modifier stuck down forever. MPCPI_SEND_KEY_RELEASE=0 turns them off.
SEND_KEY_RELEASE = os.environ.get("MPCPI_SEND_KEY_RELEASE", "1") not in ("0", "", "no")


def _deliver_cmd(sinks, path, payload):
    """Write a DAW command, opening or reopening the FIFO as needed.

    Both failure directions cost us a working instrument:

      * The FIFO exists but the DAW is not reading it yet. Opening
        O_WRONLY|O_NONBLOCK then fails with ENXIO, and that was unhandled at
        startup, so the hub died before touching the controller - no screens,
        no pads, no knobs - because Ardour happened to be slower to start.
      * The DAW exits while the hub holds the write end. The next write raises
        BrokenPipeError, which also killed the hub. Every Ardour crash took the
        control surface down with it, which is exactly the "it worked and then
        everything disappeared again" that kept coming back.

    The instrument has to outlive the DAW. A command with nowhere to go is
    dropped, the fd is dropped with it, and the next command retries the open.
    """
    if sinks["fifo"] is None:
        try:
            sinks["fifo"] = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            _trace("cmd", payload, "dropped (no DAW reading %s)" % path)
            return False
    try:
        os.write(sinks["fifo"], (payload + "\n").encode())
        _trace("cmd", payload, path)
        return True
    except OSError as exc:
        try:
            os.close(sinks["fifo"])
        except OSError:
            pass
        sinks["fifo"] = None
        _trace("cmd", payload, "dropped (%s); will reopen" % exc.__class__.__name__)
        return False

# Which mode each hold-button enters, from the control map.
HOLD_MODES = {v["button"]: k for k, v in control_map.MODES.items()
              if v.get("button")}


class Router:
    """Turns a control event into either MIDI bytes or a daw-ctl line."""

    def __init__(self, lanes=None, strips=None):
        self.lanes = lanes or ["GTR1", "GTR2", "MIC", "AUX"]
        self.strips = strips or ["MPC", "GTR1", "GTR2", "MIC",
                                 "LOOP", "VERB", "DLY", "AUX"]
        # One knob per strip is the whole point of the layout: 8 display
        # knobs, 8 strips, 8 channels on the interface. If these ever
        # diverge, some strip silently loses its knob - which is exactly
        # what happened when only knobs 5-8 were mapped.
        if len(self.strips) != 8:
            raise ValueError(
                "expected 8 mixer strips to match the 8 display knobs, got %d"
                % len(self.strips))
        self.shift = False
        # Which instrument the panel drives. See control_map.SURFACE_TOGGLE.
        self.surface = "MPC"
        # What each button sent on its press edge, so the RELEASE can send the
        # matching note-off. Keyed by button name, not by target: shift can be
        # let go between press and release, and the key that must be released
        # is the one that was actually pressed.
        self.pressed = {}
        self.held = None          # a mode button currently held
        self.pinned = None        # a latched mode
        self.page = "LOOP"

    @property
    def mode(self):
        return self.held or self.pinned or control_map.DEFAULT_MODE

    # --- buttons ---

    def wants(self, target):
        """Is this target for the instrument the panel is currently driving?

        A button with no binding for the current surface does NOTHING. That is
        the point of a mode switch: in MPC mode nothing reaches Ardour, and in
        DAW mode nothing reaches the MPC, so a press can never land somewhere
        you were not looking.
        """
        if not target or target == "modifier":
            return False
        if target.startswith("mode:"):
            return True          # hold-modes are the controller's own state
        return target.startswith("mpc:") == (self.surface == "MPC")

    def button(self, name, down):
        """Returns a list of (kind, payload); kind is 'midi', 'cmd' or 'surface'.

        ONE flat table per surface and no shifted variants. The MPC's own SHIFT
        key does that job and lives on the SHIFT button, so a button means one
        thing and the machine decides what holding shift changes about it.
        """
        # SHIFT is both our modifier for the pad layer and a real MPC key.
        if name == "shift":
            self.shift = down
            target = control_map.MPC_BUTTONS.get("shift")
            if self.surface != "MPC" or not target:
                return []
            if down:
                self.pressed[name] = target
                return [("midi", target)]
            sent = self.pressed.pop(name, None)
            return [("midi_up", sent)] if (sent and SEND_KEY_RELEASE) else []

        if name == control_map.SURFACE_TOGGLE:
            if not down:
                return []
            self.surface = ("DAW" if self.surface == "MPC" else "MPC")
            return [("surface", self.surface)]

        table = (control_map.MPC_BUTTONS if self.surface == "MPC"
                 else control_map.DAW_BUTTONS)
        target = table.get(name)

        if not down:
            sent = self.pressed.pop(name, None)
            if sent and SEND_KEY_RELEASE and sent.startswith("mpc:"):
                return [("midi_up", sent)]
            if target and target.startswith("mode:") and self.pinned != self.held:
                self.held = None
                return [("cmd", "mode %s" % self.mode)]
            return []

        if target:
            if target.startswith("mpc:"):
                self.pressed[name] = target
                return [("midi", target)]
            if target.startswith("mode:"):
                self.held = target.split(":", 1)[1]
                return [("cmd", "mode %s" % self.mode)]
            rest = target.split(":", 1)[1]
            if rest.startswith("page:"):
                self.page = rest.split(":", 1)[1]
                return [("cmd", "page %s" % self.page)]
            return [("cmd", rest.replace(":", " "))]

        # PIN latches whichever mode is held. Controller state, both surfaces.
        if name == control_map.PIN_BUTTON and self.held:
            self.pinned = None if self.pinned == self.held else self.held
            return [("cmd", "mode %s" % self.mode)]

        # In DAW mode the display buttons follow whatever the page shows.
        if self.surface == "DAW" and name.startswith("display"):
            idx = int(name[-1]) - 1
            labels = control_map.BUTTONS_RIGHT_BY_PAGE.get(
                self.page, ("", "", "", ""))
            if 4 <= idx < 4 + len(labels):
                return [("cmd", "button %s %s" % (self.page, labels[idx - 4]))]
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

    def master(self, name, delta):
        """The three master knobs: VOLUME, TEMPO, SWING.

        Separate hardware from the eight under-screen knobs, and routed by
        name so they can never fall into knob() as columns 8-10 and quietly
        move a mixer strip.

        Targets come from control_map.MASTER_KNOBS: the DAW's master fader,
        the MPC's note-variation slider, and the MPC's DATA wheel. Anything
        beginning "mpc:" is a MIDI target for the emulator; the rest is a DAW
        command.
        """
        target = control_map.MASTER_KNOBS.get(name)
        if target is None:
            return []
        if target.startswith("mpc:"):
            return [("midi", "%s:%+d" % (target, delta))]
        # "master +4", not "master master +4": the DAW master is not a
        # named strip, it is the one thing a master command can mean.
        return [("cmd", "master %+d" % delta)]

    def knob(self, index, delta):
        """Eight knobs under the screens: ONE PER MIXER STRIP.

        The hardware and the mixer line up exactly - four knobs under each
        screen, eight strips, and eight channels of the 22-channel interface
        - so the mapping is 1:1 and needs no paging to reach a channel.

        It used to spend knobs 1-4 on MPC-side controls and map only 5-8
        onto strips, which reached strips 1-4 and left LOOP, VERB, DLY and
        AUX with no knob at all: half the desk was unreachable while four
        knobs duplicated things the MPC's own panel already does.

        The MPC's own continuous controls did not need a layer here in the
        end: the DATA wheel and the note-variation slider went to the SWING
        and TEMPO knobs, which are separate hardware. So SHIFT stays unspent
        and all eight knobs mean one thing each. The three
        master knobs (VOLUME/TEMPO/SWING) are separate hardware and are
        routed by name, never through here.
        """
        if self.page in ("MIX", "LOOP"):
            strip = self.strips[index] if index < len(self.strips) else None
            if strip:
                return [("cmd", "knob %s %s %+d" % (self.page, strip, delta))]
        return [("cmd", "knob %s %d %+d" % (self.page, index, delta))]


def self_test():
    r = Router()

    # ONE FUNCTION PER BUTTON, and no button may claim two MPC keys.
    import collections
    for surface, table in (("MPC", control_map.MPC_BUTTONS),
                           ("DAW", control_map.DAW_BUTTONS)):
        counts = collections.Counter(table.values())
        dupes = [t for t, n in counts.items() if n > 1]
        assert not dupes, "%s: two buttons send %s" % (surface, dupes)

    # Every mapped name must be one the DECODER can send. "restart" was mapped
    # and never sent, so PLAY START was unreachable and nothing said so.
    import importlib.util as _u
    _s = _u.spec_from_file_location("mk1in", os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "mpc-mk1-input.py"))
    _m = _u.module_from_spec(_s); _s.loader.exec_module(_m)
    known = {b for b in _m.MK1_BUTTONS if b} | {"pad_mode"}
    for table in (control_map.MPC_BUTTONS, control_map.DAW_BUTTONS):
        unknown = set(table) - known
        assert not unknown, "mapped buttons the decoder never sends: %s" % sorted(unknown)

    # Every MPC key the machine has must be reachable, from a button or a pad.
    reachable = {t.split(":", 1)[1] for t in control_map.MPC_BUTTONS.values()
                 if t.startswith("mpc:")}
    reachable |= {t.split(":", 1)[1] for t in control_map.SHIFT_PADS.values()
                  if t.startswith("mpc:")}
    missing = set(_m.KEY) - reachable
    assert not missing, "MPC keys nothing can press: %s" % sorted(missing)

    # The six soft keys are on the six display buttons under the screens.
    for i in range(1, 7):
        assert control_map.MPC_BUTTONS["display%d" % i] == "mpc:soft%d" % i

    # Transport.
    assert r.button("play", True) == [("midi", "mpc:play")]
    r.button("play", False)
    assert r.button("mute", True) == [("midi", "mpc:stop")]
    r.button("mute", False)
    assert r.button("loop", True) == [("midi", "mpc:play_start")]
    r.button("loop", False)

    # SHIFT is the MPC's own SHIFT key, held, AND our pad modifier.
    ev = r.button("shift", True)
    assert ev == [("midi", "mpc:shift")], ev
    assert r.shift is True
    assert r.pad(0, 100) == [("midi", "mpc:song")]      # SHIFT+pad 1 types a 1
    up = r.button("shift", False)
    assert up == ([("midi_up", "mpc:shift")] if SEND_KEY_RELEASE else [])
    assert r.shift is False
    assert r.pad(0, 100) == [("midi", "pad:0:100")]     # unshifted, a drum pad

    # NOTE REPEAT sends TAP TEMPO, which is what the MK1 prints above it; the
    # MPC's own note repeat is AFTER, on SAMPLING beside it.
    assert control_map.MPC_BUTTONS["note_repeat"] == "mpc:tap_tempo"
    assert control_map.MPC_BUTTONS["sampling"] == "mpc:after"
    # FULL LEVEL is on F7, which the MPC does not have - it has six soft keys.
    assert control_map.MPC_BUTTONS["display7"] == "mpc:full_level"

    # The surface toggle isolates the two instruments.
    assert r.surface == "MPC"
    assert r.button(control_map.SURFACE_TOGGLE, True) == [("surface", "DAW")]
    assert r.button("play", True) == []                 # MPC unreachable now
    r.button("play", False)
    assert r.button("group_f", True) == [("cmd", "page MIX")]
    r.button("group_f", False)
    assert r.button(control_map.SURFACE_TOGGLE, True) == [("surface", "MPC")]
    assert r.button("play", True) == [("midi", "mpc:play")]
    r.button("play", False)

    # Knobs: one per mixer strip, and the master knobs by name.
    assert r.knob(4, -2)[0][0] == "cmd"

    # The grid is not upside down: pad 1 is bottom-left.
    flip = Mk1._pad_index
    assert flip(12) == 0 and flip(15) == 3
    assert sorted(flip(i) for i in range(16)) == list(range(16))
    assert all(flip(i) % 4 == i % 4 for i in range(16))

    # One lamp, one meaning - and on the button that actually sends the key.
    assert len(set(LAMP_TO_LED.values())) == len(LAMP_TO_LED)
    _led_of = {"display7": "DisplayButton7", "grid": "Grid", "play": "Play",
               "rec": "Rec", "sampling": "NoteRepeat"}
    for _btn, _led in _led_of.items():
        _t = control_map.MPC_BUTTONS.get(_btn, "")
        _key = _t.split(":", 1)[1] if _t.startswith("mpc:") else None
        if _key and _key in LAMP_TO_LED:
            assert LAMP_TO_LED[_key] == _led, \
                "%s lamp is on %s but %s sends it" % (_key, LAMP_TO_LED[_key], _btn)

    print("maschine-hub self-test PASS: one function per button, every MPC key "
          "reachable, surfaces isolated, pads upright")


class Mk1:
    """The USB side: one owner for both screens and all input.

    Report formats come from cabl (see docs/maschine-mk1-display-protocol.md):
    endpoint 0x84 carries pads, 0x81 carries buttons and encoders with the
    first byte selecting which. Pads report 12-bit pressure continuously
    rather than note on/off, so a hit is a threshold crossing and velocity
    is taken from the leading edge.
    """

    VENDOR, PRODUCT = 0x17CC, 0x0808
    # Pad on/off thresholds, with hysteresis and a gap wide enough to reject
    # the controller's own scan bleed.
    #
    # There was one threshold, 200, used for both edges. Two things were wrong
    # with that. Measured with --pad-stats while playing:
    #
    #   real hits          768 .. 3072
    #   bleed onto another  84 .. 224
    #
    # and the bleed always lands on the PREVIOUSLY SCANNED pad index - raw N
    # into raw N-1, including raw 8 into raw 7 and raw 0 into raw 15, which are
    # opposite corners of the grid. So it is not analog crosstalk between
    # neighbouring pads; it is the pad ADC's sample-and-hold not settling
    # between channels, and it is uniform across all sixteen. At a threshold of
    # 200 a bleed of 224 is a note-on: hitting one pad fires its scan
    # neighbour, which is what "the hi-hat repeats when I play fast" was.
    #
    # ON at 400 clears the worst observed bleed by 176 and still sits far below
    # the softest real hit. OFF at 150 gives hysteresis, so a pad decaying
    # through the on-threshold cannot chatter a second note-on.
    PAD_ON_THRESHOLD = int(os.environ.get("MPCPI_PAD_ON", "300"))
    # OFF is deliberately far below ON, not just a little below.
    #
    # The three guards are all here and all necessary: a note-on threshold
    # ABOVE the note-off threshold, a latch so a pad must fall through OFF
    # before it can fire again, and a time lockout. At OFF=120 a hard hit could
    # still ring down through 120 and back up through 300 inside one stroke,
    # which is a legitimate pair of crossings and therefore not something the
    # latch can reject - only the DEPTH it has to fall to can.
    #
    # 60 means the pad has to come most of the way back to rest. On a one-shot
    # sampler the later note-off costs nothing.
    PAD_OFF_THRESHOLD = int(os.environ.get("MPCPI_PAD_OFF", "60"))
    # Fraction of the NEXT-SCANNED channel subtracted from each pad, to cancel
    # the sample-and-hold bleed described above. MPCPI_PAD_BLEED overrides it.
    #
    # The bleed is proportional to the source, not a fixed offset - measured
    # source -> bleed pairs ran 256->34 and 2304->197, a ratio of 0.034..0.292
    # with a median of 0.108. So a flat subtraction cannot work: 150 would erase
    # a soft real hit and still leave ~750 of a hard hit's bleed, which is why
    # raising the threshold alone stopped the quiet false triggers and not the
    # loud ones. 0.20 cancels every pair captured with 70 counts to spare.
    #
    # The cost, stated plainly: scan-adjacent pads are usually also physically
    # adjacent within a row, so hitting two neighbours together subtracts real
    # signal from the softer one. At 0.20 a 768 hit alongside a 3072 hit lands
    # at 154 and is dropped. Lower MPCPI_PAD_BLEED if rolls lose notes; raise it
    # if hard hits still double-trigger their neighbour.
    PAD_BLEED = float(os.environ.get("MPCPI_PAD_BLEED", "0.20"))
    # Minimum time between note-ons on the SAME pad, seconds.
    #
    # Bleed cancellation and hysteresis both address one pad being fired by
    # ANOTHER pad's signal. Neither can stop a pad retriggering itself: a hit
    # decays, the sensor rings, and the pressure crosses the on-threshold a
    # second time. That is a real crossing, so no threshold arrangement rejects
    # it - only time does. This is what a drum pad calls retrigger lockout.
    #
    # 100ms per pad, which allows 10 hits a second ON ONE PAD. This is a floor
    # on the SAME pad only - two different pads can still be hit together, and
    # a roll alternating pads is unaffected.
    #
    # Worth knowing where the ceiling is: straight 16ths at 150bpm is 10 hits a
    # second, so a fast single-pad roll can reach this. Lower
    # MPCPI_PAD_RETRIGGER_MS if a genuine roll starts losing notes.
    PAD_RETRIGGER_S = float(os.environ.get("MPCPI_PAD_RETRIGGER_MS", "100")) / 1000.0
    # Switch debounce for the BUTTONS, seconds.
    #
    # _ctrl diffed the raw bitfield with no debounce at all, so a bouncy
    # contact - which every mechanical switch is - sent as many press/release
    # pairs as it bounced. On NOTE REPEAT, a toggle, an even number of bounces
    # leaves the state where it started and an odd number flips it: the button
    # works "sometimes", which is exactly how it was described.
    #
    # 12ms is longer than contact bounce and far shorter than a deliberate
    # double-tap, so nothing playable is lost.
    BUTTON_DEBOUNCE_S = float(os.environ.get("MPCPI_BUTTON_DEBOUNCE_MS", "12")) / 1000.0
    # Kept as the name the diagnostic reports against.
    PAD_THRESHOLD = PAD_ON_THRESHOLD

    def __init__(self):
        import usb.core                                   # noqa: F401
        import usb.util                                   # noqa: F401
        self.usb = usb
        self.dev = usb.core.find(idVendor=self.VENDOR, idProduct=self.PRODUCT)
        if self.dev is None:
            raise RuntimeError("no Maschine MK1 (17cc:0808) found")
        # Detach EVERY interface, not just 0. snd-usb-caiaq claims this
        # device (17cc:0808 is in its alias list) and binds per
        # interface, so detaching interface 0 alone leaves another held
        # and the first write fails as EBUSY - which reads like a
        # permissions problem. That is cabl issue #10, never solved
        # there. modprobe.d/blacklist-caiaq.conf should mean there is
        # nothing to detach; this is the belt to its braces.
        for n in self._interfaces():
            try:
                if self.dev.is_kernel_driver_active(n):
                    self.dev.detach_kernel_driver(n)
            except (usb.core.USBError, NotImplementedError):
                pass
        # Claim and select the altsetting FIRST; set_configuration only as a
        # fallback. Every open that called set_configuration first has
        # eventually failed with LIBUSB_ERROR_OTHER or EIO, and every one that
        # went straight to claim + altsetting has worked. This class still had
        # the old order, so the hub crash-looped on "USBError [Errno 5]
        # Input/Output Error" while the animation - which was fixed - worked
        # fine on the same device.
        #
        # ALTSETTING 1 is mandatory: in the default altsetting the pad
        # endpoint 0x84 and the display endpoint 0x08 do not exist at all.
        last = None
        for attempt in range(3):
            if attempt == 1:
                try:
                    self.dev.set_configuration()
                except usb.core.USBError:
                    pass
            elif attempt == 2:
                try:
                    usb.util.release_interface(self.dev, 0)
                except usb.core.USBError:
                    pass
                time.sleep(0.4)
            try:
                usb.util.claim_interface(self.dev, 0)
            except usb.core.USBError:
                pass
            try:
                self.dev.set_interface_altsetting(
                    interface=0, alternate_setting=mk1_leds.ALTSETTING)
                last = None
                break
            except usb.core.USBError as e:
                last = e
        if last is not None:
            raise RuntimeError(
                "cannot select altsetting %d: %s - unplug and replug the "
                "controller" % (mk1_leds.ALTSETTING, last))
        self.pad_state = [0] * 16
        self.pad_on = [False] * 16
        self.pad_raw = [0] * 16
        self.pad_last_on = [0.0] * 16
        self.pad_suppressed = 0
        self.buttons = 0
        self.button_changed_at = [0.0] * 48
        self.button_bounces = 0
        self.encoders = mk1_encoders.EncoderTracker()
        self.frames = {}
        self.leds = mk1_leds.LedBank()
        self._lamp_line = None
        self.init_panel()

    def release(self):
        """Give the interface back, so the NEXT start can claim it.

        Without this, a hub that exits for any reason leaves the interface
        claimed and the following start fails with "cannot select altsetting 1:
        Other error". That is what turned one bad frame into 27 restarts and a
        progressively more wedged device - the failure was not the crash, it
        was that nothing cleaned up after it.
        """
        try:
            self.usb.util.release_interface(self.dev, 0)
        except Exception:
            pass
        try:
            self.usb.util.dispose_resources(self.dev)
        except Exception:
            pass

    def init_panel(self):
        """Initialise both displays and light the backlight.

        THE HUB NEVER DID THIS. It only ever sent frames, and appeared to work
        because the boot animation had initialised the panels moments earlier.
        Unplug and replug the controller - or restart the hub after the
        animation is long gone - and every frame goes into a panel that was
        never switched on. The screens stay dark with nothing failing.
        //
        Writes drain first, because init commands are exactly what gets
        accepted-and-discarded when the input queue is backed up. 22 commands
        once, so the cost is irrelevant.
        """
        def w(data):
            for _ in range(40):
                for ep in mk1_leds.IN_ENDPOINTS:
                    try:
                        self.dev.read(ep, 512, timeout=2)
                    except Exception:
                        pass
                try:
                    self.dev.write(disp.EP_DISPLAY, data, timeout=250)
                    return
                except Exception:
                    continue
            raise RuntimeError("display init write failed")

        # AUTO_MSG first: it enables the button and encoder reports, and
        # sending it after the display init disturbs the display controller.
        for _ in range(6):
            try:
                self.dev.write(mk1_leds.EP_OUT, bytes(mk1_leds.AUTO_MSG),
                               timeout=300)
                break
            except Exception:
                for ep in mk1_leds.IN_ENDPOINTS:
                    try:
                        self.dev.read(ep, 512, timeout=3)
                    except Exception:
                        pass

        for index in (0, 1):
            for pkt in mk1_display.packets(index, disp.CONTRAST):
                if pkt is None:
                    time.sleep(mk1_display.SLEEP_SECONDS)
                else:
                    w(pkt)

        # The backlight is an LED byte: without it both panels stay dark
        # however correct the frames are.
        self.leds.all(mk1_leds.OFF)
        self.leds.backlight(mk1_leds.BACKLIGHT_DEFAULT)
        self.leds.flush(lambda ep, data: self._led_write(ep, data), force=True)

    def _led_write(self, ep, data):
        for _ in range(20):
            for e in mk1_leds.IN_ENDPOINTS:
                try:
                    self.dev.read(e, 512, timeout=2)
                except Exception:
                    pass
            try:
                self.dev.write(ep, data, timeout=250)
                return
            except Exception:
                continue

    def _interfaces(self):
        try:
            return [i.bInterfaceNumber
                    for i in self.dev.get_active_configuration()]
        except Exception:
            return [0]

    def init_device(self):
        """Enable input reporting and light the panel.

        Neither step is optional. AUTO_MSG (0x0B) is what switches
        unsolicited button and encoder reports on - without it the device
        streams pads and nothing else, which reads exactly like a broken
        decoder. And the display backlight is an LED byte, so both screens
        stay dark until the LED block has been written at least once.
        """
        self.dev.write(mk1_leds.EP_OUT, bytes(mk1_leds.AUTO_MSG),
                       timeout=1000)
        self.leds.all(mk1_leds.OFF)
        self.leds.backlight(mk1_leds.BACKLIGHT_DEFAULT)
        return self.flush_leds(force=True)

    def show_lamps(self, path=LAMPS):
        """Mirror the MPC's panel lamps onto the controller.

        Reads the export written by mpcpi-autoplay.lua rather than tracking
        what we sent: FULL LEVEL and NOTE REPEAT are toggles inside the MPC,
        and a lamp driven from the hub's own guess drifts the moment the state
        changes any other way - a project load, the machine's own panel, a
        reset. A lamp that lies is worse than one that is dark.

        Returns True if anything changed, so the caller can skip the USB write.
        """
        try:
            with open(path, "r") as f:
                line = f.read()
        except OSError:
            return False
        if line == self._lamp_line:
            return False
        self._lamp_line = line
        state = {}
        for pair in line.split():
            name, _, value = pair.partition("=")
            state[name] = value == "1"

        changed = False
        for name, led in LAMP_TO_LED.items():
            want = mk1_leds.BRIGHT if state.get(name) else mk1_leds.OFF
            if self.leds.get(led) != want:
                self.leds.set(led, want)
                changed = True

        return changed

    def flush_leds(self, force=False):
        """Push dirty LED groups. Cheap when nothing changed."""
        return self.leds.flush(
            lambda ep, data: self.dev.write(ep, data, timeout=1000),
            force=force)

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


    @staticmethod
    def _pad_index(raw):
        """Hardware pad number to MPC pad number.

        The MK1 numbers its pads from the TOP row down; the MPC - and every
        other pad grid, and the note mapping in encode_midi, which starts at
        note 36 - numbers them from the BOTTOM row up. Left it unconverted and
        the grid plays upside down: the top row triggers what is printed on the
        bottom row.

        Flip the row, keep the column. Do it here, at the hardware boundary, so
        everything downstream - the router, the PAD MODE command map, the
        printed shift functions - speaks one coordinate system.
        """
        return (3 - (raw >> 2)) * 4 + (raw & 3)

    def _pads(self, data, router):
        out = []
        # Take the whole report in first. The bleed correction needs the
        # NEIGHBOURING channel's value from this same scan, so a pad cannot be
        # decided until its neighbour has been read.
        seen = []
        for i in range(1, len(data) - 1, 2):
            hi, lo = data[i], data[i + 1]
            raw = (hi & 0xF0) >> 4
            if raw > 15:
                continue
            self.pad_raw[raw] = ((hi & 0x0F) << 8) | lo
            seen.append(raw)
        for raw in seen:
            # Channel k carries a fraction of channel k+1, wrapping at 15->0.
            #
            # Subtract only when this pad's own reading is SMALL relative to its
            # neighbour's. Unconditional subtraction landed real hits right on
            # the threshold - a 600 hit beside a ringing 1500 became 300, so it
            # crossed, fell back under the off-threshold and crossed again, and
            # the retrigger lockout then ate the genuine notes. The journal was
            # full of "p1 retrigger suppressed" while the pad felt dead.
            #
            # Measured bleed never exceeded 29% of its source, so anything above
            # half the neighbour's value is this pad being played, not bleed.
            own = self.pad_raw[raw]
            neighbour = self.pad_raw[(raw + 1) % 16]
            pressure = own
            if neighbour > own * 2:
                pressure = own - int(neighbour * self.PAD_BLEED)
            if pressure < 0:
                pressure = 0
            pad = self._pad_index(raw)
            self.pad_state[pad] = pressure
            # Two thresholds, and a latched per-pad state rather than a
            # comparison of the last two samples. With one threshold, a pad
            # decaying through it - or scan bleed from the neighbouring
            # channel touching it - is a fresh note-on every time it crosses.
            if not self.pad_on[pad] and pressure > self.PAD_ON_THRESHOLD:
                self.pad_on[pad] = True
                now = time.monotonic()
                if (now - self.pad_last_on[pad]) < self.PAD_RETRIGGER_S:
                    self.pad_suppressed += 1
                    _trace("pad", "p%d retrigger suppressed" % pad, "dropped")
                    continue
                self.pad_last_on[pad] = now
                # Velocity from the leading edge: the stream is pressure,
                # not note-on, so the first crossing is the hit.
                out += router.pad(pad, min(127, pressure >> 5))
            elif self.pad_on[pad] and pressure <= self.PAD_OFF_THRESHOLD:
                self.pad_on[pad] = False
                out += router.pad(pad, 0)
        return out

    def _ctrl(self, data, router):
        if not data:
            return []
        kind = data[0]
        out = []
        if kind == 0x04:
            # Button bitfield, 8 bytes: [0x04][6 bytes of bits][status].
            #
            # cabl gates on data[6] & 0x40. On this hardware the bit is
            # 0x80 - an idle report reads 04 00 00 00 00 00 80 00 - so that
            # gate rejected EVERY button report the device ever sent, and
            # did it silently. Accept either bit.
            #
            # Neither bit can be mistaken for a button: they sit at bit
            # positions 46 and 47, past the 42 names in the table.
            if len(data) > 6 and not (data[6] & 0xC0):
                return []
            # SIX bytes, 1..6 inclusive. This read five, covering bit
            # positions 0..39 - and MK1 has 42 buttons, with NoteRepeat
            # at 40 and Play at 41 living in byte 6. Play, the single
            # most used control on the panel, could not be pressed.
            #
            # Byte 6 also carries the validity flag at bit 6, which is
            # bit position 46 overall - past the 42 names in the table,
            # so it is never mistaken for a button.
            raw_bits = int.from_bytes(bytes(data[1:7]), "little")
            # Debounce per button, against the DEBOUNCED state - not against
            # the last raw report. Comparing raw to raw lets a bounce through
            # as soon as it settles differently for one report.
            now = time.monotonic()
            bits = self.buttons
            for pos in range(48):
                raw = (raw_bits >> pos) & 1
                if raw == ((bits >> pos) & 1):
                    continue
                if (now - self.button_changed_at[pos]) < self.BUTTON_DEBOUNCE_S:
                    self.button_bounces += 1
                    continue
                self.button_changed_at[pos] = now
                bits ^= (1 << pos)
            changed = bits ^ self.buttons
            self.buttons = bits
            if TRACE and changed:
                names = control_map_buttons()
                moved = []
                for _p in range(48):
                    if (changed >> _p) & 1:
                        _n = names[_p] if _p < len(names) else None
                        moved.append("%d=%s%s" % (_p, _n or "UNNAMED",
                                                  "" if (bits >> _p) & 1 else ":up"))
                _trace("btn", "raw=%s" % bytes(data[1:7]).hex(" "),
                       " ".join(moved))
            for pos, name in enumerate(control_map_buttons()):
                if name and (changed >> pos) & 1:
                    out += router.button(name, bool((bits >> pos) & 1))
        elif kind == 0x02:
            # Eleven endless pots. NOT counters: each knob is a pair of
            # analog channels that must be interpolated into an absolute
            # angle, and the byte pairs are scattered rather than
            # sequential. See mk1_encoders - the previous version of this
            # branch read sequential 16-bit values and diffed them, which
            # produced continuous meaningless movement on every knob.
            for logical, delta, _pos in self.encoders.update(data):
                if logical < 8:
                    out += router.knob(logical, delta)
                else:
                    out += router.master(MASTER_NAMES[logical - 8], delta)
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
        names = m.MK1_BUTTONS
        if len(names) < 42:
            raise RuntimeError(
                "MK1_BUTTONS has %d entries, expected 42" % len(names))
        return names
    except Exception as e:
        # Returning [] here meant every button silently stopped working,
        # with the hub running and the device responding. An input map
        # that cannot be loaded is not a degraded mode, it is a broken
        # one - say so.
        raise RuntimeError(
            "cannot load the MK1 button map from mpc-mk1-input.py: %s" % e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fifo", default=FIFO)
    # VirMIDI 0-0's raw device. Writing here makes the bytes appear as INPUT
    # on that same port, which is what the emulator opens with
    # -midiin "VirMIDI 0-0".
    #
    # This defaulted to /dev/snd/midiC1D0, which is a card NUMBER, and card
    # numbering follows enumeration order: card 1 was the UAC2 gadget on the
    # netboot root and is the USB audio codec on the SD card. So the hub was
    # writing MIDI into an audio interface, and no pad reached the emulator.
    ap.add_argument("--midi", default="/dev/snd/midiC0D0",
                    help="raw MIDI device to write pads/buttons into; must be "
                         "the port the emulator opens with -midiin")
    ap.add_argument("--pc-midi", default=None,
                    help="also mirror the controller to this MIDI port "
                         "(the USB gadget's cable 2), so a computer sees "
                         "the Maschine as an ordinary MIDI controller")
    ap.add_argument("--left", default=LCD_L)
    ap.add_argument("--right", default=LCD_R)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--led-only", default=None, metavar="NAME",
                    help="diagnostic: light exactly ONE led by name and hold "
                         "it, so the wire order can be checked against the "
                         "panel. Stop mpcpi-maschine first")
    ap.add_argument("--led-walk", type=float, default=None, metavar="SECONDS",
                    help="diagnostic: light every led in turn for SECONDS "
                         "each, printing the name, to find where an index "
                         "really lands. Stop mpcpi-maschine first")
    ap.add_argument("--pad-stats", type=float, default=None, metavar="SECONDS",
                    help="diagnostic: read raw pad pressures for SECONDS and "
                         "print a grid of resting/peak values and threshold "
                         "crossings, to see whether a chattering pad is sitting "
                         "on PAD_THRESHOLD. Stop mpcpi-maschine first: the hub "
                         "claims the controller exclusively")
    ap.add_argument("--no-usb", action="store_true",
                    help="route only, do not open the controller")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.no_usb:
        print("routing only; no controller opened")
        return 0

    if args.led_only or args.led_walk is not None:
        return led_probe(args.led_only, args.led_walk)

    if args.pad_stats is not None:
        return pad_stats(args.pad_stats)

    router = Router()
    try:
        mk1 = Mk1()
    except Exception as exc:
        print("maschine-hub: %s" % exc, file=sys.stderr)
        return 1

    # Events decoded while pushing a frame are collected here and dispatched
    # by the caller, so nothing read during a screen update is lost.
    out = []
    self_ref = [None]
    router_ref = [router]

    def packer(dev, index, px, w, h):
        """Pack and send one screen, draining the input queue as it goes.

        Two things the hub was getting wrong.
        //
        It wrote frames without draining, and this device accepts writes
        while its input queue is backed up then FAILS them - the hub
        crash-looped on "USBError [Errno 5]" after a frame or two, which is
        why one screen appeared and the other stayed black with vertical
        tearing: partial frames from a process that kept restarting. The pad
        stream delivers a report every ~24ms and a frame is 24 writes, so the
        queue refills mid-frame; a sip before each chunk is what keeps it
        clear.
        //
        And it packed the MPC's 1-bit LCD through pack_display's default,
        which scales a source byte as a brightness LEVEL. A 1-bit panel's
        pixels are 1, so lit pixels came out at level 1 of 31 - present, but
        so dim as to be barely there. level=0x1F makes a lit pixel fully lit,
        which is what a monochrome source means.
        """
        # BOTH screens render inverted: dark content on a light field.
        #
        # That is how the MPC2000XL's own LCD reads - dark pixels on light
        # green - so a set pixel in its framebuffer means DARK, and mapping
        # set -> bright turned the panel inside out with the text becoming
        # the background. The DAW panel is our own renderer and could go
        # either way; inverted matches the MPC beside it and is easier to
        # read on a dim STN panel, where a mostly-lit field gives the eye
        # more to work with than a mostly-dark one.
        #
        # Kept per-call rather than global because the two screens genuinely
        # could need opposite senses - one flag for both is what made
        # MPC_MK1_INVERT unable to serve either properly.
        frame = disp.pack_display(w, h, px, level=0x1F, invert=INVERT_SCREEN)

        # The drain below DECODES what it reads instead of discarding it.
        #
        # This is what made input and display appear to break each other. A
        # frame is 24 chunks and each one drains the IN endpoints first - which
        # is required, or the device rejects the write - so a frame threw away
        # up to 48 reports. Every button press that happened to land during a
        # screen update was silently eaten, and screen updates are almost
        # always happening. The hub emitted zero MIDI over thirty seconds of
        # button pressing while decoding those same buttons correctly in
        # isolation.
        #
        # Draining and decoding are the same operation. Anything else loses
        # input.
        def sip():
            for ep in mk1_leds.IN_ENDPOINTS:
                try:
                    data = dev.read(ep, 512, timeout=1)
                except Exception:
                    continue
                if not len(data):
                    continue
                try:
                    if ep == EP_PADS:
                        out.extend(self_ref[0]._pads(data, router_ref[0]))
                    else:
                        out.extend(self_ref[0]._ctrl(data, router_ref[0]))
                except Exception:
                    pass

        for pkt in mk1_display.frame_packets(index, frame, disp.FRAME_BYTES):
            sip()
            sent = False
            for _ in range(20):
                try:
                    dev.write(disp.EP_DISPLAY, pkt, timeout=250)
                    sent = True
                    break
                except Exception:
                    sip()
            if not sent:
                # Report, do not raise on a single chunk.
                #
                # Raising here produced a doom loop: 27 restarts, and each
                # dying process left the interface claimed, so the next start
                # failed with "cannot select altsetting 1" and the device got
                # progressively more wedged. The screens appeared for a moment
                # each cycle and vanished.
                #
                # A transient failure is normal on this device. Only sustained
                # failure means the controller is really gone, and that is
                # counted by the caller.
                raise _FrameFailed("chunk rejected after 20 attempts")

    # No os.path.exists guard: it is a race, not a check. The FIFO can appear
    # between the test and the open, and can exist with nobody reading it,
    # which the test cannot see. _deliver_cmd owns opening and reopening.
    fifo = None

    midi = None
    try:
        midi = open(args.midi, "wb", buffering=0)
    except OSError:
        print("maschine-hub: no MIDI port at %s" % args.midi, file=sys.stderr)

    # The mirror is best-effort by design: the gadget only exists while a
    # computer is plugged in, and the instrument must not care.
    pc = None
    if args.pc_midi:
        try:
            pc = open(args.pc_midi, "wb", buffering=0)
        except OSError:
            print("maschine-hub: no PC MIDI at %s" % args.pc_midi,
                  file=sys.stderr)

    last_frame = 0.0
    frame_fails = 0
    # Release the interface no matter how this ends - clean return, exception,
    # or SIGTERM from systemctl restart. This is the difference between a
    # restart that works and a restart that cannot open the device.
    import atexit
    atexit.register(mk1.release)
    # One delivery path for both dispatch sites. They were copies, and the
    # copies had already drifted: the main loop mirrored every midi event to
    # the PC port, while the during-frame path mirrored only when the local
    # MIDI port had opened. Same events, two behaviours, depending on whether
    # a screen happened to be updating.
    sinks = {"fifo": fifo, "midi": midi, "pc": pc}

    def deliver(events):
        for kind, payload in events:
            if kind == "cmd":
                _deliver_cmd(sinks, args.fifo, payload)
            elif kind in ("midi", "midi_up"):
                down = kind == "midi"
                if sinks["midi"] is not None:
                    sinks["midi"].write(encode_midi(payload, down))
                    _trace(kind, payload, args.midi)
                else:
                    _trace("midi", payload, "dropped (no MIDI port)")
                # Same bytes the rig hears: pads with real velocity, panel
                # keys as notes. A DAW maps them like any pad controller.
                if sinks["pc"] is not None:
                    try:
                        sinks["pc"].write(encode_midi(payload, down))
                    except OSError:
                        sinks["pc"] = None
            elif kind == "surface":
                # The toggle's own LED IS the indicator, so it is set here and
                # not through the lamp mirror - that reflects the MPC's state,
                # and this is the controller's own.
                if self_ref[0] is not None:
                    self_ref[0].leds.set(
                        "DisplayButton8",
                        mk1_leds.BRIGHT if payload == "DAW" else mk1_leds.OFF)
                    self_ref[0].flush_leds()
                _trace("surf", payload, "controller now drives the " + payload)
            else:
                _trace(kind, payload, "unrouted")

    while True:
        deliver(mk1.poll(router))
        # Screens at a BUDGET, not as fast as the loop spins.
        #
        # This pushed both screens every 2ms - up to 500 frames a second,
        # 12,000 USB transfers, on a device that is also streaming pad and
        # encoder reports and that fails writes whenever its input queue backs
        # up. The input path and the display path were starving each other,
        # which is why fixing one kept breaking the other.
        #
        # Ten frames a second is more than a mixer readout needs, and
        # push_screen already skips an unchanged frame, so the real rate is
        # lower still.
        now = time.monotonic()
        if now - last_frame >= FRAME_INTERVAL:
            last_frame = now
            self_ref[0] = mk1
            try:
                mk1.push_screen(0, args.left, packer)
                mk1.push_screen(1, args.right, packer)
                # The MPC's panel lamps ride the same budget as the screens.
                # Both are cheap when nothing changed - show_lamps compares the
                # exported line and flush_leds only writes dirty groups - so a
                # settled instrument costs one file read per frame.
                if mk1.show_lamps():
                    mk1.flush_leds()
                frame_fails = 0
            except _FrameFailed as e:
                frame_fails += 1
                if frame_fails >= FRAME_FAIL_LIMIT:
                    print("maschine-hub: %d consecutive frame failures; "
                          "the controller is gone" % frame_fails,
                          file=sys.stderr)
                    return 1
        # Dispatch anything decoded while a frame was being pushed. Without
        # this the events are collected and dropped, which is no better than
        # discarding the reports.
        if out:
            deliver(out)
            del out[:]
        time.sleep(0.002)


def led_probe(only, walk):
    """Light LEDs by NAME so the wire order can be checked against the panel.

    mk1_leds.LED_ORDER is cabl's wire order, and the group-1 header carries an
    off-by-one that the file warns against "correcting" without hardware in
    front of you. This is that hardware check: if the light that comes on is
    not the one named, the table or the block offset is wrong by exactly the
    distance between them.
    """
    mk1 = Mk1()
    mk1.leds.all(mk1_leds.OFF)
    mk1.leds.backlight(mk1_leds.BACKLIGHT_DEFAULT)
    mk1.flush_leds(force=True)
    if only:
        if only not in mk1_leds.LED_INDEX:
            print("no such LED: %s\nnames: %s"
                  % (only, " ".join(mk1_leds.LED_ORDER)), file=sys.stderr)
            return 2
        mk1.leds.set(only, mk1_leds.BRIGHT)
        mk1.flush_leds(force=True)
        print("LIT: %s (index %d). Ctrl-C when you have looked."
              % (only, mk1_leds.LED_INDEX[only]))
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        return 0
    for name in mk1_leds.LED_ORDER:
        if name.startswith("Unused") or name == "DisplayBacklight":
            continue
        mk1.leds.all(mk1_leds.OFF)
        mk1.leds.backlight(mk1_leds.BACKLIGHT_DEFAULT)
        mk1.leds.set(name, mk1_leds.BRIGHT)
        mk1.flush_leds(force=True)
        print("  %-18s index %d" % (name, mk1_leds.LED_INDEX[name]), flush=True)
        time.sleep(walk)
    return 0


def pad_stats(seconds):
    """Print what the pad sensors are actually reporting.

    A pad that retriggers at high speed is usually not a mapping fault - it is
    a sensor whose resting pressure sits near PAD_THRESHOLD, crossing it on
    noise alone. _pads() uses ONE threshold with no hysteresis:

        if pressure > PAD_THRESHOLD and was <= PAD_THRESHOLD:   note on
        elif pressure <= PAD_THRESHOLD and was > PAD_THRESHOLD: note off

    so every noise excursion across 200 is a fresh note. This shows, per pad,
    the resting floor, the peak, and how many times it crossed while untouched.
    Leave your hands OFF the controller for the first half.
    """
    import collections
    mk1 = Mk1()
    lo = [4096] * 16
    hi = [0] * 16
    crossings = [0] * 16
    last = [0] * 16
    samples = collections.Counter()
    end = time.monotonic() + seconds
    live_at = [0.0]
    reads = 0
    errors = collections.Counter()
    first = None
    print("reading raw pad pressures for %.0fs - PRESS THE SUSPECT PAD "
          "repeatedly" % seconds)
    while time.monotonic() < end:
        try:
            data = mk1.dev.read(EP_PADS, 64, timeout=100)
        except Exception as e:
            errors[type(e).__name__ + ": " + str(e)[:40]] += 1
            continue
        reads += 1
        if first is None:
            first = bytes(data)
        # Live view, so a press can be SEEN rather than only summarised. This
        # is what shows crosstalk: press one pad and watch whether a neighbour
        # rises with it.
        live = {}
        for i in range(1, len(data) - 1, 2):
            raw = (data[i] & 0xF0) >> 4
            pressure = ((data[i] & 0x0F) << 8) | data[i + 1]
            if raw > 15:
                continue
            pad = Mk1._pad_index(raw)
            lo[pad] = min(lo[pad], pressure)
            hi[pad] = max(hi[pad], pressure)
            samples[pad] += 1
            if (pressure > Mk1.PAD_THRESHOLD) != (last[pad] > Mk1.PAD_THRESHOLD):
                crossings[pad] += 1
            last[pad] = pressure
            if pressure > 20:
                live[pad] = pressure
        if live and (time.monotonic() - live_at[0]) > 0.05:
            live_at[0] = time.monotonic()
            peak = max(live, key=live.get)
            print("  pressed p%-2d(c%d) = %-5d | also: %s"
                  % (peak, peak % 4 + 1, live[peak],
                     ", ".join("p%d(c%d)=%d" % (p, p % 4 + 1, v)
                               for p, v in sorted(live.items(),
                                                  key=lambda kv: -kv[1])
                               if p != peak) or "-"))

    print("\nreads=%d  total pad samples=%d" % (reads, sum(samples.values())))
    if errors:
        for msg, n in errors.most_common(3):
            print("  read error x%d: %s" % (n, msg))
    if first is not None:
        print("  first report: %s" % first[:16].hex(" "))
    if not reads:
        print("NO PAD REPORTS. The endpoint produced nothing - the device is "
              "not streaming, so nothing below is measured.")
        return 1

    print("\nthreshold = %d. Grid is laid out as the pads are, top row first."
          % Mk1.PAD_THRESHOLD)
    for row in range(3, -1, -1):
        cells = []
        for col in range(4):
            pad = row * 4 + col
            n = samples[pad]
            mark = "!" if crossings[pad] else " "
            cells.append("p%-2d %4d-%-4d x%-3d%s"
                         % (pad, lo[pad] if n else 0, hi[pad], crossings[pad], mark))
        print("  " + " | ".join(cells))
    print("\ncolumns are left to right; 'x' is threshold crossings while idle.")
    bad = [p for p in range(16) if crossings[p]]
    if bad:
        print("CHATTERING UNTOUCHED: pads %s - these cross %d on noise alone."
              % (", ".join(str(p) for p in bad), Mk1.PAD_THRESHOLD))
    else:
        print("no pad crossed the threshold untouched.")
    return 0


def encode_midi(target, down=True):
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
    return bytes([0x90 if down else 0x80, 52 + code - 1, 100 if down else 0])


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
