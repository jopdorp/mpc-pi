"""Maschine MK1 wire-protocol tests.

These cover the parts of the protocol that are silently wrong rather than
loudly broken: a button that never fires, a knob that moves the wrong
parameter, a pad row that lights mirrored. None of them raise, none of
them log, and all of them look like "the mapping is just different" when
you meet them on hardware.

Every expectation here is from shaduzlabs/cabl's MaschineMK1.cpp, which
is a working implementation. Where cabl looks like it has a typo, the
test asserts cabl's behaviour and says why - see the group-1 header
offset and the pad row order.
"""
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MASCHINE = os.path.join(os.path.dirname(HERE), "scripts", "maschine")
sys.path.insert(0, MASCHINE)


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(MASCHINE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


L = _load("mk1_leds", "mk1_leds.py")
HUB = _load("hub", "maschine-hub.py")
ENC = _load("mk1_encoders", "mk1_encoders.py")


class FakeRouter:
    def __init__(self):
        self.hits = []

    def button(self, name, down):
        self.hits.append(("btn", name, down))
        return []

    def pad(self, index, velocity):
        self.hits.append(("pad", index, velocity))
        return []

    def knob(self, index, delta):
        self.hits.append(("knob", index, delta))
        return []


def bare_mk1():
    """An Mk1 with decoder state but no USB device."""
    dev = HUB.Mk1.__new__(HUB.Mk1)
    dev.buttons = 0
    dev.encoders = [None] * 11
    dev.pad_state = [0] * 16
    dev.PAD_THRESHOLD = HUB.Mk1.PAD_THRESHOLD
    return dev


def ctrl_buttons(bits, status=0x80):
    """A button report.

    status defaults to 0x80 because that is what the hardware sends: an
    idle report reads 04 00 00 00 00 00 80 00. cabl gates on 0x40, which
    rejected every real report - silently, since a dropped report looks
    identical to a button nobody pressed.
    """
    b = bytearray(8)
    b[0] = 0x04
    b[1:7] = bits.to_bytes(6, "little")
    b[6] |= status
    return b


def ctrl_encoders(values):
    b = bytearray(64)
    b[0] = 0x02
    for i, v in enumerate(values):
        b[1 + i * 2] = (v >> 8) & 0xFF     # big-endian, high byte first
        b[2 + i * 2] = v & 0xFF
    return b


class TestButtons(unittest.TestCase):
    def test_play_is_reachable(self):
        """Play is bit 41, in byte 6.

        The decoder read data[1:6] - five bytes, bit positions 0..39 - so
        Play and NoteRepeat could not be pressed at all. On a transport
        controller that is the most important button on the panel.
        """
        dev = bare_mk1()
        r = FakeRouter()
        dev._ctrl(ctrl_buttons(1 << 41), r)
        self.assertIn(("btn", "play", True), r.hits)

    def test_note_repeat_is_reachable(self):
        dev = bare_mk1()
        r = FakeRouter()
        dev._ctrl(ctrl_buttons(1 << 40), r)
        self.assertIn(("btn", "note_repeat", True), r.hits)

    def test_validity_bit_is_not_a_button(self):
        """Byte 6 bit 6 is the validity gate - bit position 46 overall.

        It is set on every valid report, so if it were inside the button
        range it would read as a button held down forever.
        """
        dev = bare_mk1()
        r = FakeRouter()
        dev._ctrl(ctrl_buttons(0), r)
        self.assertEqual(r.hits, [])

    def test_hardware_status_bit_is_accepted(self):
        """0x80, as the device actually sends it."""
        dev = bare_mk1()
        r = FakeRouter()
        dev._ctrl(ctrl_buttons(1 << 41, status=0x80), r)
        self.assertIn(("btn", "play", True), r.hits)

    def test_cabl_status_bit_is_also_accepted(self):
        """0x40, as cabl documents it - accept either rather than guess."""
        dev = bare_mk1()
        r = FakeRouter()
        dev._ctrl(ctrl_buttons(1 << 41, status=0x40), r)
        self.assertIn(("btn", "play", True), r.hits)

    def test_status_bits_are_not_buttons(self):
        """They sit at bit positions 46 and 47, past the 42 names."""
        dev = bare_mk1()
        r = FakeRouter()
        dev._ctrl(ctrl_buttons(0, status=0xC0), r)
        self.assertEqual(r.hits, [])

    def test_invalid_report_is_dropped(self):
        dev = bare_mk1()
        b = bytearray(8)
        b[0] = 0x04
        b[1] = 0x01                    # a button set, but no status bit
        r = FakeRouter()
        dev._ctrl(b, r)
        self.assertEqual(r.hits, [])

    def test_button_table_is_complete(self):
        """42 buttons with bit 8 unused.

        Closing that gap once shifted every button from Rec onwards by
        one, so Shift pressed Grid.
        """
        names = HUB.control_map_buttons()
        self.assertEqual(len(names), 42)
        self.assertIsNone(names[8])
        self.assertEqual(names[9], "rec")
        self.assertEqual(names[41], "play")

    def test_missing_button_table_raises(self):
        """An unloadable map must not degrade to 'no buttons work'."""
        self.assertTrue(callable(HUB.control_map_buttons))
        names = HUB.control_map_buttons()
        self.assertTrue(names, "empty map should raise, not return []")


class TestEncoders(unittest.TestCase):
    """The encoders are analog pairs interpolated into an angle, not counters.

    The old tests here asserted a permutation of eleven sequential 16-bit
    wire slots, taken from cabl's processEncoders switch. That model was
    wrong at the root - there are no sequential 16-bit values - so the
    permutation described a layout the device does not have, and the tests
    passed while every knob did nothing.
    """

    def test_byte_map_matches_the_kernel(self):
        """Offsets are from caiaq's own per-knob comments."""
        self.assertEqual(ENC.ERP_BYTES[0], (21, 20))   # knob 1, left screen
        self.assertEqual(ENC.ERP_BYTES[3], (3, 2))     # knob 4
        self.assertEqual(ENC.ERP_BYTES[7], (1, 0))     # knob 8, right screen
        self.assertEqual(ENC.ERP_BYTES[8], (17, 16))   # VOLUME
        self.assertEqual(ENC.ERP_BYTES[9], (11, 10))   # TEMPO
        self.assertEqual(ENC.ERP_BYTES[10], (5, 4))    # SWING
        self.assertEqual(ENC.N_ENCODERS, 11)

    def test_byte_pairs_are_not_sequential(self):
        """The trap: assuming adjacent pairs decodes eleven wrong knobs."""
        flat = [b for pair in ENC.ERP_BYTES for b in pair]
        self.assertNotEqual(flat, list(range(22)))
        self.assertEqual(len(set(flat)), 22, "every byte used exactly once")

    def test_decode_erp_spans_the_full_turn(self):
        """Both channels sweeping must reach every part of the circle."""
        decades = {ENC.decode_erp(a, b) // 100
                   for a in range(0, 256, 4) for b in range(0, 256, 4)}
        self.assertEqual(decades, set(range(10)))

    def test_decode_erp_is_in_range(self):
        for a in range(0, 256, 8):
            for b in range(0, 256, 8):
                v = ENC.decode_erp(a, b)
                self.assertTrue(0 <= v < ENC.FULL_TURN, (a, b, v))

    def test_wrap_is_the_short_way_round(self):
        """998 -> 2 is +4. Plain subtraction makes it -996, which on a
        mixer send is a full sweep instead of a nudge."""
        self.assertEqual(ENC.shortest_delta(998, 2), 4)
        self.assertEqual(ENC.shortest_delta(2, 998), -4)
        self.assertEqual(ENC.shortest_delta(500, 520), 20)
        self.assertEqual(ENC.shortest_delta(520, 500), -20)

    def test_short_report_is_rejected(self):
        self.assertIsNone(ENC.positions(bytes([0x02]) + bytes(10)))
        self.assertIsNotNone(ENC.positions(bytes([0x02]) + bytes(22)))

    def test_tracker_primes_without_emitting(self):
        """The first report establishes position; it is not movement."""
        t = ENC.EncoderTracker()
        report = bytes([0x02]) + bytes(range(22))
        self.assertEqual(t.update(report), [])
        self.assertEqual(t.update(report), [])

    def test_tracker_deadband_suppresses_idle_jitter(self):
        """Analog sensors wander. Without a floor, every untouched knob
        emits a stream of one-step deltas forever."""
        t = ENC.EncoderTracker(deadband=3)
        t.pos = [500] * ENC.N_ENCODERS
        self.assertEqual(t._emit_for_test(0, 501), [])
        self.assertEqual(t._emit_for_test(0, 502), [])
        self.assertNotEqual(t._emit_for_test(0, 510), [])


def pad_report(pressures):
    """A realistic pad report: 31 pairs, each tagged with its pad index.

    A zero-filled buffer is NOT a valid fixture. Every pair decodes as
    pad = high nibble, so all-zeros reads as 31 consecutive samples of
    "pad 0 at pressure 0" - which releases any pad 0 hit placed in the
    first pair. The device always tags each slot, so the test data must
    too.
    """
    b = bytearray(64)
    for slot in range(31):
        pad = slot % 16
        p = pressures.get(pad, 0)
        b[1 + slot * 2] = (pad << 4) | ((p >> 8) & 0x0F)
        b[2 + slot * 2] = p & 0xFF
    return b


class TestPads(unittest.TestCase):
    def test_pressure_is_12_bit_across_the_pair(self):
        dev = bare_mk1()
        r = FakeRouter()
        dev._pads(pad_report({0: 4095}), r)
        self.assertEqual(len(r.hits), 1)
        kind, index, velocity = r.hits[0]
        self.assertEqual((kind, index), ("pad", 0))
        self.assertEqual(velocity, 127)  # 4095 >> 5, clamped to 127

    def test_pad_index_comes_from_the_high_nibble(self):
        dev = bare_mk1()
        r = FakeRouter()
        dev._pads(pad_report({11: 4095}), r)
        self.assertEqual([h[1] for h in r.hits], [11])

    def test_below_threshold_is_not_a_hit(self):
        dev = bare_mk1()
        r = FakeRouter()
        dev._pads(pad_report({0: 16}), r)   # 16, well under the 200 threshold
        self.assertEqual(r.hits, [])

    def test_release_fires_once_after_a_hit(self):
        dev = bare_mk1()
        dev._pads(pad_report({5: 3000}), FakeRouter())
        r = FakeRouter()
        dev._pads(pad_report({}), r)
        self.assertEqual(r.hits, [("pad", 5, 0)])


class TestLeds(unittest.TestCase):
    def test_table_is_62_entries(self):
        self.assertEqual(len(L.LED_ORDER), L.N_LEDS)
        self.assertEqual(len(set(L.LED_ORDER)), L.N_LEDS)

    def test_backlight_index(self):
        """If this moves, both screens go dark and it looks like the
        display protocol is broken."""
        self.assertEqual(L.LED_INDEX["DisplayBacklight"], 58)

    def test_pad_rows_are_reversed_on_the_wire(self):
        """cabl's order is Pad4,3,2,1 / Pad8,7,6,5 / ...

        Writing pads in natural order mirrors every row horizontally,
        which on a 4x4 grid reads as a mapping choice rather than a bug.
        """
        self.assertEqual(L.LED_ORDER[0:4], ("Pad4", "Pad3", "Pad2", "Pad1"))
        self.assertEqual(L.LED_ORDER[12:16],
                         ("Pad16", "Pad15", "Pad14", "Pad13"))

    def test_display_buttons_descend(self):
        self.assertEqual(L.LED_INDEX["DisplayButton8"], 49)
        self.assertEqual(L.LED_INDEX["DisplayButton1"], 56)

    def test_group_split_and_headers(self):
        """Group 1's header offset is 0x1E while its data starts at 31.

        That asymmetry is cabl's, and cabl works. Asserted so nobody
        'fixes' it from the armchair.
        """
        self.assertEqual(L.GROUP0_HEADER, (0x0C, 0x00))
        self.assertEqual(L.GROUP1_HEADER, (0x0C, 0x1E))
        bank = L.LedBank()
        blocks = list(bank.blocks(force=True))
        self.assertEqual([len(p) for _, p in blocks], [31, 31])

    def test_dirty_tracking_is_per_group(self):
        bank = L.LedBank()
        bank.flush(lambda ep, d: None)          # init sends both
        sent = []
        bank.set_pad(1, L.BRIGHT)
        bank.flush(lambda ep, d: sent.append(d[1]))
        self.assertEqual(sent, [0x00])          # group 0 only
        sent.clear()
        bank.backlight()
        bank.flush(lambda ep, d: sent.append(d[1]))
        self.assertEqual(sent, [0x1E])          # group 1 only
        sent.clear()
        bank.flush(lambda ep, d: sent.append(d[1]))
        self.assertEqual(sent, [])              # nothing changed

    def test_leds_go_to_the_generic_endpoint_not_the_display(self):
        self.assertEqual(L.EP_OUT, 0x01)
        self.assertNotEqual(L.EP_OUT, 0x08)

    def test_unknown_led_is_rejected(self):
        with self.assertRaises(KeyError):
            L.LedBank().set("Master", 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
