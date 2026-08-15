#!/usr/bin/env python3
"""DAW pages for the Maschine MK1's right-hand display (255x64).

Design rules this file follows, in priority order — they exist because
the performer looks at this screen for a fraction of a second between
playing notes:

1. **State before detail.** What a lane is doing (recording, playing,
   empty) must be readable without focusing. States are encoded as
   brightness and shape, not just words: recording is a filled block,
   playing is an outline, empty is dim.
2. **The countdown is the news.** In live looping the urgent question is
   "how long until this closes". Bars remaining gets the largest glyphs
   on the page.
3. **Hardware alignment.** The eight body columns line up with the eight
   encoders, and the footer labels line up with the eight buttons, so
   the mapping never has to be remembered.
4. **The tab strip never moves.** Page identity sits in the same pixels
   on every page, so glancing costs nothing.

Snapshot the pages for review:  daw_ui.py --snapshot <outdir>
"""
import sys

try:
    from ui import Frame, OFF, DIM, MUTED, NORMAL, BRIGHT, GLYPH_H
    import control_map
except ImportError:  # running from the repo root
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    from ui import Frame, OFF, DIM, MUTED, NORMAL, BRIGHT, GLYPH_H
    import control_map

PAGES = ("LOOP", "MIX", "FX", "SONG")

# Knobs 1-4 and Buttons 1-4 belong to the LEFT display, 5-8 to the RIGHT
# (NI's manual and the kernel driver's own comments: "4 under the left
# screen" / "4 under the right screen"). Screen R therefore owns four
# encoders and four buttons, not eight.
#
# That is a gift, not a limit: four columns are 63px instead of 31, so a
# cell fits ten characters rather than five - close to Push 1's budget,
# whose five-character truncation was its most-cited flaw. It also lands
# exactly on the four loop lanes (GTR1, GTR2, MIC, AUX).
COLS = 4
COL_W = 62
COL_X = [i * 64 for i in range(COLS)]

# More than four items page in banks of four, Elektron-style: press the
# page button again to toggle. Dots in the button cell show which bank.
BANK_SIZE = COLS

# The MK1's eight buttons sit ABOVE the displays and its encoders BELOW
# them, so the legend for the buttons hugs the top edge and the
# encoder-owned values hug the bottom edge. Label adjacency is the one
# rule every surveyed controller obeys (Push, Maschine, Elektron); an
# earlier version of this file had the button legend along the bottom,
# pointing at the encoders.
BTNBAR_H = 10          # button legend, top edge, adjacent to the buttons
ENCBAR_Y = 50          # encoder strip, bottom edge, adjacent to the knobs
HEADER_Y = BTNBAR_H + 1
BODY_Y = 20


# --- shared chrome ---------------------------------------------------


def draw_button_bar(f, st):
    """The eight button labels, along the top edge under the buttons.

    The first four are the pages, so the tab strip and the legend are the
    same eight cells rather than two competing rows - the page buttons
    are simply four of the eight buttons.
    """
    labels = list(st.get("buttons")
                  or control_map.BUTTONS_RIGHT_BY_PAGE.get(st["page"],
                                                           ("", "", "", "")))
    for i, label in enumerate(labels[:COLS]):
        x = COL_X[i]
        if not label:
            continue
        active = label in st.get("buttons_active", ())
        if active:
            f.fill(x, 0, COL_W, GLYPH_H + 3, BRIGHT)
            f.text_center(x, COL_W, 1, label, OFF)
        else:
            f.text_center(x, COL_W, 1, label, NORMAL)
    f.hline(0, BTNBAR_H, 255, DIM)


