"""Maschine MK1 encoder decoding.

The eleven knobs are NOT counters. Each one is a pair of analog channels -
two offset ramps, like a sine/cosine pair - and the absolute angle has to be
interpolated from both. The kernel's snd-usb-caiaq calls this `decode_erp`
(endless rotary potentiometer) and returns 0..999 for a full turn.

This project previously read the report as eleven big-endian 16-bit values
at sequential offsets and took the difference between frames as a delta.
That model is wrong in every part:

  * The values are two analog channels, so a 16-bit read of the pair is a
    meaningless number that changes constantly. It looked exactly like
    sensor noise, because it was two sensors read as one integer.
  * The bytes are NOT sequential. Knob 1 is bytes 21 and 20, knob 4 is
    bytes 3 and 2, VOLUME is 17 and 16 - scattered, and each pair is in
    (high, low) order with the SECOND byte first in the call.
  * There is no counter to diff. Position is absolute; a delta is the
    shortest way round the circle between two positions.

Byte offsets and the knob they belong to come from caiaq's own comments -
"4 under the left screen", "4 under the right screen", volume, tempo,
swing - which is also the only authority we have for which physical knob is
which.
"""

# decode_erp's constants, from sound/usb/caiaq/input.c.
HIGH_PEAK = 268
LOW_PEAK = -7
_RANGE = HIGH_PEAK - LOW_PEAK
DEG90 = _RANGE // 2
DEG180 = _RANGE
DEG270 = DEG90 + DEG180
DEG360 = DEG180 * 2
_MID = (HIGH_PEAK + LOW_PEAK) // 2

# Logical knob -> (byte_a, byte_b), as passed to decode_erp(a, b). Offsets
# are into the report body, i.e. AFTER the leading 0x02 report byte.
#
# Order here is the panel order the rest of this codebase uses: knobs 1-4
# under the left screen, 5-8 under the right, then the three master knobs.
ERP_BYTES = (
    (21, 20),   # knob 1   left screen
    (15, 14),   # knob 2
    (9, 8),     # knob 3
    (3, 2),     # knob 4
    (19, 18),   # knob 5   right screen
    (13, 12),   # knob 6
    (7, 6),     # knob 7
    (1, 0),     # knob 8
    (17, 16),   # VOLUME
    (11, 10),   # TEMPO
    (5, 4),     # SWING
)

N_ENCODERS = len(ERP_BYTES)
BODY_BYTES = 22          # caiaq refuses the report below this length
FULL_TURN = 1000         # decode_erp normalises to 0..999

NAMES = ("knob1", "knob2", "knob3", "knob4", "knob5", "knob6", "knob7",
         "knob8", "volume", "tempo", "swing")


def decode_erp(a, b):
    """Absolute position 0..999 from one encoder's two analog channels.

    A transcription of caiaq's decode_erp. The weighting is the point: near
    a channel's peak that channel carries almost no angular information, so
    each is weighted by how far it is from the midpoint and the two
    estimates are blended. Using either channel alone gives a position that
    is accurate over part of the turn and useless over the rest.
    """
    weight_b = abs(_MID - a) - (_RANGE // 2 - 100) // 2
    if weight_b < 0:
        weight_b = 0
    elif weight_b > 100:
        weight_b = 100
    weight_a = 100 - weight_b

    if a < _MID:
        # 0..90 and 270..360 degrees
        pos_b = b - LOW_PEAK + DEG270
        if pos_b >= DEG360:
            pos_b -= DEG360
    else:
        # 90..270 degrees
        pos_b = HIGH_PEAK - b + DEG90

    if b > _MID:
        # 0..180 degrees
        pos_a = a - LOW_PEAK
    else:
        # 180..360 degrees
        pos_a = HIGH_PEAK - a + DEG180

    ret = pos_a * weight_a + pos_b * weight_b
    ret = ret * 10 // DEG360
    if ret < 0:
        ret += FULL_TURN
    elif ret >= FULL_TURN:
        ret -= FULL_TURN
    return ret


def positions(report):
    """Decode a 0x02 report into eleven absolute positions, or None.

    `report` is the whole transfer including the leading 0x02.
    """
    body = report[1:]
    if len(body) < BODY_BYTES:
        return None
    return [decode_erp(body[a], body[b]) for a, b in ERP_BYTES]


def shortest_delta(prev, now, full=FULL_TURN):
    """Signed movement between two absolute positions on a circle.

    These are endless pots: 998 -> 2 is +4, not -996. Taking the plain
    difference makes every wrap look like a jump across the whole range,
    which on a mixer send is the difference between a nudge and a full
    sweep.
    """
    d = (now - prev) % full
    if d > full // 2:
        d -= full
    return d


class EncoderTracker:
    """Absolute positions in, movement out, with a deadband.

    The deadband is not optional. These are analog sensors sampled
    continuously: a knob nobody is touching reports positions that wander
    by a step or two, and without a floor every idle knob emits a stream of
    tiny deltas forever.
    """

    def __init__(self, deadband=3):
        self.deadband = deadband
        self.pos = [None] * N_ENCODERS

    def _emit_for_test(self, index, new_pos):
        """Feed one absolute position directly. Test hook: constructing
        analog channel pairs that decode to an exact angle is a puzzle, and
        the deadband logic is worth testing on its own."""
        prev = self.pos[index]
        d = shortest_delta(prev, new_pos)
        if abs(d) < self.deadband:
            return []
        self.pos[index] = new_pos
        return [(index, d, new_pos)]

    def update(self, report):
        """Returns [(index, delta, position)] for knobs that actually moved."""
        pos = positions(report)
        if pos is None:
            return []
        out = []
        for i, p in enumerate(pos):
            prev = self.pos[i]
            if prev is None:
                self.pos[i] = p
                continue
            d = shortest_delta(prev, p)
            if abs(d) < self.deadband:
                continue
            self.pos[i] = p
            out.append((i, d, p))
        return out
