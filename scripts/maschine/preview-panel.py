#!/usr/bin/env python3
"""Render both Maschine displays side by side for design review.

Screen L carries the emulated MPC2000XL LCD (the real frame exported by
patch 0039 when one is available, otherwise a placeholder), screen R
carries a DAW page. Reviewing them together is the point: the instrument
is one surface with two windows, and a page that reads well alone can
still fight the LCD next to it.

  preview-panel.py out.png [page] [/dev/shm/mpc-lcd]
"""
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ui import Frame, DIM, MUTED, NORMAL, BRIGHT, MAX  # noqa: E402
import daw_ui  # noqa: E402

GAP = 12          # the physical bezel between the two panels
HEADER_FMT = "<4sIHHI"
HEADER_SIZE = struct.calcsize(HEADER_FMT)


def load_lcd(path):
    """Return a Frame holding the exported MPC LCD, or None."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    if len(data) < HEADER_SIZE:
        return None
    magic, _seq, w, h, _ = struct.unpack_from(HEADER_FMT, data, 0)
    if magic != b"MPCL":
        return None
    px = data[HEADER_SIZE:HEADER_SIZE + w * h]
    if len(px) < w * h:
        return None
    f = Frame()
    f.clear()
    # The MPC panel is 240x64 inside a 255x64 window: centre it so the
    # bezel gap is even, the way the hardware LCD sits in its cutout.
    ox = max(0, (f.w - w) // 2)
    for y in range(min(h, f.h)):
        for x in range(w):
            if px[y * w + x]:
                f.point(ox + x, y, MAX)
    return f


def placeholder_lcd():
    f = Frame()
    f.clear()
    f.rect(8, 6, 239, 52, DIM)
    f.text_center(0, 255, 22, "MPC2000XL LCD", MUTED)
    f.text_center(0, 255, 34, "NO EXPORT - RUN THE EMULATOR", DIM)
    return f


def combine(left, right, path, scale=3):
    total_w = left.w + GAP + right.w
    out = Frame(total_w, max(left.h, right.h))
    out.clear()
    for y in range(left.h):
        for x in range(left.w):
            out.px[y * total_w + x] = left.px[y * left.w + x]
    off = left.w + GAP
    for y in range(right.h):
        for x in range(right.w):
            out.px[y * total_w + off + x] = right.px[y * right.w + x]
    out.to_png(path, scale=scale)
    return out


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "panel.png"
    page = sys.argv[2].upper() if len(sys.argv) > 2 else "LOOP"
    lcd_path = sys.argv[3] if len(sys.argv) > 3 else "/dev/shm/mpc-lcd"

    left = load_lcd(lcd_path)
    source = "live export"
    if left is None:
        left = placeholder_lcd()
        source = "placeholder"
    right = daw_ui.render(daw_ui.sample_state(page))
    combine(left, right, out)
    print("wrote %s (left: %s, right: %s)" % (out, source, page))


if __name__ == "__main__":
    main()
