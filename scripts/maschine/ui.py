#!/usr/bin/env python3
"""Drawing primitives for the Maschine MK1 displays.

The panel is 255x64 with 5 bits per pixel, so there are 32 brightness
levels rather than plain on/off — the DAW pages use that for hierarchy
(a dim label next to a bright value reads instantly at arm's length,
where two equally bright rows do not).

No dependencies: the framebuffer is a bytearray of levels 0..31 and the
PNG writer is the same minimal one the LCD bridge already uses, so this
runs on the appliance as well as on a desktop for design review.
"""
import struct
import zlib

W, H = 255, 64
MAX = 0x1F

# Brightness roles. Naming them keeps the pages consistent and makes a
# global contrast change one edit.
OFF = 0
DIM = 6         # inactive labels, grid lines
MUTED = 12      # secondary values
NORMAL = 20     # ordinary text
BRIGHT = MAX    # the thing the eye should land on first

# 5x7 font, column-major, bit 0 = top row.
FONT = {
    " ": (0x00, 0x00, 0x00, 0x00, 0x00),
    "!": (0x00, 0x00, 0x5F, 0x00, 0x00),
    "#": (0x14, 0x7F, 0x14, 0x7F, 0x14),
    "%": (0x23, 0x13, 0x08, 0x64, 0x62),
    "(": (0x00, 0x1C, 0x22, 0x41, 0x00),
    ")": (0x00, 0x41, 0x22, 0x1C, 0x00),
    "*": (0x14, 0x08, 0x3E, 0x08, 0x14),
    "+": (0x08, 0x08, 0x3E, 0x08, 0x08),
    ",": (0x00, 0x50, 0x30, 0x00, 0x00),
    "-": (0x08, 0x08, 0x08, 0x08, 0x08),
    ".": (0x00, 0x60, 0x60, 0x00, 0x00),
    "/": (0x20, 0x10, 0x08, 0x04, 0x02),
    "0": (0x3E, 0x51, 0x49, 0x45, 0x3E),
    "1": (0x00, 0x42, 0x7F, 0x40, 0x00),
    "2": (0x42, 0x61, 0x51, 0x49, 0x46),
    "3": (0x21, 0x41, 0x45, 0x4B, 0x31),
    "4": (0x18, 0x14, 0x12, 0x7F, 0x10),
    "5": (0x27, 0x45, 0x45, 0x45, 0x39),
    "6": (0x3C, 0x4A, 0x49, 0x49, 0x30),
    "7": (0x01, 0x71, 0x09, 0x05, 0x03),
    "8": (0x36, 0x49, 0x49, 0x49, 0x36),
    "9": (0x06, 0x49, 0x49, 0x29, 0x1E),
    ":": (0x00, 0x36, 0x36, 0x00, 0x00),
    "<": (0x08, 0x14, 0x22, 0x41, 0x00),
    "=": (0x14, 0x14, 0x14, 0x14, 0x14),
    ">": (0x41, 0x22, 0x14, 0x08, 0x00),
    "?": (0x02, 0x01, 0x51, 0x09, 0x06),
    "A": (0x7E, 0x11, 0x11, 0x11, 0x7E),
    "B": (0x7F, 0x49, 0x49, 0x49, 0x36),
    "C": (0x3E, 0x41, 0x41, 0x41, 0x22),
    "D": (0x7F, 0x41, 0x41, 0x22, 0x1C),
    "E": (0x7F, 0x49, 0x49, 0x49, 0x41),
    "F": (0x7F, 0x09, 0x09, 0x09, 0x01),
    "G": (0x3E, 0x41, 0x49, 0x49, 0x7A),
    "H": (0x7F, 0x08, 0x08, 0x08, 0x7F),
    "I": (0x00, 0x41, 0x7F, 0x41, 0x00),
    "J": (0x20, 0x40, 0x41, 0x3F, 0x01),
    "K": (0x7F, 0x08, 0x14, 0x22, 0x41),
    "L": (0x7F, 0x40, 0x40, 0x40, 0x40),
    "M": (0x7F, 0x02, 0x0C, 0x02, 0x7F),
    "N": (0x7F, 0x04, 0x08, 0x10, 0x7F),
    "O": (0x3E, 0x41, 0x41, 0x41, 0x3E),
    "P": (0x7F, 0x09, 0x09, 0x09, 0x06),
    "Q": (0x3E, 0x41, 0x51, 0x21, 0x5E),
    "R": (0x7F, 0x09, 0x19, 0x29, 0x46),
    "S": (0x46, 0x49, 0x49, 0x49, 0x31),
    "T": (0x01, 0x01, 0x7F, 0x01, 0x01),
    "U": (0x3F, 0x40, 0x40, 0x40, 0x3F),
    "V": (0x1F, 0x20, 0x40, 0x20, 0x1F),
    "W": (0x3F, 0x40, 0x38, 0x40, 0x3F),
    "X": (0x63, 0x14, 0x08, 0x14, 0x63),
    "Y": (0x07, 0x08, 0x70, 0x08, 0x07),
    "Z": (0x61, 0x51, 0x49, 0x45, 0x43),
    "[": (0x00, 0x7F, 0x41, 0x41, 0x00),
    "]": (0x00, 0x41, 0x41, 0x7F, 0x00),
    "_": (0x40, 0x40, 0x40, 0x40, 0x40),
}
GLYPH_W, GLYPH_H = 5, 7
CHAR_ADVANCE = GLYPH_W + 1


