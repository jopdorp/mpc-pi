"""Maschine MK1 LED output.

The third of the device that had no code at all. Displays and input were
implemented; the LED block was one line of prose in the protocol doc.

That gap was worse than "pads do not light up", because **the display
backlight is an LED byte**. Index 58, DisplayBacklight - cabl sets it to
0x5C at the end of init. Without writing the LED block at all, both
screens stay dark no matter how correct the frame data is, and a first
bring-up would look like a broken display protocol while the real cause
sat in an unimplemented subsystem.

Layout taken from shaduzlabs/cabl `src/devices/ni/MaschineMK1.cpp`
(`enum class MaschineMK1::Led` and `sendLeds()`), which is a working
implementation rather than a description of one.

Brightness is the only thing writable - one byte per LED, 0x00 to 0x7F.
There is no colour channel: RGB per-pad is MK2.

But the panel is NOT one colour. Observed on hardware: pads light green,
the group buttons A-H light blue, some buttons light red, and the display
backlight is white. Those colours are fixed in the hardware, one per
control, and a byte written here only sets how brightly that control's
own colour shows.

An earlier version of this file and of the protocol doc said "single
colour amber", which is wrong in a way that misleads design work: a page
can rely on a given control's colour being constant and meaningful
(blue always means a group), and must never try to choose one.
"""

# Endpoint. NOT the display endpoint (0x08) - LEDs, MIDI out and the init
# handshake all share the generic OUT endpoint. Confirmed on hardware:
# writing the LED block here lights pads, buttons and the screen
# backlights. Writing the identical block to 0x08 is *accepted* and
# silently discarded, which is the more dangerous of the two failures.
EP_OUT = 0x01

# Interface 0 has TWO alternate settings, and this is not in cabl or in
# any published write-up of the device:
#
#   alt 0:  ep 0x01 OUT, 0x81 IN
#   alt 1:  ep 0x01 OUT, 0x81 IN, 0x84 IN (pads), 0x08 OUT (display)
#
# A USB device defaults to alt 0, where the pad and display endpoints DO
# NOT EXIST - reads from 0x84 fail with EIO and display writes fail the
# same way. Nothing works properly until the interface is switched.
ALTSETTING = 1

# The device streams input continuously on 0x81 and 0x84, and it will not
# accept output while reports are queued: writes to 0x01 return
# ETIMEDOUT (errno 110), not EBUSY and not EPIPE. Drain the IN endpoints
# and the same write succeeds.
#
# This is why cabl runs an async read loop with output on a tick rather
# than writing on demand, and it is worth stating plainly because the
# symptom points nowhere near the cause: a timeout on an OUT endpoint
# reads as "the device is not listening" when it actually means "the
# host has stopped listening".
IN_ENDPOINTS = (0x81, 0x84)

# Declaration order IS the wire order: the index of a name in this list is
# its byte offset in the 62-byte LED block.
#
# Two traps live in here, both of which look like typos and are not:
#
#   * Pads run 4,3,2,1 / 8,7,6,5 / 12,11,10,9 / 16,15,14,13 - reversed
#     within each row of four. Writing pads in natural order mirrors
#     every row horizontally, which on a 4x4 grid looks like a plausible
#     "the pads are just mapped differently" result rather than a bug.
#   * DisplayButton runs 8..1, descending, unlike everything else.
LED_ORDER = (
    "Pad4", "Pad3", "Pad2", "Pad1",
    "Pad8", "Pad7", "Pad6", "Pad5",
    "Pad12", "Pad11", "Pad10", "Pad9",
    "Pad16", "Pad15", "Pad14", "Pad13",
    "Mute", "Solo", "Select", "Duplicate",
    "Navigate", "Keyboard", "Pattern", "Scene",
    "Shift", "Erase", "Grid", "TransportRight",
    "Rec", "Play",
    "Unused1",                      # index 30 - end of group 0
    "TransportLeft", "Loop",
    "GroupH", "GroupG", "GroupD", "GroupC",
    "GroupF", "GroupE", "GroupB", "GroupA",
    "AutoWrite", "Snap", "BrowseRight", "BrowseLeft",
    "Sampling", "Browse", "Step", "Control",
    "DisplayButton8", "DisplayButton7", "DisplayButton6", "DisplayButton5",
    "DisplayButton4", "DisplayButton3", "DisplayButton2", "DisplayButton1",
    "NoteRepeat",
    "DisplayBacklight",             # index 58 - the screens' backlight
    "Unused2", "Unused3", "Unused4",
)

