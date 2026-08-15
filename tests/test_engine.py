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
    def setUp(self):
        self.r = maschine_hub_shim.Router()

    def test_transport_goes_to_the_mpc(self):
        self.assertEqual(self.r.button("play", True), [("midi", "mpc:play")])

    def test_shift_reaches_the_bar_moves(self):
        self.r.button("shift", True)
        self.assertEqual(self.r.button("play", True),
                         [("midi", "mpc:play_start")])

    def test_hold_is_the_mode(self):
        self.assertEqual(self.r.mode, "MPC")
        self.r.button("pad_mode", True)
        self.assertEqual(self.r.mode, "LOOP")
        self.assertEqual(self.r.pad(0, 100), [("cmd", "rec GTR1")])
        self.r.button("pad_mode", False)
        self.assertEqual(self.r.mode, "MPC")
        self.assertEqual(self.r.pad(0, 100), [("midi", "pad:0:100")])

    def test_pin_latches(self):
        self.r.button("pad_mode", True)
        self.r.button("display1", True)
        self.r.button("pad_mode", False)
        self.assertEqual(self.r.mode, "LOOP")

    def test_column_is_lane(self):
        self.r.button("pad_mode", True)
        # Row 1 is PLAY, column 2 is MIC.
        self.assertEqual(self.r.pad(6, 100), [("cmd", "play MIC")])


if __name__ == "__main__":
    unittest.main(verbosity=2)
