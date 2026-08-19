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

# The two continuous controls reach the emulator over control change, not
# notes. Must match MIDI_CC_DATA_WHEEL / MIDI_CC_NOTE_VARIATION in
# patches/mame/0049.
CC_DATA_WHEEL = 1
CC_NOTE_VARIATION = 2
# NOTE VARIATION is absolute on the wire, so its position lives here.
_variation = 64

# Encoder units per one step of an MPC continuous control.
#
# mk1_encoders normalises a revolution to 1000 units. 40 gives 25 steps per
# turn, which is about what the MPC's own detented wheel does; unscaled it was
# 1000 and a nudge crossed the whole field. MPCPI_WHEEL_UNITS_PER_STEP tunes it
# - lower is faster.
WHEEL_UNITS_PER_STEP = float(os.environ.get("MPCPI_WHEEL_UNITS_PER_STEP", "40"))
# How long a partial turn is carried before it is forgotten. Long enough for a
# slow deliberate turn, short enough that idle sensor drift never accumulates.
WHEEL_CARRY_S = float(os.environ.get("MPCPI_WHEEL_CARRY_MS", "250")) / 1000.0

# Send MPC keys as a TAP - press and release together - rather than holding the
# key for as long as the button is held.
#
# Holding is what the hardware does, and the firmware responds to it the way
# the hardware does: it AUTO-REPEATS. On the cursor that means one deliberate
# press walks two fields, because a comfortable press outlasts the repeat
# delay. Nothing in the controller is double-firing - the trace shows exactly
# one press and one release - the machine is doing what a held key means.
#
# A tap cannot repeat, so a press is one step. The cost is hold-to-scroll,
# which is worth losing to make single presses trustworthy; set
# MPCPI_TAP_KEYS=0 to hold instead.
#
# SHIFT is exempt and always holds: it is a modifier, and a modifier that taps
# is not a modifier.
TAP_KEYS = os.environ.get("MPCPI_TAP_KEYS", "1") not in ("0", "", "no")

# Measure how often the pad endpoint is actually sampled. The loop reads pads,
# then buttons, then sleeps, so a hit can wait behind the button read - and how
# long that is worth knowing before anyone argues about buffer sizes.
POLL_STATS = bool(os.environ.get("MPCPI_HUB_POLL_STATS"))

# Poll the button endpoint every Nth pass. Buttons choose modes; pads are
# played in time, and giving both the same attention cost the pads 4ms a hit.
BUTTON_POLL_EVERY = int(os.environ.get("MPCPI_BUTTON_POLL_EVERY", "4"))

# How fast a pad's remembered peak fades, per report. Reports arrive about
# every 1.4ms, so 0.96 leaves about half after 20ms.
#
# Slowing the DECAY is the right lever for bleed that still gets through on
# medium-soft hits, rather than raising PAD_BLEED. The coefficient applies to
# genuine simultaneous hits too - at 0.45 a real 1500 hit beside a 3072 one
# falls to 118 and is lost - whereas a longer memory only strengthens the
# correction in the lagging case, which is the one that leaks.
PAD_PEAK_DECAY = float(os.environ.get("MPCPI_PAD_PEAK_DECAY", "0.96"))

# The pressure that means velocity 127. Where a pad tops out is a property of
# the hardware AND of how hard the player actually hits, so it is a setting
# rather than a shift. 1950 rather than 2600 - full velocity a quarter earlier,
# by ear, so the top of the range is reachable without hammering.
# POLL_STATS prints the peak seen per pad if it needs measuring again.
PAD_FULL_SCALE = int(os.environ.get("MPCPI_PAD_FULL_SCALE", "2300"))

# Physical neighbours of each pad - left, right, above, below. Kept for the
# crosstalk MEASUREMENT below; the suppression rule that used to be here is
# gone, because it ate real playing: alternating two adjacent pads quickly is
# two neighbours within its window at different strengths, so the softer hit
# was suppressed and simply did not sound.
def _pad_neighbours(pad):
    row, col = divmod(pad, 4)
    out = []
    if col > 0: out.append(pad - 1)
    if col < 3: out.append(pad + 1)
    if row > 0: out.append(pad - 4)
    if row < 3: out.append(pad + 4)
    return out


PAD_NEIGHBOURS = {p: _pad_neighbours(p) for p in range(16)}


_MK1_BUTTON_NAMES = []
try:
    import importlib.util as _iu
    _sp = _iu.spec_from_file_location(
        "mk1in_names", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "mpc-mk1-input.py"))
    _mod = _iu.module_from_spec(_sp)
    _sp.loader.exec_module(_mod)
    _MK1_BUTTON_NAMES = list(_mod.MK1_BUTTONS) + ["pad_mode"]
except Exception:
    pass


# --- press feedback ---------------------------------------------------------
#
# Light a pad or button while it is being played. The hard rule is that this
# must never touch an LED the MACHINE owns: the lamp mirror drives Play, Rec,
# Grid, F7, the four banks, Mute and NoteRepeat from the MPC's own outputs, and
# a press overwriting one would replace real state with a guess - the exact
# failure the lamp export was built to avoid.
#
# LAMP_OWNED is computed from LAMP_TO_LED rather than listed, so adding a lamp
# later cannot silently hand its LED to the press feedback.
def _led_for_button(name):
    if name.startswith("display"):
        return "DisplayButton%s" % name[-1]
    if name == "pad_mode":
        return "Keyboard"           # what cabl calls the 1st-gen PAD MODE key
    return "".join(part.capitalize() for part in name.split("_"))


BUTTON_LEDS = {}
for _b in [b for b in _MK1_BUTTON_NAMES if b]:
    _led = _led_for_button(_b)
    if _led in mk1_leds.LED_INDEX:
        BUTTON_LEDS[_b] = _led

# Pads and buttons are lit while HELD, not flashed - a light that goes out
# while your finger is still down reads as a dropped hit.
#
# But a light also has to be SEEN. LED changes used to be flushed only inside
# the 100ms screen budget, so a hit shorter than that was lit and darkened
# between two flushes and never reached the hardware at all - fast playing lit
# nothing. So: flush promptly when something changes, and hold a pad lit for a
# minimum time even if it was released sooner.
LED_FLUSH_S = float(os.environ.get("MPCPI_LED_FLUSH_MS", "8")) / 1000.0
PAD_LIGHT_MIN_S = float(os.environ.get("MPCPI_PAD_LIGHT_MIN_MS", "60")) / 1000.0

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

