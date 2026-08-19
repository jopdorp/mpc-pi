#!/usr/bin/env python3
"""Loop engine, transport and control-plane tests.

These are the parts that decide when audio starts and stops, so their
bugs are musical rather than visual: a lane that arms half a bar late is
worse than one that looks wrong.
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "daw"))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "maschine"))

import control_map                                        # noqa: E402
import daw_ctl                                            # noqa: E402
import daw_ctl_clock                                      # noqa: E402
import osc                                                # noqa: E402
import chains                                             # noqa: E402
import maschine_hub_shim                                  # noqa: E402


class TestTransport(unittest.TestCase):
    def setUp(self):
        self.t = daw_ctl.Transport(rate=48000)
        self.t.bpm = 120.0

    def test_bar_length(self):
        self.assertEqual(self.t.samples_per_bar(), 96000)

    def test_bar_grid_from_export(self):
        # 4.5 bars elapsed puts the playhead half a bar past a line.
        self.t.update_from_export(1, 9000, 5_000_000)
        self.assertEqual(self.t.bar_anchor_number, 5)
        self.assertEqual(self.t.next_bar_sample(5_000_000), 5_048_000)

    def test_next_bar_is_inclusive(self):
        """A playhead exactly on a bar line must not skip a whole bar."""
        self.t.update_from_export(1, 0, 0)
        self.assertEqual(self.t.next_bar_sample(0), 0)
        self.assertEqual(self.t.next_bar_sample(1), 96000)

    def test_tempo_change_takes_effect(self):
        self.t.update_from_export(1, 0, 0)
        self.t.bpm = 86.0
        self.assertEqual(self.t.samples_per_bar(),
                         int(round(48000 * 60 / 86 * 4)))

    def test_stopped_transport_does_not_move_the_grid(self):
        self.t.update_from_export(1, 0, 0)
        anchor = self.t.bar_anchor_sample
        self.t.update_from_export(0, 50_000, 9_999_999)
        self.assertEqual(self.t.bar_anchor_sample, anchor,
                         "a stopped transport moved the bar grid")


class TestEngine(unittest.TestCase):
    def setUp(self):
        t = daw_ctl.Transport(rate=48000)
        t.bpm = 120.0
        t.update_from_export(1, 0, 0)
        self.eng = daw_ctl.Engine(t)
        self.eng.add_lane("LOOP1", bars=2)

    def test_arm_quantizes_to_the_bar(self):
        acts = self.eng.command("rec LOOP1", playhead=10_000)
        self.assertEqual(acts, ["arm LOOP1 at 96000"])
        self.assertEqual(self.eng.tick(50_000), [],
                         "recording started before the bar line")
        self.assertEqual(self.eng.tick(96_000), ["record-start LOOP1"])

    def test_finalize_is_whole_bars(self):
        self.eng.command("rec LOOP1", playhead=0)
        self.eng.tick(0)
        acts = self.eng.command("stop LOOP1", playhead=192_000)
        self.assertIn("finalize LOOP1 length 192000", acts)

    def test_repetitions_are_not_relaid(self):
        self.eng.command("rec LOOP1", playhead=0)
        self.eng.tick(0)
        self.eng.command("stop LOOP1", playhead=192_000)
        first = self.eng.tick(300_000)
        self.assertTrue(first and first[0].startswith("repeat"))
        self.assertEqual(self.eng.tick(300_000), [],
                         "the same region was laid twice")

    def test_undo_silences_the_lane(self):
        self.eng.command("rec LOOP1", playhead=0)
        self.eng.tick(0)
        self.eng.command("stop LOOP1", playhead=192_000)
        self.eng.command("undo LOOP1", playhead=0)
        self.assertEqual(self.eng.tick(400_000), [])

    def test_unknown_lane_reports_rather_than_raises(self):
        self.assertEqual(self.eng.command("rec NOPE", playhead=0),
                         ["error no-lane NOPE"])


class TestClock(unittest.TestCase):
    def test_midi_realtime_mid_message(self):
        """Realtime bytes are legal inside another message and must not
        confuse the counter."""
        bars = []
        t = daw_ctl_clock.ClockTracker(on_bar=lambda n: bars.append(n))
        t.feed([daw_ctl_clock.START], 0.0)
        dt = 60.0 / 120.0 / 24.0
        n = 0
        for i in range(96):
            t.feed([daw_ctl_clock.CLOCK], i * dt)
            n += 1
            if i == 5:
                t.feed([0x90], i * dt)      # note-on straddling a clock
                t.feed([60], i * dt)
        self.assertEqual(bars, [1])
        self.assertAlmostEqual(t.bpm, 120.0, delta=0.5)

    def test_stop_halts_counting(self):
        t = daw_ctl_clock.ClockTracker()
        t.feed([daw_ctl_clock.START], 0.0)
        t.feed([daw_ctl_clock.CLOCK], 0.01)
        t.feed([daw_ctl_clock.STOP], 0.02)
        before = t.clock_count
        t.feed([daw_ctl_clock.CLOCK], 0.03)
        self.assertEqual(t.clock_count, before)


class TestOsc(unittest.TestCase):
    def test_padding_rule(self):
        # A path already a multiple of four still takes a whole pad word.
        self.assertEqual(osc.encode("/abc"), b"/abc\0\0\0\0,\0\0\0")

    def test_argument_types(self):
        m = osc.encode("/strip/gain", 3, -6.0)
        self.assertIn(b",if\0", m)

    def test_rejects_unsupported(self):
        with self.assertRaises(TypeError):
            osc.encode("/x", None)


class TestChains(unittest.TestCase):
    def test_signal_order(self):
        g = [s["name"] for s in chains.CHAINS["GTR1"]]
        self.assertLess(g.index("OD"), g.index("AMP"))
        self.assertLess(g.index("AMP"), g.index("CAB"))
        self.assertEqual(chains.CHAINS["MASTER"][-1]["name"], "LIMIT")

    def test_engine_swap_keeps_shape(self):
        for track, chain in chains.CHAINS.items():
            a = [s["name"] for s in chains.resolve(chain, "guitarix")]
            b = [s["name"] for s in chains.resolve(chain, "nam")]
            self.assertEqual(a, b, track)

    def test_every_slot_resolves(self):
        for engine in ("guitarix", "nam"):
            for track, chain in chains.CHAINS.items():
                for slot in chains.resolve(chain, engine):
                    self.assertTrue(slot["uri"], "%s/%s" % (track, slot["name"]))


class TestRouting(unittest.TestCase):
    """What a control does, asserted against the tables that decide it.

    EVERY NAME HERE IS READ FROM control_map. A test that types "LOOP1" or
    "display1 mutes MIC" passes a rename that lands on only one side, which
    is exactly the failure this suite exists to catch - it happened once
    already, and the green test is what let it ship.
    """

    def setUp(self):
        self.r = maschine_hub_shim.Router()

    # --- helpers ---

    def keys(self, events):
        """The MPC keys a press produced, ignoring how it was delivered.

        MPCPI_TAP_KEYS makes a press emit its own release immediately, so
        one press is one event or two depending on a setting. Which key the
        MPC saw is the claim; whether the release rode along is TAP_KEYS'
        business and is asserted where that behaviour lives.
        """
        return [payload for kind, payload in events if kind == "midi"]

    def to_daw(self, router=None):
        """Move the panel onto the DAW surface, using the gesture that does
        it rather than assigning the attribute - the toggle is a control
        that can break like any other."""
        r = router or self.r
        self.assertEqual(r.button(control_map.SURFACE_TOGGLE, True),
                         [("surface", "DAW")])
        r.button(control_map.SURFACE_TOGGLE, False)
        return r

    def hold_mode(self, name, router=None):
        """Hold a mode the way the panel does, SHIFT included if it needs one."""
        r = router or self.r
        spec = control_map.MODES[name]
        if spec.get("shift"):
            r.button("shift", True)
        return r.button(spec["button"], True)

    def release_mode(self, name, router=None):
        r = router or self.r
        spec = control_map.MODES[name]
        out = r.button(spec["button"], False)
        if spec.get("shift"):
            r.button("shift", False)
        return out

    def assert_pads_reach_the_mpc(self, r, where):
        """A pad hit must always be addressed at the INSTRUMENT.

        There are two legal answers and no third: bare, the pad is a drum
        pad; with SHIFT held - which the SHIFT+MUTE chord means is held -
        it types one of the MPC's ten digits, which are its MODE keys. Both
        reach the machine. What must never happen is a ("cmd", ...): that
        is a pad that has been taken away and given to the mixer.
        """
        events = r.pad(6, 100)
        self.assertTrue(all(kind in ("midi", "midi_up") for kind, _ in events),
                        where)
        if r.shift:
            # A SHIFTED PAD IS A KEY, SO IT IS TAPPED: press and release
            # together, the release landing while SHIFT is still down, exactly
            # as the machine's own panel reports a number let go before its
            # modifier. It used to send the press alone, which latched a panel
            # key in the MPC for good.
            key = control_map.SHIFT_PADS[7]
            self.assertEqual(events, [("midi", key), ("midi_up", key)], where)
            self.assertEqual(r.pad(6, 0), [],
                             "%s: the pad release fired the key again" % where)
        else:
            self.assertEqual(events, [("midi", "pad:6:100")], where)

    # --- transport ---

    def test_transport_goes_to_the_mpc(self):
        self.assertEqual(self.keys(self.r.button("play", True)), ["mpc:play"])

    def test_transport_reaches_the_mpc_from_either_surface(self):
        """Invariant: leaving the mixer to stop the beat is not a thing.

        PLAY, STOP and RESTART are panel-wide. This used to be the opposite -
        the transport belonged to whichever surface was up - and the mixer
        could only be reached by giving up the ability to stop.
        """
        for name, key in control_map.ALWAYS.items():
            r = maschine_hub_shim.Router()
            self.assertEqual(self.keys(r.button(name, True)), [key], name)
            r.button(name, False)
            self.to_daw(r)
            # Including MUTE, which is the key the mixer would most like to
            # have back: bare it is STOP on both surfaces, and only the
            # SHIFT+MUTE chord means mute - see test_hold_is_the_mode.
            self.assertEqual(self.keys(r.button(name, True)), [key],
                             "%s stopped reaching the MPC on the DAW surface"
                             % name)

    def test_the_bar_move_has_its_own_button(self):
        """PLAY START is a button, not a shifted PLAY.

        This test used to press SHIFT+PLAY and expect mpc:play_start. There
        is no shift layer any more: SHIFT is the MPC's OWN shift key, held,
        so every shifted function on the machine works the way its panel
        prints it - and a second meaning for PLAY would be a chord to
        memorise rather than a label to read. The bar-level move that test
        cared about is still one press away, on the button the MK1 prints
        RESTART.
        """
        self.assertIn("mpc:play_start", control_map.ALWAYS.values())
        button = [b for b, t in control_map.ALWAYS.items()
                  if t == "mpc:play_start"][0]
        self.assertEqual(self.keys(self.r.button(button, True)),
                         ["mpc:play_start"])

    def test_shift_is_the_mpcs_own_shift_key(self):
        """It modifies our pad layer AND passes through to the machine.

        Held, not tapped: a modifier that taps is not a modifier. And it
        must not change what PLAY does, or the MPC would see SHIFT held and
        a different key than the player pressed.
        """
        self.assertEqual(self.r.button("shift", True),
                         [("midi", "mpc:shift")])
        self.assertTrue(self.r.shift)
        self.assertEqual(self.keys(self.r.button("play", True)), ["mpc:play"])
        self.r.button("play", False)
        # SHIFT+pad types the MPC's digits, which are also its MODE keys.
        self.assertEqual(self.keys(self.r.pad(0, 100)),
                         [control_map.SHIFT_PADS[1]])
        self.r.button("shift", False)
        self.assertFalse(self.r.shift)

    # --- modes ---

    def test_hold_is_the_mode(self):
        """Every mode is entered by HOLDING its own button, and leaves on
        release. Nothing cycles, so a mode can never be arrived at by
        accident or forgotten - the muscular effort is the reminder.

        The pads used to be what a mode retargeted; they are not, and the
        assertion below says so at every step.
        """
        self.to_daw()
        for name, spec in control_map.MODES.items():
            if not spec["button"]:
                continue                    # the resting state, nothing held
            with self.subTest(mode=name):
                self.assertEqual(self.r.mode, control_map.DEFAULT_MODE)
                self.assertEqual(self.hold_mode(name),
                                 [("cmd", "mode %s" % name)])
                self.assertEqual(self.r.mode, name)
                self.assert_pads_reach_the_mpc(
                    self.r, "%s took the pads away" % name)
                self.assertEqual(self.release_mode(name),
                                 [("cmd", "mode %s" % control_map.DEFAULT_MODE)])
                self.assertEqual(self.r.mode, control_map.DEFAULT_MODE)

    def test_a_mode_does_not_latch(self):
        """There is no PIN.

        This test used to hold the mode, press PIN, release, and require the
        mode to STAY. That latch existed because the mode owned the pads: a
        chord needed both hands, so you had to be able to put it down. Modes
        retarget seven display buttons now and the pads never move, so the
        latch would only be state nobody asked to read - and a latched mixer
        mode is how you clear a loop while reaching for a kick drum.
        """
        self.assertIsNone(control_map.PIN_BUTTON)
        self.to_daw()
        for mode in self.held_modes():
            with self.subTest(mode=mode):
                self.hold_mode(mode)
                self.assertEqual(self.r.mode, mode)
                self.release_mode(mode)
                self.assertEqual(self.r.mode, control_map.DEFAULT_MODE,
                                 "the mode outlived the button that holds it")

    # --- the pads ---

    def test_the_pads_are_always_the_mpcs(self):
        """Invariant #1 (docs/daw-interaction.md): mixing must never cost
        you the drums.

        The pads used to BE the loop grid - column is lane, row is verb -
        so reaching for a mixer mode took the instrument away mid-phrase.
        Both surfaces, every mode, both pad layers.
        """
        for surface in control_map.SURFACES:
            # The mixer modes live in DAW_BUTTONS, so the MPC surface has
            # only the resting state to be in - holding MUTE there is STOP,
            # which is the transport being panel-wide, not a mode.
            modes = (list(control_map.MODES) if surface == "DAW"
                     else [control_map.DEFAULT_MODE])
            for mode in modes:
                r = maschine_hub_shim.Router()
                if surface == "DAW":
                    self.to_daw(r)
                if control_map.MODES[mode]["button"]:
                    self.hold_mode(mode, r)
                    self.assertEqual(r.mode, mode,
                                     "%s could not be entered" % mode)
                self.assert_pads_reach_the_mpc(r, "%s/%s" % (surface, mode))

    # --- the display row: seven buttons, seven strips ---

    def test_a_display_button_is_a_strip(self):
        """Column is lane, as it always was - the column moved off the pads
        and onto the row of buttons that already names the tracks.

        Order is the mixer's own, which is also the order of the knobs
        directly above them, so the panel reads the same way top to bottom.
        """
        for i, strip in enumerate(control_map.MUTE_STRIPS):
            r = self.to_daw(maschine_hub_shim.Router())
            self.assertEqual(r.button("display%d" % (i + 1), True),
                             [("cmd", "focus %s" % strip)])

    def test_the_strip_row_runs_in_the_desks_own_order(self):
        """Display button n sits directly under knob n, so the row and the
        mixer must agree about which strip is where.

        Not a restatement of how MUTE_STRIPS is built: the claim is that
        the order SURVIVES, whatever it is built from. A hand-written or
        re-sorted list would put D1 under a different strip from knob 1
        while every other test here still passed, because they all ask the
        same table where things are.
        """
        positions = [control_map.STRIPS.index(n)
                     for n in control_map.MUTE_STRIPS]
        self.assertEqual(positions, sorted(positions),
                         "the strip buttons run in a different order from "
                         "the knobs above them")

    def held_modes(self):
        return [m for m, spec in control_map.MODES.items() if spec["button"]]

    def test_a_held_mode_retargets_the_display_row(self):
        for mode in self.held_modes():
            for i, strip in enumerate(control_map.MUTE_STRIPS):
                r = self.to_daw(maschine_hub_shim.Router())
                self.hold_mode(mode, r)
                with self.subTest(mode=mode, strip=strip):
                    self.assertEqual(
                        r.button("display%d" % (i + 1), True),
                        [("cmd", "%s %s" % (mode.lower(), strip))])

    def test_armed_display_buttons_punch_in_and_out(self):
        """REC arms, a strip button punches, the same button closes it.

        This is what the pad grid's REC/PLAY/STOP/CLEAR rows became. One
        row, one modifier-free path, and the instrument still under your
        hands throughout.
        """
        r = self.to_daw()
        strip = control_map.MUTE_STRIPS[1]
        button = "display%d" % (control_map.MUTE_STRIPS.index(strip) + 1)
        self.assertEqual(r.button("rec", True), [("cmd", "arm 1")])
        r.button("rec", False)
        self.assertEqual(r.button(button, True), [("cmd", "punch_in %s" % strip)])
        r.button(button, False)
        self.assertEqual(r.button(button, True), [("cmd", "punch_out %s" % strip)])
        r.button(button, False)
        self.assertEqual(r.button("rec", True), [("cmd", "arm 0")])
        r.button("rec", False)
        self.assertEqual(r.button(button, True), [("cmd", "focus %s" % strip)],
                         "disarming left the strip buttons punching")

    def test_a_knob_is_a_strip(self):
        """Eight knobs, eight strips, no banking - so knob n moves strip n.

        Knobs 1-4 used to drive MPC-side controls and only 5-8 reached the
        mixer, which left half the desk with no knob at all.
        """
        self.assertEqual(len(control_map.STRIPS), 8)
        for i, strip in enumerate(control_map.STRIPS):
            self.assertEqual(self.r.knob(i, +3),
                             [("cmd", "knob %s %s +3" % (self.r.page, strip))])


if __name__ == "__main__":
    unittest.main(verbosity=2)