LED_INDEX = {name: i for i, name in enumerate(LED_ORDER)}

N_LEDS = 62
assert len(LED_ORDER) == N_LEDS, "LED table must be exactly %d entries" % N_LEDS

# Group boundary. cabl splits on `led > Unused1`, i.e. group 0 is 0..30
# and group 1 is 31..61 - 31 bytes each.
GROUP0 = slice(0, 31)
GROUP1 = slice(31, 62)

# The second header byte for group 1 is 0x1E (30), while its data starts
# at index 31. That off-by-one asymmetry looks like a bug and is not:
# it is what cabl's working implementation sends. Do not "correct" it
# without hardware in front of you.
GROUP0_HEADER = (0x0C, 0x00)
GROUP1_HEADER = (0x0C, 0x1E)

# cabl uses 0x5C, the maximum is 0x7F, and "too dark" on this device is
# usually the backlight rather than the contrast - they are separate axes
# and each is useless against the other's problem.
#
# 0x68 is a compromise: clearly brighter than cabl's default, but not the
# maximum. This is a bus-powered device on a port a Pi 5 limits to 600mA
# total, and it has twice gone unresponsive after sustained full-brightness
# LED use. Peaks are fine; holding the maximum for minutes is what to
# avoid. Raise it with MPC_MK1_BACKLIGHT once usb_max_current_enable=1 is
# set and a 5A supply is confirmed.
BACKLIGHT_DEFAULT = 0x68
BRIGHT = 0x7F
DIM = 0x20
OFF = 0x00

# Sent to EP_OUT during init, before reading input. Undocumented in every
# write-up of this device found so far; cabl issues it unconditionally
# between the first frame and the first LED block. Input reports were
# never observed to start without it, so it is treated as required.
INIT_HANDSHAKE = (0x0B, 0xFF, 0x02, 0x05)


def pad_led(n):
    """LED name for physical pad n (1-16, bottom-left is 1 as NI numbers)."""
    if not 1 <= n <= 16:
        raise ValueError("pad %r out of range 1..16" % n)
    return "Pad%d" % n


class LedBank:
    """The 62 LED bytes, with dirty tracking per group.

    Held as state rather than written through, because the device takes
    LEDs in two 31-byte blocks: changing one pad means resending the
    whole group it belongs to. Tracking dirtiness per group is what keeps
    a pad animation from pushing 62 bytes per frame down a bus that is
    also carrying two 10,880-byte display frames.
    """

    def __init__(self):
        self._v = bytearray(N_LEDS)
        self._dirty0 = True
        self._dirty1 = True

    def __len__(self):
        return N_LEDS

    def set(self, name, value):
        """Set one LED by name. Returns True if the value changed."""
        try:
            i = LED_INDEX[name]
        except KeyError:
            raise KeyError(
                "unknown LED %r - names come from LED_ORDER, which is the "
                "wire order from cabl" % (name,))
        v = max(0, min(0x7F, int(value)))
        if self._v[i] == v:
            return False
        self._v[i] = v
        if i < 31:
            self._dirty0 = True
        else:
            self._dirty1 = True
        return True

    def get(self, name):
        return self._v[LED_INDEX[name]]

    def set_pad(self, n, value):
        return self.set(pad_led(n), value)

    def all(self, value):
        for name in LED_ORDER:
            self.set(name, value)

    def backlight(self, value=BACKLIGHT_DEFAULT):
        """The screens' backlight. Nothing is visible on either display
        until this is non-zero, however good the frame data is."""
        return self.set("DisplayBacklight", value)

    def blocks(self, force=False):
        """Yield (header, payload) for each group that needs sending."""
        if force or self._dirty0:
            yield GROUP0_HEADER, bytes(self._v[GROUP0])
        if force or self._dirty1:
            yield GROUP1_HEADER, bytes(self._v[GROUP1])

    def mark_sent(self):
        self._dirty0 = False
        self._dirty1 = False

    def flush(self, write, force=False):
        """Send dirty groups via write(endpoint, data). Returns blocks sent."""
        n = 0
        for header, payload in self.blocks(force=force):
            write(EP_OUT, bytes(header) + payload)
            n += 1
        self.mark_sent()
        return n
