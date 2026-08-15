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

COLS = 8
COL_W = 31
COL_X = [i * 32 for i in range(COLS)]

HEADER_H = 10
FOOTER_Y = 53


# --- shared chrome ---------------------------------------------------


def draw_header(f, st):
    """Tab strip left, transport right. Identical on every page."""
    x = 1
    for name in PAGES:
        if name == st["page"]:
            x = f.text_inverted(x + 1, 1, name) + 3
        else:
            x = f.text(x + 1, 1, name, DIM) + 3

    # The MPC's own LCD sits immediately to the left and already shows
    # tempo and bar position, so repeating them here would spend this
    # screen's scarcest resource - width - on information the performer
    # can already see. The right side carries what only the DAW knows.
    x_right = 254

    # Xruns: a live rig needs to know it is glitching before the take is
    # ruined. Dim at zero so a healthy system stays quiet.
    xruns = st.get("xruns", 0)
    label = "XR%d" % xruns
    f.text_right(x_right, 1, label, BRIGHT if xruns else DIM)
    x_right -= f.text_width(label) + 6

    # A recording count, inverted, because arming the wrong lane is the
    # expensive mistake in live looping.
    recording = st.get("recording", 0)
    if recording:
        badge = "REC%d" % recording
        f.text_inverted(x_right - f.text_width(badge) + 1, 1, badge)
        x_right -= f.text_width(badge) + 6

    # The space the tempo used to occupy becomes a transient message
    # zone: confirmations ("LOOP1 ARMED"), warnings and undo feedback
    # appear here and fade, so the rig never needs a modal dialog that a
    # performer would have to dismiss mid-bar.
    msg = st.get("message")
    if msg:
        # Starts clear of the tab strip, which is 95px wide at most.
        zone_x = 100
        # Leave the transport glyph its 8px plus a gap on the right.
        width = max(0, x_right - zone_x - 16)
        if width > 0:
            f.text_center(zone_x, width, 1, msg[:width // 6], MUTED)

    # Shape carries transport state even when the eye is elsewhere.
    tx = x_right - 8
    if st.get("playing"):
        for i in range(6):
            f.vline(tx + i, 1 + i // 2, GLYPH_H - (i // 2) * 2, BRIGHT)
    else:
        f.fill(tx, 1, 2, GLYPH_H, MUTED)
        f.fill(tx + 4, 1, 2, GLYPH_H, MUTED)
    f.hline(0, HEADER_H, 255, DIM)


def draw_footer(f, labels, active=()):
    """Eight button labels, aligned to the eight hardware buttons."""
    f.hline(0, FOOTER_Y - 2, 255, DIM)
    for i, label in enumerate(labels[:COLS]):
        if not label:
            continue
        if i in active:
            f.fill(COL_X[i], FOOTER_Y - 1, COL_W, GLYPH_H + 3, MUTED)
            f.text_center(COL_X[i], COL_W, FOOTER_Y + 1, label, OFF)
        else:
            f.text_center(COL_X[i], COL_W, FOOTER_Y + 1, label, NORMAL)


def column_divider(f, i, top=HEADER_H + 2):
    """Separator between encoder columns. `top` lets a page keep its own
    full-width info row clear - a divider drawn through a header badge
    breaks the badge in half."""
    if i:
        f.vline(COL_X[i] - 1, top, FOOTER_Y - top - 3, DIM)


# --- LOOP ------------------------------------------------------------


def page_loop(f, st):
    draw_header(f, st)
    for i, lane in enumerate(st["lanes"][:COLS]):
        x = COL_X[i]
        column_divider(f, i)
        state = lane.get("state", "empty")
        name = lane.get("name", "-")[:5]

        if state == "empty":
            f.text_center(x, COL_W, 13, name, DIM)
            f.hline(x + 8, 30, COL_W - 16, DIM)
            continue

        # State lives in the name row, so the number below can mean the
        # same thing on every lane: recording is a bright block, overdub a
        # dimmer one, armed is outlined, playing is plain text.
        if state == "rec":
            f.fill(x, 12, COL_W, GLYPH_H + 3, BRIGHT)
            f.text_center(x, COL_W, 13, name, OFF)
        elif state == "dub":
            f.fill(x, 12, COL_W, GLYPH_H + 3, MUTED)
            f.text_center(x, COL_W, 13, name, OFF)
        elif state == "armed":
            f.rect(x, 12, COL_W, GLYPH_H + 3, NORMAL)
            f.text_center(x, COL_W, 13, name, NORMAL)
        else:
            f.text_center(x, COL_W, 13, name, NORMAL)

        # One meaning for the big number everywhere: bars until this lane
        # comes round. That is the question being asked mid-performance.
        remain = lane.get("bars_remaining")
        if remain is not None:
            # No caption: a large number under a lane name in a looper
            # reads as "bars left" once, and the 7 pixels a caption costs
            # are worth more as separation between the widgets below.
            f.text_center(x, COL_W, 23, str(remain), BRIGHT, scale=2)
        else:
            f.text_center(x, COL_W, 27, "WAIT", NORMAL)

        # Ticks (segmented) and level (continuous) sit apart so they never
        # read as one widget.
        f.progress_ticks(x + 3, 40, COL_W - 6,
                         lane.get("bars", 0), lane.get("bar", 0))
        f.meter(x + 3, 46, COL_W - 6, 3, lane.get("level", 0.0),
                BRIGHT if state in ("rec", "dub") else MUTED)

    active = tuple(i for i, l in enumerate(st["lanes"][:COLS])
                   if l.get("state") in ("rec", "dub"))
    draw_footer(f, [l.get("key", "") for l in st["lanes"][:COLS]], active)


# --- MIX -------------------------------------------------------------


def page_mix(f, st):
    draw_header(f, st)
    for i, ch in enumerate(st["mixer"][:COLS]):
        x = COL_X[i]
        column_divider(f, i)
        name = ch.get("name", "-")[:5]
        # Solo inverts the name, mute dims it: no extra row to collide
        # with the footer, and both states survive a glance.
        if ch.get("solo"):
            f.fill(x, 12, COL_W, GLYPH_H + 3, BRIGHT)
            f.text_center(x, COL_W, 13, name, OFF)
        else:
            f.text_center(x, COL_W, 13, name, DIM if ch.get("mute") else NORMAL)

        top, height = 24, 24
        # Fader: a thin track with a wide knob.
        track_x = x + 7
        f.vline(track_x, top, height, DIM)
        f.hline(track_x - 3, top + int(height * 0.25), 7, DIM)   # unity
        knob_y = top + int((1.0 - ch.get("gain", 0.8)) * (height - 3))
        f.fill(track_x - 4, knob_y, 9, 3, BRIGHT)

        # Meter: a solid column growing from the bottom - deliberately a
        # different shape from the fader so the two never trade places.
        mx = x + COL_W - 10
        level = ch.get("level", 0.0)
        f.rect(mx, top, 5, height, DIM)
        lit = int(level * (height - 2))
        if lit:
            f.fill(mx + 1, top + height - 1 - lit, 3, lit, BRIGHT)
        peak = ch.get("peak")
        if peak:
            f.hline(mx - 1, top + height - 1 - int(peak * (height - 2)), 7,
                    MUTED)

    # The eight buttons toggle mute for the strip above them, so the label
    # is the action and inversion is the state.
    draw_footer(f, ["MUTE"] * len(st["mixer"][:COLS]),
                tuple(i for i, c in enumerate(st["mixer"][:COLS])
                      if c.get("mute")))


MAXCLIP = BRIGHT


# --- FX --------------------------------------------------------------


def page_fx(f, st):
    draw_header(f, st)
    fx = st.get("fx", {})
    f.text(2, 13, fx.get("track", "-")[:6], BRIGHT)
    # Reserve the badge's width so a long plugin name truncates instead
    # of running underneath it.
    badge = "BYPASS" if fx.get("bypass") else "ACTIVE"
    badge_x = 254 - f.text_width(badge) - 3
    f.text(46, 13, fx.get("name", "-")[:(badge_x - 50) // 6], NORMAL)
    if fx.get("bypass"):
        f.text_right(254, 13, badge, MUTED)
    else:
        f.text_inverted(badge_x, 13, badge)
    f.hline(0, 22, 255, DIM)

    for i, p in enumerate(fx.get("params", [])[:COLS]):
        x = COL_X[i]
        column_divider(f, i, top=24)
        f.text_center(x, COL_W, 25, p.get("name", "-")[:5], DIM)
        # Value gets the emphasis, label stays quiet: the performer is
        # reading numbers here, not names.
        f.text_center(x, COL_W, 34, p.get("value", "-")[:5], BRIGHT)
        f.meter(x + 3, 45, COL_W - 6, 3, p.get("norm", 0.0), NORMAL)

    # Encoders already own the parameters above; the buttons are for
    # moving around the chain, so repeating the names here would waste
    # the only eight controls left.
    draw_footer(f, ["<TRK", "TRK>", "<FX", "FX>", "BYP", "PRE", "NEXT",
                    "SAVE"])


# --- SONG ------------------------------------------------------------


def page_song(f, st):
    draw_header(f, st)
    song = st.get("song", {})
    f.text(2, 13, "SEQ", DIM)
    f.text(24, 13, song.get("sequence", "-")[:12], BRIGHT)
    f.text_right(254, 13, "%d BARS" % song.get("bars", 0), MUTED)

    # Arrangement ribbon: the whole song across the screen with the
    # playhead on it, so position is spatial rather than numeric.
    top, height = 24, 14
    total = max(1, song.get("bars", 1))
    f.rect(1, top, 253, height, DIM)
    for seg in song.get("sections", []):
        sx = 1 + int(seg["start"] / total * 251)
        sw = max(2, int(seg["length"] / total * 251))
        f.fill(sx + 1, top + 1, sw, height - 2,
               BRIGHT if seg.get("current") else MUTED)
        if sw > 20:
            f.text(sx + 3, top + 4, seg.get("name", "")[:4],
                   OFF if seg.get("current") else NORMAL)
    head = 1 + int(song.get("position", 0) / total * 251)
    f.vline(head, top - 3, height + 6, BRIGHT)

    f.text(2, 44, "LOOPS", DIM)
    f.text(40, 44, "%d ON TIMELINE" % song.get("loops", 0), NORMAL)

    draw_footer(f, ["PREV", "NEXT", "ADD", "DEL", "", "", "SAVE", "QUIT"])


RENDERERS = {"LOOP": page_loop, "MIX": page_mix, "FX": page_fx,
             "SONG": page_song}


def render(st):
    f = Frame()
    RENDERERS[st["page"]](f, st)
    return f


# --- sample states for design review ---------------------------------


def sample_state(page):
    st = {"page": page, "playing": True, "bpm": 86.0, "position": "005.3",
          "recording": 1, "xruns": 0, "message": "GTR2 REC 2 BARS"}
    st["lanes"] = [
        {"name": "GTR1", "state": "play", "bars": 4, "bar": 3,
         "bars_remaining": 1, "level": 0.55, "key": "STOP"},
        {"name": "GTR2", "state": "rec", "bars": 4, "bar": 2,
         "bars_remaining": 2, "level": 0.82, "key": "REC"},
        {"name": "MIC", "state": "dub", "bars": 2, "bar": 1,
         "bars_remaining": 1, "level": 0.30, "key": "DUB"},
        {"name": "AUX", "state": "play", "bars": 8, "bar": 5,
         "bars_remaining": 3, "level": 0.12, "key": "STOP"},
        {"name": "L5", "state": "armed", "bars": 4, "bar": 0,
         "level": 0.0, "key": "ARM"},
        {"name": "L6", "state": "empty", "key": "REC"},
        {"name": "L7", "state": "empty", "key": "REC"},
        {"name": "L8", "state": "empty", "key": "REC"},
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