def draw_status(f, st):
    """One status line under the buttons: mode, transient message, health.

    A persistent mode name in a fixed position is deliberate. Neither
    Push nor Maschine ships one - they rely on a lit button - but a lit
    button is exactly the indicator that fails when attention is on the
    music rather than the panel.
    """
    y = HEADER_Y + 1
    # Page identity is permanent and lives in a fixed corner. Neither
    # Push nor Maschine ships this - they rely on a lit button - but a
    # lit button is the indicator that fails when attention is on the
    # music rather than the panel.
    f.text_inverted(3, y, st["page"])
    mode = st.get("mode", "")
    if mode:
        f.text(6 + f.text_width(st["page"]), y, mode, MUTED)

    x_right = 254
    xruns = st.get("xruns", 0)
    label = "XR%d" % xruns
    f.text_right(x_right, y, label, BRIGHT if xruns else DIM)
    x_right -= f.text_width(label) + 6

    recording = st.get("recording", 0)
    if recording:
        badge = "REC%d" % recording
        f.text_inverted(x_right - f.text_width(badge) + 1, y, badge)
        x_right -= f.text_width(badge) + 6

    tx = x_right - 8
    if st.get("playing"):
        for i in range(6):
            f.vline(tx + i, y + i // 2, GLYPH_H - (i // 2) * 2, BRIGHT)
    else:
        f.fill(tx, y, 2, GLYPH_H, MUTED)
        f.fill(tx + 4, y, 2, GLYPH_H, MUTED)

    # Bank dots: more than four items page in fours, Elektron-style, and
    # the page indicator ships from day one rather than being retrofitted
    # after users cannot tell there is a second page.
    banks = st.get("banks", 1)
    if banks > 1:
        cur = st.get("bank", 0)
        dx = 6 + f.text_width(st["page"]) + f.text_width(st.get("mode", ""))
        for b in range(banks):
            if b == cur:
                f.fill(dx, y + 2, 4, 4, BRIGHT)
            else:
                f.rect(dx, y + 2, 4, 4, DIM)
            dx += 6


    # The expanded-label line: the full, untruncated name and value of
    # whichever encoder is being turned. Truncated 5-character cells are
    # what broke Push 1's heads-up premise; this is the documented fix.
    msg = st.get("message")
    if msg:
        zone_x = f.text_width(st["page"]) + f.text_width(mode) + 14
        width = max(0, tx - zone_x - 6)
        if width > 0:
            f.text_center(zone_x, width, y, msg[:width // 6], MUTED)


def draw_encoder_bar(f, st, values):
    """Bottom strip: what the eight encoders control, next to the knobs."""
    f.hline(0, ENCBAR_Y - 2, 255, DIM)
    for i, v in enumerate(values[:COLS]):
        if v is None:
            continue
        x = COL_X[i]
        f.meter(x + 2, ENCBAR_Y, COL_W - 4, 3, v.get("norm", 0.0),
                v.get("level", NORMAL))
        text = v.get("text")
        if text:
            f.text_center(x, COL_W, ENCBAR_Y + 5, text[:5], NORMAL)


def draw_header(f, st):
    draw_button_bar(f, st)
    draw_status(f, st)


def column_divider(f, i, top=BODY_Y):
    """Separator between encoder columns. `top` lets a page keep its own
    full-width info row clear - a divider drawn through a header badge
    breaks the badge in half."""
    if i:
        f.vline(COL_X[i] - 1, top, ENCBAR_Y - top - 4, DIM)


# --- LOOP ------------------------------------------------------------


def page_loop(f, st):
    draw_header(f, st)
    encoders = []
    for i, lane in enumerate(st["lanes"][:COLS]):
        x = COL_X[i]
        column_divider(f, i)
        state = lane.get("state", "empty")
        name = lane.get("name", "-")[:6]

        if state == "empty":
            f.text_center(x, COL_W, BODY_Y + 1, name, DIM)
            f.text_center(x, COL_W, BODY_Y + 14, "EMPTY", DIM)
            encoders.append(None)
            continue

        # 62px fits the name and the state word on one row, so the state
        # is written as well as shown - fill carries it at a glance, the
        # word removes any doubt on a second look.
        word = {"rec": "REC", "dub": "DUB", "armed": "ARM",
                "play": "PLAY"}.get(state, "")
        if state == "rec":
            f.fill(x, BODY_Y, COL_W, GLYPH_H + 3, BRIGHT)
            f.text(x + 3, BODY_Y + 1, name, OFF)
            f.text_right(x + COL_W - 3, BODY_Y + 1, word, OFF)
        elif state == "dub":
            f.fill(x, BODY_Y, COL_W, GLYPH_H + 3, MUTED)
            f.text(x + 3, BODY_Y + 1, name, OFF)
            f.text_right(x + COL_W - 3, BODY_Y + 1, word, OFF)
        elif state == "armed":
            f.rect(x, BODY_Y, COL_W, GLYPH_H + 3, NORMAL)
            f.text(x + 3, BODY_Y + 1, name, NORMAL)
            f.text_right(x + COL_W - 3, BODY_Y + 1, word, NORMAL)
        else:
            f.text(x + 3, BODY_Y + 1, name, NORMAL)
            f.text_right(x + COL_W - 3, BODY_Y + 1, word, MUTED)

        # The sweep is the primary channel and is never blanked while
        # recording; the ticks below answer the separate "where in the
        # bar" question that BOSS gives a whole second ring.
        bars = lane.get("bars", 0)
        bar = lane.get("bar", 0)
        phase = lane.get("phase", 0.0)
        progress = (bar + phase) / bars if bars else 0.0
        f.meter(x + 2, BODY_Y + 12, COL_W - 4, 5, progress,
                BRIGHT if state in ("rec", "dub") else NORMAL)
        f.progress_ticks(x + 2, BODY_Y + 18, COL_W - 4, bars, bar)

        remain = lane.get("bars_remaining")
        if remain is not None:
            # 62px is ten characters; "4 OF 4 BARS" is eleven and bled
            # into the next column.
            f.text_center(x, COL_W, BODY_Y + 21,
                          "BAR %d/%d" % (bar + 1, bars), MUTED)
        else:
            f.text_center(x, COL_W, BODY_Y + 21, "WAITING", MUTED)

        encoders.append({"norm": lane.get("level", 0.0),
                         "level": BRIGHT if state in ("rec", "dub") else MUTED,
                         "text": name})

    draw_encoder_bar(f, st, encoders)


# --- MIX -------------------------------------------------------------


def page_mix(f, st):
    """Eight channels plus master. Master is ALWAYS visible in the last
    column - a mixer whose master can scroll out of view fails at the one
    moment it matters - so channels bank through columns 1-3 in threes.

    At 27px of body height a vertical fader is a stub, so gain and meter
    are horizontal, stacked: gain bar with a unity tick, then the meter
    with a peak-hold line and a clip block at the right end that latches
    bright. Sends A/B are the two thin bars underneath.
    """
    draw_header(f, st)
    bank = st.get("bank", 0)
    strips = st["mixer"][bank * 3:bank * 3 + 3]
    master = st.get("master", {"name": "MSTR"})
    encoders = []

    def strip(x, ch, is_master=False):
        name = ch.get("name", "-")[:6]
        db = ch.get("db", "")
        if ch.get("solo") or is_master:
            f.fill(x, BODY_Y, COL_W, GLYPH_H + 3, BRIGHT)
            f.text(x + 3, BODY_Y + 1, name, OFF)
            f.text_right(x + COL_W - 3, BODY_Y + 1, db, OFF)
        else:
            ink = DIM if ch.get("mute") else NORMAL
            f.text(x + 3, BODY_Y + 1, name, ink)
            f.text_right(x + COL_W - 3, BODY_Y + 1, db, MUTED)

        # gain: track + knob + unity tick
        gy = BODY_Y + 12
        f.hline(x + 2, gy + 1, COL_W - 4, DIM)
        ux = x + 2 + int((COL_W - 4) * 0.75)
        f.vline(ux, gy - 1, 5, DIM)
        kx = x + 2 + int(ch.get("gain", 0.8) * (COL_W - 7))
        f.fill(kx, gy - 1, 3, 5, BRIGHT)

        # meter: fill + peak line + clip latch
        my = BODY_Y + 18
        if is_master:
            for j, side in enumerate(("l", "r")):
                yy = my + j * 4
                f.fill(x + 2, yy, COL_W - 8, 3, DIM)
                lv = ch.get("level_%s" % side, ch.get("level", 0.0))
                f.fill(x + 2, yy, int(lv * (COL_W - 8)), 3, BRIGHT)
                pk = ch.get("peak_%s" % side, 0.0)
                if pk:
                    f.vline(x + 2 + int(pk * (COL_W - 9)), yy, 3, BRIGHT)
        else:
            f.fill(x + 2, my, COL_W - 8, 4, DIM)
            f.fill(x + 2, my, int(ch.get("level", 0.0) * (COL_W - 8)), 4,
                   BRIGHT)
            pk = ch.get("peak", 0.0)
            if pk:
                f.vline(x + 2 + int(pk * (COL_W - 9)), my, 4, BRIGHT)
        if ch.get("clip"):
            f.fill(x + COL_W - 5, my, 3, 4 if not is_master else 7, BRIGHT)

        # sends A/B, master shows none
        if not is_master:
            sy = my + 6
            half = (COL_W - 8) // 2
            for j, key in enumerate(("send_a", "send_b")):
                sx = x + 2 + j * (half + 4)
                f.fill(sx, sy, half, 2, DIM)
                f.fill(sx, sy, int(ch.get(key, 0.0) * half), 2, MUTED)

        encoders.append({"norm": ch.get("gain", 0.0), "level": NORMAL,
                         "text": db or name})

    for i, ch in enumerate(strips):
        column_divider(f, i)
        strip(COL_X[i], ch)
    column_divider(f, 3)
    strip(COL_X[3], master, is_master=True)
    draw_encoder_bar(f, st, encoders)


# --- FX --------------------------------------------------------------


def _fx_eq_view(f, fx):
    """Parametric EQ drawn as its response curve - the shape IS the UI.

    x is log frequency 20 Hz..20 kHz, the centre line is 0 dB. Band
    markers sit on the curve; the focused band (the one the encoders are
    editing) is the bright one.
    """
    import math
    top, bot = BODY_Y + 11, ENCBAR_Y - 4
    mid = (top + bot) // 2
    f.hline(2, mid, 251, DIM)
    bands = fx.get("bands", [])
    scale = (bot - top) / 2 / 18.0        # +-18 dB full scale

    def fx_x(freq):
        lo, hi = math.log(20.0), math.log(20000.0)
        return 2 + int((math.log(max(20.0, min(20000.0, freq))) - lo)
                       / (hi - lo) * 250)

    def gain_at(freq):
        g = 0.0
        for b in bands:
            typ = b.get("type", "bell")
            f0, bg, q = b["freq"], b.get("gain", 0.0), b.get("q", 1.0)
            r = math.log(freq / f0) * q * 1.7
            if typ == "bell":
                g += bg * math.exp(-r * r)
            elif typ == "hishelf":
                g += bg / (1.0 + math.exp(-r * 2))
            elif typ == "loshelf":
                g += bg / (1.0 + math.exp(r * 2))
            elif typ == "hipass" and freq < f0:
                g -= 24.0 * math.log(f0 / freq) / math.log(4)
            elif typ == "lopass" and freq > f0:
                g -= 24.0 * math.log(freq / f0) / math.log(4)
        return g

    prev = None
    for px in range(2, 253):
        freq = 20.0 * (1000.0 ** ((px - 2) / 250.0))
        y = mid - int(max(-18, min(18, gain_at(freq))) * scale)
        y = max(top, min(bot, y))
        if prev is not None:
            lo, hi = sorted((prev, y))
            for yy in range(lo, hi + 1):
                f.point(px, yy, NORMAL)
        else:
            f.point(px, y, NORMAL)
        prev = y

    focus = fx.get("focus", 0)
    for i, b in enumerate(bands):
        bx = fx_x(b["freq"])
        by = mid - int(max(-18, min(18, b.get("gain", 0.0))) * scale)
        if i == focus:
            f.fill(bx - 1, by - 1, 3, 3, BRIGHT)
        else:
            f.point(bx, by, MUTED)


def _fx_comp_view(f, fx):
    """Compressor: transfer curve, gain-reduction meter, in/out meters.

    The GR meter is the working display on a compressor - it is what the
    engineer watches - so it gets the width; the transfer curve carries
    threshold and ratio as shape.
    """
    top, bot = BODY_Y + 11, ENCBAR_Y - 4
    h = bot - top
    # transfer curve box
    bx, bw = 2, h
    f.rect(bx, top, bw, h, DIM)
    thr = fx.get("threshold_norm", 0.6)
    ratio = fx.get("ratio", 4.0)
    kx = bx + int(thr * (bw - 2))
    ky = bot - int(thr * (h - 2))
    for px in range(bx + 1, bx + bw - 1):
        t = (px - bx - 1) / max(1, bw - 3)
        if px <= kx:
            y = bot - 1 - int(t * (h - 2))
        else:
            y = ky - int((px - kx) / max(1, bw - 2 - (kx - bx)) *
                         (h - 2) * (1.0 - thr) / ratio)
        f.point(px, max(top + 1, min(bot - 1, y)), NORMAL)
    f.point(kx, ky, BRIGHT)

    # gain reduction meter
    gx = bx + bw + 10
    gw = 150
    f.text(gx, top, "GR", DIM)
    gr = fx.get("gr_db", 0.0)
    f.fill(gx + 16, top + 1, gw, 5, DIM)
    f.fill(gx + 16, top + 1, int(min(1.0, gr / 20.0) * gw), 5, BRIGHT)
    f.text(gx + 16 + gw + 4, top, "-%.1f" % gr, BRIGHT)
    # in/out share one row - stacking them ran into the encoder strip
    yy = top + 10
    half = (gw - 30) // 2
    f.text(gx, yy, "IN", DIM)
    f.fill(gx + 16, yy + 1, half, 3, DIM)
    f.fill(gx + 16, yy + 1, int(fx.get("in_level", 0.0) * half), 3, MUTED)
    ox = gx + 16 + half + 8
    f.text(ox, yy, "OUT", DIM)
    f.fill(ox + 22, yy + 1, half, 3, DIM)
    f.fill(ox + 22, yy + 1, int(fx.get("out_level", 0.0) * half), 3, MUTED)
    # sidechain source, named: an invisible sidechain is a debugging trap
    sc = fx.get("sidechain")
    if sc:
        f.text(gx + 16 + gw + 4, yy, "SC:" + sc[:5], BRIGHT)


def page_fx(f, st):
    """One track's plugin chain. The chain is slot chips on the context
    row; the body is a purpose-built view per plugin kind - an EQ is a
    curve, a compressor is a transfer function and a GR meter - because
    plugin GUIs are X11 bitmaps that cannot exist on this panel, and a
    curve reads faster than eight numbers anyway. The encoders always
    edit the focused bank of four parameters, named in the bottom strip.
    """
    draw_header(f, st)
    fx = st.get("fx", {})

    f.text(3, BODY_Y, fx.get("track", "-")[:5], BRIGHT)
    cx = 3 + f.text_width("XXXXX") + 8
    for i, slot in enumerate(fx.get("chain", [])[:4]):
        label = slot.get("name", "-")[:4]
        w = f.text_width(label) + 6
        if i == fx.get("slot", 0):
            f.fill(cx - 2, BODY_Y - 1, w, GLYPH_H + 3, BRIGHT)
            f.text(cx + 1, BODY_Y, label, OFF)
        elif slot.get("bypass"):
            f.text(cx + 1, BODY_Y, label, DIM)
            f.hline(cx, BODY_Y + 3, w - 3, DIM)
        else:
            f.rect(cx - 2, BODY_Y - 1, w, GLYPH_H + 3, DIM)
            f.text(cx + 1, BODY_Y, label, NORMAL)
        cx += w + 4
    f.hline(0, BODY_Y + 9, 255, DIM)

    kind = fx.get("kind", "params")
    if kind == "eq":
        _fx_eq_view(f, fx)
    elif kind == "comp":
        _fx_comp_view(f, fx)
    else:
        bank = st.get("bank", 0)
        params = fx.get("params", [])[bank * COLS:(bank + 1) * COLS]
        for i, prm in enumerate(params):
            x = COL_X[i]
            column_divider(f, i, top=BODY_Y + 11)
            f.text_center(x, COL_W, BODY_Y + 12, prm.get("name", "-")[:9],
                          DIM)
            f.text_center(x, COL_W, BODY_Y + 21, prm.get("value", "-")[:9],
                          BRIGHT)

    encoders = []
    for prm in fx.get("knobs", fx.get("params", []))[:COLS]:
        encoders.append({"norm": prm.get("norm", 0.0), "level": NORMAL,
                         "text": prm.get("name", "")[:5]})
    draw_encoder_bar(f, st, encoders)


# --- SONG ------------------------------------------------------------


def page_song(f, st):
    draw_header(f, st)
    song = st.get("song", {})
    f.text(2, BODY_Y, "SEQ", DIM)
    f.text(24, BODY_Y, song.get("sequence", "-")[:12], BRIGHT)
    # Both counts go on the header row: adding a line below the ribbon
    # ran it into the encoder strip, and the width was free.
    f.text_right(254, BODY_Y, "%d BARS  %d LOOPS" % (
        song.get("bars", 0), song.get("loops", 0)), MUTED)

    # The arrangement as a map: position is spatial, not numeric, which
    # is the one thing the big-screen loopers get wrong.
    top, height = BODY_Y + 10, 13
    total = max(1, song.get("bars", 1))
    f.rect(1, top, 253, height, DIM)
    for seg in song.get("sections", []):
        sx = 1 + int(seg["start"] / total * 251)
        sw = max(2, int(seg["length"] / total * 251))
        f.fill(sx + 1, top + 1, sw, height - 2,
               BRIGHT if seg.get("current") else MUTED)
        if sw > 20:
            f.text(sx + 3, top + 3, seg.get("name", "")[:4],
                   OFF if seg.get("current") else NORMAL)
    head = 1 + int(song.get("position", 0) / total * 251)
    f.vline(head, top - 3, height + 5, BRIGHT)

    # The four encoders get named jobs rather than being left dead: a
    # blank cell is a legitimate state, but four blank cells on a whole
    # page is just unused surface.
    pos = song.get("position", 0)
    draw_encoder_bar(f, st, [
        {"norm": pos / total, "level": NORMAL, "text": "SCRUB"},
        {"norm": song.get("zoom", 0.5), "level": NORMAL, "text": "ZOOM"},
        {"norm": 0.0, "level": DIM, "text": "SECT"},
        None,
    ])


def draw_pad_overlay(f, st):
    """The 4x4 pad map, drawn over the page while PAD MODE is held.

    This is the single most direct answer to "what do my pads do right
    now", and it is an overlay rather than a page because holding a mode
    button to preview it - and reverting on release - is what keeps a
    performer from getting lost. A held mode cannot be forgotten; the
    muscular effort is the reminder.

    Columns are lanes, matching both the four screen columns above and
    the MPC's own Clip-program convention, so "column = lane" is true on
    the pads, on the screen and in the MPC idiom at the same time.
    """
    pads = st.get("pads", {})
    rows = pads.get("rows", ("REC", "PLAY", "STOP", "CLEAR"))
    grid = pads.get("grid", [[0] * COLS for _ in rows])

    # Opaque, not translucent. A first attempt dimmed the page and drew
    # the grid over it; the two layers landed on the same rows and the
    # result was illegible. What makes this a peek is that it is
    # momentary - held, not entered - not that you can see through it.
    f.fill(0, BTNBAR_H + 1, f.w, f.h - BTNBAR_H - 1, OFF)

    gutter = 34
    cell_w = (f.w - gutter - 4) // COLS
    f.text(2, HEADER_Y + 1, "PADS", BRIGHT)
    f.text(34, HEADER_Y + 1, pads.get("mode", "")[:24], MUTED)

    for r, label in enumerate(rows[:4]):
        y = BODY_Y + 2 + r * 9
        f.text(2, y, label[:5], MUTED)
        for c in range(COLS):
            x = gutter + c * cell_w
            state = grid[r][c] if r < len(grid) and c < len(grid[r]) else 0
            if state == 2:        # active
                f.fill(x, y, cell_w - 3, 6, BRIGHT)
            elif state == 1:      # available
                f.rect(x, y, cell_w - 3, 6, NORMAL)
            else:                 # unavailable - visibly a third state,
                f.hline(x, y + 5, cell_w - 3, DIM)   # not just dimmer


# --- WAVE ------------------------------------------------------------


def page_wave(f, st):
    """Audio take editor: the waveform, trim handles, playhead.

    Reached by SELECT + a pad (edit that lane's take) or NAVIGATE. The
    audio outside the trim is drawn dim rather than hidden - what a trim
    is about to discard is exactly what the eye needs to check - and the
    encoders map to START / END / ZOOM / GAIN with the values in the
    bottom strip.
    """
    draw_header(f, st)
    wv = st.get("wave", {})

    f.text(3, BODY_Y, wv.get("lane", "-")[:5], BRIGHT)
    f.text(40, BODY_Y, wv.get("region", "-")[:16], NORMAL)
    f.text_right(254, BODY_Y, wv.get("length", ""), MUTED)

    top, bot = BODY_Y + 10, ENCBAR_Y - 4
    mid = (top + bot) // 2
    half_h = (bot - top) // 2
    f.hline(1, mid, 253, DIM)

    data = wv.get("peaks", [])
    n = len(data)
    t0, t1 = wv.get("trim", (0.0, 1.0))
    gain = wv.get("gain", 1.0)
    for px in range(1, 254):
        pos = (px - 1) / 252.0
        if n:
            amp = data[min(n - 1, int(pos * n))] * gain
        else:
            amp = 0.0
        hh = max(0, min(half_h, int(amp * half_h)))
        inside = t0 <= pos <= t1
        level = NORMAL if inside else DIM
        if hh:
            f.vline(px, mid - hh, hh * 2 + 1, level)

    # trim handles: bright rules with feet, unmistakably grabbable
    for t in (t0, t1):
        tx = 1 + int(t * 252)
        f.vline(tx, top - 2, bot - top + 4, BRIGHT)
        f.hline(tx - 2, top - 2, 5, BRIGHT)
        f.hline(tx - 2, bot + 2, 5, BRIGHT)

    ph = wv.get("playhead")
    if ph is not None:
        px = 1 + int(ph * 252)
        f.vline(px, top, bot - top, MUTED)

    draw_encoder_bar(f, st, [
        {"norm": t0, "level": NORMAL, "text": "START"},
        {"norm": t1, "level": NORMAL, "text": "END"},
        {"norm": wv.get("zoom", 0.0), "level": NORMAL, "text": "ZOOM"},
        {"norm": min(1.0, gain / 2.0), "level": NORMAL, "text": "GAIN"},
    ])


RENDERERS = {"WAVE": page_wave, "LOOP": page_loop, "MIX": page_mix, "FX": page_fx,
             "SONG": page_song}


def render(st):
    f = Frame()
    RENDERERS[st["page"]](f, st)
    if st.get("pad_overlay"):
        draw_pad_overlay(f, st)
    return f


# --- sample states for design review ---------------------------------


def sample_state(page):
    st = {"page": page, "playing": True, "bpm": 86.0, "position": "005.3",
          "recording": 1, "xruns": 0, "mode": "DAW",
          "message": "GTR2 LEVEL  -6.0 DB",
          "buttons_active": ()}
    st["lanes"] = [
        {"name": "GTR1", "state": "play", "bars": 4, "bar": 3,
         "bars_remaining": 1, "phase": 0.4, "level": 0.55},
        {"name": "GTR2", "state": "rec", "bars": 4, "bar": 2,
         "bars_remaining": 2, "phase": 0.2, "level": 0.82},
        {"name": "MIC", "state": "dub", "bars": 2, "bar": 1,
         "bars_remaining": 1, "phase": 0.7, "level": 0.30},
        {"name": "AUX", "state": "play", "bars": 8, "bar": 5,
         "bars_remaining": 3, "phase": 0.1, "level": 0.12},
        {"name": "L5", "state": "armed", "bars": 4, "bar": 0,
         "level": 0.0},
        {"name": "L6", "state": "empty"},
        {"name": "L7", "state": "empty"},
        {"name": "L8", "state": "empty"},
    ]
    st["banks"] = 2
    st["bank"] = 0
    st["pads"] = {
        "mode": "LOOP - COLUMN IS LANE",
        "rows": ("REC", "PLAY", "STOP", "CLEAR"),
        # 0 unavailable, 1 available, 2 active
        "grid": [[1, 2, 1, 1],
                 [2, 1, 2, 2],
                 [1, 1, 1, 1],
                 [0, 1, 0, 0]],
    }
    import math as _m
    st["wave"] = {
        "lane": "GTR2", "region": "TAKE 3", "length": "2 BARS  192000",
        "trim": (0.08, 0.86), "playhead": 0.31, "zoom": 0.0, "gain": 1.0,
        "peaks": [abs(_m.sin(i / 6.0)) * _m.exp(-((i % 63) / 40.0))
                  * (0.35 + 0.65 * _m.exp(-i / 160.0)) + 0.04
                  for i in range(252)],
    }
    st["master"] = {"name": "MSTR", "db": "0.0", "gain": 0.85,
                    "level_l": 0.72, "level_r": 0.66,
                    "peak_l": 0.81, "peak_r": 0.74}
    st["mixer"] = [
        {"db": "-3.5", "send_a": 0.15, "send_b": 0.3, "name": "MPC", "gain": 0.80, "level": 0.62, "peak": 0.71},
        {"db": "-8.0", "send_a": 0.45, "send_b": 0.1, "name": "GTR1", "gain": 0.65, "level": 0.44, "peak": 0.52},
        {"db": "-6.5", "send_a": 0.35, "send_b": 0.2, "name": "GTR2", "gain": 0.70, "level": 0.05, "peak": 0.30},
        {"db": "-12.0", "send_a": 0.6, "send_b": 0.25, "name": "MIC", "gain": 0.55, "level": 0.88, "peak": 0.96,
         "solo": True},
        {"db": "-5.0", "send_a": 0.2, "send_b": 0.4, "name": "LOOP", "gain": 0.75, "level": 0.33, "peak": 0.40},
        {"db": "-18.0", "send_a": 0.0, "send_b": 0.0, "name": "VERB", "gain": 0.40, "level": 0.20, "peak": 0.25},
        {"db": "-20.0", "send_a": 0.0, "send_b": 0.0, "name": "DLY", "gain": 0.35, "level": 0.10, "peak": 0.18,
         "mute": True},
        {"db": "0.0", "send_a": 0.0, "send_b": 0.0, "name": "MSTR", "gain": 0.85, "level": 0.70, "peak": 0.80},
    ]
    st["fx"] = {
        "track": "GTR1", "kind": "eq", "slot": 0, "focus": 1,
        "chain": [
            {"name": "EQ"}, {"name": "COMP"}, {"name": "DRV"},
            {"name": "VERB", "bypass": True},
        ],
        "bands": [
            {"type": "hipass", "freq": 80, "q": 1.0},
            {"type": "bell", "freq": 220, "gain": -3.5, "q": 1.4},
            {"type": "bell", "freq": 2400, "gain": 4.0, "q": 0.8},
            {"type": "hishelf", "freq": 8000, "gain": 2.0, "q": 0.7},
        ],
        "knobs": [
            {"name": "FREQ", "norm": 0.35},
            {"name": "GAIN", "norm": 0.30},
            {"name": "Q", "norm": 0.55},
            {"name": "TYPE", "norm": 0.25},
        ],
    }
    st["song"] = {
        "sequence": "LT-BEAT", "bars": 32, "position": 12, "loops": 4,
        "zoom": 0.5,
        "sections": [
            {"name": "INTR", "start": 0, "length": 8},
            {"name": "VRSE", "start": 8, "length": 8, "current": True},
            {"name": "CHRS", "start": 16, "length": 8},
            {"name": "OUTR", "start": 24, "length": 8},
        ],
    }
    return st


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--snapshot":
        outdir = sys.argv[2]
        for page in PAGES:
            f = render(sample_state(page))
            path = "%s/page-%s.png" % (outdir, page.lower())
            f.to_png(path)
            print("wrote %s" % path)
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "--ascii":
        page = sys.argv[2].upper() if len(sys.argv) > 2 else "LOOP"
        print(render(sample_state(page)).to_ascii())
        return
    print(__doc__)
    sys.exit(2)


if __name__ == "__main__":
    main()
