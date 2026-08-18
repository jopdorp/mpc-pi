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
MPC_IMG   = os.path.join(HERE, "..", "..", "docs", "reference",
                         "mpc2000xl-panel-page.png")

# Both panels come from the manufacturers' own manuals. An earlier version of
# this drew the Maschine from mk1_leds.LED_ORDER - the order cabl reports LEDs
# in, which says nothing about where a button is - and produced a device that
# does not exist.
#
# Maschine: MASCHINE 1.5 Reference Manual p.22, figure is 1179x982.
# MPC2000XL: Operator's Manual p.4 "Panel Descriptions / Front Panel",
#            page rendered at 260 dpi to 2149x3041.
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
for _i in range(8):
    PANEL_BOXES["display%d" % (_i + 1)] = (330 + _i * 91, 90, 66, 26)

# MPC controls, in the rendered page's pixels, before cropping.
MPC_BOXES = {
    "F1-F6":        (566, 880, 360,  40),
    "MAIN SCREEN":  (752, 985,  70,  35),
    "WINDOW":       (896, 980,  70,  38),
    "SHIFT":        (424,1148,  62,  38),
    "ENTER":        (600,1148,  70,  38),
    "AFTER":        (428,1272,  62,  36),
    "TAP TEMPO":    (602,1262,  74,  52),
    "UNDO":         (566,1370,  66,  32),
    "ERASE":        (652,1370,  66,  32),
    "CURSOR":       (786,1278, 140,  96),
    "DATA":         (770, 1060, 200, 200),
    "STEP":         (556,1446, 148,  38),
    "GO TO":        (722,1446,  76,  38),
    "BAR":          (818,1446, 152,  38),
    "REC":          (556,1530,  70,  50),
    "OVER DUB":     (644,1530,  70,  50),
    "STOP":         (734,1530,  70,  50),
    "PLAY":         (820,1530,  70,  50),
    "PLAY START":   (908,1530,  70,  50),
    "FULL LEVEL":   (1186, 800, 100,  70),
    "16 LEVELS":    (1282, 800, 100,  70),
    "NEXT SEQ":     (1186, 892, 100,  56),
    "TRACK MUTE":   (1282, 892, 100,  56),
    "PAD BANK A-D": (1394, 892, 348,  56),
    "PADS 1-16":    (1150, 990, 620, 590),
}
# Which Maschine control drives each MPC control. Derived from control_map so
# the two halves of the picture cannot disagree.
MPC_SOURCE = {}
for _btn, _pair in list(control_map.TRANSPORT.items()) + list(control_map.PANEL.items()):
    for _shift, _t in ((False, _pair[0]), (True, _pair[1])):
        if _t and _t.startswith("mpc:"):
            _k = _t.split(":", 1)[1].replace("_", " ").upper()
            _label = ("SHIFT+" if _shift else "") + _btn.replace("_", " ").upper()
            MPC_SOURCE.setdefault(_k, []).append(_label)
for _btn, _t in control_map.PAD_SECTION.items():
    if _t.startswith("mpc:"):
        _k = _t.split(":", 1)[1].replace("_", " ").upper()
        MPC_SOURCE.setdefault(_k, []).append(_btn.replace("_", " ").upper())
for _btn, _t in control_map.GROUPS.items():
    if _t.startswith("mpc:"):
        _k = _t.split(":", 1)[1].replace("_", " ").upper()
        MPC_SOURCE.setdefault(_k, []).append(_btn.replace("_", " ").upper())

MPC_ALIAS = {
    "F1-F6": "SOFT1", "MAIN SCREEN": "MAIN SCREEN", "WINDOW": "WINDOW",
    "SHIFT": "SHIFT", "ENTER": "ENTER", "AFTER": "AFTER",
    "TAP TEMPO": "TAP TEMPO", "UNDO": "UNDO", "ERASE": "ERASE",
    "STEP": "STEP LEFT", "GO TO": "GO TO", "BAR": "BAR LEFT",
    "REC": "RECORD", "OVER DUB": "OVER DUB", "STOP": "STOP",
    "PLAY": "PLAY", "PLAY START": "PLAY START",
    "FULL LEVEL": "FULL LEVEL", "16 LEVELS": "SIXTEEN LEVELS",
    "NEXT SEQ": "NEXT SEQ", "TRACK MUTE": "TRACK MUTE",
    "PAD BANK A-D": "BANK A", "CURSOR": "LEFT", "DATA": None,
    "PADS 1-16": None,
}
MPC_LAMPS = {
    "AFTER": "led0", "REC": "led1", "PLAY": "led3", "OVER DUB": "led4",
    "FULL LEVEL": "led8", "16 LEVELS": "led15", "TRACK MUTE": "led11",
    "NEXT SEQ": "led12", "PAD BANK A-D": "led13/10/14/9",
}

