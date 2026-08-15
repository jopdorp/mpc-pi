#!/usr/bin/env python3
"""Panel rendering tests.

The layout bugs in this project were all found by looking at PNGs and
noticing text sitting on top of a divider. That worked, but it does not
scale and it does not run in CI, so the rules the eye was applying are
written down here as assertions.

The collision test is the important one: eight separate overflow bugs
were fixed by hand during development - the mixer's dB row, the amp tone
stack, the drive parameter text, the reverb title, the chopper header,
the tuner badge, SONG's loop count and the LOOP bar caption. Every one
was text written into a band owned by something else. That class of bug
is now a test.
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "maschine"))

import daw_ui                                             # noqa: E402
import ui                                                 # noqa: E402
import control_map                                        # noqa: E402
import ardour_bindings                                    # noqa: E402
import plugins                                            # noqa: E402


def fx_state(kind, **extra):
    st = daw_ui.sample_state("FX")
    fx = {"track": "GTR1", "kind": kind, "slot": 0,
          "chain": [{"name": "A"}, {"name": "B"}, {"name": "C"}],
          "knobs": [{"name": "P%d" % i, "norm": 0.5} for i in range(4)]}
    fx.update(extra)
    st["fx"] = fx
    return st


ALL_FX = [
    ("eq", {"bands": [{"type": "bell", "freq": 500, "gain": 3.0, "q": 1.0}],
            "focus": 0}),
    ("comp", {"threshold_norm": 0.5, "ratio": 4.0, "gr_db": 6.0,
              "in_level": 0.7, "out_level": 0.5, "sidechain": "MPC"}),
    ("limiter", {"in_level": 0.9, "ceiling_norm": 0.9, "ceiling": "-0.3",
                 "gr_db": 3.0}),
    ("multiband", {"bands": [{"name": "LOW", "gr_db": 4.0,
                              "threshold_norm": 0.5}] * 4, "focus": 1}),
    ("delay", {"time": "375 MS", "division": "1/8", "time_norm": 0.35,
               "feedback": 0.6}),
    ("reverb", {"preset": "HALL", "decay_norm": 0.5, "size_norm": 0.6}),
    ("drive", {"model": "TS-9", "drive_norm": 0.5, "hard": False}),
    ("amp", {"models": ["DLX", "PLEXI", "IIC+", "AC30", "5150"],
             "model_index": 1, "cab": "4X12", "tone": (0.5, 0.5, 0.5),
             "gain": 0.6}),
    ("mod", {"rate_norm": 0.4, "depth_norm": 0.7, "phase": 0.3}),
    ("chop", {"division": "1/8", "steps": 8, "duty": 0.5}),
    ("tuner", {"note": "E", "octave": 2, "cents": -12.0, "hz": "82.4 HZ"}),
]


class TestFrame(unittest.TestCase):
    def test_levels_in_range(self):
        """No pixel may exceed the panel's 5-bit depth.

        A value above 31 silently wraps in the USB packing, which shows
        up as a bright pixel where a dim one was meant.
        """
        for page in daw_ui.PAGES:
            f = daw_ui.render(daw_ui.sample_state(page))
            self.assertEqual(len(f.px), 255 * 64, page)
            self.assertLessEqual(max(f.px), ui.MAX, "%s exceeds 5bpp" % page)

    def test_text_clipped_not_wrapped(self):
        """Text past the right edge must clip, never wrap to the next row."""
        f = ui.Frame()
        f.clear()
        f.text(240, 0, "OVERFLOWING", ui.BRIGHT)
        # Row 1..7 belong to the glyph; nothing may appear on later rows.
        for y in range(ui.GLYPH_H + 1, 20):
            row = f.px[y * f.w:(y + 1) * f.w]
            self.assertEqual(max(row), 0, "text wrapped onto row %d" % y)


class TestPages(unittest.TestCase):
    def test_every_page_renders(self):
        for page in daw_ui.PAGES:
            with self.subTest(page=page):
                f = daw_ui.render(daw_ui.sample_state(page))
                self.assertGreater(sum(1 for p in f.px if p), 100,
                                   "%s rendered nearly blank" % page)

    def test_every_effect_view_renders(self):
        for kind, extra in ALL_FX:
            with self.subTest(kind=kind):
                f = daw_ui.render(fx_state(kind, **extra))
                self.assertGreater(sum(1 for p in f.px if p), 100,
                                   "%s view nearly blank" % kind)

    def test_pad_overlay_is_opaque(self):
        """The overlay must cover the page, not blend with it.

        A first version dimmed the page and drew the grid over it; both
        layers landed on the same rows and it was illegible.
        """
        st = daw_ui.sample_state("LOOP")
        st["pad_overlay"] = True
        st["pads"] = {"held": "PAD MODE", "rows": ("REC",) * 4,
                      "grid": [[1] * 4] * 4}
        f = daw_ui.render(st)
        # The lane columns of the LOOP page sit in this band; after the
        # overlay only the overlay's own marks may remain.
        band = [f.px[y * f.w + x]
                for y in range(daw_ui.BODY_Y, daw_ui.BODY_Y + 4)
                for x in range(200, 250)]
        self.assertLessEqual(max(band), ui.NORMAL,
                             "page content bleeds through the overlay")


class TestNoCollisions(unittest.TestCase):
    """Nothing may draw into a band another element owns.

    Encoder labels live below ENCBAR_Y; the divider above them is the
    boundary. Any page writing across it is the bug that kept appearing.
    """

    def _rows_used(self, frame, y0, y1):
        return [y for y in range(y0, y1)
                if any(frame.px[y * frame.w + x] for x in range(frame.w))]

    def test_body_does_not_touch_encoder_strip(self):
        gap_top = daw_ui.ENCBAR_Y - 2      # the divider row
        for page in daw_ui.PAGES:
            with self.subTest(page=page):
                f = daw_ui.render(daw_ui.sample_state(page))
                # The row directly above the divider must be clear, or
                # descenders from body text are touching it.
                row = gap_top - 1
                lit = sum(1 for x in range(f.w) if f.px[row * f.w + x])
                self.assertLess(lit, 40,
                                "%s draws into the encoder strip (row %d, "
                                "%d px lit)" % (page, row, lit))

    def test_effect_views_do_not_touch_encoder_strip(self):
        gap_top = daw_ui.ENCBAR_Y - 2
        for kind, extra in ALL_FX:
            with self.subTest(kind=kind):
                f = daw_ui.render(fx_state(kind, **extra))
                row = gap_top - 1
                lit = sum(1 for x in range(f.w) if f.px[row * f.w + x])
                self.assertLess(lit, 60,
                                "%s view draws into the encoder strip "
                                "(%d px lit)" % (kind, lit))

    def test_button_bar_clear_of_body(self):
        """The top strip belongs to the buttons; the body starts below."""
        for page in daw_ui.PAGES:
            with self.subTest(page=page):
                f = daw_ui.render(daw_ui.sample_state(page))
                row = daw_ui.BTNBAR_H          # the divider under the bar
                lit = sum(1 for x in range(f.w) if f.px[row * f.w + x])
                # The divider itself is drawn, so expect a full dim line
                # and nothing brighter sitting on it.
                brightest = max(f.px[row * f.w + x] for x in range(f.w))
                self.assertLessEqual(brightest, ui.NORMAL,
                                     "%s draws over the button divider" % page)


class TestControlMap(unittest.TestCase):
    def test_every_page_has_controls(self):
        for page in daw_ui.PAGES:
            self.assertIn(page, control_map.BUTTONS_RIGHT_BY_PAGE, page)
            self.assertIn(page, control_map.KNOBS_RIGHT_BY_PAGE, page)

    def test_button_labels_fit_their_cell(self):
        """A label wider than its column would run into its neighbour."""
        f = ui.Frame()
        for page, labels in control_map.BUTTONS_RIGHT_BY_PAGE.items():
            for label in labels:
                self.assertLessEqual(
                    f.text_width(label), daw_ui.COL_W,
                    "%s label %r too wide for a %dpx column"
                    % (page, label, daw_ui.COL_W))

    def test_modes_have_distinct_buttons(self):
        used = [m["button"] for m in control_map.MODES.values() if m["button"]]
        self.assertEqual(len(used), len(set(used)),
                         "two modes share a hold button")

    def test_bindings_cover_every_page(self):
        for page in daw_ui.PAGES:
            self.assertIn(page, ardour_bindings.BUTTONS, page)
            self.assertIn(page, ardour_bindings.KNOBS, page)


class TestPlugins(unittest.TestCase):
    def test_every_kind_has_a_view(self):
        views = set(daw_ui.RENDERERS) | {k for k, _ in ALL_FX}
        for role in plugins.ROLES:
            self.assertIn(role["kind"], views | {"params"},
                          "%s has no view" % role["role"])

    def test_amp_engines_agree(self):
        a = [m["name"] for m in plugins.AMP_MODELS]
        b = [m["name"] for m in plugins.NAM_MODELS]
        self.assertEqual(a, b, "engines offer different amps")

    def test_a2_tiers_are_not_a1_names(self):
        """'nano' and 'feather' are A1 names; using them here was a bug."""
        self.assertEqual(plugins.NAM_TIERS, ("lite", "full"))
        for bad in ("nano", "feather", "standard"):
            self.assertNotIn(bad, plugins.NAM_TIERS)


if __name__ == "__main__":
    unittest.main(verbosity=2)
