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
            # 62px columns fit ten characters; the old five-character cap
            # was a leftover from the eight-column layout and truncated
            # "XF OUT" to "XF OU".
            f.text_center(x, COL_W, ENCBAR_Y + 5, text[:10], NORMAL)


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
    _strips_view(f, st, "LOOP")


# --- MIX -------------------------------------------------------------


def _strips_view(f, st, lens):
    """The shared vertical-strip view behind both MIX and LOOP.

    One geometry, two lenses: a channel occupies the same column on both
    pages, so the hand that just muted GTR2 on MIX finds GTR2's loop in
    the same place on LOOP. What changes per lens is only the meaning of
    the columns inside a strip: MIX shows the audio meter with peak and
    clip plus the two send bars; LOOP swaps the meter for the loop
    position sweep and a bars-remaining digit, and strips that are not
    loop lanes go quiet instead of pretending.
    """
    draw_header(f, st)
    strips = list(st["mixer"][:8])
    master = st.get("master", {"name": "MSTR"})
    lanes = {l.get("name"): l for l in st.get("lanes", [])}
    n = len(strips) + 1
    sw = 255 // n
    focus = st.get("focus_bank", 0) * 4

    top = BODY_Y + 9
    bot = ENCBAR_Y - 4
    travel = bot - top - 2

    def vmeter(mx, level, peak, clip, ink=NORMAL):
        f.fill(mx, top, 3, travel + 2, OFF)
        f.vline(mx - 1, top, travel + 2, DIM)
        f.vline(mx + 3, top, travel + 2, DIM)
        lit = int(level * travel)
        if lit:
            f.fill(mx, top + travel + 1 - lit, 3, lit, ink)
        if peak:
            f.hline(mx, top + travel + 1 - int(peak * travel), 3, BRIGHT)
        if clip:
            f.fill(mx, top - 3, 3, 2, BRIGHT)

    def strip(i, x, ch, is_master=False):
        lane = lanes.get(ch.get("name"))
        state = lane.get("state") if lane else None
        name = ch.get("name", "-")[:4]

        if is_master or ch.get("solo") or state == "rec":
            f.fill(x, BODY_Y, sw - 2, GLYPH_H + 2, BRIGHT)
            f.text_center(x, sw - 2, BODY_Y + 1, name, OFF)
        elif state == "dub":
            f.fill(x, BODY_Y, sw - 2, GLYPH_H + 2, MUTED)
            f.text_center(x, sw - 2, BODY_Y + 1, name, OFF)
        elif state == "armed":
            f.rect(x, BODY_Y, sw - 2, GLYPH_H + 2, NORMAL)
            f.text_center(x, sw - 2, BODY_Y + 1, name, NORMAL)
        else:
            quiet = (lens == "LOOP" and not is_master and lane is None)
            f.text_center(x, sw - 2, BODY_Y + 1, name,
                          DIM if (ch.get("mute") or quiet) else NORMAL)

        fx_ = x + 4
        f.vline(fx_, top, travel + 2, DIM)
        f.hline(fx_ - 2, top + int(travel * 0.25), 5, DIM)
        ky = top + int((1.0 - ch.get("gain", 0.8)) * travel)
        f.fill(fx_ - 3, ky, 7, 3, BRIGHT)

        if is_master:
            vmeter(x + 12, master.get("level_l", 0.0),
                   master.get("peak_l", 0.0), master.get("clip"))
            vmeter(x + 18, master.get("level_r", 0.0),
                   master.get("peak_r", 0.0), False)
        elif lens == "LOOP":
            if lane:
                bars = lane.get("bars", 0)
                pos = ((lane.get("bar", 0) + lane.get("phase", 0.0)) / bars
                       if bars else 0.0)
                vmeter(x + 12, pos, 0.0, False,
                       BRIGHT if state in ("rec", "dub") else NORMAL)
                remain = lane.get("bars_remaining")
                if remain is not None:
                    f.text(x + 19, top + 1, str(remain)[:1], BRIGHT)
        else:
            vmeter(x + 12, ch.get("level", 0.0), ch.get("peak", 0.0),
                   ch.get("clip"))
            for j, key in enumerate(("send_a", "send_b")):
                sx = x + 19 + j * 4
                f.vline(sx, top, travel + 2, DIM)
                lit = int(ch.get(key, 0.0) * travel)
                if lit:
                    f.fill(sx, top + travel + 1 - lit, 2, lit, MUTED)

        if not is_master and focus <= i < focus + 4:
            f.hline(x, bot + 2, sw - 2, BRIGHT)

    for i, ch in enumerate(strips):
        strip(i, 1 + i * sw, ch)
    strip(8, 1 + 8 * sw, master, is_master=True)

    focused = strips[focus:focus + 4]
    draw_encoder_bar(f, st, [
        {"norm": ch.get("gain", 0.0), "level": NORMAL,
         "text": "%s %s" % (ch.get("name", "")[:4], ch.get("db", ""))}
        for ch in focused])


