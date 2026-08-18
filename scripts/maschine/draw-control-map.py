#!/usr/bin/env python3
"""Draw the Maschine MK1 next to the MPC2000XL, with the mapping between them.

The map is READ FROM control_map.py, not retyped here. A picture of a mapping
that has drifted from the code is worse than no picture, and this project has
already lost hours to a binding ("restart") that existed in the map, did not
exist on the hardware, and looked correct everywhere it was written down.

    scripts/maschine/draw-control-map.py [-o out.png]
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import control_map                                              # noqa: E402

import importlib.util as _ilu                                   # noqa: E402
_spec = _ilu.spec_from_file_location("mk1in", os.path.join(HERE, "mpc-mk1-input.py"))
mk1in = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(mk1in)

# --- palette ---------------------------------------------------------------
BG        = (18, 19, 22)
PANEL     = (38, 40, 46)
PANEL_EDGE= (72, 76, 86)
PAD       = (54, 57, 66)
PAD_EDGE  = (96, 101, 114)
TEXT      = (232, 233, 238)
DIM       = (150, 154, 165)
MAPPED    = (94, 200, 160)      # has an MPC binding
SHIFTED   = (232, 176, 96)      # reachable only with SHIFT
DAWCOL    = (128, 162, 232)     # goes to Ardour, not the MPC
UNMAPPED  = (108, 60, 64)

W, H = 2100, 1740


def font(size, bold=False):
    for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSans%s.ttf"
                 % ("-Bold" if bold else ""),
                 "/usr/share/fonts/TTF/DejaVuSans%s.ttf"
                 % ("-Bold" if bold else "")):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


F_TITLE = font(40, True)
F_SUB   = font(19)
F_BTN   = font(15, True)
F_SMALL = font(13)
F_LEG   = font(16)
F_HEAD  = font(20, True)


def binding(name):
    """(plain, shifted) for a Maschine button, from the live control map."""
    for table in (control_map.TRANSPORT, control_map.PANEL):
        if name in table:
            return table[name]
    if name in control_map.PAD_SECTION:
        return (control_map.PAD_SECTION[name], None)
    if name in control_map.GROUPS:
        return (control_map.GROUPS[name], None)
    return (None, None)


def short(target):
    if not target:
        return ""
    if target == "modifier":
        return "SHIFT"
    kind, _, rest = target.partition(":")
    if kind == "mpc":
        return rest.replace("_", " ").upper()
    if kind == "mode":
        return "MODE " + rest
    if kind == "daw":
        return "DAW " + rest.split(":")[-1].replace("_", " ")
    return target


def colour_for(plain):
    if not plain or plain == "modifier":
        return UNMAPPED if not plain else PAD
    if plain.startswith("mpc:"):
        return MAPPED
    return DAWCOL


def rrect(d, box, radius, fill, outline, width=2):
    d.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def button(d, x, y, w, h, label, name=None, force=None):
    plain, shifted = binding(name) if name else (None, None)
    edge = force or colour_for(plain)
    rrect(d, (x, y, x + w, y + h), 6, PAD, edge, 2)
    d.text((x + w / 2, y + 9), label, font=F_BTN, fill=TEXT, anchor="ma")
    if name:
        if plain and plain != "modifier":
            d.text((x + w / 2, y + h / 2 + 1), short(plain), font=F_SMALL,
                   fill=MAPPED if plain.startswith("mpc:") else DAWCOL, anchor="ma")
        if shifted:
            d.text((x + w / 2, y + h - 18), "⇧ " + short(shifted), font=F_SMALL,
                   fill=SHIFTED, anchor="ma")


PANEL_IMG = os.path.join(HERE, "..", "..", "docs", "reference", "mk1-panel-raw.png")

# Where each control sits on the manual's own panel figure (1179x982), read off
# the figure rather than invented. Boxes are (x, y, w, h) in that image's pixels.
#
# This project drew this diagram once from the LED wire order and got a panel
# that does not exist. The wire order is the order cabl reports LEDs in; it has
# nothing to do with where the buttons are. So the geometry now comes from the
# 1.5 manual's controller overview, page 22.
PANEL_BOXES = {
    "control":        (161,  82,  58, 32),
    "step":           (238,  76,  58, 38),
    "browse":         (161, 154,  58, 40),
    "sampling":       (238, 154,  58, 40),
    "browse_left":    (161, 212,  58, 36),
    "browse_right":   (238, 212,  58, 36),
    "snap":           (161, 288,  58, 38),
    "auto_write":     (238, 288,  58, 40),
    "note_repeat":    (390, 392,  62, 56),
    "group_a":        (161, 538,  58, 42),
    "group_b":        (238, 538,  58, 42),
    "group_c":        (316, 538,  58, 42),
    "group_d":        (393, 538,  58, 42),
    "group_e":        (161, 598,  58, 42),
    "group_f":        (238, 598,  58, 42),
    "group_g":        (316, 598,  58, 42),
    "group_h":        (393, 598,  58, 42),
    "loop":           (161, 730,  58, 42),
    "transport_left": (238, 730,  58, 42),
    "transport_right":(316, 730,  58, 42),
    "grid":           (393, 730,  58, 42),
    "play":           (161, 788,  58, 42),
    "rec":            (238, 788,  58, 42),
    "erase":          (316, 788,  58, 42),
    "shift":          (393, 788,  58, 42),
    "scene":          (498, 398,  58, 44),
    "pattern":        (498, 454,  58, 44),
    "pad_mode":       (498, 510,  58, 44),
    "navigate":       (498, 566,  58, 44),
    "duplicate":      (498, 622,  58, 44),
    "select":         (498, 678,  58, 44),
    "solo":           (498, 734,  58, 44),
    "mute":           (498, 790,  58, 44),
}
# The eight display buttons across the top of the figure.
for _i in range(8):
    PANEL_BOXES["display%d" % (_i + 1)] = (330 + _i * 91, 90, 66, 26)

# Crop to the panel itself. The manual's figure carries a numbered callout
# column down each side and a second, half-cut panel below - all of it noise
# here, and the callout numbers actively fight our own labels.
CROP = (104, 8, 1092, 858)
CROP_DX, CROP_DY = CROP[0], CROP[1]

SCALE = 1.55
panel = Image.open(PANEL_IMG).convert("RGB").crop(CROP)
PW_, PH_ = int(panel.width * SCALE), int(panel.height * SCALE)
panel = panel.resize((PW_, PH_), Image.LANCZOS)

W = PW_ + 860
H = PH_ + 300

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

d.text((40, 26), "Maschine MK1  \u2192  MPC2000XL", font=F_TITLE, fill=TEXT)
d.text((40, 76),
       "Panel figure: MASCHINE 1.5 Reference Manual p.22 (1st-generation "
       "labels). Bindings read live from scripts/maschine/control_map.py.",
       font=F_SUB, fill=DIM)

PANEL_X, PANEL_Y = 40, 140
img.paste(panel, (PANEL_X, PANEL_Y))

def mark(name, box):
    bx, by, bw, bh = box
    x, y, w, h = [int(v * SCALE) for v in
                  (bx - CROP_DX, by - CROP_DY, bw, bh)]
    x += PANEL_X; y += PANEL_Y
    plain, shifted = binding(name)
    col = colour_for(plain)
    d.rounded_rectangle((x, y, x + w, y + h), radius=4, outline=col, width=3)
    label = short(plain)
    if label:
        tw = d.textlength(label, font=F_SMALL)
        ly = y + h + 2
        d.rectangle((x - 2, ly, x - 2 + tw + 8, ly + 17), fill=BG)
        d.text((x + 2, ly + 1), label, font=F_SMALL, fill=col)
    if shifted:
        sl = "\u21e7" + short(shifted)
        tw = d.textlength(sl, font=F_SMALL)
        ly = y + h + 20
        d.rectangle((x - 2, ly, x - 2 + tw + 8, ly + 17), fill=BG)
        d.text((x + 2, ly + 1), sl, font=F_SMALL, fill=SHIFTED)

for name, box in PANEL_BOXES.items():
    mark(name, box)

# ------------------------------------------------------------------- MPC ----
CX = PANEL_X + PW_ + 30
d.text((CX, PANEL_Y - 4), "WHAT THE MPC2000XL RECEIVES", font=F_HEAD, fill=TEXT)

GROUPS_OUT = [
    ("TRANSPORT", [("PLAY", "led3"), ("STOP", None), ("PLAY START", None),
                   ("REC", "led1"), ("OVER DUB", "led4"), ("GO TO", None),
                   ("STEP \u25c0 \u25b6", None), ("BAR \u25c0 \u25b6", None)]),
    ("PAD / PERFORM", [("AFTER (note repeat)", "led0"), ("FULL LEVEL", "led8"),
                       ("16 LEVELS", "led15"), ("TRACK MUTE", "led11"),
                       ("NEXT SEQ", "led12"),
                       ("BANK A/B/C/D", "led13/10/14/9")]),
    ("SCREEN / EDIT", [("SOFT KEY 1-6", None), ("MAIN SCREEN", None),
                       ("WINDOW", None), ("ENTER", None),
                       ("CURSOR \u25c0 \u25b6 \u25b2 \u25bc", None),
                       ("UNDO", None), ("ERASE", None)]),
    ("MODES", [("LOAD", None), ("SAVE / MISC", None), ("MIXER", None),
               ("PROGRAM", None), ("SAMPLE", None), ("TRIM", None),
               ("SONG", None), ("TAP TEMPO", None), ("MIDI SYNC", None)]),
]
y = PANEL_Y + 30
for title, items in GROUPS_OUT:
    d.text((CX, y), title, font=F_BTN, fill=DIM)
    y += 24
    for label, lamp in items:
        d.rounded_rectangle((CX, y, CX + 320, y + 30), radius=5, fill=PAD,
                            outline=SHIFTED if lamp else PAD_EDGE, width=2)
        d.text((CX + 10, y + 7), label, font=F_SMALL, fill=TEXT)
        if lamp:
            d.text((CX + 312, y + 7), lamp, font=F_SMALL, fill=SHIFTED,
                   anchor="ra")
        y += 34
    y += 12

d.text((CX + 350, PANEL_Y + 30), "PADS", font=F_BTN, fill=DIM)
for row in range(4):
    for col in range(4):
        pad = (3 - row) * 4 + col
        bx = CX + 350 + col * 88
        by = PANEL_Y + 54 + row * 76
        d.rounded_rectangle((bx, by, bx + 80, by + 68), radius=6, fill=PAD,
                            outline=MAPPED, width=2)
        d.text((bx + 40, by + 10), "PAD %d" % (pad + 1), font=F_BTN,
               fill=TEXT, anchor="ma")
        d.text((bx + 40, by + 34), "note %d" % (36 + pad), font=F_SMALL,
               fill=MAPPED, anchor="ma")
        sh = control_map.SHIFT_PADS.get(pad + 1)
        if sh:
            d.text((bx + 40, by + 50), short(sh)[:11], font=F_SMALL,
                   fill=SHIFTED if sh.startswith("mpc:") else DAWCOL, anchor="ma")

ky = PANEL_Y + 54 + 4 * 76 + 24
d.text((CX + 350, ky), "KNOBS", font=F_BTN, fill=DIM)
ky += 26
for label, meaning in (("K1-K8", "8 Ardour mixer strips"),
                       ("VOLUME", "DAW master"),
                       ("TEMPO", "note variation"),
                       ("SWING", "MPC DATA wheel")):
    d.rounded_rectangle((CX + 350, ky, CX + 700, ky + 30), radius=5, fill=PAD,
                        outline=DAWCOL, width=2)
    d.text((CX + 360, ky + 7), label, font=F_SMALL, fill=TEXT)
    d.text((CX + 692, ky + 7), meaning, font=F_SMALL, fill=DAWCOL, anchor="ra")
    ky += 34

# ---------------------------------------------------------------- legend ----
LY = PANEL_Y + PH_ + 24
for i, (col, name, meaning) in enumerate([
        (MAPPED,  "green",  "sends an MPC panel key or pad"),
        (SHIFTED, "amber",  "needs SHIFT held, or is an MPC lamp mirrored back to the controller"),
        (DAWCOL,  "blue",   "goes to Ardour through daw-ctl, not to the MPC"),
        (UNMAPPED,"red",    "no binding - the button does nothing")]):
    x = 40 + (i % 2) * 700
    yy = LY + (i // 2) * 30
    d.rectangle((x, yy, x + 30, yy + 18), fill=PAD, outline=col, width=3)
    d.text((x + 42, yy), name, font=F_LEG, fill=col)
    d.text((x + 120, yy), meaning, font=F_LEG, fill=DIM)

d.text((40, H - 40),
       "Pad 1 is bottom-left on both machines; the MK1 reports its pads from "
       "the TOP row down and the hub flips the row at the hardware boundary. "
       "SHIFT+PLAY is STOP - the MK1 has no stop button.",
       font=F_SMALL, fill=DIM)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out",
                    default=os.path.join(HERE, "..", "..", "docs", "reference",
                                         "maschine-mpc2000xl-mapping.png"))
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    img.save(out)
    print("wrote %s (%dx%d)" % (out, W, H))
