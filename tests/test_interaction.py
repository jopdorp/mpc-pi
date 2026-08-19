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

STRIP AND LANE NAMES COME FROM THE TABLES, never from a literal. This
file used to name MIC, GTR1 and AUX, and it stayed green through the
rename that replaced all three - it was testing a desk nobody owned. Ask
control_map and daw-ctl what things are called.
"""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "maschine"))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "daw"))
sys.path.insert(0, HERE)

import daw_ui                                              # noqa: E402
import mk1_encoders                                        # noqa: E402
import ui                                                  # noqa: E402
import control_map                                         # noqa: E402
import maschine_hub_shim                                   # noqa: E402
import daw_ctl_shim                                        # noqa: E402


# Which button opens which page. control_map.GROUPS is gone: the group row
# folded into the one flat per-surface table when the shift layer was
# removed, so there is nothing left for it to be separate from. Read the
# pages back out of the table that actually binds them.
PAGE_BUTTONS = {target.split(":")[-1]: button
                for button, target in control_map.DAW_BUTTONS.items()
                if target.startswith("daw:page:")}


def strip_button(name):
    """The display button that addresses a strip.

    D1-D7, in the mixer's own order, which is also the order of the knobs
    directly above them. Derived rather than written out so a rename - or a
    sixth loop track - moves the button with it.
    """
    return "display%d" % (control_map.MUTE_STRIPS.index(name) + 1)


class FakeOsc:
    """Records what would have gone to Ardour."""

    def __init__(self):
        self.sent = []

    def send(self, path, *args):
        self.sent.append((path, args))


class Rig:
    """The instrument, wired the way it is on the board."""

    def __init__(self, rolling=True, surface="MPC"):
        self.osc = FakeOsc()
        # A queue of its own. Closing a take appends region work to
        # /dev/shm/daw-region-queue by default, and a test run on the
        # appliance would hand a live session governor a punch-out - which
        # stops its transport. Tests drive the real reducer; they must not
        # reach the real rig.
        self.queue = os.path.join(tempfile.mkdtemp(), "queue")
        self.daw = daw_ctl_shim.Daw(self.osc, queue=self.queue)
        self.router = maschine_hub_shim.Router()
        if rolling:
            # A looper quantises to a bar grid, so it needs a transport.
            # Recording with the transport stopped is a legitimate
            # refusal, tested separately - it is not the normal state to
            # test everything else in.
            self.daw.transport.update_from_export(1, 0, 0)
        if surface == "DAW":
            self.to_daw()

    # --- physical actions ---

    def to_daw(self):
        """Point the panel at Ardour, by pressing the button that does it.

        Not `router.surface = "DAW"`: the toggle is a control like any
        other and can break like any other, and every DAW gesture below is
        unreachable if it does.
        """
        events = self.router.button(control_map.SURFACE_TOGGLE, True)
        assert events == [("surface", "DAW")], events
        self.router.button(control_map.SURFACE_TOGGLE, False)
        return self

    def press(self, button):
        self._apply(self.router.button(button, True))
        self._apply(self.router.button(button, False))

    def hold(self, button):
        self._apply(self.router.button(button, True))

    def release(self, button):
        self._apply(self.router.button(button, False))

    def press_strip(self, name):
        self.press(strip_button(name))

    def hit_pad(self, index, velocity=100):
        self._apply(self.router.pad(index, velocity))
        self._apply(self.router.pad(index, 0))

    def turn(self, knob, delta):
        self._apply(self.router.knob(knob, delta))

    def _apply(self, events):
        # Only "cmd" reaches daw-ctl. "midi" goes to the emulator and
        # "surface" is the router's own state; both are asserted where they
        # are produced, because there is nothing downstream of here that
        # could notice them.
        for kind, payload in events:
            if kind == "cmd":
                self.daw.command(payload)

    def midi(self, button):
        """What the MPC saw, without touching the DAW side.

        MPCPI_TAP_KEYS makes a press emit its own release immediately, so a
        press is one event or two depending on a setting; the keys are the
        claim.
        """
        events = self.router.button(button, True)
        self.router.button(button, False)
        return [payload for kind, payload in events if kind == "midi"]

    # --- what the player sees ---

    def frame(self):
        """Exactly what daw-ui-daemon draws: the state daw-ctl publishes.

        Nothing is patched in on the way. This used to synthesise a
        "pad_overlay" whenever a mode was held, back when a mode retargeted
        the pads and the screen had to show what the grid had become. Modes
        retarget the display buttons now, the pads never move, and no
        process anywhere sets that key - so a rig that added it was testing
        a screen the appliance cannot draw.
        """
        return daw_ui.render(self.daw.ui_state())


class ModeMixin:
    """Holding a mode is a chord on this panel: SHIFT+MUTE, or SOLO alone.

    Which of the two it is comes from control_map.MODES, so a mode that
    gains or loses its modifier does not need this file edited.
    """

    def hold_mode(self, rig, name):
        spec = control_map.MODES[name]
        if spec.get("shift"):
            rig.hold("shift")
        rig.hold(spec["button"])
        self.assertEqual(rig.daw.mode, name,
                         "%s did not reach daw-ctl" % name)

    def release_mode(self, rig, name):
        spec = control_map.MODES[name]
        rig.release(spec["button"])
        if spec.get("shift"):
            rig.release("shift")

    def held_modes(self):
        return [m for m, spec in control_map.MODES.items() if spec["button"]]


class TestPageSwitching(unittest.TestCase):
    """A page button must change the page AND the screen."""

    def test_group_buttons_reach_every_page(self):
        for page, button in sorted(PAGE_BUTTONS.items()):
            rig = Rig(surface="DAW")
            start = rig.daw.page
            before = rig.frame()
            rig.press(button)
            self.assertEqual(rig.daw.page, page, button)
            after = rig.frame()
            if page != start:
                self.assertNotEqual(bytes(before.px), bytes(after.px),
                                    "%s changed page to %s without "
                                    "changing the screen" % (button, page))

    def test_page_buttons_do_nothing_on_the_mpc_surface(self):
        """The toggle isolates the two instruments.

        A press can never land somewhere the player was not looking, which
        is the entire point of having a surface toggle rather than a panel
        where everything is always live.
        """
        for page, button in sorted(PAGE_BUTTONS.items()):
            rig = Rig()                      # MPC surface, where we start
            start = rig.daw.page
            rig.press(button)
            self.assertEqual(rig.daw.page, start,
                             "%s changed the DAW page from the MPC surface"
                             % button)

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

    def test_a_page_renders_before_anything_is_recorded(self):
        """An empty session is the state every set starts in.

        EDIT raised IndexError on an empty lane list, inside render(), which
        took daw-ui-daemon down and froze the right-hand screen on its last
        frame - from one press of a page button on a fresh session.
        """
        for page in daw_ui.PAGES:
            with self.subTest(page=page):
                rig = Rig()
                rig.daw.page = page
                self.assertEqual(rig.daw.ui_state()["lanes"], [])
                f = rig.frame()
                self.assertGreater(sum(1 for p in f.px if p), 100,
                                   "%s rendered nearly blank" % page)


class TestHeldModes(ModeMixin, unittest.TestCase):
    """Hold-to-enter must be visible while held and gone after release."""

    def test_mode_appears_while_held_and_leaves_after(self):
        """The screen has to name the mode, because nothing else does.

        This used to hold PAD MODE and expect a 4x4 map of what the pads had
        become. The pads do not become anything now - see
        docs/daw-interaction.md, invariant 1 - so what the player needs to
        see is which mode is engaged, which is the word in the status line.
        """
        for mode in self.held_modes():
            with self.subTest(mode=mode):
                rig = Rig(surface="DAW")
                plain = bytes(rig.frame().px)
                self.hold_mode(rig, mode)
                held = bytes(rig.frame().px)
                self.assertNotEqual(plain, held,
                                    "holding %s showed nothing on screen"
                                    % mode)
                self.release_mode(rig, mode)
                self.assertEqual(plain, bytes(rig.frame().px),
                                 "the screen did not return after release")

    def test_a_mode_does_not_latch(self):
        """There is no PIN.

        The latch existed because a mode owned the pads: the chord needed
        both hands, so you had to be able to put it down. A mode retargets
        seven display buttons now and the pads never move, so a latch would
        only be state nobody asked to read - and a mixer mode that outlives
        the finger holding it is how you clear a loop while reaching for a
        kick drum.
        """
        self.assertIsNone(control_map.PIN_BUTTON)
        for mode in self.held_modes():
            with self.subTest(mode=mode):
                rig = Rig(surface="DAW")
                self.hold_mode(rig, mode)
                self.release_mode(rig, mode)
                self.assertEqual(rig.daw.mode, control_map.DEFAULT_MODE)
                # And the row is a selector again, not a mute button.
                strip = control_map.MUTE_STRIPS[0]
                rig.press_strip(strip)
                self.assertEqual(rig.daw.focus, strip)

    def test_a_held_mode_reaches_the_strip_and_the_screen(self):
        """SHIFT+MUTE+Dn mutes strip n; SOLO+Dn solos it.

        A modifier over the focus model: it reaches any strip without
        moving focus, which is the whole reason it exists.
        """
        books = {"MUTE": "mutes", "SOLO": "solos"}
        for mode in self.held_modes():
            strip = control_map.MUTE_STRIPS[2]
            with self.subTest(mode=mode):
                rig = Rig(surface="DAW")
                focus = rig.daw.focus
                before = bytes(rig.frame().px)
                self.hold_mode(rig, mode)
                rig.press_strip(strip)
                self.release_mode(rig, mode)
                book = getattr(rig.daw, books[mode])
                self.assertTrue(book[strip], "%s %s did nothing" % (mode, strip))
                self.assertEqual(rig.daw.focus, focus,
                                 "the modifier moved focus as well")
                self.assertNotEqual(before, bytes(rig.frame().px),
                                    "a %s strip looks the same as a plain one"
                                    % mode.lower())

    def test_the_master_has_no_button_on_the_row(self):
        """Seven strips, seven free buttons, and the master is not one of
        them: soloing it does nothing and muting it kills the whole desk
        from a button beside the loop tracks."""
        self.assertNotIn("MASTER", control_map.MUTE_STRIPS)
        self.assertEqual(len(control_map.MUTE_STRIPS), 7)


class TestTheButtonRowDrivesLanes(ModeMixin, unittest.TestCase):
    """REC arms, a strip button punches - and the lane must appear on screen.

    This class used to press pads: row was the verb, column was the lane.
    The pads went back to the MPC and the verbs moved onto the row of
    buttons that already names the tracks, so the gestures changed and the
    claims did not.
    """

    def test_recording_a_lane_shows_it(self):
        rig = Rig(surface="DAW")
        self.assertEqual(rig.daw.ui_state()["lanes"], [],
                         "a fresh rig should have no lanes drawn")
        before = bytes(rig.frame().px)
        rig.press("rec")
        lane = daw_ctl_shim.LANES[0]
        rig.press_strip(lane)
        names = [l["name"] for l in rig.daw.ui_state()["lanes"]]
        self.assertIn(lane, names, "punching in did not arm %s" % lane)
        self.assertNotEqual(before, bytes(rig.frame().px),
                            "the armed lane never reached the screen")

    def test_each_button_arms_its_own_lane(self):
        for lane in daw_ctl_shim.LANES:
            with self.subTest(lane=lane):
                rig = Rig(surface="DAW")
                rig.press("rec")
                rig.press_strip(lane)
                names = [l["name"] for l in rig.daw.ui_state()["lanes"]]
                self.assertEqual(names, [lane],
                                 "%s armed %s" % (strip_button(lane), names))

    def test_punching_out_closes_the_take(self):
        """The same button closes it. One row, one modifier-free path."""
        rig = Rig(surface="DAW")
        lane = daw_ctl_shim.LANES[0]
        rig.press("rec")
        rig.press_strip(lane)
        self.assertIn(lane, rig.daw.rolling)
        rig.press_strip(lane)
        self.assertNotIn(lane, rig.daw.rolling,
                         "the second press did not punch out")

    def test_a_send_button_says_it_is_not_a_lane(self):
        """D1-D7 covers the sends, which cannot be recorded onto.

        A button that reads as broken is worse than one that refuses out
        loud, and the sends sit on the same row as the loop tracks.
        """
        sends = [n for n in control_map.MUTE_STRIPS
                 if n not in daw_ctl_shim.LANES]
        self.assertTrue(sends, "the desk has no sends on the strip row")
        rig = Rig(surface="DAW")
        rig.press("rec")
        before = bytes(rig.frame().px)
        rig.press_strip(sends[0])
        self.assertEqual(rig.daw.ui_state()["lanes"], [])
        self.assertIn(sends[0], rig.daw.message)
        self.assertNotEqual(before, bytes(rig.frame().px),
                            "the refusal never reached the screen")

    def test_rec_with_a_stopped_transport_tells_the_player(self):
        """A refusal the screen does not show is a dead button."""
        rig = Rig(rolling=False, surface="DAW")
        rig.press("rec")
        before = bytes(rig.frame().px)
        rig.press_strip(daw_ctl_shim.LANES[0])
        self.assertEqual(rig.daw.ui_state()["lanes"], [],
                         "armed a lane with no bar grid")
        self.assertTrue(rig.daw.message,
                        "the engine refused and said nothing")
        self.assertNotEqual(before, bytes(rig.frame().px),
                            "the refusal never reached the screen")

    def test_an_unarmed_button_selects_instead_of_recording(self):
        """Recording without REC lit is the one surprise a looper must
        never spring."""
        rig = Rig(surface="DAW")
        lane = daw_ctl_shim.LANES[1]
        rig.press_strip(lane)
        self.assertEqual(rig.daw.focus, lane)
        self.assertEqual(rig.daw.ui_state()["lanes"], [])

    def test_pads_never_reach_the_looper(self):
        """Invariant 1: the instrument never goes away.

        Every surface, every mode, armed or not. The pads used to BE the
        loop grid, so this test could only be written after they stopped
        being it - and it is the one that has to keep failing loudly if
        they are ever taken again.
        """
        for surface in ("MPC", "DAW"):
            modes = [None] + (self.held_modes() if surface == "DAW" else [])
            for mode in modes:
                with self.subTest(surface=surface, mode=mode):
                    rig = Rig(surface=surface)
                    if surface == "DAW":
                        rig.press("rec")     # armed, the worst case
                    if mode:
                        self.hold_mode(rig, mode)
                    sent = len(rig.osc.sent)
                    for pad in range(16):
                        rig.hit_pad(pad)
                    self.assertEqual(rig.daw.ui_state()["lanes"], [],
                                     "a pad hit leaked into the looper")
                    self.assertEqual(len(rig.osc.sent), sent,
                                     "a pad hit reached Ardour")


class TestKnobsMoveOneStrip(unittest.TestCase):
    """A knob must move its own strip and leave the neighbours alone."""

    # The encoders report an absolute angle normalised to one revolution, so
    # a delta is an angle, not a detent: a "+3" is three thousandths of a
    # turn and moves a fader by 0.04 dB, which is correctly invisible. A
    # quarter turn is what a hand does when it means to change something.
    QUARTER_TURN = mk1_encoders.FULL_TURN // 4

    def setUp(self):
        self.rig = Rig(surface="DAW")
        # The mixer is the LOOP page: MIX was merged into it when they
        # turned out to be one page with something missing from each half.
        self.rig.press(PAGE_BUTTONS["LOOP"])
        self.assertEqual(self.rig.daw.page, "LOOP")

    def test_knob_changes_its_strip_only(self):
        before = [m["db"] for m in self.rig.daw.ui_state()["mixer"]]
        self.rig.turn(0, self.QUARTER_TURN)  # knob 1 -> strip 1
        after = [m["db"] for m in self.rig.daw.ui_state()["mixer"]]
        differing = [i for i, (a, b) in enumerate(zip(before, after)) if a != b]
        self.assertEqual(len(differing), 1,
                         "one knob changed %d strips" % len(differing))
        self.assertEqual(differing[0], 0, "knob 1 moved another strip")

    def test_every_knob_has_a_strip(self):
        """Eight knobs, eight strips, no banking.

        Knobs 1-4 used to drive MPC-side controls and only 5-8 reached the
        mixer, so half the desk had no knob at all and four knobs duplicated
        the MPC's own front panel.
        """
        for i, strip in enumerate(daw_ctl_shim.STRIPS):
            rig = Rig(surface="DAW")
            rig.turn(i, self.QUARTER_TURN)
            moved = [m["name"] for m in rig.daw.ui_state()["mixer"]
                     if float(m["db"])]
            self.assertEqual(moved, [strip], "knob %d moved %s" % (i, moved))

    def test_the_screen_shows_the_change_and_leaves_neighbours_alone(self):
        """The moved strip redraws; the strips beside it do not.

        Deliberately not "only one column band changed": the message line
        spans the whole width, so a correct redraw always touches more than
        one band. The claim that matters is narrower - a neighbour must not
        move when you did not touch it.
        """
        before = self.rig.frame()
        # Knob 1 is strip 1. One knob per strip: eight knobs under the
        # screens, eight strips. This used to read turn(4) because indices
        # 4-7 were remapped onto strips 0-3, which left strips 5-8 with no
        # knob at all.
        self.rig.turn(0, self.QUARTER_TURN)
        after = self.rig.frame()
        self.assertNotEqual(bytes(before.px), bytes(after.px),
                            "turning a knob changed nothing on screen")

        # Rows above the message line, so the shared message band cannot
        # make a neighbour look repainted.
        strip_w = before.w // len(daw_ctl_shim.STRIPS)
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
        self.rig.turn(0, +self.QUARTER_TURN)
        self.rig.turn(0, -self.QUARTER_TURN)
        self.assertEqual(self.rig.daw.ui_state()["mixer"][0]["db"], start,
                         "a knob is not symmetric")


class TestTransportReachesTheInstrument(ModeMixin, unittest.TestCase):
    """The transport belongs to the MPC, on both surfaces."""

    def test_play_is_midi_not_a_daw_command(self):
        """And it stays that way with the panel pointed at Ardour.

        Binding PLAY to Ardour would fight the one clock the system agrees
        on, and leaving the mixer to stop the beat only sounds reasonable
        when you are not playing.
        """
        for surface in ("MPC", "DAW"):
            with self.subTest(surface=surface):
                rig = Rig(surface=surface)
                events = rig.router.button("play", True)
                self.assertEqual([k for k, _ in events if k == "cmd"], [])
                self.assertIn(control_map.ALWAYS["play"],
                              [p for k, p in events if k == "midi"])
                self.assertEqual(rig.osc.sent, [],
                                 "the transport reached Ardour")

    def test_the_one_modifier_changes_what_a_control_does(self):
        """SHIFT+MUTE is the only shifted button on the panel besides
        SHIFT+pad, and this is why it earns the exception.

        MUTE *is* STOP - the transport is panel-wide - so the mixer's mute
        moves under SHIFT rather than taking the key away. The old test here
        pressed SHIFT+PLAY and asserted a whole shift layer that no longer
        exists; this is the one surviving case, and it is a real one.
        """
        rig = Rig(surface="DAW")
        bare = rig.midi("mute")
        self.assertEqual(bare, [control_map.ALWAYS["mute"]],
                         "bare MUTE stopped being the transport's STOP")

        rig.hold("shift")
        shifted = rig.router.button("mute", True)
        self.assertNotEqual(bare, [p for k, p in shifted if k == "midi"],
                            "SHIFT did not change what MUTE does")
        self.assertEqual(shifted, [("cmd", "mode MUTE")])
        rig.release("mute")
        rig.release("shift")


class TestFrameStaysLegal(unittest.TestCase):
    """Whatever the interaction, the frame obeys the panel's rules."""

    LANE = daw_ctl_shim.LANES[0]
    OTHER = daw_ctl_shim.LANES[1]

    SEQUENCES = [
        ("the mixer and a knob", ["daw", "press:" + PAGE_BUTTONS["LOOP"],
                                  "turn:0:+250"]),
        ("fx page", ["daw", "press:" + PAGE_BUTTONS["FX"]]),
        ("song page", ["daw", "press:" + PAGE_BUTTONS["SONG"]]),
        # EDIT with nothing recorded raised inside render() and took the
        # screen daemon down, so it is a sequence rather than a page test.
        ("edit page on an empty session",
         ["daw", "press:" + PAGE_BUTTONS["EDIT"]]),
        ("a lane punched in", ["daw", "press:rec", "strip:" + LANE]),
        ("two lanes rolling",
         ["daw", "press:rec", "strip:" + LANE, "strip:" + OTHER]),
        ("a muted strip", ["daw", "hold:shift", "hold:mute", "strip:" + LANE,
                           "release:mute", "release:shift"]),
        ("pads while a mode is held",
         ["daw", "hold:solo", "pad:0", "pad:5", "release:solo"]),
        # The instrument, untouched: no DAW gesture at all.
        ("nothing but the MPC", ["pad:0", "press:play"]),
    ]

    def _run(self, steps):
        rig = Rig()
        for step in steps:
            kind, _, arg = step.partition(":")
            if kind == "daw":
                rig.to_daw()
            elif kind == "press":
                rig.press(arg)
            elif kind == "hold":
                rig.hold(arg)
            elif kind == "release":
                rig.release(arg)
            elif kind == "strip":
                rig.press_strip(arg)
            elif kind == "pad":
                rig.hit_pad(int(arg))
            elif kind == "turn":
                knob, delta = arg.split(":")
                rig.turn(int(knob), int(delta))
            else:
                raise AssertionError("unknown step %r" % step)
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
                # Let go of anything the sequence left held. There is no
                # latch to clear as well - modes end with the finger.
                for button in ("mute", "solo", "shift"):
                    rig.release(button)
                if rig.router.surface != "DAW":
                    rig.to_daw()
                rig.press(PAGE_BUTTONS["LOOP"])
                self.assertEqual(rig.daw.page, "LOOP",
                                 "%s left the surface unresponsive" % name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