def page_mix(f, st):
    _strips_view(f, st, "MIX")


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


def _fx_limiter_view(f, fx):
    """Limiter: the ceiling, and how hard we are hitting it.

    A limiter has one question - am I clipping the ceiling, and by how
    much - so the gain-reduction meter is the whole display, with the
    ceiling as a fixed line the input bar cannot cross.
    """
    top, bot = BODY_Y + 11, ENCBAR_Y - 4
    f.text(3, top, "IN", DIM)
    w = 190
    f.fill(24, top, w, 6, DIM)
    f.fill(24, top, int(min(1.0, fx.get("in_level", 0.0)) * w), 6, NORMAL)
    ceil = fx.get("ceiling_norm", 0.9)
    f.vline(24 + int(ceil * w), top - 2, 10, BRIGHT)
    f.text(24 + w + 6, top, fx.get("ceiling", "-0.3"), BRIGHT)

    gr = fx.get("gr_db", 0.0)
    f.text(3, top + 11, "GR", DIM)
    f.fill(24, top + 11, w, 6, DIM)
    f.fill(24, top + 11, int(min(1.0, gr / 12.0) * w), 6, BRIGHT)
    f.text(24 + w + 6, top + 11, "-%.1f" % gr, BRIGHT)
    if fx.get("over"):
        f.text_inverted(24, top + 21, "OVER")


def _fx_multiband_view(f, fx):
    """Multiband: one column per band, each with its own GR bar.

    Bands are drawn left to right as frequency, so the picture matches
    the EQ view's axis; the selected band is bright and its crossover
    frequencies are written under it.
    """
    top, bot = BODY_Y + 11, ENCBAR_Y - 4
    bands = fx.get("bands", [])
    if not bands:
        return
    n = len(bands)
    bw = (250 - (n - 1) * 3) // n
    sel = fx.get("focus", 0)
    # Labels first, bars below them: putting the labels underneath left
    # the bars 7px tall, which is not a meter.
    for i, b in enumerate(bands):
        x = 3 + i * (bw + 3)
        ink = BRIGHT if i == sel else MUTED
        f.text_center(x, bw, top, b.get("name", "")[:5],
                      BRIGHT if i == sel else DIM)
        by = top + 9
        h = bot - by
        f.rect(x, by, bw, h, DIM)
        gr = min(1.0, b.get("gr_db", 0.0) / 18.0)
        lit = int(gr * (h - 2))
        if lit:
            f.fill(x + 1, by + 1, bw - 2, lit, ink)
        thr = b.get("threshold_norm", 0.5)
        f.hline(x, by + h - int(thr * (h - 2)), bw, NORMAL)