CROP = (104, 8, 1092, 858)
CROP_DX, CROP_DY = CROP[0], CROP[1]
MK_SCALE = 1.5
mk = Image.open(PANEL_IMG).convert("RGB").crop(CROP)
MKW, MKH = int(mk.width * MK_SCALE), int(mk.height * MK_SCALE)
mk = mk.resize((MKW, MKH), Image.LANCZOS)

MCROP = (337, 590, 1815, 1660)
MC_DX, MC_DY = MCROP[0], MCROP[1]
MPC_SCALE = 1.0
mp = Image.open(MPC_IMG).convert("RGB").crop(MCROP)
MPW, MPH = int(mp.width * MPC_SCALE), int(mp.height * MPC_SCALE)
mp = mp.resize((MPW, MPH), Image.LANCZOS)

W = 80 + MKW + 60 + MPW + 40
H = 190 + max(MKH, MPH) + 210

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

d.text((40, 26), "Maschine MK1  \u2192  MPC2000XL", font=F_TITLE, fill=TEXT)
d.text((40, 76),
       "Both panels are the manufacturers' own figures - MASCHINE 1.5 Reference "
       "Manual p.22 (1st-generation labels) and the MPC2000XL Operator's Manual "
       "p.4. Bindings are read live from scripts/maschine/control_map.py.",
       font=F_SUB, fill=DIM)

MKX, MKY = 40, 150
img.paste(mk, (MKX, MKY))
d.text((MKX, MKY - 26), "MASCHINE MK1 - what you press", font=F_HEAD, fill=TEXT)

MPX, MPY = MKX + MKW + 60, 150
img.paste(mp, (MPX, MPY))
d.text((MPX, MPY - 26), "AKAI MPC2000XL - what the emulator receives",
       font=F_HEAD, fill=TEXT)


def tag(x, y, text, colour, above=False):
    tw = d.textlength(text, font=F_SMALL)
    ty = y - 18 if above else y
    d.rectangle((x - 3, ty, x + tw + 5, ty + 17), fill=BG)
    d.text((x + 1, ty + 1), text, font=F_SMALL, fill=colour)


for name, box in PANEL_BOXES.items():
    bx, by, bw, bh = box
    x = MKX + int((bx - CROP_DX) * MK_SCALE)
    y = MKY + int((by - CROP_DY) * MK_SCALE)
    w, h = int(bw * MK_SCALE), int(bh * MK_SCALE)
    plain, shifted = binding(name)
    col = colour_for(plain)
    d.rounded_rectangle((x, y, x + w, y + h), radius=4, outline=col, width=3)
    if short(plain):
        tag(x, y + h + 2, short(plain), col)
    if shifted:
        tag(x, y + h + 20, "\u21e7" + short(shifted), SHIFTED)

for name, box in MPC_BOXES.items():
    bx, by, bw, bh = box
    x = MPX + int((bx - MC_DX) * MPC_SCALE)
    y = MPY + int((by - MC_DY) * MPC_SCALE)
    w, h = int(bw * MPC_SCALE), int(bh * MPC_SCALE)
    key = MPC_ALIAS.get(name)
    srcs = MPC_SOURCE.get(key, []) if key else []
    lamp = MPC_LAMPS.get(name)
    col = MAPPED if srcs else (SHIFTED if name == "PADS 1-16" else UNMAPPED)
    if name in ("DATA",):
        col = DAWCOL
    d.rounded_rectangle((x, y, x + w, y + h), radius=4, outline=col, width=3)
    label = name
    tag(x, y - 18, label, TEXT)
    if name == "PADS 1-16":
        tag(x, y + h + 2, "16 pads, notes 36-51", MAPPED)
    elif name == "DATA":
        tag(x, y + h + 2, "SWING knob", DAWCOL)
    elif srcs:
        tag(x, y + h + 2, " / ".join(sorted(set(srcs))[:2]), MAPPED)
    else:
        tag(x, y + h + 2, "not mapped", UNMAPPED)
    if lamp:
        tag(x, y + h + 20, "lamp " + lamp, SHIFTED)

LY = 150 + max(MKH, MPH) + 30
for i, (col, name, meaning) in enumerate([
        (MAPPED,  "green",  "a Maschine button reaches this MPC control"),
        (SHIFTED, "amber",  "needs SHIFT, or is an MPC lamp mirrored to the controller"),
        (DAWCOL,  "blue",   "goes to Ardour, or is a knob rather than a key"),
        (UNMAPPED,"red",    "nothing on the Maschine reaches it")]):
    x = 40 + (i % 2) * 760
    yy = LY + (i // 2) * 30
    d.rectangle((x, yy, x + 30, yy + 18), fill=PAD, outline=col, width=3)
    d.text((x + 42, yy), name, font=F_LEG, fill=col)
    d.text((x + 120, yy), meaning, font=F_LEG, fill=DIM)

d.text((40, H - 46),
       "Pad 1 is bottom-left on both machines; the MK1 reports its pads from the "
       "TOP row down and the hub flips the row at the hardware boundary. "
       "SHIFT+PLAY is STOP, because the MK1 has no stop button.",
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
