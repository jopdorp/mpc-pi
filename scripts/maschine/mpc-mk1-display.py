#!/usr/bin/env python3
"""Push the emulated MPC2000XL LCD to a Maschine MK1 display over USB.

Frame source: the shared file written by MAME when MAME_MPC_LCD_EXPORT is
set (patch 0039): a 16-byte header (magic 'MPCL', u32 sequence, u16 width,
u16 height, u32 reserved) followed by width*height bytes, one per pixel,
nonzero = lit. The emulator rewrites it only when the frame content changes.

Modes:
  --usb            send to the first Maschine MK1 (default when available)
  --preview out.png  render the current frame to a PNG instead (no hardware)
  --ascii          dump the frame as text once and exit (no dependencies)

The USB protocol follows docs/maschine-mk1-display-protocol.md, ported from
shaduzlabs/cabl (BSD-style; see that repo for the original).
"""

import argparse
import mmap
import os
import struct
import sys
import time

MK1_VENDOR = 0x17CC
MK1_PRODUCT = 0x0808  # Maschine MK1 controller; verify with lsusb on hardware
EP_DISPLAY = 0x08

DISPLAY_W = 255
DISPLAY_H = 64
TRIPLES_PER_ROW = 85          # 255 px / 3
ROW_BYTES = TRIPLES_PER_ROW * 2  # 3 px pack into 2 bytes (5 bpp)
# 64 rows x 170 bytes = 10880, which is exactly 21 * 502 + 338. The
# earlier value of 5358 (10 chunks) could only carry 31 of the 64 rows,
# so the bottom half of every frame was silently dropped - the packing
# loop simply broke out when it ran past the end of the buffer.
FRAME_BYTES = 21 * 502 + 338  # 10880 = DISPLAY_H * ROW_BYTES

# Display polarity is genuinely unresolved between reverse-engineering
# sources: cabl's setPixel stores the COMPLEMENT of the 5-bit level (so
# 0x1F on the wire would be darkest and the MK1 renders dark-on-light,
# matching reviews that call the MK1 "inverse video" against the MK2),
# while Macchina maps lit pixels straight to 0x1F. If cabl is right, our
# whole brightness hierarchy renders upside down. One frame on hardware
# settles it; until then this is a single flag rather than a rewrite.
# Polarity: SETTLED ON HARDWARE 2026-08-17, and the default is now 1.
#
# A split frame with level 0x00 on the left half and 0x1F on the right was
# viewed head-on: the RIGHT half - level 0x1F - is the DARKER one. So a
# high wire value is DARK and 0x00 is light. The panel is inverse video,
# which matches reviews describing the MK1 that way next to the MK2, and
# matches cabl's setPixel storing the complement.
#
# This code takes `lit` as brightness INTENT (0 = background, 31 = full
# brightness), so intent must be complemented before it goes on the wire
# for bright things to look bright. Hence INVERT defaults to on.
#
# Read the panel HEAD-ON when checking this. These LCDs shift so much
# with viewing angle that the first observation of this very test read the
# opposite way round, and the wrong conclusion was briefly committed.
INVERT = os.environ.get("MPC_MK1_INVERT", "1") not in ("0", "", "no")

HEADER_FMT = "<4sIHHI"
HEADER_SIZE = struct.calcsize(HEADER_FMT)