def _fx_delay_view(f, fx):
    """Delay: the repeats, spaced by the actual delay time.

    Drawn as decaying taps on a timeline, which shows feedback and time
    at once. The time is written in both ms and note division, because
    against an MPC sequence the division is what a musician means.
    """
    top, bot = BODY_Y + 11, ENCBAR_Y - 4
    base = bot - 2
    f.text(3, top, fx.get("time", "375 MS"), BRIGHT)
    f.text(70, top, fx.get("division", "1/8"), NORMAL)
    f.text_right(254, top, "MIX %s" % fx.get("mix", "30%"), MUTED)
    spacing = max(8, int(fx.get("time_norm", 0.3) * 90))
    level = 1.0
    x = 8
    while x < 250 and level > 0.05:
        h = max(2, int(level * (bot - top - 12)))
        f.fill(x, base - h, 3, h, BRIGHT if x == 8 else NORMAL)
        level *= fx.get("feedback", 0.5)
        x += spacing
    f.hline(3, base, 250, DIM)


def _fx_reverb_view(f, fx):
    """Reverb: an exponential tail whose length is the decay.

    Size shifts the early reflections drawn under the tail, so the two
    parameters a player actually reaches for are visible as shape.
    """
    import math
    top, bot = BODY_Y + 11, ENCBAR_Y - 4
    base = bot - 2
    # Name and mix ride the status line's message zone instead of a row
    # of their own; the tail needs every pixel of the 15px body.
    f.text(3, top, fx.get("preset", "HALL")[:5], BRIGHT)
    decay = max(0.05, fx.get("decay_norm", 0.5))
    height = bot - top - 2
    for i in range(240):
        env = math.exp(-i / (decay * 210.0))
        h = int(env * height)
        if h > 0:
            f.vline(10 + i, base - h, h, NORMAL)
    # early reflections: a few discrete taps whose spread is "size"
    size = fx.get("size_norm", 0.5)
    for k in range(4):
        x = 10 + int((k + 1) * size * 26)
        if x < 250:
            f.fill(x, base - height, 2, height, BRIGHT)


