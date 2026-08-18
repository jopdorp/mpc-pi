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

        # `and down`: without it PIN toggles on press AND on release, so
        # a real press-and-release pins the mode and instantly unpins
        # it, and the latch does nothing on hardware. The routing
        # self-test sent only the press edge and never noticed; a finger
        # always sends both.
        if name == control_map.PIN_BUTTON and self.held and down:
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
    # One knob per strip, all eight reachable. The old assertion here was
    # that knob 1 sent the MPC's data wheel, which is exactly the mapping
    # that left half the desk without a knob.
    r.page = "MIX"
    for i, strip in enumerate(r.strips):
        assert r.knob(i, 1) == [("cmd", "knob MIX %s +1" % strip)], i
    # The DATA wheel is the SWING knob now - a dedicated control, not a
    # modifier combination, because it is the MPC's most used value control.
    assert r.master("swing", +3) == [("midi", "mpc:data_wheel:+3")]
    assert r.master("tempo", -2) == [("midi", "mpc:note_variation:-2")]
    assert r.master("volume", +4) == [("cmd", "master +4")]
    # SHIFT no longer steals a knob.
    r.shift = True
    assert r.knob(0, 1) == [("cmd", "knob MIX MPC +1")]
    r.shift = False
    r.page = "MIX"
    # Knob 5 is the FIFTH strip now, not the first. Under the old split it
    # was strip index 0 because indices 4-7 were remapped to 0-3.
    assert r.knob(4, -2) == [("cmd", "knob MIX LOOP -2")]

    # The MPC's printed shift-pad functions stay true.
    r.button("shift", True)
    assert r.pad(0, 100) == [("midi", "mpc:undo")]
    assert r.pad(4, 100) == [("cmd", "action quantize")]

    # The grid is not upside down. The MK1 numbers its pads from the top row
    # down and the MPC numbers them from the bottom row up, so pad 0 - note 36,
    # the one every pad grid puts bottom left - must come from the LAST
    # hardware row, not the first.
    flip = Mk1._pad_index
    assert flip(12) == 0 and flip(15) == 3, "bottom hardware row is not pads 0-3"
    assert flip(0) == 12 and flip(3) == 15, "top hardware row is not pads 12-15"
    assert sorted(flip(i) for i in range(16)) == list(range(16)), \
        "pad remap is not a bijection"
    assert all(flip(i) % 4 == i % 4 for i in range(16)), \
        "pad remap moved a column; only rows should flip"


    print("maschine-hub self-test PASS: routing verified for buttons, "
          "pads, pad orientation, knobs, shift and hold-modes")


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
    PAD_ON_THRESHOLD = 400
    PAD_OFF_THRESHOLD = 150
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
        self.buttons = 0
        self.encoders = mk1_encoders.EncoderTracker()
        self.frames = {}
        self.leds = mk1_leds.LedBank()
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
        for i in range(1, len(data) - 1, 2):
            hi, lo = data[i], data[i + 1]
            raw = (hi & 0xF0) >> 4
            pressure = ((hi & 0x0F) << 8) | lo
            if raw > 15:
                continue
            pad = self._pad_index(raw)
            self.pad_state[pad] = pressure
            # Two thresholds, and a latched per-pad state rather than a
            # comparison of the last two samples. With one threshold, a pad
            # decaying through it - or scan bleed from the neighbouring
            # channel touching it - is a fresh note-on every time it crosses.
            if not self.pad_on[pad] and pressure > self.PAD_ON_THRESHOLD:
                self.pad_on[pad] = True
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
            bits = int.from_bytes(bytes(data[1:7]), "little")
            changed = bits ^ self.buttons
            self.buttons = bits
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
            elif kind == "midi":
                if sinks["midi"] is not None:
                    sinks["midi"].write(encode_midi(payload))
                    _trace("midi", payload, args.midi)
                else:
                    _trace("midi", payload, "dropped (no MIDI port)")
                # Same bytes the rig hears: pads with real velocity, panel
                # keys as notes. A DAW maps them like any pad controller.
                if sinks["pc"] is not None:
                    try:
                        sinks["pc"].write(encode_midi(payload))
                    except OSError:
                        sinks["pc"] = None
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
