#!/usr/bin/env python3
"""End-to-end interaction tests: press a control, check the screen.

Everything else in this suite tests one layer. test_panel renders states
nobody produced; the hub self-test routes events nobody draws. Between
them sits the only question a player actually asks - I pressed this, did
the right thing happen and does the screen show it - and nothing was
answering it.

So these drive the real chain, with no mocks except the OSC socket:

    input event -> Router -> command line -> Daw.command()
                -> Daw.ui_state() -> daw_ui.render() -> pixels

A test asserts on the pixels, not on the state dict, wherever the claim
is about what the player sees. State can be right while the view of it
is blank, and that failure is invisible to every other test here.

Two styles, deliberately:

  * reaction - the region that must change did change, and the regions
    that must not change did not. This catches a redraw that updates
    the number and forgets the meter, and a redraw that repaints half
    the screen when one strip moved.
  * appearance - the frame still obeys the panel's rules (5bpp, no
    collisions with the encoder strip, not blank). A page that reacts
    correctly and draws into the encoder labels is still broken.

Golden images are deliberately NOT used. They fail on every intentional
pixel change, so they get regenerated without being read, and after two
regenerations they assert only that the code does what it currently
does.
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "maschine"))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "daw"))
sys.path.insert(0, HERE)

import daw_ui                                              # noqa: E402
import ui                                                  # noqa: E402
import control_map                                         # noqa: E402
import maschine_hub_shim                                   # noqa: E402
import daw_ctl_shim                                        # noqa: E402


class FakeOsc:
    """Records what would have gone to Ardour."""

    def __init__(self):
        self.sent = []

    def send(self, path, *args):
        self.sent.append((path, args))


class Rig:
    """The instrument, wired the way it is on the board."""

    def __init__(self, rolling=True):
        self.osc = FakeOsc()
        self.daw = daw_ctl_shim.Daw(self.osc)
        self.router = maschine_hub_shim.Router()
        if rolling:
            # A looper quantises to a bar grid, so it needs a transport.
            # Recording with the transport stopped is a legitimate
            # refusal, tested separately - it is not the normal state to
            # test everything else in.
            self.daw.transport.update_from_export(1, 0, 0)

    # --- physical actions ---

    def press(self, button):
        self._apply(self.router.button(button, True))
        self._apply(self.router.button(button, False))

    def hold(self, button):
        self._apply(self.router.button(button, True))

    def release(self, button):
        self._apply(self.router.button(button, False))

    def hit_pad(self, index, velocity=100):
        self._apply(self.router.pad(index, velocity))
        self._apply(self.router.pad(index, 0))

    def turn(self, knob, delta):
        self._apply(self.router.knob(knob, delta))

    def _apply(self, events):
        for kind, payload in events:
            if kind == "cmd":
                self.daw.command(payload)

    # --- what the player sees ---

    def frame(self):
        st = self.daw.ui_state()
        st.setdefault("bpm", 120.0)
        st.setdefault("position", "001.1")
        st.setdefault("buttons_active", ())
        if self.router.mode != "MPC":
            st["pad_overlay"] = True
            st["pads"] = {
                "mode": self.router.mode,
                "rows": control_map.LOOP_PAD_ROWS,
                "grid": [[1] * 4 for _ in range(4)],
            }
        return daw_ui.render(st)


def lit_rows(frame, x0=0, x1=None):
    """Which rows have any lit pixel in a column band."""
    x1 = frame.w if x1 is None else x1
    return {y for y in range(frame.h)
            if any(frame.px[y * frame.w + x] for x in range(x0, x1))}


def region(frame, x0, y0, x1, y1):
    return tuple(frame.px[y * frame.w + x]
                 for y in range(y0, y1) for x in range(x0, x1))


class TestPageSwitching(unittest.TestCase):
    """A page button must change the page AND the screen."""

    def test_group_buttons_reach_every_page(self):
        for button, target in sorted(control_map.GROUPS.items()):
            if not target.startswith("daw:page:"):
                continue
            page = target.split(":")[-1]
            rig = Rig()
            before = rig.frame()
            rig.press(button)
            self.assertEqual(rig.daw.page, page, button)
            after = rig.frame()
            if page != "LOOP":          # LOOP is where we started
                self.assertNotEqual(bytes(before.px), bytes(after.px),
                                    "%s changed page to %s without "
                                    "changing the screen" % (button, page))

    def test_each_page_draws_its_own_thing(self):
        """No two pages may render identically - that would mean the page
        switch is cosmetic."""
        seen = {}
        for page in daw_ui.PAGES:
            rig = Rig()
            rig.daw.page = page
            seen[page] = bytes(rig.frame().px)
        self.assertEqual(len(set(seen.values())), len(seen),
                         "two pages render the same pixels")


class TestHoldModes(unittest.TestCase):
    """Hold-to-enter must be visible while held and gone after release."""

    def test_overlay_appears_while_held_and_leaves_after(self):
        rig = Rig()
        plain = bytes(rig.frame().px)
        rig.hold("pad_mode")
        held = bytes(rig.frame().px)
        self.assertNotEqual(plain, held,
                            "holding PAD MODE showed nothing on screen")
        rig.release("pad_mode")
        self.assertEqual(plain, bytes(rig.frame().px),
                         "the screen did not return after release")

    def test_pin_keeps_the_overlay_after_release(self):
        rig = Rig()
        rig.hold("pad_mode")
        held = bytes(rig.frame().px)
        rig.press(control_map.PIN_BUTTON)
        rig.release("pad_mode")
        self.assertEqual(rig.router.mode, "LOOP")
        self.assertEqual(held, bytes(rig.frame().px),
                         "PIN latched the mode but the screen dropped it")


class TestPadsDriveLanes(unittest.TestCase):
    """Column is lane, row is verb - and the lane must appear on screen."""

    def test_recording_a_lane_shows_it(self):
        rig = Rig()
        rig.hold("pad_mode")
        self.assertEqual(rig.daw.ui_state()["lanes"], [],
                         "a fresh rig should have no lanes drawn")
        rig.hit_pad(0)                       # row 0 = REC, column 0 = GTR1
        names = [l["name"] for l in rig.daw.ui_state()["lanes"]]
        self.assertIn("GTR1", names, "REC on pad 0 did not arm GTR1")

    def test_each_column_arms_its_own_lane(self):
        for col, lane in enumerate(["GTR1", "GTR2", "MIC", "AUX"]):
            rig = Rig()
            rig.hold("pad_mode")
            rig.hit_pad(col)
            names = [l["name"] for l in rig.daw.ui_state()["lanes"]]
            self.assertEqual(names, [lane],
                             "column %d armed %s, expected %s"
                             % (col, names, lane))

    def test_rec_with_a_stopped_transport_tells_the_player(self):
        """A refusal the screen does not show is a dead pad."""
        rig = Rig(rolling=False)
        rig.hold("pad_mode")
        before = bytes(rig.frame().px)
        rig.hit_pad(0)
        self.assertEqual(rig.daw.ui_state()["lanes"], [],
                         "armed a lane with no bar grid")
        self.assertTrue(rig.daw.message,
                        "the engine refused and said nothing")
        self.assertNotEqual(before, bytes(rig.frame().px),
                            "the refusal never reached the screen")

    def test_pads_do_not_touch_lanes_in_mpc_mode(self):
        """Without the mode held, pads belong to the instrument."""
        rig = Rig()
        rig.hit_pad(0)
        self.assertEqual(rig.daw.ui_state()["lanes"], [],
                         "an MPC pad hit leaked into the looper")


class TestKnobsMoveOneStrip(unittest.TestCase):
    """A knob must move its own strip and leave the neighbours alone."""

    def setUp(self):
        self.rig = Rig()
        self.rig.press("group_f")            # MIX
        self.assertEqual(self.rig.daw.page, "MIX")

    def test_knob_changes_its_strip_only(self):
        before = [m["db"] for m in self.rig.daw.ui_state()["mixer"]]
        self.rig.turn(0, +3)                 # knob 1 -> strip 1
        after = [m["db"] for m in self.rig.daw.ui_state()["mixer"]]
        differing = [i for i, (a, b) in enumerate(zip(before, after)) if a != b]
        self.assertEqual(len(differing), 1,
                         "one knob changed %d strips" % len(differing))

    def test_the_screen_shows_the_change_and_leaves_neighbours_alone(self):
        """The moved strip redraws; the strips beside it do not.

        Deliberately not "only one column band changed": MIX draws nine
        vertical strips across 255px, and the message line spans the
        whole width, so a correct redraw always touches more than one
        band. The claim that matters is narrower - a neighbour must not
        move when you did not touch it.
        """
        before = self.rig.frame()
        # Knob 1 is strip 1. One knob per strip: eight knobs under the
        # screens, eight strips. This used to read turn(4) because indices
        # 4-7 were remapped onto strips 0-3, which left strips 5-8 with no
        # knob at all.
        self.rig.turn(0, +5)
        after = self.rig.frame()
        self.assertNotEqual(bytes(before.px), bytes(after.px),
                            "turning a knob changed nothing on screen")

        # Rows above the message line, so the shared message band cannot
        # make a neighbour look repainted.
        strip_w = before.w // 9
        body = range(daw_ui.BODY_Y, daw_ui.ENCBAR_Y - 10)
        moved = [x for x in range(before.w)
                 if any(before.px[y * before.w + x] !=
                        after.px[y * after.w + x] for y in body)]
        self.assertTrue(moved, "the strip did not redraw in the body")
        self.assertLess(min(moved), strip_w * 2,
                        "the change landed away from strip 1")
        far = range(strip_w * 3, before.w)
        self.assertFalse([x for x in moved if x in far],
                         "turning strip 1 repainted distant strips")

    def test_opposite_turns_cancel(self):
        start = self.rig.daw.ui_state()["mixer"][0]["db"]
        self.rig.turn(0, +4)
        self.rig.turn(0, -4)
        self.assertEqual(self.rig.daw.ui_state()["mixer"][0]["db"], start,
                         "a knob is not symmetric")


class TestTransportReachesTheInstrument(unittest.TestCase):
    """Transport belongs to the MPC, and SHIFT reaches the second layer."""

    def test_play_is_midi_not_a_daw_command(self):
        rig = Rig()
        events = rig.router.button("play", True)
        self.assertEqual(events, [("midi", "mpc:play")])

    def test_shift_changes_what_a_control_does(self):
        rig = Rig()
        plain = rig.router.button("play", True)
        rig.router.button("shift", True)
        shifted = rig.router.button("play", True)
        self.assertNotEqual(plain, shifted,
                            "SHIFT did not change the transport action")


class TestFrameStaysLegal(unittest.TestCase):
    """Whatever the interaction, the frame obeys the panel's rules."""

    SEQUENCES = [
        ("mix and a knob", ["press:group_f", "turn:4:+3"]),
        ("fx page", ["press:group_g"]),
        ("song page", ["press:group_h"]),
        ("loop with a lane", ["hold:pad_mode", "pad:0", "release:pad_mode"]),
        ("pinned overlay", ["hold:pad_mode", "press:display1"]),
        ("two lanes", ["hold:pad_mode", "pad:0", "pad:1"]),
    ]

    def _run(self, steps):
        rig = Rig()
        for step in steps:
            kind, _, arg = step.partition(":")
            if kind == "press":
                rig.press(arg)
            elif kind == "hold":
                rig.hold(arg)
            elif kind == "release":
                rig.release(arg)
            elif kind == "pad":
                rig.hit_pad(int(arg))
            elif kind == "turn":
                knob, delta = arg.split(":")
                rig.turn(int(knob), int(delta))
        return rig

    def test_sequences_leave_a_legal_frame(self):
        gap = daw_ui.ENCBAR_Y - 3
        for name, steps in self.SEQUENCES:
            with self.subTest(sequence=name):
                f = self._run(steps).frame()
                self.assertEqual(len(f.px), 255 * 64, name)
                self.assertLessEqual(max(f.px), ui.MAX,
                                     "%s exceeded 5bpp" % name)
                self.assertGreater(sum(1 for p in f.px if p), 100,
                                   "%s rendered nearly blank" % name)
                lit = sum(1 for x in range(f.w) if f.px[gap * f.w + x])
                self.assertLess(lit, 60,
                                "%s draws into the encoder strip" % name)

    def test_no_sequence_wedges_the_router(self):
        """After any sequence the rig still responds to a page change."""
        for name, steps in self.SEQUENCES:
            with self.subTest(sequence=name):
                rig = self._run(steps)
                rig.release("pad_mode")
                rig.router.pinned = None
                rig.press("group_e")
                self.assertEqual(rig.daw.page, "LOOP",
                                 "%s left the surface unresponsive" % name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