def _fx_drive_view(f, fx):
    """Overdrive / distortion: the clipping curve itself.

    The transfer curve says everything a drive pedal does - how early it
    breaks up and how hard it squares off - and one look distinguishes a
    Tube Screamer's soft mid-hump from a DS-1's harder edge.
    """
    import math
    top, bot = BODY_Y + 11, ENCBAR_Y - 4
    h = bot - top
    mid = (top + bot) // 2
    box = h
    f.rect(3, top, box, h, DIM)
    f.hline(3, mid, box, DIM)
    f.vline(3 + box // 2, top, h, DIM)
    drive = 1.0 + fx.get("drive_norm", 0.5) * 12.0
    hard = fx.get("hard", False)
    for i in range(1, box - 1):
        xin = (i / (box - 2)) * 2 - 1
        if hard:
            y = max(-1.0, min(1.0, xin * drive))
        else:
            y = math.tanh(xin * drive)
        py = mid - int(y * (h / 2 - 2))
        f.point(3 + i, max(top + 1, min(bot - 1, py)), BRIGHT)
    # Name and clip character only: DRIVE/TONE/LEVEL/MIX are already
    # named in the encoder strip, and repeating them here overflowed it.
    x = 3 + box + 10
    f.text(x, top + 2, fx.get("model", "")[:16], BRIGHT)
    f.text_right(253, top + 2,
                 "HARD" if fx.get("hard") else "SOFT", MUTED)


def _fx_amp_view(f, fx):
    """Amp: which combo, its tone stack, and the cab.

    The three voicings are named on screen rather than hidden behind a
    number, and the tone stack is drawn as three bars because that is how
    an amp's panel reads - you set a shape, not a list of values.
    """
    top, bot = BODY_Y + 11, ENCBAR_Y - 4
    # Five voicings fit across 255px at five characters each; the chips
    # are the whole selector, so no paging and nothing hidden.
    models = fx.get("models", [])
    cur = fx.get("model_index", 0)
    x = 3
    for i, m in enumerate(models[:5]):
        label = m[:5]
        w = f.text_width(label) + 6
        if i == cur:
            f.fill(x, top, w, GLYPH_H + 3, BRIGHT)
            f.text(x + 3, top + 1, label, OFF)
        else:
            f.rect(x, top, w, GLYPH_H + 3, DIM)
            f.text(x + 3, top + 1, label, MUTED)
        x += w + 4
    f.text_right(254, top + 1, fx.get("cab", "")[:8], MUTED)

    # The tone stack sits directly above the encoders that set it, one
    # bar per column, and carries no labels of its own: the encoder strip
    # already names GAIN / BASS / MID / MASTER, and repeating them here
    # cost the rows this view needs.
    ty = top + 13
    vals = list(fx.get("tone", (0.5, 0.5, 0.5)))
    values = [fx.get("gain", 0.5)] + vals
    for i, v in enumerate(values[:COLS]):
        bx = COL_X[i] + 3
        f.fill(bx, ty, COL_W - 8, 5, DIM)
        f.fill(bx, ty, int(v * (COL_W - 8)), 5, BRIGHT)


def _fx_mod_view(f, fx):
    """Chorus / flanger: the LFO drawn as the waveform it is.

    Rate and depth are a shape, not two numbers - one look says how fast
    and how far. The sweep marker rides the curve at the current LFO
    phase, so a stopped rig still shows which way the modulation is
    heading.
    """
    import math
    top, bot = BODY_Y + 11, ENCBAR_Y - 4
    mid = (top + bot) // 2
    height = (bot - top) // 2 - 1
    f.hline(2, mid, 251, DIM)
    rate = max(0.15, fx.get("rate_norm", 0.3)) * 4.0
    depth = fx.get("depth_norm", 0.6)
    for px in range(2, 253):
        t = (px - 2) / 250.0
        y = mid - int(math.sin(t * math.tau * rate) * height * depth)
        f.point(px, max(top, min(bot, y)), NORMAL)
    ph = fx.get("phase", 0.25)
    px = 2 + int(ph * 250)
    py = mid - int(math.sin(ph * math.tau * rate) * height * depth)
    f.fill(px - 1, max(top, min(bot, py)) - 1, 3, 3, BRIGHT)


def _fx_chop_view(f, fx):
    """Chopper: the gate pattern against the bar, as a square wave.

    The division is snapped to the MPC's tempo, so the pattern drawn here
    is literally where the sound stops and starts in the bar - and the
    beat ticks underneath line the chop up with the grid. One knob owns
    the division, which is the control a player reaches for mid-song.
    """
    top, bot = BODY_Y + 11, ENCBAR_Y - 4
    steps = max(1, fx.get("steps", 8))
    duty = fx.get("duty", 0.5)
    w = 250 // steps
    for i in range(steps):
        x = 2 + i * w
        on = int(w * duty)
        # high while the gate is open, low while it chops out
        f.fill(x, top, on, bot - top, MUTED if i % 2 else BRIGHT)
        f.vline(x, top, bot - top, DIM)
    # beat ticks: four to the bar, so the chop is read against the grid
    for b in range(5):
        bx = 2 + int(b * 250 / 4)
        f.vline(min(252, bx), bot + 1, 2, NORMAL)


def _fx_tuner_view(f, fx):
    """Tuner: the one effect whose display *is* the product.

    A big note name, and a needle on a centre-marked scale with a wide
    in-tune window drawn as a box. Cents are shown as a number too, but
    the needle is what a player reads - and the IN TUNE box is what they
    read from three metres away with a guitar in their hands.
    """
    top, bot = BODY_Y + 11, ENCBAR_Y - 4
    note = fx.get("note", "-")
    cents = fx.get("cents", 0.0)
    in_tune = abs(cents) <= 4

    # Note name at double size on the left; the octave rides small.
    f.text(4, top + 2, note[:2], BRIGHT, scale=2)
    if fx.get("octave") is not None:
        f.text(4 + f.text_width(note[:2], 2), top + 10,
               str(fx["octave"]), MUTED)

    # Scale: -50..+50 cents across the remaining width.
    sx, sw = 56, 196
    mid = sx + sw // 2
    f.hline(sx, bot - 4, sw, DIM)
    for c in range(-50, 51, 10):
        x = mid + int(c / 50.0 * (sw // 2))
        f.vline(x, bot - 7, 4, NORMAL if c == 0 else DIM)
    # the in-tune window, drawn as a box so it reads at a distance
    win = int(4 / 50.0 * (sw // 2))
    f.rect(mid - win, top, win * 2, bot - top - 6,
           BRIGHT if in_tune else DIM)

    nx = mid + int(max(-50.0, min(50.0, cents)) / 50.0 * (sw // 2))
    f.vline(nx, top, bot - top - 6, BRIGHT)
    f.fill(nx - 1, top, 3, 3, BRIGHT)

    # The readout sits left of the scale so it never covers the needle
    # it is describing.
    if in_tune:
        f.text_inverted(sx + 2, top + 2, "IN TUNE")
    else:
        f.text(sx + 2, top + 2, "%+d" % round(cents), NORMAL)
    f.text_right(252, top + 2, fx.get("hz", ""), MUTED)


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
    views = {"eq": _fx_eq_view, "comp": _fx_comp_view,
             "limiter": _fx_limiter_view, "multiband": _fx_multiband_view,
             "delay": _fx_delay_view, "reverb": _fx_reverb_view,
             "drive": _fx_drive_view, "amp": _fx_amp_view,
             "mod": _fx_mod_view, "chop": _fx_chop_view,
             "tuner": _fx_tuner_view}
    if kind in views:
        views[kind](f, fx)
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
                         "text": prm.get("name", "")[:10]})
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
    """The 4x4 pad map, drawn while a mode button is held.

    Each pad mode has its own button (PAD MODE, MUTE, SOLO) and holding
    it *is* the mode; releasing returns the pads to the MPC. While held
    this map covers the page so the performer sees what the pads mean
    before hitting one. The header names the held button and says what
    release does, because a mode you cannot name is a mode you can get
    lost in - and PIN is offered on the spot for when both hands are
    needed elsewhere.

    Columns are lanes, matching the four screen columns above and Akai's
    own Clip-program convention, so "column = lane" is true on the pads,
    on the screen and in the MPC idiom at once.
    """
    pads = st.get("pads", {})
    rows = pads.get("rows", ("REC", "PLAY", "STOP", "CLEAR"))
    grid = pads.get("grid", [[0] * COLS for _ in rows])
    labels = pads.get("labels")

    # Opaque, not translucent: a first attempt dimmed the page and drew
    # the grid over it, and the two layers were illegible together. What
    # makes this a peek is that it is momentary, not see-through.
    f.fill(0, BTNBAR_H + 1, f.w, f.h - BTNBAR_H - 1, OFF)

    held = pads.get("held", "PAD MODE")
    f.text_inverted(3, HEADER_Y + 1, "HOLD " + held)
    f.text_right(254, HEADER_Y + 1, "RELEASE = MPC PADS", MUTED)

    gutter = 34
    cell_w = (f.w - gutter - 4) // COLS
    for r, label in enumerate(rows[:4]):
        y = BODY_Y + 2 + r * 9
        f.text(2, y, label[:5], MUTED)
        for c in range(COLS):
            x = gutter + c * cell_w
            state = grid[r][c] if r < len(grid) and c < len(grid[r]) else 0
            w = cell_w - 3
            if state == 2:        # active now
                f.fill(x, y, w, 7, BRIGHT)
            elif state == 1:      # available
                f.rect(x, y, w, 7, NORMAL)
            else:                 # unavailable: a third shape, not just
                f.hline(x, y + 6, w, DIM)      # a dimmer version of one
            if labels:
                txt = (labels[r][c] if r < len(labels)
                       and c < len(labels[r]) else "")
                if txt:
                    f.text_center(x, w, y + 1, txt[:4],
                                  OFF if state == 2 else
                                  (NORMAL if state == 1 else DIM))


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


# --- EDIT ------------------------------------------------------------


def page_edit(f, st):
    """The arrangement editor: stacked lanes, zoomable in and out.

    Zoomed out, three or more lanes stack as plain blocks for moving
    parts around; zoomed in to one or two lanes, the regions draw their
    waveforms, because aligning a syllable is done against the wave, not
    against a label. Text follows the same rule: lane tags live in a
    narrow gutter, and only the selected region's name is written, in the
    context row rather than on the audio.
    """
    draw_header(f, st)
    ed = st.get("edit", {})
    lanes = ed.get("lanes", [])
    win0, win1 = ed.get("window", (0.0, 8.0))
    span = max(0.001, win1 - win0)
    show = max(1, min(len(lanes), ed.get("zoom_lanes", len(lanes))))
    first = max(0, min(ed.get("first_lane", 0), len(lanes) - show))

    sel = None
    for ln in lanes:
        for r in ln.get("regions", []):
            if r.get("sel"):
                sel = r
    # No text row inside the page: the selected region's name and the
    # snap setting ride the status line, and every reclaimed pixel goes
    # to lane height - the waveform is the alignment tool, not labels.
    st.setdefault("message",
                  "%s  SNAP %s" % ((sel.get("name", "") if sel else ""),
                                   ed.get("snap", "1/16")))

    GUTTER = 14

    def tx(bar):
        return GUTTER + int((bar - win0) / span * (253 - GUTTER))

    ry = BODY_Y
    bar = int(win0)
    while bar <= win1:
        x = tx(bar)
        if GUTTER <= x <= 253:
            f.vline(x, ry, 3 if bar % 4 == 0 else 2,
                    NORMAL if bar % 4 == 0 else DIM)
        bar += int(max(1, span // 16))

    area_top, area_bot = BODY_Y + 5, ENCBAR_Y - 3
    lane_h = (area_bot - area_top - (show - 1)) // show
    draw_waves = show <= 2 and lane_h >= 10

    for li in range(show):
        lane = lanes[first + li]
        top = area_top + li * (lane_h + 1)
        bot = top + lane_h
        mid = (top + bot) // 2
        # lane tag in the gutter: two characters, no more text than that
        f.text(1, top + (lane_h - GLYPH_H) // 2, lane.get("tag", "?")[:2],
               BRIGHT if lane.get("sel") else DIM)
        f.hline(GUTTER - 3, mid, 2, DIM)

        ordered = sorted(lane.get("regions", []), key=lambda r: r["start"])
        for r in ordered:
            x0, x1 = tx(r["start"]), tx(r["start"] + r["len"])
            x0c, x1c = max(GUTTER, x0), min(253, x1)
            if x1c <= x0c:
                continue
            selr = r.get("sel")
            if draw_waves:
                f.rect(x0c, top, x1c - x0c, lane_h,
                       BRIGHT if selr else DIM)
                peaks = r.get("peaks")
                half = (lane_h - 4) // 2
                for px in range(x0c + 1, x1c - 1):
                    pos = (px - x0) / max(1, x1 - x0)
                    if peaks:
                        amp = peaks[min(len(peaks) - 1,
                                        int(pos * len(peaks)))]
                    else:
                        amp = 0.3
                    hh = max(1, int(amp * half))
                    f.vline(px, mid - hh, hh * 2,
                            NORMAL if selr else MUTED)
            else:
                f.fill(x0c, top, x1c - x0c, lane_h,
                       MUTED if selr else DIM)
                if selr:
                    f.rect(x0c, top, x1c - x0c, lane_h, BRIGHT)
            # fades as corner diagonals at any zoom
            fi = tx(r["start"] + r.get("fade_in", 0.0)) - x0
            fo = x1 - tx(r["start"] + r["len"] - r.get("fade_out", 0.0))
            for i in range(min(fi, x1c - x0c)):
                y = bot - 1 - int(i / max(1, fi) * (lane_h - 2))
                f.point(x0 + i, y, BRIGHT if selr else NORMAL)
            for i in range(min(fo, x1c - x0c)):
                y = bot - 1 - int(i / max(1, fo) * (lane_h - 2))
                f.point(x1 - i, y, BRIGHT if selr else NORMAL)

        for a, b in zip(ordered, ordered[1:]):
            oa, ob = tx(b["start"]), tx(a["start"] + a["len"])
            if ob > oa:
                w = ob - oa
                for i in range(w):
                    y1 = bot - 1 - int(i / max(1, w - 1) * (lane_h - 2))
                    y2 = top + 1 + int(i / max(1, w - 1) * (lane_h - 2))
                    f.point(oa + i, y1, BRIGHT)
                    f.point(oa + i, y2, BRIGHT)

    ph = ed.get("playhead")
    if ph is not None and win0 <= ph <= win1:
        f.vline(tx(ph), ry, area_bot - ry, BRIGHT)

    g = sel.get("gain", 1.0) if sel else 1.0
    zoom_norm = 1.0 - min(1.0, span / 32.0)
    draw_encoder_bar(f, st, [
        {"norm": ed.get("move_norm", 0.5), "level": NORMAL, "text": "MOVE"},
        {"norm": zoom_norm, "level": NORMAL, "text": "ZOOM"},
        {"norm": (sel.get("fade_out", 0.0) / 2.0) if sel else 0,
         "level": NORMAL, "text": "XFADE"},
        {"norm": min(1.0, g / 2.0), "level": NORMAL, "text": "GAIN"},
    ])


RENDERERS = {"EDIT": page_edit, "WAVE": page_wave, "LOOP": page_loop, "MIX": page_mix, "FX": page_fx,
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
    import math as _m2
    def _pk(seed, n=64):
        return [abs(_m2.sin(i * 0.55 + seed)) *
                _m2.exp(-((i * 7 + seed * 13) % n) / (n * 0.8)) + 0.08
                for i in range(n)]
    st["edit"] = {
        "snap": "1/16", "playhead": 3.25, "window": (0.0, 8.0),
        "zoom_lanes": 3, "first_lane": 0,
        "lanes": [
            {"tag": "VX", "sel": True, "regions": [
                {"name": "VERSE A", "start": 0.0, "len": 1.9,
                 "fade_in": 0.05, "fade_out": 0.3, "peaks": _pk(1)},
                {"name": "FIX", "start": 2.1, "len": 1.2, "sel": True,
                 "fade_in": 0.25, "fade_out": 0.25, "gain": 1.1,
                 "peaks": _pk(2)},
                {"name": "VERSE B", "start": 3.1, "len": 2.4,
                 "fade_in": 0.3, "fade_out": 0.1, "peaks": _pk(3)},
                {"name": "TAG", "start": 6.0, "len": 1.5,
                 "fade_in": 0.05, "fade_out": 0.05, "peaks": _pk(4)},
            ]},
            {"tag": "G1", "regions": [
                {"name": "GTR", "start": 0.0, "len": 4.0,
                 "fade_in": 0.1, "fade_out": 0.1, "peaks": _pk(5)},
                {"name": "GTR2", "start": 4.0, "len": 4.0,
                 "fade_in": 0.1, "fade_out": 0.1, "peaks": _pk(6)},
            ]},
            {"tag": "MI", "regions": [
                {"name": "HOOK", "start": 1.0, "len": 2.0,
                 "fade_in": 0.1, "fade_out": 0.4, "peaks": _pk(7)},
                {"name": "HOOK2", "start": 2.7, "len": 2.0,
                 "fade_in": 0.4, "fade_out": 0.1, "peaks": _pk(8)},
            ]},
        ],
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
        {"db": "-9.0", "send_a": 0.1, "send_b": 0.35, "name": "AUX", "gain": 0.6, "level": 0.25, "peak": 0.33},
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