class Frame:
    def __init__(self, width=W, height=H):
        self.w = width
        self.h = height
        self.px = bytearray(width * height)

    # --- primitives ---

    def clear(self, level=OFF):
        for i in range(len(self.px)):
            self.px[i] = level

    def point(self, x, y, level=BRIGHT):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y * self.w + x] = level

    def hline(self, x, y, length, level=NORMAL):
        for i in range(max(0, x), min(self.w, x + length)):
            self.point(i, y, level)

    def vline(self, x, y, length, level=NORMAL):
        for j in range(max(0, y), min(self.h, y + length)):
            self.point(x, j, level)

    def rect(self, x, y, w, h, level=NORMAL):
        self.hline(x, y, w, level)
        self.hline(x, y + h - 1, w, level)
        self.vline(x, y, h, level)
        self.vline(x + w - 1, y, h, level)

    def fill(self, x, y, w, h, level=BRIGHT):
        for j in range(max(0, y), min(self.h, y + h)):
            for i in range(max(0, x), min(self.w, x + w)):
                self.px[j * self.w + i] = level

    # --- text ---

    def text(self, x, y, s, level=NORMAL, scale=1, spacing=1):
        """Draw `s` with its top-left at (x, y). Returns the end x."""
        cx = x
        for ch in s.upper():
            glyph = FONT.get(ch, FONT["?"])
            for col, bits in enumerate(glyph):
                for row in range(GLYPH_H):
                    if bits & (1 << row):
                        if scale == 1:
                            self.point(cx + col, y + row, level)
                        else:
                            self.fill(cx + col * scale, y + row * scale,
                                      scale, scale, level)
            cx += (GLYPH_W + spacing) * scale
        return cx

    def text_width(self, s, scale=1, spacing=1):
        return len(s) * (GLYPH_W + spacing) * scale

    def text_right(self, x_right, y, s, level=NORMAL, scale=1):
        return self.text(x_right - self.text_width(s, scale), y, s, level, scale)

    def text_center(self, x, w, y, s, level=NORMAL, scale=1):
        tw = self.text_width(s, scale)
        return self.text(x + max(0, (w - tw) // 2), y, s, level, scale)

    def text_inverted(self, x, y, s, pad=1, level=BRIGHT, ink=OFF):
        """Bright block with dark text: the strongest emphasis available."""
        tw = self.text_width(s)
        self.fill(x - pad, y - pad, tw + pad * 2 - 1, GLYPH_H + pad * 2, level)
        self.text(x, y, s, ink)
        return x + tw

    # --- widgets ---

    def meter(self, x, y, w, h, value, level=BRIGHT, back=DIM):
        """Horizontal bar, `value` in 0..1."""
        self.fill(x, y, w, h, back)
        lit = int(round(max(0.0, min(1.0, value)) * w))
        if lit:
            self.fill(x, y, lit, h, level)

    def progress_ticks(self, x, y, w, bars, filled, level=BRIGHT, back=DIM):
        """One tick per bar; how far a loop has played. Reads faster than a
        continuous bar when the count matters (3 of 4 bars)."""
        if bars <= 0:
            return
        gap = 1
        seg = max(1, (w - gap * (bars - 1)) // bars)
        for i in range(bars):
            bx = x + i * (seg + gap)
            self.fill(bx, y, seg, 2, level if i < filled else back)

    # --- output ---

    def to_png(self, path, scale=3):
        """Grayscale PNG, scaled up so a human can review the layout."""
        rows = b""
        for y in range(self.h):
            line = bytearray()
            for x in range(self.w):
                v = self.px[y * self.w + x]
                line += bytes([min(255, v * 255 // MAX)]) * scale
            for _ in range(scale):
                rows += b"\x00" + bytes(line)

        def chunk(tag, data):
            c = tag + data
            return (struct.pack(">I", len(data)) + c
                    + struct.pack(">I", zlib.crc32(c)))

        png = (b"\x89PNG\r\n\x1a\n"
               + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w * scale,
                                            self.h * scale, 8, 0, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(rows, 9))
               + chunk(b"IEND", b""))
        with open(path, "wb") as f:
            f.write(png)

    def to_ascii(self):
        ramp = " .:-=+*#%@"
        out = []
        for y in range(self.h):
            row = "".join(
                ramp[min(len(ramp) - 1, self.px[y * self.w + x] * len(ramp) // 32)]
                for x in range(self.w))
            out.append(row)
        return "\n".join(out)