def read_frame(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < HEADER_SIZE:
        return None
    magic, seq, width, height, _ = struct.unpack_from(HEADER_FMT, data, 0)
    if magic != b"MPCL":
        return None
    pixels = data[HEADER_SIZE:HEADER_SIZE + width * height]
    if len(pixels) < width * height:
        return None
    return seq, width, height, pixels


def pack_display(width, height, pixels, level=None):
    """Pack a frame into the MK1's 5-bpp 3-pixels-per-2-bytes layout,
    placed at the top-left of the 255x64 panel.

    The panel has 32 brightness levels and the DAW pages use them as a
    hierarchy (dim labels, bright values), so a source byte is taken as a
    level 0..31 rather than a flag. Pass an explicit `level` to force
    every lit pixel to one brightness, which is what the MPC's own 1-bit
    LCD wants."""
    out = bytearray(FRAME_BYTES)
    for y in range(DISPLAY_H):
        row_base = y * ROW_BYTES
        if row_base + ROW_BYTES > FRAME_BYTES:
            break
        for x in range(DISPLAY_W):
            lit = 0
            if x < width and y < height and pixels[y * width + x]:
                lit = level if level is not None else min(
                    0x1F, pixels[y * width + x])
            if INVERT:
                lit = 0x1F - lit
            triple = x // 3
            block = x % 3
            byte_index = row_base + triple * 2
            if byte_index + 1 >= FRAME_BYTES:
                break
            # 15 bits little-window packing per cabl GDisplayMaschineMK1:
            # px0 -> byte0 bits 7..3, px1 -> byte0 bits 2..0 + byte1 bits
            # 7..6, px2 -> byte1 bits 5..1.
            if block == 0:
                out[byte_index] = (out[byte_index] & 0x07) | (lit << 3)
            elif block == 1:
                out[byte_index] = (out[byte_index] & 0xF8) | (lit >> 2)
                out[byte_index + 1] = (out[byte_index + 1] & 0x3F) | ((lit & 0x03) << 6)
            else:
                out[byte_index + 1] = (out[byte_index + 1] & 0xC1) | (lit << 1)
    return bytes(out)


class Mk1Usb:
    def __init__(self, display_index=0):
        import usb.core
        import usb.util
        self.usb = __import__("usb.core", fromlist=["core"])
        self.dev = usb.core.find(idVendor=MK1_VENDOR)
        if self.dev is None:
            raise RuntimeError("no Maschine MK1 found (vendor 0x17cc)")
        if self.dev.is_kernel_driver_active(0):
            self.dev.detach_kernel_driver(0)
        try:
            self.dev.set_configuration()
        except Exception:
            pass                      # already configured
        # MANDATORY: in the default altsetting 0 the display endpoint 0x08
        # is not present at all and every write fails EIO.
        usb.util.claim_interface(self.dev, 0)
        self.dev.set_interface_altsetting(interface=0, alternate_setting=1)
        self.d = display_index << 1

    def _w(self, header, payload=b""):
        self.dev.write(EP_DISPLAY, bytes(header) + payload, timeout=1000)

    def init_display(self):
        """The COMPLETE sequence - all 22 commands, verified on hardware.

        This used to stop at {d,00,01,31}, which is where the protocol doc
        stopped. The omitted tail contains {d,00,01,0xAF} - DISPLAY ON.
        Without it every frame was correctly formatted, accepted by the
        device, and pushed into a panel that had never been switched on:
        writes succeeded, a full contrast sweep changed nothing, and the
        screens showed only their backlight.
        """
        d = self.d
        W = lambda *b: self._w((d,) + b)
        W(0x00, 0x01, 0x30)
        W(0x00, 0x04, 0xCA, 0x04, 0x0F, 0x00)
        time.sleep(0.02)
        W(0x00, 0x02, 0xBB, 0x00)
        W(0x00, 0x01, 0xD1)
        W(0x00, 0x01, 0x94)
        W(0x00, 0x03, 0x81, 0x1E, 0x02)
        time.sleep(0.02)
        W(0x00, 0x02, 0x20, 0x08)
        time.sleep(0.02)
        W(0x00, 0x02, 0x20, 0x0B)
        time.sleep(0.02)
        W(0x00, 0x01, 0xA6)
        W(0x00, 0x01, 0x31)
        W(0x00, 0x04, 0x32, 0x00, 0x00, 0x05)
        W(0x00, 0x01, 0x34)
        W(0x00, 0x01, 0x30)
        W(0x00, 0x04, 0xBC, 0x00, 0x01, 0x02)
        W(0x00, 0x03, 0x75, 0x00, 0x3F)
        W(0x00, 0x03, 0x15, 0x00, 0x54)
        W(0x00, 0x01, 0x5C)
        W(0x00, 0x01, 0x25)
        time.sleep(0.02)
        W(0x00, 0x01, 0xAF)              # DISPLAY ON
        time.sleep(0.02)
        W(0x00, 0x04, 0xBC, 0x02, 0x01, 0x01)
        W(0x00, 0x01, 0xA6)
        W(0x00, 0x03, 0x81, 0x25, 0x02)

    def send_frame(self, frame):
        d = self.d
        assert len(frame) == FRAME_BYTES
        self._w([d, 0x00, 0x03, 0x75, 0x00, 0x3F])
        self._w([d, 0x00, 0x03, 0x15, 0x00, 0x54])
        self._w([d, 0x01, 0xF7, 0x5C], frame[0:502])
        offset = 502
        # 20 middle chunks: first + 20 middle + final 338 = 10880.
        while offset + 502 <= FRAME_BYTES - 338:
            self._w([d + 1, 0x01, 0xF6], frame[offset:offset + 502])
            offset += 502
        self._w([d + 1, 0x01, 0x52], frame[offset:FRAME_BYTES])


def preview_png(width, height, pixels, path):
    # minimal PNG writer (grayscale, no deps)
    import zlib
    rows = b""
    for y in range(height):
        rows += b"\x00" + bytes(
            255 if pixels[y * width + x] else 0 for x in range(width))
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(rows))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frame_file", help="path written by MAME_MPC_LCD_EXPORT")
    ap.add_argument("--display", type=int, default=0, choices=[0, 1])
    ap.add_argument("--preview", metavar="PNG", help="write one frame to PNG and exit")
    ap.add_argument("--ascii", action="store_true", help="dump one frame as text and exit")
    ap.add_argument("--poll-hz", type=float, default=60.0)
    args = ap.parse_args()

    frame = read_frame(args.frame_file)
    if frame is None:
        sys.exit(f"no valid frame in {args.frame_file}")
    seq, width, height, pixels = frame

    if args.ascii:
        step = 4
        for y in range(0, height, step):
            print("".join("#" if pixels[y * width + x] else "." for x in range(0, width, 2)))
        return
    if args.preview:
        preview_png(width, height, pixels, args.preview)
        print(f"frame {seq} ({width}x{height}) -> {args.preview}")
        return

    mk1 = Mk1Usb(args.display)
    mk1.init_display()
    last_seq = None
    interval = 1.0 / args.poll_hz
    while True:
        frame = read_frame(args.frame_file)
        if frame is not None:
            seq, width, height, pixels = frame
            if seq != last_seq:
                mk1.send_frame(pack_display(width, height, pixels))
                last_seq = seq
        time.sleep(interval)


if __name__ == "__main__":
    main()
