"""Maschine MK1 display protocol, in ONE place.

The 22-command init sequence was written out three times - in the boot
animation, the bring-up tool, and the LCD bridge - and it diverged. The
animation's version framed every command wrongly: its helper inserted a
length byte on top of the one already being passed, so

    C(0x01, 0x30)        intended  {d, 00, 01, 30}
                         sent      {d, 00, 02, 01, 30}

All 22 commands were malformed, INCLUDING 0xAF display-on. The panel never
initialised and showed its uninitialised RAM, which reads as all-white. No
error was possible: the device accepts whatever it is handed.

Two wrong explanations came out of that before the real one, and both are
worth remembering because they were plausible:

  * "It only worked when the bring-up tool had already initialised the
    panels" - no; the animation's init never initialised anything.
  * "Draining before every write fixes init" - no; it made malformed
    commands arrive reliably. It also produced a 1.9fps measurement that
    suggested a frame-rate trade-off which does not exist.

So the sequence lives here now, as data, and every consumer uses it.
"""

# Command packet layout: {d, 0x00, length, payload...} with d = index << 1.
# Each entry below is the (length, payload...) tuple - i.e. everything after
# {d, 0x00}. `None` means "sleep 20ms here".
SLEEP = None
SLEEP_SECONDS = 0.02

# Contrast is substituted at build time. 0x10 was chosen by looking at the
# hardware: cabl's 0x25 is too dark on this unit, and above ~0x20 the greys
# crush toward black.
CONTRAST_PLACEHOLDER = "CONTRAST"


def init_commands(contrast=0x10):
    """The full 22-command init, as a list of tuples and SLEEP markers.

    Order matters and the tail matters most: an earlier version of the
    protocol doc stopped at {01, 31}, twelve commands in, and the code
    followed it. The omitted tail contains 0xAF - display on - so every
    frame went into a panel that had never been switched on.
    """
    return [
        (0x01, 0x30),
        (0x04, 0xCA, 0x04, 0x0F, 0x00),
        SLEEP,
        (0x02, 0xBB, 0x00),
        (0x01, 0xD1),
        (0x01, 0x94),
        (0x03, 0x81, contrast, 0x02),
        SLEEP,
        (0x02, 0x20, 0x08),
        SLEEP,
        (0x02, 0x20, 0x0B),
        SLEEP,
        (0x01, 0xA6),                 # normal (non-inverted) scan
        (0x01, 0x31),
        # --- the tail the protocol doc used to omit ---
        (0x04, 0x32, 0x00, 0x00, 0x05),
        (0x01, 0x34),
        (0x01, 0x30),
        (0x04, 0xBC, 0x00, 0x01, 0x02),
        (0x03, 0x75, 0x00, 0x3F),     # row window 0..63
        (0x03, 0x15, 0x00, 0x54),     # column window 0..84
        (0x01, 0x5C),
        (0x01, 0x25),
        SLEEP,
        (0x01, 0xAF),                 # *** DISPLAY ON ***
        SLEEP,
        (0x04, 0xBC, 0x02, 0x01, 0x01),
        (0x01, 0xA6),
        (0x03, 0x81, contrast, 0x02),
    ]


def packets(index, contrast=0x10):
    """Yield (bytes_or_None) ready to write. None means sleep.

    Doing the framing here is the point: `{d, 0x00}` and the length come
    from one place, so a caller cannot supply the length twice.
    """
    d = index << 1
    for cmd in init_commands(contrast):
        if cmd is SLEEP:
            yield None
        else:
            yield bytes((d, 0x00) + tuple(cmd))


def frame_packets(index, frame, frame_bytes=None):
    """Yield the packets for one full frame: two window commands, 22 chunks.

    21 chunks of 502 plus a final 338 is 10,880 bytes exactly, which is
    64 rows x 170 bytes. An earlier revision of the doc said 5,358, which
    covers 31 rows - the bridge inherited it and silently dropped the bottom
    half of every frame.
    """
    total = frame_bytes if frame_bytes is not None else len(frame)
    d = index << 1
    yield bytes([d, 0x00, 0x03, 0x75, 0x00, 0x3F])
    yield bytes([d, 0x00, 0x03, 0x15, 0x00, 0x54])
    yield bytes([d, 0x01, 0xF7, 0x5C]) + frame[0:502]
    off = 502
    while off + 502 <= total - 338:
        yield bytes([d + 1, 0x01, 0xF6]) + frame[off:off + 502]
        off += 502
    yield bytes([d + 1, 0x01, 0x52]) + frame[off:total]