# LEDs the MACHINE owns. Press feedback must never write these: they carry the
# MPC's real state, and a press overwriting one would put a guess where the
# truth belongs. Derived from the table rather than listed, so adding a lamp
# cannot silently hand its LED to the press feedback.
LAMP_OWNED = set(LAMP_TO_LED.values())
# The surface toggle's own LED is state too - it shows which instrument the
# panel is driving. Press feedback lit it on press and CLEARED it on release,
# which wiped the indicator every time it was used.
LAMP_OWNED.add("DisplayButton8")



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

    def __init__(self, strips=None):
        # NO LANE LIST. This carried ["GTR1", "GTR2", "MIC", "AUX"] long after
        # the desk became LOOP1..LOOP5 + DELAY/REVERB/MASTER, and nothing ever
        # read it - it was left over from when the pads were the loop grid and
        # a column was a lane. The recordable lanes are derived from
        # control_map.STRIPS by daw-ctl, which is the side that owns them.
        # Eight knobs, eight strips. The names live in control_map.STRIPS,
        # which is the one place to change them.
        self.strips = strips or control_map.STRIPS
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
        # Carried remainder per master knob, so slow turns are not rounded away.
        self._wheel_accum = {}
        self._wheel_seen = {}
        # What each button sent on its press edge, so the RELEASE can send the
        # matching note-off. Keyed by button name, not by target: shift can be
        # let go between press and release, and the key that must be released
        # is the one that was actually pressed.
        self.pressed = {}
        self.held = None          # a mode button currently held
        # Loop recording arms globally and punches per strip, so the state is
        # "are we arming" plus "which strips are rolling", not a mode.
        self.armed = False
        self.rolling = set()
        self.focus = 0            # which strip the page-level verbs act on
        self.page = "LOOP"
        # Is the file browser up? It is an OVERLAY on the right-hand screen
        # rather than a page: it opens from either surface, the pads and the
        # transport keep working underneath it, and closing puts back whatever
        # page was there.
        #
        # Only the flag lives here. daw-ctl owns the cursor and the listing,
        # because it owns every other piece of screen state and two owners of
        # one cursor is how a screen and a controller end up disagreeing about
        # what is selected. This flag decides one thing: where the browse keys
        # and the big knob point.
        self.files = False

    @property
    def mode(self):
        return self.held or control_map.DEFAULT_MODE

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
            if down:
                if self.surface != "MPC" or not target:
                    return []
                self.pressed[name] = target
                return [("midi", target)]
            # A RELEASE IS OWED FOR ANY PRESS WE SENT, whatever the surface
            # says NOW.
            #
            # This asked "are we on the MPC surface?" on the way up as well as
            # on the way down, so a SHIFT held across a surface toggle - press
            # SHIFT, press DISPLAY 8, let go - sent the key DOWN and then
            # returned [] on the release. The MPC was left holding SHIFT with
            # nothing able to lift it: every later press re-sends the down, and
            # the release is refused for the same reason it was the first time.
            #
            # That is exactly the reported "shift is stuck, my pads do not
            # work" - with SHIFT down the machine reads every pad as a shifted
            # one - and it survives restarts of nothing, because the state that
            # is wrong lives in the emulated machine rather than here.
            #
            # self.pressed is the record of what we actually sent, so let it
            # decide. Nothing else can strand a key.
            sent = self.pressed.pop(name, None)
            return [("midi_up", sent)] if (sent and SEND_KEY_RELEASE) else []

        # TRANSPORT REACHES THE MPC FROM EITHER SURFACE.
        #
        # Checked before the per-surface table so neither table has to carry a
        # copy, and so a DAW binding can never shadow it. SHIFT+MUTE is the one
        # exception: the bare key is STOP, and the mixer's mute sits under
        # SHIFT rather than taking the key away from the transport.
        if name in control_map.ALWAYS and not (
                name == "mute" and self.surface == "DAW" and self.shift):
            target = control_map.ALWAYS[name]
            if not down:
                sent = self.pressed.pop(name, None)
                # A HELD MODE ENDS WITH ITS BUTTON, even when the release
                # arrives down this path instead of the per-surface one.
                #
                # SHIFT+MUTE enters the mixer's MUTE mode, and the guard above
                # only routes MUTE away from the transport WHILE SHIFT IS
                # HELD. Let go of SHIFT before MUTE and the release lands here,
                # where nothing cleared self.held - so MUTE stayed latched and
                # the display buttons went on muting strips with no modifier
                # held. Same shape as the SHIFT bug above: state entered on the
                # way down and abandoned on the way up.
                if self.held and HOLD_MODES.get(name) == self.held:
                    self.held = None
                    return [("cmd", "mode %s" % self.mode)]
                return [("midi_up", sent)] if (sent and SEND_KEY_RELEASE
                                               and not TAP_KEYS) else []
            if TAP_KEYS and SEND_KEY_RELEASE:
                return [("midi", target), ("midi_up", target)]
            self.pressed[name] = target
            return [("midi", target)]

        # --- the file browser ---------------------------------------------
        #
        # Checked after the transport so a browser key can never shadow one -
        # you must be able to stop the beat with a listing up - and before the
        # surface toggle so display8 can close the browser first.
        #
        # SHIFT+NAVIGATE toggles it, from either surface. Loading a disk feeds
        # the MPC, but a player on the DAW surface who wants another kit should
        # not have to change surfaces to ask for one, and NAVIGATE is unbound in
        # DAW_BUTTONS so nothing is taken away there.
        if down and name == control_map.FILES_BUTTON and self.shift:
            self.files = not self.files
            return [("cmd", "files open" if self.files else "files close")]
        if self.files:
            if name == control_map.FILES_CLOSE:
                if not down:
                    return []
                self.files = False
                return [("cmd", "files close")]
            verb = control_map.FILES_BUTTONS.get(name)
            if verb:
                if not down:
                    # A key pressed BEFORE the browser opened still has to be
                    # released. Swallowing the release leaves the emulator
                    # holding the key down forever, which with
                    # MPCPI_TAP_KEYS=0 is a cursor key that never stops
                    # repeating - the same class of bug the tap default exists
                    # to avoid.
                    sent = self.pressed.pop(name, None)
                    return [("midi_up", sent)] if (sent and SEND_KEY_RELEASE) \
                        else []
                return [("cmd", verb)]

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
            if target and target.startswith("mode:"):
                self.held = None
                return [("cmd", "mode %s" % self.mode)]
            return []

        if target:
            if target.startswith("mpc:"):
                if TAP_KEYS and SEND_KEY_RELEASE:
                    # Both, in order, so the firmware sees a short press and
                    # never starts repeating.
                    return [("midi", target), ("midi_up", target)]
                self.pressed[name] = target
                return [("midi", target)]
            if target.startswith("mode:"):
                _m = target.split(":", 1)[1]
                # A mode declared shift:True is only entered with SHIFT held.
                # Without this, SHIFT+MUTE and MUTE are the same press and the
                # transport key would silently become a mixer modifier.
                if control_map.MODES.get(_m, {}).get("shift") and not self.shift:
                    return []
                self.held = _m
                return [("cmd", "mode %s" % self.mode)]
            rest = target.split(":", 1)[1]
            if rest.startswith("page:"):
                self.page = rest.split(":", 1)[1]
                return [("cmd", "page %s" % self.page)]
            if rest == "arm":
                self.armed = not self.armed
                if not self.armed:
                    self.rolling.clear()
                return [("cmd", "arm %d" % int(self.armed))]
            return [("cmd", rest.replace(":", " "))]

        # NO PIN. Modes are held and end when released - see control_map.MODES.

        # While MUTE or SOLO is held, display 1-7 ARE the strips - the seven
        # that can meaningfully be muted, master excluded. This is the mixer
        # gesture Maschine itself uses (hold the mode, tap the target), moved
        # off the pads so the pads can stay the instrument.
        #
        # Only display5-8 sit under this screen; 1-4 are under the LEFT one,
        # which is showing the MPC, so four of these seven have no on-screen
        # label. Their order is the mixer's own - LOOP1..LOOP5, DELAY, REVERB -
        # which is the same order as the knobs above them.
        if self.surface == "DAW" and name.startswith("display"):
            idx = int(name[len("display"):]) - 1
            if 0 <= idx < len(control_map.MUTE_STRIPS):
                strip = control_map.MUTE_STRIPS[idx]
                # Held modifier wins: reach any strip without moving focus.
                if self.mode in ("MUTE", "SOLO"):
                    return [("cmd", "%s %s" % (self.mode.lower(), strip))]
                # ARMED: the strip buttons punch in and out. This is why the
                # pads are never needed for looping - the row that already
                # names the tracks does the recording too.
                if self.armed:
                    if strip in self.rolling:
                        self.rolling.discard(strip)
                        return [("cmd", "punch_out %s" % strip)]
                    self.rolling.add(strip)
                    return [("cmd", "punch_in %s" % strip)]
                # Otherwise they select. One press, and every page-level verb
                # then acts on what you just picked.
                self.focus = idx
                return [("cmd", "focus %s" % strip)]
            return []

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
            # PRESS ONLY. This fired on the RELEASE too - velocity 0 is a pad
            # event like any other - so one SHIFT+pad sent the MPC key TWICE:
            # once on the way down and again on the way up. The screen jumped
            # to the target and then straight back off it, which reads as the
            # navigation not sticking rather than as a double press.
            if not velocity:
                return []
            target = control_map.SHIFT_PADS.get(index + 1)
            if not target:
                return []
            if not target.startswith("mpc:"):
                return [("cmd", "action %s" % target.split(":", 1)[1])]
            # THE SAME GESTURE MUST REACH THE SAME KEY FROM EITHER SURFACE.
            #
            # It did not. SHIFT is only sent to the MPC on the MPC surface -
            # DAW_BUTTONS has no "shift" - but this layer fired on both, so
            # one gesture meant two things and neither the panel nor the
            # screen said which:
            #
            #   MPC surface: SHIFT held + 1/SONG  -> SONG mode
            #   DAW surface:             1/SONG   -> types "1" into whatever
            #                                        field the cursor is on
            #
            # Both verified on the appliance against the exported LCD. The
            # DAW-surface case is the worse of the two: it silently EDITS the
            # machine - a sequence number, a tempo, a program - on a gesture
            # whose whole purpose is to change screen.
            #
            # So the modifier is reconciled here rather than left to whatever
            # the surface happened to send. The machine wants SHIFT held for
            # its ten numeric mode keys and refuses every other key while
            # SHIFT is down (control_map.SHIFT_PADS_SHIFTED has the
            # measurements), so:
            #
            #   a mode key, SHIFT not already down  ->  press it, tap, release
            #   a bare key, SHIFT already down      ->  lift it, tap, press
            #
            # WHETHER THE MACHINE HOLDS SHIFT IS READ OFF self.pressed, never
            # off the surface. self.pressed is the record of what we actually
            # sent; the surface is where the panel is pointing NOW, and the
            # two disagree the moment a player holds SHIFT across a D8. Every
            # stuck-modifier bug in this file came from asking the second
            # question when the first was meant.
            #
            # Every borrow is a matched pair inside ONE event list, so the
            # modifier is put back before anything else can be dispatched and
            # nothing can strand it - not a surface change, not a release
            # arriving out of order, not a lost pad-up.
            key = target.split(":", 1)[1]
            if not SEND_KEY_RELEASE:
                # Without releases none of the above can be undone, so do not
                # start: this escape hatch keeps the old press-only behaviour.
                return [("midi", target)]
            wants_shift = key in control_map.SHIFT_PADS_SHIFTED
            machine_holds_shift = "shift" in self.pressed
            if wants_shift and not machine_holds_shift:
                borrow, restore = ("midi", "mpc:shift"), ("midi_up", "mpc:shift")
            elif machine_holds_shift and not wants_shift:
                borrow, restore = ("midi_up", "mpc:shift"), ("midi", "mpc:shift")
            else:
                borrow = restore = None
            out = [borrow] if borrow else []
            # TAPPED - PRESS AND RELEASE - LIKE EVERY OTHER MPC KEY.
            #
            # This sent the key DOWN and nothing else, ever. Not "the release
            # is late": there is no code path that releases it, so one
            # SHIFT+pad latched a panel key in the machine permanently, and
            # each further gesture latched another one on top.
            #
            # Measured at the wire with the hub's own decoder driven by
            # synthetic reports, a SHIFT+pad-4 gesture produced exactly:
            #
            #   90 46 64   SHIFT   down
            #   90 44 64   4/SAMPLE down
            #   80 46 00   SHIFT   up
            #
            # and no 80 44 00. The real panel always sends the pair - see
            # docs/mpc2000xl-panel-protocol.md, 84 = key down and 85 = key up -
            # and an unshifted numeric key is a DIGIT: held down on the main
            # screen it types itself into the sequence field, verified on the
            # appliance. So the latched key is not inert, it is a number key
            # waiting to be read without its modifier.
            #
            # Sending both here rather than on the pad's release is deliberate:
            # the release then lands while SHIFT is still down, which is the
            # order the machine sees from its own panel when a player lifts the
            # number before the modifier. Waiting for the pad to fall would put
            # it after the SHIFT release whenever the modifier is let go first,
            # and would strand the key again if the pad's release is ever lost.
            out += [("midi", target), ("midi_up", target)]
            if restore:
                out.append(restore)
            return out
        # THE PADS ARE ALWAYS THE MPC'S. On both surfaces, in every mode.
        #
        # They used to be re-targeted by mode - hold MUTE and the grid became a
        # strip selector, hold PAD MODE and it became loop transport - so
        # reaching for the mixer took the drums away mid-phrase. The strips
        # live on the display buttons now, which nothing was playing.
        return [("midi", "pad:%d:%d" % (index, velocity))]

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
        # THE BROWSER TAKES THE BIG KNOB WHILE IT IS OPEN, on either surface.
        # The knob already means "move through the thing"; the thing is the
        # listing until it closes. Detented through the same accumulator as
        # the MPC's data wheel, so one detent is one row rather than one row
        # per report.
        if self.files and name == "swing":
            steps = self._wheel_steps(name, delta)
            return [("cmd", "files move %+d" % steps)] if steps else []

        # Surface next: the big knob is the MPC's DATA wheel when the panel
        # drives the MPC and the DAW's jog when it drives Ardour. Same gesture,
        # different instrument - which is the only way one knob can serve both
        # without a mode to remember.
        target = control_map.MASTER_KNOBS_BY_SURFACE.get(
            self.surface, {}).get(name) or control_map.MASTER_KNOBS.get(name)
        if target is None:
            return []
        if target.startswith("mpc:"):
            steps = self._wheel_steps(name, delta)
            if not steps:
                return []
            return [("midi", "%s:%+d" % (target, steps))]
        # "master +4", not "master master +4": the DAW master is not a
        # named strip, it is the one thing a master command can mean.
        # The verb comes from the TARGET, not from a hardcoded name. This said
        # "master" unconditionally, so the moment a second DAW target existed -
        # the jog - it silently moved the master fader instead.
        return [("cmd", "%s %+d" % (target.split(":", 1)[1], delta))]

    def _wheel_steps(self, name, delta):
        """Encoder units to detents, with the remainder carried.

        SCALE IT. mk1_encoders reports an absolute angle normalised to 1000
        units per revolution, so passing the raw delta through made one turn of
        the knob about a thousand steps of the MPC's data wheel - the same
        arithmetic that made the Ardour knobs unusable. A real MPC data wheel
        has coarse detents; WHEEL_UNITS_PER_STEP sets how far the knob turns
        for one of them, and the remainder is carried so a slow turn still
        moves rather than being rounded away.

        Drop a stale remainder before adding to it. These are analog sensors:
        an untouched knob wanders, and anything past the tracker's deadband
        arrives here. Carrying the remainder forever turns that wander into a
        random walk that eventually crosses a step - measured at seven wheel
        messages in six idle seconds, nudging whatever field the cursor was on,
        with nobody touching the controller.

        A real turn produces a continuous run of deltas; noise arrives in
        isolated ticks. Forgetting the remainder after a pause keeps the carry
        (so slow turns still register) without letting drift integrate.

        Shared by the MPC's wheel and the file browser's cursor, so the
        browser cannot quietly get a different feel from the same knob.
        """
        now = time.monotonic()
        if (now - self._wheel_seen.get(name, 0.0)) > WHEEL_CARRY_S:
            self._wheel_accum[name] = 0
        self._wheel_seen[name] = now
        self._wheel_accum[name] = self._wheel_accum.get(name, 0) + delta
        steps = int(self._wheel_accum[name] / WHEEL_UNITS_PER_STEP)
        if steps:
            self._wheel_accum[name] -= steps * WHEEL_UNITS_PER_STEP
        return steps

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


