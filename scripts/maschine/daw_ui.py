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
except ImportError:  # running from the repo root
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    from ui import Frame, OFF, DIM, MUTED, NORMAL, BRIGHT, GLYPH_H

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
    labels = list(st.get("buttons", PAGES))
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
    draw_header(f, st)
    encoders = []
    for i, ch in enumerate(st["mixer"][:COLS]):
        x = COL_X[i]
        column_divider(f, i)
        name = ch.get("name", "-")[:5]
        if ch.get("solo"):
            f.fill(x, BODY_Y, COL_W, GLYPH_H + 3, BRIGHT)
            f.text_center(x, COL_W, BODY_Y + 1, name, OFF)
        else:
            f.text_center(x, COL_W, BODY_Y + 1, name,
                          DIM if ch.get("mute") else NORMAL)

        top, height = BODY_Y + 12, 14
        # A fader is a knob on a thin track; a meter is a solid column.
        # When both were thin vertical lines they swapped identities.
        track_x = x + 8
        f.vline(track_x, top, height, DIM)
        f.hline(track_x - 3, top + int(height * 0.25), 7, DIM)
        knob_y = top + int((1.0 - ch.get("gain", 0.8)) * (height - 3))
        f.fill(track_x - 4, knob_y, 9, 3, BRIGHT)

        mx = x + COL_W - 11
        level = ch.get("level", 0.0)
        f.rect(mx, top, 5, height, DIM)
        lit = int(level * (height - 2))
        if lit:
            f.fill(mx + 1, top + height - 1 - lit, 3, lit, BRIGHT)
        peak = ch.get("peak")
        if peak:
            f.hline(mx - 1, top + height - 1 - int(peak * (height - 2)), 7,
                    MUTED)

        encoders.append({"norm": ch.get("gain", 0.0), "level": NORMAL,
                         "text": name})
    draw_encoder_bar(f, st, encoders)


# --- FX --------------------------------------------------------------


def page_fx(f, st):
    draw_header(f, st)
    fx = st.get("fx", {})
    f.text(2, BODY_Y - 8, fx.get("track", "-")[:6], BRIGHT)
    badge = "BYPASS" if fx.get("bypass") else "ACTIVE"
    badge_x = 254 - f.text_width(badge) - 3
    f.text(46, BODY_Y - 8, fx.get("name", "-")[:(badge_x - 50) // 6], NORMAL)
    if fx.get("bypass"):
        f.text_right(254, BODY_Y - 8, badge, MUTED)
    else:
        f.text_inverted(badge_x, BODY_Y - 8, badge)

    encoders = []
    for i, prm in enumerate(fx.get("params", [])[:COLS]):
        x = COL_X[i]
        column_divider(f, i, top=BODY_Y + 2)
        f.text_center(x, COL_W, BODY_Y + 4, prm.get("name", "-")[:5], DIM)
        f.text_center(x, COL_W, BODY_Y + 14, prm.get("value", "-")[:5], BRIGHT)
        encoders.append({"norm": prm.get("norm", 0.0), "level": NORMAL,
                         "text": prm.get("value", "")[:5]})
    draw_encoder_bar(f, st, encoders)


# --- SONG ------------------------------------------------------------


def page_song(f, st):
    draw_header(f, st)
    song = st.get("song", {})
    f.text(2, BODY_Y, "SEQ", DIM)
    f.text(24, BODY_Y, song.get("sequence", "-")[:12], BRIGHT)
    f.text_right(254, BODY_Y, "%d BARS" % song.get("bars", 0), MUTED)

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
    draw_encoder_bar(f, st, [None] * COLS)


RENDERERS = {"LOOP": page_loop, "MIX": page_mix, "FX": page_fx,
             "SONG": page_song}


def render(st):
    f = Frame()
    RENDERERS[st["page"]](f, st)
    return f


# --- sample states for design review ---------------------------------


def sample_state(page):
    st = {"page": page, "playing": True, "bpm": 86.0, "position": "005.3",
          "recording": 1, "xruns": 0, "mode": "DAW",
          "message": "GTR2 LEVEL  -6.0 DB",
          "buttons": ("REC", "ARM", "UNDO", "PIN"),
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
    st["mixer"] = [
        {"name": "MPC", "gain": 0.80, "level": 0.62, "peak": 0.71},
        {"name": "GTR1", "gain": 0.65, "level": 0.44, "peak": 0.52},
        {"name": "GTR2", "gain": 0.70, "level": 0.05, "peak": 0.30},
        {"name": "MIC", "gain": 0.55, "level": 0.88, "peak": 0.96,
         "solo": True},
        {"name": "LOOP", "gain": 0.75, "level": 0.33, "peak": 0.40},
        {"name": "VERB", "gain": 0.40, "level": 0.20, "peak": 0.25},
        {"name": "DLY", "gain": 0.35, "level": 0.10, "peak": 0.18,
         "mute": True},
        {"name": "MSTR", "gain": 0.85, "level": 0.70, "peak": 0.80},
    ]
    st["fx"] = {
        "track": "GTR1", "name": "GUITARIX DRIVE", "bypass": False,
        "params": [
            {"name": "DRIVE", "value": "6.5", "norm": 0.65},
            {"name": "TONE", "value": "-2.0", "norm": 0.40},
            {"name": "LEVEL", "value": "0.0", "norm": 0.50},
            {"name": "LOW", "value": "+3.0", "norm": 0.65},
            {"name": "MID", "value": "-1.5", "norm": 0.42},
            {"name": "HIGH", "value": "+1.0", "norm": 0.55},
            {"name": "MIX", "value": "100", "norm": 1.00},
            {"name": "OUT", "value": "-3.0", "norm": 0.35},
        ],
    }
    st["song"] = {
        "sequence": "LT-BEAT", "bars": 32, "position": 12, "loops": 4,
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