def daw_pages():
    """Which DAW pages exist, from the page bindings themselves."""
    return {v.split(":")[-1] for v in control_map.DAW_BUTTONS.values()
            if v.startswith("daw:page:")}


def self_test():
    r = Router()

    def sent(events):
        """The MPC key a press produced, ignoring whether it tapped or held."""
        for kind, payload in events:
            if kind == "midi":
                return payload
        return None


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
    # NO EXEMPTIONS. This set used to be "| {'pad_mode'}", an escape hatch
    # added directly beneath a comment about "restart" being mapped and never
    # sent - and it hid the same bug again: MPC_BUTTONS bound OVER DUB to
    # "pad_mode", the panel reports that key as "keyboard", and OVER DUB was
    # unreachable on the instrument for as long as the exemption existed.
    known = {b for b in _m.MK1_BUTTONS if b}
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

    # ...AND THE OTHER DIRECTION, WHICH IS THE ONE THAT ACTUALLY SHIPPED A BUG.
    #
    # The check above only asks whether every key the machine HAS can be
    # pressed. It never asked whether every key the map NAMES exists. So
    # SHIFT_PADS could carry - and did carry, for months - four keys the
    # MPC2000XL does not have:
    #
    #   13: mpc:semitone_down   14: mpc:semitone_up
    #   15: mpc:octave_down     16: mpc:octave_up
    #
    # Those are soft functions reached from a screen, not panel keys. There
    # is no keycode, so encode_midi returned b"" and the hub wrote ZERO BYTES
    # for each of them. Four pads that answered a press with nothing, on a
    # panel whose whole design position is that a control either does its one
    # job or is not bound - and every test was green, because the only
    # question anyone asked ran the other way.
    #
    # Ask both. A target has to name something the machine has AND encode to
    # bytes; b"" is the failure mode, so it is the assertion.
    _continuous = {"data_wheel", "note_variation"}
    _routed = [("MPC_BUTTONS", control_map.MPC_BUTTONS.values()),
               ("DAW_BUTTONS", control_map.DAW_BUTTONS.values()),
               ("ALWAYS", control_map.ALWAYS.values()),
               ("SHIFT_PADS", control_map.SHIFT_PADS.values()),
               ("MASTER_KNOBS", control_map.MASTER_KNOBS.values())]
    for _by_surface in control_map.MASTER_KNOBS_BY_SURFACE.values():
        _routed.append(("MASTER_KNOBS_BY_SURFACE", _by_surface.values()))
    for _where, _targets in _routed:
        for _t in _targets:
            if not _t or not _t.startswith("mpc:"):
                continue
            _k = _t.split(":", 1)[1]
            if _k in _continuous:
                # The wheel and the slider are CONTROL CHANGE, not keys, and
                # encode_midi wants a delta appended. Checked separately -
                # search CC_DATA_WHEEL below.
                continue
            assert _k in _m.KEY, \
                "%s: mpc:%s is not a key the MPC2000XL has" % (_where, _k)
            assert encode_midi(_t), \
                "%s: mpc:%s encodes to no bytes at all" % (_where, _k)

    # Every SHIFT+pad target must be on ONE side of the modifier split, and
    # the shifted side must not name keys the layer does not carry - a mode
    # key listed there and nowhere else is a key that cannot be pressed at
    # all, because the digits have no other home on this panel.
    _pad_keys = {t.split(":", 1)[1] for t in control_map.SHIFT_PADS.values()
                 if t.startswith("mpc:")}
    assert control_map.SHIFT_PADS_SHIFTED <= _pad_keys, \
        "SHIFT_PADS_SHIFTED names keys no pad sends: %s" % sorted(
            control_map.SHIFT_PADS_SHIFTED - _pad_keys)

    # The six soft keys are on the six display buttons under the screens.
    for i in range(1, 7):
        assert control_map.MPC_BUTTONS["display%d" % i] == "mpc:soft%d" % i

    # Transport.
    assert sent(r.button("play", True)) == "mpc:play"
    r.button("play", False)
    assert sent(r.button("mute", True)) == "mpc:stop"
    r.button("mute", False)
    assert sent(r.button("loop", True)) == "mpc:play_start"
    r.button("loop", False)

    # SHIFT is the MPC's own SHIFT key, held, AND our pad modifier.
    ev = r.button("shift", True)
    assert ev == [("midi", "mpc:shift")], ev
    assert r.shift is True
    assert sent(r.pad(0, 100)) == "mpc:song"            # SHIFT+pad 1 types a 1
    # AND IT LETS GO OF IT. A SHIFT+pad used to send the key down and never
    # up, so every gesture latched one more panel key in the machine for good.
    # The release rides with the press so it lands while SHIFT is still held,
    # which is the order the machine's own panel produces.
    if SEND_KEY_RELEASE:
        assert r.pad(0, 100) == [("midi", "mpc:song"),
                                 ("midi_up", "mpc:song")], r.pad(0, 100)
        # ...and the pad's own release adds nothing, or the key fires twice.
        assert r.pad(0, 0) == [], "SHIFT+pad fired again on the release"
    up = r.button("shift", False)
    assert up == ([("midi_up", "mpc:shift")] if SEND_KEY_RELEASE else [])
    assert r.shift is False
    assert r.pad(0, 100) == [("midi", "pad:0:100")]     # unshifted, a drum pad

    # A SHIFT HELD ACROSS A SURFACE TOGGLE MUST STILL BE RELEASED.
    #
    # Press SHIFT on the MPC surface, toggle to the DAW with it held, let go:
    # the release used to be refused because the surface no longer matched, so
    # the MPC held SHIFT forever and read every pad as a shifted one. That is
    # the reported "shift is stuck and my pads do not work", and nothing in
    # the hub could undo it.
    rss = Router()
    assert rss.button("shift", True) == [("midi", "mpc:shift")]
    rss.button(control_map.SURFACE_TOGGLE, True)
    assert rss.surface == "DAW"
    assert rss.button("shift", False) == (
        [("midi_up", "mpc:shift")] if SEND_KEY_RELEASE else []), \
        "a SHIFT pressed on the MPC surface was never released"
    assert "shift" not in rss.pressed

    # And a held MODE ends with its button even if SHIFT went first.
    rsm = Router()
    rsm.button(control_map.SURFACE_TOGGLE, True)
    rsm.button("shift", True)
    assert rsm.button("mute", True) == [("cmd", "mode MUTE")]
    rsm.button("shift", False)
    rsm.button("mute", False)
    assert rsm.held is None, "MUTE stayed latched after its button came up"

    # NOTE REPEAT sends TAP TEMPO, which is what the MK1 prints above it; the
    # MPC's own note repeat is AFTER, on SAMPLING beside it.
    assert control_map.MPC_BUTTONS["note_repeat"] == "mpc:tap_tempo"
    assert control_map.MPC_BUTTONS["sampling"] == "mpc:after"
    # FULL LEVEL is on F7, which the MPC does not have - it has six soft keys.
    assert control_map.MPC_BUTTONS["display7"] == "mpc:full_level"

    # The surface toggle isolates the two instruments.
    assert r.surface == "MPC"
    # PIN and the surface toggle are handled BEFORE the DAW_BUTTONS lookup, so
    # a binding in that table for either one is dead code that looks alive.
    # Nothing checked it, and PIN has already moved once - from display1, when
    # display1 became LOOP1's mute button.
    assert control_map.PIN_BUTTON is None, \
        "PIN is back; modes are held, so a latch is state nobody asked to read"
    assert control_map.SURFACE_TOGGLE not in control_map.DAW_BUTTONS, \
        "%s toggles the surface and is also bound" % control_map.SURFACE_TOGGLE
    # The strip buttons are display1..N; the toggle must not be one of them.
    _strip_btns = {"display%d" % (i + 1)
                   for i in range(len(control_map.MUTE_STRIPS))}
    assert control_map.SURFACE_TOGGLE not in _strip_btns, \
        "the surface toggle is on a button that mutes a strip"
    # Every DAW page a button opens must have a renderer, or it opens a hole.
    assert daw_pages() == {"LOOP", "FX", "SONG", "EDIT"}, daw_pages()
    # Every mode must be reachable: a mode with no button can only be the
    # resting state, or it can never be entered.
    for _m, _d in control_map.MODES.items():
        assert _d.get("button") or _m == control_map.DEFAULT_MODE, \
            "mode %s has no button and is not the resting state" % _m
        # A mode whose button is also panel-wide transport MUST be shifted,
        # or the transport key is quietly stolen by the mixer.
        if _d.get("button") in control_map.ALWAYS:
            assert _d.get("shift"), \
                "mode %s sits on transport key %s without SHIFT" % (
                    _m, _d["button"])
        assert _d["pads"] == "mpc", \
            "mode %s steals the pads; they belong to the MPC" % _m

    # SHIFT+pad must fire ONCE, on the press. Sending it on the release too
    # navigated to the target screen and immediately back off it.
    _rs = Router()
    _rs.shift = True
    _first = next(iter(control_map.SHIFT_PADS))
    assert _rs.pad(_first - 1, 100), "SHIFT+pad must act on the press"
    assert _rs.pad(_first - 1, 0) == [], \
        "SHIFT+pad must do nothing on the release - it double-pressed the key"
    _rs.shift = False

    # SHIFT+PAD MUST REACH THE MACHINE THE SAME WAY FROM EITHER SURFACE.
    #
    # It did not. SHIFT is only sent to the MPC on the MPC surface, so the
    # same gesture that opened SONG mode there typed a bare "1" into the
    # field under the cursor on the DAW surface - both measured against the
    # exported LCD. What has to match is not the byte stream (on the MPC
    # surface the player's own SHIFT press is in it) but WHAT THE MACHINE
    # SEES: which key, and whether SHIFT was down when it arrived.
    if SEND_KEY_RELEASE:
        def _delivery(surface):
            """{pad: (key, was SHIFT down when it landed)} for one surface."""
            rp = Router()
            if surface == "DAW":
                rp.button(control_map.SURFACE_TOGGLE, True)
            rp.button("shift", True)
            seen = {}
            for n, t in control_map.SHIFT_PADS.items():
                if not t.startswith("mpc:"):
                    continue
                down = "shift" in rp.pressed
                key = at_key = None
                for kind, payload in rp.pad(n - 1, 100):
                    if payload == "mpc:shift":
                        down = kind == "midi"
                    elif kind == "midi":
                        key, at_key = payload, down
                assert key is not None, "%s: pad %d sent no key" % (surface, n)
                # A BORROWED MODIFIER IS ALWAYS PUT BACK, in the same event
                # list that borrowed it, or the next gesture inherits a shift
                # nobody is holding.
                assert down == ("shift" in rp.pressed), \
                    "%s: pad %d left SHIFT %s" % (surface, n,
                                                  "down" if down else "up")
                seen[n] = (key, at_key)
            rp.button("shift", False)
            assert "shift" not in rp.pressed
            return seen

        _mpc_side, _daw_side = _delivery("MPC"), _delivery("DAW")
        assert _mpc_side == _daw_side, \
            "SHIFT+pad differs between surfaces: %s" % sorted(
                n for n in _mpc_side if _mpc_side[n] != _daw_side[n])
        # ...and the modifier is the one that key needs. The ten mode keys
        # arrive with SHIFT DOWN; every other key arrives with it UP, because
        # the firmware ignores a key that has no shifted function while SHIFT
        # is held - which is why ENTER and MAIN SCREEN, real keys with real
        # keycodes, did nothing at all on the MPC surface.
        for _n, (_key, _shifted) in _mpc_side.items():
            _name = _key.split(":", 1)[1]
            assert _shifted == (_name in control_map.SHIFT_PADS_SHIFTED), \
                "pad %d delivers %s with SHIFT %s" % (
                    _n, _name, "down" if _shifted else "up")

    # THE PADS STAY THE MPC'S, whatever mode is held and whichever surface is
    # up. This is the property the whole mixer redesign exists to protect.
    _rm = Router()
    for _surface in ("MPC", "DAW"):
        _rm.surface = _surface
        for _held in (None, "MUTE", "SOLO"):
            _rm.held = _held
            assert _rm.pad(5, 100) == [("midi", "pad:5:100")], \
                "pads must reach the MPC in %s/%s" % (_surface, _held)
    _rm.held = None

    # Hold MUTE, tap a display button, that strip mutes.
    _rm.surface = "DAW"
    _rm.held = "MUTE"
    assert _rm.button("display1", True) == [("cmd", "mute LOOP1")]
    assert _rm.button("display7", True) == [("cmd", "mute REVERB")]
    _rm.held = "SOLO"
    assert _rm.button("display3", True) == [("cmd", "solo LOOP3")]
    # display8 is the surface toggle and must NOT become a strip - and the
    # master has no button at all, which is why there are seven and not eight.
    assert "MASTER" not in control_map.MUTE_STRIPS
    assert len(control_map.MUTE_STRIPS) == 7, "seven strips, seven free buttons"
    _rm.held = None
    _rm.surface = "MPC"

    assert r.button(control_map.SURFACE_TOGGLE, True) == [("surface", "DAW")]

    # TRANSPORT REACHES THE MPC FROM EITHER SURFACE. This used to assert the
    # opposite - that play was unreachable in DAW mode - which meant stopping
    # the beat required leaving the mixer first.
    for _b, _key in control_map.ALWAYS.items():
        for _sfc in ("MPC", "DAW"):
            r.surface = _sfc
            if _b == "mute" and _sfc == "DAW":
                continue                 # SHIFT+MUTE is the mixer's; see below
            assert sent(r.button(_b, True)) == _key, \
                "%s must reach the MPC on the %s surface" % (_b, _sfc)
            r.button(_b, False)
    r.surface = "DAW"

    # Bare MUTE is STOP even here; the mixer's mute needs SHIFT.
    assert sent(r.button("mute", True)) == "mpc:stop"
    r.button("mute", False)
    r.shift = True
    assert r.button("mute", True) == [("cmd", "mode MUTE")]
    r.button("mute", False)
    r.shift = False

    # The four pages fill the group row in panel order, and MIX is not among
    # them - it was merged into LOOP when they turned out to be one page.
    assert "MIX" not in daw_pages(), "the MIX page was merged into LOOP"
    assert [control_map.DAW_BUTTONS.get("group_" + g) for g in "efgh"] == \
        ["daw:page:LOOP", "daw:page:FX", "daw:page:SONG", "daw:page:EDIT"]
    # group_a-d stay free on the DAW surface. They are the MPC's pad banks on
    # the other one, so binding them means the same key does two unrelated
    # things depending on a mode - possible, but it should be a decision.
    for _g in "abcd":
        assert "group_" + _g not in control_map.DAW_BUTTONS

    # REC arms; the strip buttons then punch instead of selecting, and punch
    # again to close. This is the whole reason the pads stay the MPC's.
    r.armed = False
    assert r.button("display2", True) == [("cmd", "focus LOOP2")]
    r.button("display2", False)
    assert r.button("rec", True) == [("cmd", "arm 1")]
    r.button("rec", False)
    assert r.button("display2", True) == [("cmd", "punch_in LOOP2")]
    r.button("display2", False)
    assert r.button("display2", True) == [("cmd", "punch_out LOOP2")]
    r.button("display2", False)
    assert r.button("rec", True) == [("cmd", "arm 0")]
    r.button("rec", False)
    assert r.button("display2", True) == [("cmd", "focus LOOP2")]
    r.button("display2", False)

    assert r.button(control_map.SURFACE_TOGGLE, True) == [("surface", "MPC")]
    assert sent(r.button("play", True)) == "mpc:play"
    r.button("play", False)

    # THE BIG KNOB FOLLOWS THE SURFACE: DATA wheel for the MPC, jog for the DAW.
    _rj = Router()
    _rj.surface = "MPC"
    assert any(t.startswith("mpc:data_wheel") for _, t in _rj.master("swing", 400)), \
        "swing must be the MPC data wheel on the MPC surface"
    _rj.surface = "DAW"
    _ev = _rj.master("swing", 400)
    assert _ev and _ev[0][0] == "cmd" and "jog" in _ev[0][1], \
        "swing must be the DAW jog on the DAW surface, got %r" % (_ev,)
    # VOLUME and TEMPO are NOT gated - the master fader and note variation mean
    # the same thing wherever you are.
    for _s in ("MPC", "DAW"):
        _rj.surface = _s
        assert _rj.master("tempo", 400), "tempo must work on %s" % _s

    # Knobs: one per mixer strip, and the master knobs by name.
    assert r.knob(4, -2)[0][0] == "cmd"

    # The grid is not upside down: pad 1 is bottom-left.
    flip = Mk1._pad_index
    assert flip(12) == 0 and flip(15) == 3
    assert sorted(flip(i) for i in range(16)) == list(range(16))
    assert all(flip(i) % 4 == i % 4 for i in range(16))

    # A cursor press is ONE step: tapped, so the firmware cannot auto-repeat.
    r8 = Router()
    ev = r8.button("browse_left", True)
    if TAP_KEYS and SEND_KEY_RELEASE:
        assert ev == [("midi", "mpc:left"), ("midi_up", "mpc:left")], ev
        assert r8.button("browse_left", False) == [], "release already sent"
    # SHIFT still HOLDS - a modifier that taps is not a modifier.
    assert r8.button("shift", True) == [("midi", "mpc:shift")]
    assert r8.button("shift", False) == [("midi_up", "mpc:shift")]

    # The wheel must be SCALED, and the remainder carried rather than dropped.
    r7 = Router()
    assert r7.master("swing", 5) == [], "a nudge should not move the wheel"
    total = 0
    for _ in range(20):                       # 20 x 5 = 100 units
        for kind, payload in r7.master("swing", 5):
            total += int(payload.rsplit(":", 1)[1])
    assert total == int(100 / WHEEL_UNITS_PER_STEP), \
        "100 units gave %d steps, expected %d" % (total, 100 / WHEEL_UNITS_PER_STEP)

    # Idle drift must NOT accumulate into wheel steps.
    r9 = Router()
    for _ in range(30):                       # isolated 4-unit ticks, far apart
        r9._wheel_seen["swing"] = 0.0         # pretend each is long after the last
        assert r9.master("swing", 4) == [], "sensor drift moved the wheel"

    # --- the file browser -------------------------------------------------
    #
    # SHIFT+NAVIGATE opens it, the big knob moves the cursor, the two browse
    # keys go up and in, STEP (which is the MPC's ENTER) loads, and D8 closes.
    # browser.py's own self-test proves the listing works and proves nothing
    # about the panel reaching it, so every gesture below is asserted against
    # what the router actually returns.
    rb = Router()
    assert rb.files is False
    # NAVIGATE alone is still MAIN SCREEN. The browser must not cost an MPC
    # key - that is the whole reason it is the one shifted button.
    assert sent(rb.button("navigate", True)) == "mpc:main_screen"
    rb.button("navigate", False)
    assert rb.files is False, "an unshifted NAVIGATE opened the browser"
    assert rb.button("shift", True) == [("midi", "mpc:shift")]
    assert rb.button("navigate", True) == [("cmd", "files open")], \
        "SHIFT+NAVIGATE must open the browser"
    assert rb.files is True
    rb.button("navigate", False)
    rb.button("shift", False)

    # The three keys become the listing's, and the MPC sees none of them.
    assert rb.button("browse_left", True) == [("cmd", "files up")]
    assert rb.button("browse_left", False) == []
    assert rb.button("browse_right", True) == [("cmd", "files into")]
    rb.button("browse_right", False)
    assert rb.button("step", True) == [("cmd", "files enter")]
    rb.button("step", False)

    # The wheel moves the cursor on the same detents the MPC's data wheel
    # uses, so a nudge still moves nothing and one detent is one row.
    assert rb.master("swing", 5) == [], "a nudge should not move the cursor"
    ev = rb.master("swing", int(WHEEL_UNITS_PER_STEP))
    assert ev == [("cmd", "files move +1")], ev
    ev = rb.master("swing", -2 * int(WHEEL_UNITS_PER_STEP))
    assert ev == [("cmd", "files move -1")], ev

    # THE PADS ARE STILL THE MPC'S. The browser is a screen, not a mode - the
    # same rule that took the mixer off the grid. Both pad layers survive it.
    assert rb.pad(3, 99) == [("midi", "pad:3:99")]
    rb.button("shift", True)
    assert sent(rb.pad(0, 100)) == "mpc:song", "SHIFT+pad still types digits"
    rb.button("shift", False)
    # And so does the transport: you can stop the beat with a listing up.
    assert sent(rb.button("play", True)) == "mpc:play"
    rb.button("play", False)

    # D8 closes rather than toggling the surface, and the NEXT press toggles -
    # so the way out is in the same place it always is, one press deeper.
    assert rb.button(control_map.SURFACE_TOGGLE, True) == [("cmd", "files close")]
    assert rb.files is False
    assert rb.surface == "MPC", "closing the browser also flipped the surface"
    assert rb.button(control_map.SURFACE_TOGGLE, True) == [("surface", "DAW")]
    # Closed, the browse keys are the MPC's cursor keys again.
    rb.surface = "MPC"
    assert sent(rb.button("browse_left", True)) == "mpc:left"
    rb.button("browse_left", False)

    # It opens from the DAW surface too: wanting another kit is not a reason
    # to change surfaces first. SHIFT sends nothing there but still modifies.
    rb2 = Router()
    rb2.surface = "DAW"
    assert rb2.button("shift", True) == [], "SHIFT is not an MPC key here"
    assert rb2.button("navigate", True) == [("cmd", "files open")]
    # ...and SHIFT+NAVIGATE closes it again: the way in is also a way out.
    assert rb2.button("navigate", True) == [("cmd", "files close")]
    assert rb2.files is False
    rb2.button("shift", False)

    # A browser key that was also panel-wide transport would take the
    # transport away exactly when the player is least able to notice.
    assert not (set(control_map.FILES_BUTTONS) & set(control_map.ALWAYS)), \
        "a browser key shadows the transport"
    # Every browser key must be a key the DECODER can send - the same trap
    # that made OVER DUB unreachable for months.
    for _b in list(control_map.FILES_BUTTONS) + [control_map.FILES_BUTTON]:
        assert _b in known, "%s is not a key this panel can send" % _b
    # The browser is not a page in the group row, so nothing but the shifted
    # button and D8 may claim those keys.
    assert control_map.FILES_BUTTON not in control_map.DAW_BUTTONS

    # A page a button opens must have a renderer, or the gesture opens a hole.
    import daw_ui as _dui
    assert "FILES" in _dui.RENDERERS, \
        "SHIFT+NAVIGATE opens a page nothing knows how to draw"
    for _p in daw_pages():
        assert _p in _dui.RENDERERS, "page %s has no renderer" % _p
    # --snapshot renders PAGES, so a renderer missing from that list is a page
    # no design review ever sees. WAVE and EDIT were in that hole for months.
    assert set(_dui.PAGES) == set(_dui.RENDERERS), \
        "--snapshot draws %s but renderers exist for %s" % (
            sorted(_dui.PAGES), sorted(_dui.RENDERERS))

    # The two continuous controls must produce CONTROL CHANGE, not silence.
    wheel = encode_midi("mpc:data_wheel:+3")
    assert wheel and wheel[0] == 0xB0 and wheel[1] == CC_DATA_WHEEL and wheel[2] == 3, wheel
    back = encode_midi("mpc:data_wheel:-3")
    assert back[2] == 125, back          # two's complement: -3 is 125
    var = encode_midi("mpc:note_variation:+10")
    assert var and var[0] == 0xB0 and var[1] == CC_NOTE_VARIATION
    # The SWING knob is what turns the wheel.
    assert control_map.MASTER_KNOBS["swing"] == "mpc:data_wheel"

    # Pad LEDs are numbered 1..16, our pad index is 0..15. Passing the index
    # straight through lights the wrong pad AND raises on pad 0 - and poll()
    # catches everything, so the exception silently dropped the whole report
    # and pad 1 stopped working entirely.
    _lb = mk1_leds.LedBank()
    for _p in range(16):
        _lb.set_pad(_p + 1, mk1_leds.BRIGHT)
        assert _lb.get("Pad%d" % (_p + 1)) == mk1_leds.BRIGHT, \
            "pad index %d lit the wrong LED" % _p
    try:
        _lb.set_pad(0, mk1_leds.BRIGHT)
        raise AssertionError("pad_led(0) should raise - it is 1-based")
    except ValueError:
        pass

    # The panel and the session must describe the same desk. A rename that
    # lands on one side leaves knobs addressing strips that do not exist,
    # which moves nothing and reports nothing.
    import json as _json
    _here = os.path.dirname(os.path.abspath(__file__))
    _chains = os.path.join(_here, "..", "daw", "chains.json")
    if os.path.exists(_chains):
        with open(_chains) as _f:
            _keys = set(_json.load(_f))
        _orphans = _keys - set(control_map.STRIPS)
        assert not _orphans, (
            "chains.json names strips that do not exist: %s. Renaming the desk "
            "with MPCPI_STRIPS means re-keying chains.json to match - the "
            "chains are looked up by NAME." % sorted(_orphans))
    assert len(control_map.STRIPS) == 8, "eight knobs, eight strips"
    assert "LOOP" not in control_map.STRIPS, "LOOP is a page, not a strip"

    # The mode indicator must survive the press that changes it.
    assert "DisplayButton8" in LAMP_OWNED, \
        "press feedback would clear the surface indicator on release"

    # Press feedback must never write a machine-owned LED.
    for _b, _led in BUTTON_LEDS.items():
        if _led in LAMP_OWNED:
            assert _led not in [l for l in BUTTON_LEDS.values()
                                if l not in LAMP_OWNED], "overlap"
    _m = Mk1.__new__(Mk1)
    _m.leds = mk1_leds.LedBank()
    for _led in LAMP_OWNED:
        assert _m.press_light(_led, True) is False, \
            "a press wrote %s, which the machine owns" % _led
        assert _m.leds.get(_led) == mk1_leds.OFF
    assert _m.press_light("Solo", True) is True, "a free LED must light"

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

    # A TAP SHORTER THAN THE BOUNCE WINDOW MUST STILL DELIVER BOTH EDGES.
    #
    # EP_CTRL is change-only - measured, it sends nothing at all while idle -
    # so an edge the debounce drops is never offered again. Dropping the
    # release of a quick tap left the button held forever: its next press was
    # a silent no-op and its next release fired a bare key-up, which is the
    # "a previously pressed button goes off by itself" report.
    _d = Mk1.__new__(Mk1)
    _d._init_state()
    _rd = Router()
    _pos = control_map_buttons().index("play")
    _d.button_raw = 1 << _pos
    assert _d.settle_buttons(_rd), "press must be delivered"
    assert _d.buttons == (1 << _pos)
    _d.button_raw = 0                      # released inside the window
    _d.settle_buttons(_rd)
    assert _d.buttons == (1 << _pos), "release inside the window must defer"
    _d.button_changed_at[_pos] -= Mk1.BUTTON_DEBOUNCE_S * 2      # window expires
    _d.settle_buttons(_rd)
    assert _d.buttons == 0, "deferred release never arrived - button stuck down"
    # And a bounce train settles on its final value rather than emitting each
    # flip - the reason the window exists at all.
    _d.button_raw = 1 << _pos
    _d.button_changed_at[_pos] -= Mk1.BUTTON_DEBOUNCE_S * 2
    assert _d.settle_buttons(_rd)
    for _ in range(6):                     # contact chatter, all inside 12ms
        _d.button_raw ^= (1 << _pos)
        _d.settle_buttons(_rd)
        assert _d.buttons == (1 << _pos), "a bounce escaped the window"
    _d.button_raw = 1 << _pos              # chatter settled back where it began
    _d.button_changed_at[_pos] -= Mk1.BUTTON_DEBOUNCE_S * 2
    _d.settle_buttons(_rd)
    assert _d.buttons == (1 << _pos), "settled on the wrong value"

    # TRACE-only code is not exercised by anything above, so a wrong call in it
    # ships and then crashes the hub the first time someone enables tracing -
    # which is exactly what happened: _trace takes three arguments and a new
    # call site passed two, so the service died in the poll loop and the panel
    # went dead. Check the arity statically instead; it costs one parse.
    import ast as _ast
    _src = _ast.parse(open(os.path.abspath(__file__)).read())
    _bad = [n.lineno for n in _ast.walk(_src)
            if isinstance(n, _ast.Call)
            and getattr(n.func, "id", "") == "_trace" and len(n.args) != 3]
    assert not _bad, "_trace takes (kind, payload, sink); wrong at lines %s" % _bad

    print("maschine-hub self-test PASS: one function per button, every MPC key "
          "reachable, surfaces isolated, pads upright, taps not swallowed")


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
    # 300, and it cannot go to 250. The trace shows why:
    #
    #   pad3 raw=256   raw=512   raw=1792   raw=2048   raw=2560   raw=3584
    #
    # every reading a MULTIPLE OF 256. That channel reports in sixteen coarse
    # steps, so 256 is the smallest non-zero value it can produce - and a
    # threshold of 250 sits BELOW the pad's minimum signal, which makes the
    # faintest contact a note-on. It also fires on the ghost, and no amount of
    # bleed subtraction helps: when the ghost fired, the neighbour read 0 and
    # its remembered peak read 0, so there was nothing to subtract.
    #
    # 300 requires the second step. Softer hits than that cannot be
    # distinguished from noise on this hardware, at this report rate.
    #
    # The old note, still true:
    #
    # It measured 0 on all sixteen pads at the device's normal report rate, so
    # 250 has the whole range to itself. It is NOT unconditionally safe: asking
    # the analog channels to report at rate 1 instead of 10 - sampling the ADC
    # faster than it settles - lifted the floor to ~256, and every pad then
    # free-ran on its own noise. That was mistaken for crosstalk for a while.
    #
    # So if the report rate is ever changed, measure the floor again first.
    # POLL_STATS prints it per pad.
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
    # ZERO. The pad must return all the way to rest before it can fire again.
    #
    # That is only safe because the idle floor was measured and it really is 0
    # on all sixteen pads - so "back to rest" is a state the hardware actually
    # reaches, not an unreachable ideal that would leave a pad latched forever.
    # It gives the widest possible separation from a re-trigger: a hit that
    # rings down through any positive value and back up cannot fire twice.
    #
    # On a one-shot sampler a late note-off costs nothing.
    PAD_OFF_THRESHOLD = int(os.environ.get("MPCPI_PAD_OFF", "0"))
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
    PAD_BLEED = float(os.environ.get("MPCPI_PAD_BLEED", "0"))
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
        self._init_state()
        self.init_panel()

    def _init_state(self):
        """Every field the DECODERS touch, and nothing that needs USB.

        Split out of __init__ so a caller with no controller plugged in can
        have the real state without the real device: the tests and this
        module's own self-test build one with __new__ and call this. They used
        to hand-write the subset each of them happened to need, which is a
        second copy of this list that nothing keeps in step - and it fell
        behind twice, once when the debounce grew button_raw/button_changed_at
        and once when the pad decoder grew its peak tracking. Both times the
        tests failed with AttributeError on code that was working fine.
        """
        self.pad_state = [0] * 16
        self.pad_on = [False] * 16
        self.pad_raw = [0] * 16
        self.pad_peak = [0] * 16
        self.pad_last_on = [0.0] * 16
        self.pad_last_force = [0] * 16
        self.pad_crosstalk = 0
        self._watch = None
        self._leds_dirty = False
        self._pad_lit_at = [0.0] * 16
        self._led_flushed_at = 0.0
        self._ctrl_tick = 0
        self._pad_read_at = 0.0
        self._pad_gaps = []
        self._read_waits = []
        self._pad_seen_max = [0] * 16
        self.pad_suppressed = 0
        self.buttons = 0
        # Last bitfield the HARDWARE reported, which is not what we have acted
        # on yet. settle_buttons closes the gap when the bounce window allows.
        self.button_raw = 0
        self.button_changed_at = [0.0] * 48
        self.button_bounces = 0
        self.encoders = mk1_encoders.EncoderTracker()
        self.frames = {}
        self.leds = mk1_leds.LedBank()
        self._lamp_line = None

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

    def press_light(self, led, on):
        """Light an LED for a press, unless the MACHINE owns it.

        The refusal is the point. LAMP_TO_LED's values are driven from the
        MPC's own outputs, and letting a press write one would put a guess
        where real state belongs - PLAY would light because you pressed it
        rather than because the sequencer is running, which is the failure the
        lamp export exists to prevent.
        """
        if not led or led in LAMP_OWNED:
            return False
        return self.leds.set(led, mk1_leds.BRIGHT if on else mk1_leds.OFF)

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

    def poll(self, router, timeout=2):
        """Read whatever is pending and return routed events.

        PADS FIRST AND OFTEN. This read pads and buttons with the same 4ms
        timeout and then slept 2ms, so a pad hit waited behind a button
        endpoint that usually has nothing to say: measured, the pads were
        sampled every 6.25ms with a tail to 16ms. That is several times the
        entire audio path, and no buffer size can win it back.

        Buttons are polled every BUTTON_POLL_EVERY passes instead. A button is
        a mode change; a pad is a note, and only one of them is played in time.
        """
        events = []
        try:
            _t0 = time.monotonic() if POLL_STATS else 0.0
            data = self.dev.read(EP_PADS, 64, timeout=timeout)
            if POLL_STATS:
                now = time.monotonic()
                self._read_waits.append(now - _t0)
                if self._pad_read_at:
                    self._pad_gaps.append(now - self._pad_read_at)
                self._pad_read_at = now
            events += self._pads(data, router)
        except Exception:
            pass
        self._ctrl_tick += 1
        if not (self._ctrl_tick % BUTTON_POLL_EVERY):
            # DRAIN it, do not take one report and leave the rest queued.
            #
            # EP_CTRL is change-only, so every report queued behind the one we
            # take is an EDGE - a press or a release that has already happened.
            # Reading one per four passes while a press and its release both
            # sit in the FIFO means the release waits four more passes for no
            # reason, and a burst never catches up.
            #
            # Bounded, because the encoders can talk continuously while a knob
            # is turning and this loop must not become the pad loop's problem.
            for _ in range(8):
                try:
                    data = self.dev.read(EP_CTRL, 64, timeout=1)
                except Exception:
                    break
                if not len(data):
                    break
                events += self._ctrl(data, router)
        # Every pass, report or not: a transition held back by the bounce
        # window has to be reconsidered while the endpoint stays silent, and
        # EP_CTRL stays silent until something else moves.
        events += self.settle_buttons(router)
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

    def velocity(self, pressure):
        """Map pad pressure to MIDI velocity 1..127.

        This was `min(127, pressure >> 5)`, a fixed shift, which puts full
        scale at 4064 counts. The pads do not reach that, so the top of the
        range was unreachable no matter how hard they were hit - a hard hit
        landed around 96 and 127 could not be played at all.
        
        Now it interpolates between the on-threshold and PAD_FULL_SCALE, so
        the softest hit that registers is 1 and a hit at full scale is 127.
        Both ends are settings, because where a pad tops out is a property of
        the hardware and this one has already been measured wrong once.
        """
        span = max(1, PAD_FULL_SCALE - self.PAD_ON_THRESHOLD)
        v = 1 + int(round((pressure - self.PAD_ON_THRESHOLD) * 126.0 / span))
        return max(1, min(127, v))

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
            value = ((hi & 0x0F) << 8) | lo
            self.pad_raw[raw] = value
            # A decaying peak per channel, so a hit still counts as a bleed
            # source for a few milliseconds after its own reading has fallen.
            self.pad_peak[raw] = max(value,
                                     int(self.pad_peak[raw] * PAD_PEAK_DECAY))
            if POLL_STATS and value > self._pad_seen_max[raw]:
                self._pad_seen_max[raw] = value
            seen.append(raw)
        # Sample the watched neighbour before deciding anything this pass.
        if self._watch is not None:
            w_raw, w_pad, w_force, w_t0, w_samples = self._watch
            nb_raw = (w_raw - 1) % 16
            w_samples.append((int((time.monotonic() - w_t0) * 1000),
                              self.pad_raw[nb_raw]))
            if len(w_samples) >= 24:
                peak = max(v for _, v in w_samples)
                at = [ms for ms, v in w_samples if v == peak][0]
                _trace("lag", "p%d hit %d -> neighbour p%d peaks %d at %dms"
                       % (w_pad + 1, w_force,
                          Mk1._pad_index(nb_raw) + 1, peak, at),
                       " ".join("%d:%d" % (ms, v) for ms, v in w_samples))
                self._watch = None

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
            # Compare against the neighbour's recent PEAK, not its value right
            # now. The bleed LAGS its source: by the time the neighbour's
            # crosstalk peaks on this channel, the pad that caused it has
            # already decayed, so an instantaneous comparison stops recognising
            # it as bleed and lets the raw value through. That is the ghost
            # that survived the first correction - and lowering the on
            # threshold to 250 made it easier to reach.
            neighbour = max(self.pad_raw[(raw + 1) % 16],
                            self.pad_peak[(raw + 1) % 16])
            # OFF BY DEFAULT (PAD_BLEED=0).
            #
            # This and the crosstalk rule were both built on the belief that
            # the ghosting LAGGED its source. That was never demonstrated: the
            # trace it came from showed the ghosting pad's neighbour reading 0
            # with a remembered peak of 0, which does not mean "the peak
            # decayed" - it means there was no neighbour signal at all. The
            # ghost was the on-threshold sitting under the pad's 256-count
            # minimum step, and raising it to 300 is what actually fixed it.
            #
            # Subtracting 0.35 of a neighbour's peak from every hit costs real
            # playing: a 600-count snare after a 2048-count hihat loses ~500
            # and falls under the threshold, which is the disappearing hit that
            # was reported. Set MPCPI_PAD_BLEED to re-enable it if a ghost ever
            # returns that the threshold cannot explain.
            #
            # ALWAYS subtract. There used to be a gate - only correct when the
            # neighbour was more than twice this pad's reading - and it failed
            # in exactly the case that matters. The bleed lags its source, the
            # remembered peak decays while it arrives, and once the peak has
            # fallen near the bleed's own size the gate stops firing and the
            # raw value passes. Measured: a 2048 hit on pad 3 put 253 on pad 2,
            # about 12%, and 253 is above the 250 threshold.
            #
            # Subtracting unconditionally is safe because the correction is
            # PROPORTIONAL: a genuine simultaneous hit is far larger than its
            # neighbour's bleed and survives with most of its velocity, while
            # bleed is removed entirely.
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
                if TRACE and self._watch is None:
                    # Follow the scan neighbour for the next few milliseconds.
                    # The snapshot below shows ONE instant; whether the leak
                    # lags needs its shape over time, which is the claim two
                    # deleted corrections rested on and nobody had measured.
                    self._watch = [raw, pad, own, time.monotonic(), []]
                if TRACE:
                    # The whole grid at the moment of the hit, laid out as the
                    # pads sit, so physical crosstalk is visible as a shape
                    # rather than inferred from one neighbour.
                    rows = []
                    for r in range(3, -1, -1):
                        rows.append(" ".join(
                            "p%-2d=%-5d" % (r * 4 + c + 1,
                                            self.pad_raw[Mk1._pad_index(r * 4 + c)])
                            for c in range(4)))
                    _trace("grid", "hit p%d" % (pad + 1), " | ".join(rows))
                    _trace("padraw",
                           "pad%-2d raw=%-5d nb(raw%d)=%-5d peak=%-5d -> %d"
                           % (pad + 1, own, (raw + 1) % 16,
                              self.pad_raw[(raw + 1) % 16],
                              self.pad_peak[(raw + 1) % 16], pressure),
                           "ON")
                self.pad_on[pad] = True
                now = time.monotonic()
                if (now - self.pad_last_on[pad]) < self.PAD_RETRIGGER_S:
                    self.pad_suppressed += 1
                    _trace("pad", "p%d retrigger suppressed" % pad, "dropped")
                    continue
                self.pad_last_on[pad] = now
                self.pad_last_force[pad] = pressure
                if self.leds.set_pad(pad + 1, mk1_leds.BRIGHT):
                    self._leds_dirty = True
                self._pad_lit_at[pad] = now
                # Velocity from the leading edge: the stream is pressure,
                # not note-on, so the first crossing is the hit.
                out += router.pad(pad, self.velocity(pressure))
            elif self.pad_on[pad] and pressure <= self.PAD_OFF_THRESHOLD:
                self.pad_on[pad] = False
                # Lit while HELD - but never for less than PAD_LIGHT_MIN_S, or
                # a fast hit is invisible. If the pad was released sooner than
                # that, leave it lit and let the loop darken it.
                if (time.monotonic() - self._pad_lit_at[pad]) >= PAD_LIGHT_MIN_S:
                    self._pad_lit_at[pad] = 0.0
                    if self.leds.set_pad(pad + 1, mk1_leds.OFF):
                        self._leds_dirty = True
                out += router.pad(pad, 0)
        return out

    def settle_buttons(self, router):
        """Move the debounced button state toward what the hardware reports.

        THE DEBOUNCE MUST DEFER A TRANSITION, NEVER DISCARD ONE.

        This used to drop any edge that arrived inside the bounce window and
        then wait for the device to mention it again. The device never does:
        EP_CTRL is change-only. Measured idle, over five seconds of reading as
        fast as the endpoint allows, it sends exactly zero reports. There is no
        periodic state report to correct a wrong guess.

        So a discarded edge was permanent. The consequences, all three of which
        were reported from the panel:

          * a quick tap - press, then release inside 12ms - kept the button
            DOWN in our state forever. The MPC got the key-down and never the
            key-up.
          * the next press of that button was then a no-op: the bit was already
            set, so nothing changed and nothing was sent. "Doesn't work
            reliably."
          * and its release DID differ, so that press emitted a bare key-up for
            a button pressed some time ago - a previously-pressed button firing
            at a moment nothing was pressed. That is the phantom.

        Deferring instead costs nothing: a bounce train still settles to its
        final state, because the intermediate flips are absorbed and only the
        value standing when the window expires is applied. A real tap's release
        lands at the end of the window instead of the middle - 12ms late, once,
        and it lands.

        Called on EVERY poll pass, not only when a report arrives, which is the
        half that makes it work. A deferred edge has to be reconsidered while
        the endpoint stays silent.
        """
        diff = self.button_raw ^ self.buttons
        if not diff:
            return []
        now = time.monotonic()
        bits = self.buttons
        for pos in range(48):
            if not (diff >> pos) & 1:
                continue
            if (now - self.button_changed_at[pos]) < self.BUTTON_DEBOUNCE_S:
                self.button_bounces += 1
                continue
            self.button_changed_at[pos] = now
            bits ^= (1 << pos)
        changed = bits ^ self.buttons
        if not changed:
            return []
        self.buttons = bits
        out = []
        names = control_map_buttons()
        for pos, name in enumerate(names):
            if name and (changed >> pos) & 1:
                down = bool((bits >> pos) & 1)
                if TRACE:
                    _trace("btn", "%d=%s" % (pos, name),
                           "down" if down else "up")
                if self.press_light(BUTTON_LEDS.get(name), down):
                    self._leds_dirty = True
                out += router.button(name, down)
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
            # Record what the hardware says. Deciding what to DO about it is
            # settle_buttons' job, and it has to be able to run again later.
            self.button_raw = int.from_bytes(bytes(data[1:7]), "little")
            if TRACE and self.button_raw != self.buttons:
                _trace("btn", "raw=%s" % bytes(data[1:7]).hex(" "),
                       "pending %012x" % (self.button_raw ^ self.buttons))
            out += self.settle_buttons(router)
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
                    mk1._leds_dirty = True
                if mk1._leds_dirty:
                    mk1._leds_dirty = False
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

        # LEDs, on every pass rather than once per screen frame. A hit shorter
        # than the 100ms frame budget used to be set and cleared between two
        # flushes and never appeared at all.
        _now = time.monotonic()
        for _p in range(16):
            if (mk1._pad_lit_at[_p] and not mk1.pad_on[_p]
                    and (_now - mk1._pad_lit_at[_p]) >= PAD_LIGHT_MIN_S):
                mk1._pad_lit_at[_p] = 0.0
                if mk1.leds.set_pad(_p + 1, mk1_leds.OFF):
                    mk1._leds_dirty = True
        if mk1._leds_dirty and (_now - mk1._led_flushed_at) >= LED_FLUSH_S:
            mk1._leds_dirty = False
            mk1._led_flushed_at = _now
            try:
                mk1.flush_leds()
            except Exception:
                pass
        if POLL_STATS and len(mk1._pad_gaps) >= 400:
            g = sorted(mk1._pad_gaps)
            mk1._pad_gaps = []
            w = sorted(mk1._read_waits) or [0.0]
            mk1._read_waits = []
            # Split the cycle: time WAITING for the device against time we
            # spend before asking it again. Only one of those can be fixed here.
            print("hub: pad cycle ms med=%.2f p99=%.2f max=%.2f | "
                  "usb wait med=%.2f | our work med=%.2f"
                  % (g[len(g)//2]*1000, g[int(len(g)*0.99)]*1000, g[-1]*1000,
                     w[len(w)//2]*1000,
                     (g[len(g)//2] - w[len(w)//2])*1000),
                  file=sys.stderr, flush=True)
            # The idle floor, per pad, in the units PAD_ON is compared against.
            # It is NOT zero, and PAD_ON has to clear it - lowering the
            # threshold under it made every pad free-run.
            print("hub: pad max since last report: %s"
                  % " ".join("p%d=%d" % (Mk1._pad_index(i) + 1, v)
                             for i, v in enumerate(mk1._pad_seen_max)),
                  file=sys.stderr, flush=True)
            mk1._pad_seen_max = [0] * 16
        # No sleep. The pad read blocks for up to its timeout, which paces the
        # loop against the device rather than against a fixed delay added on
        # top of it - the 2ms that used to be here was pure added latency.


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
    # The two continuous controls ride CONTROL CHANGE, not notes. They are the
    # DATA wheel and the NOTE VARIATION slider, and they are not keys - which
    # is why encoding them as one produced nothing at all for months:
    # encode_midi split "mpc:data_wheel:+3" on the first colon, looked up
    # "data_wheel:+3" in the KEYCODE table, missed, and returned b"".
    if target.startswith("mpc:data_wheel:"):
        delta = int(target.rsplit(":", 1)[1])
        # Relative two's complement, clamped to what one message can carry.
        step = max(-63, min(63, delta))
        if not step:
            return b""
        return bytes([0xB0, CC_DATA_WHEEL, step & 0x7f if step > 0
                      else (128 + step)])
    if target.startswith("mpc:note_variation:"):
        delta = int(target.rsplit(":", 1)[1])
        # Absolute, because it is a slider: the hub holds the position.
        global _variation
        _variation = max(0, min(127, _variation + delta))
        return bytes([0xB0, CC_NOTE_VARIATION, _variation])

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
