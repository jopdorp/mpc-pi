#!/usr/bin/env python3
"""What plugins sit on each track, in order.

Signal order is not a preference, it is how the instruments work: a
tuner reads the dry string before anything colours it, drive goes into
the amp rather than after it, the cab follows the amp because that is
what a cab does, and dynamics land after the cab so they act on the
finished tone. Getting this wrong sounds wrong in a way no parameter can
fix, so the order lives here once and the session template follows it.

Emitted as a JSON-able structure so both the Lua session builder and the
panel's FX page read the same chain definition — the chips drawn on the
FX page are literally this list.

    chains.py --self-test
    chains.py                 print the chains
"""
import os
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "maschine"))
import plugins                                            # noqa: E402


def _first_uri(kind, index=0):
    """The preferred URI for a role of this kind."""
    roles = plugins.role_for_kind(kind)
    if not roles:
        return None
    return roles[min(index, len(roles) - 1)]["uris"][0]


# Guitar: tuner first so it hears the dry string; overdrive into the amp;
# cab after the amp; EQ and compressor after the cab so they shape the
# finished tone rather than the raw pickup.
# No tuner slot. It used to sit first in every guitar chain, bypassed,
# and measurement made the case for removing it outright: at 190us per
# instance it was the most expensive plugin in the entire desk, and two
# of them came to 380us - a third of the whole quantum-48 budget - for
# something that is only wanted while a string is being tuned and is
# silent the rest of the time. Even bypassed it occupies a slot in a
# chain the panel navigates four at a time.
#
# The tuner is its own client now, tapping the input when TUNER mode is
# entered. That also frees it from the chain's constraints: it wants the
# dry signal, no latency compensation, and no obligation to run at the
# graph's quantum.
GUITAR = [
    {"name": "OD", "kind": "drive", "role": 0, "bypass": True,
     "why": "into the amp, never after it"},
    {"name": "AMP", "kind": "amp",
     "why": "the voicing; five combos selectable"},
    {"name": "CAB", "kind": "amp", "cab": True,
     "why": "guitarix models the cab as its own stage"},
    {"name": "EQ", "kind": "eq",
     "why": "shapes the finished tone, not the raw pickup"},
    {"name": "COMP", "kind": "comp", "bypass": True,
     "why": "after the cab so it acts on what you hear"},
]

# Vocal / mic: no amp, and the compressor comes before the EQ so the EQ
# is not chasing a moving level.
VOCAL = [
    {"name": "EQ", "kind": "eq", "why": "hi-pass out the room rumble"},
    {"name": "COMP", "kind": "comp",
     "why": "sidechain-capable; ducks against the MPC when wanted"},
    {"name": "DEESS", "kind": "eq", "bypass": True,
     "why": "a narrow band on the parametric does the job"},
]

# The MPC's own stereo out: light touch only. It is already a finished
# mix from the sampler's perspective.
MPC = [
    {"name": "EQ", "kind": "eq", "bypass": True, "why": "corrective only"},
]

# Master: multiband before the limiter, limiter last, always. The limiter
# is the last thing before the converters and nothing may follow it.
MASTER = [
    {"name": "MBAND", "kind": "multiband", "bypass": True,
     "why": "glue; off by default because it is easy to overdo"},
    {"name": "LIMIT", "kind": "limiter",
     "why": "last in the chain, always: nothing follows the ceiling",
     # Lookahead off. Measured on the board: this was the ONLY plugin in
     # the whole desk reporting any latency at all - 220 samples, 5.0ms
     # at 44.1k, which is nearly five times the entire quantum-48 period.
     # The master chain sits in the live monitor path, so that is delay
     # between a string being struck and the player hearing it, and it
     # costs no CPU so no DSP measurement would ever have shown it.
     # A lookahead limiter is a mastering tool; live, the ceiling is
     # worth a little overshoot to keep the instrument responsive.
     # Keyed by the parameter's LABEL, which is what the session
     # builder matches. LSP's lookahead is control index 15 today and
     # its symbol is "lk", but an index changes silently between plugin
     # releases and would then set the wrong control forever; a label
     # that stops matching sets nothing and says so.
     "params": {"Lookahead": 0.0}},
]

# Send buses.
FX_A = [{"name": "VERB", "kind": "reverb", "why": "Dragonfly hall"}]
FX_B = [{"name": "DELAY", "kind": "delay", "why": "tempo-synced"}]

# Modulation lives on the guitar tracks but off by default: it is a
# per-song choice, and an always-on chorus is how a rig starts sounding
# like a preset.
GUITAR_OPTIONAL = [
    {"name": "CHOR", "kind": "mod", "role": 0, "bypass": True},
    {"name": "FLNG", "kind": "mod", "role": 1, "bypass": True},
    {"name": "CHOP", "kind": "chop", "bypass": True},
]

CHAINS = {
    "MPC": MPC,
    "GTR1": GUITAR + GUITAR_OPTIONAL,
    "GTR2": GUITAR + GUITAR_OPTIONAL,
    "MIC": VOCAL,
    "AUX": VOCAL,
    "GTR1+": [], "GTR2+": [], "MIC+": [],      # overdub partners stay dry
    "FX A": FX_A,
    "FX B": FX_B,
    "MASTER": MASTER,
}


def resolve(chain, amp_engine="guitarix"):
    """Attach the preferred URI to every slot.

    `amp_engine` swaps only the amp slot. The cab slot stays either way:
    guitarix needs it because it models the cab separately, and NAM needs
    it because amp-only captures have no cab in them. That is why the
    engine is invisible downstream - the chain shape does not change.
    """
    assert amp_engine in plugins.AMP_ENGINES, amp_engine
    out = []
    for slot in chain:
        entry = dict(slot)
        if slot.get("cab"):
            amp = plugins.role_for_kind("amp")[0]
            entry["uri"] = amp.get("cab_uri")
        elif slot["kind"] == "amp" and amp_engine == "nam":
            entry["uri"] = plugins.NAM_URI
            entry["engine"] = "nam"
            # Lite is the default tier: the cheapest that still sounds
            # like the amp. quality_scale < 0.5 selects it.
            entry["params"] = {plugins.NAM_QUALITY_PORT:
                               0.0 if plugins.NAM_DEFAULT_TIER == "lite"
                               else 1.0}
        else:
            entry["uri"] = _first_uri(slot["kind"], slot.get("role", 0))
        # Slot-level params ride along, merged under any the engine
        # choice already set. Without this the manifest could declare a
        # setting - the limiter's lookahead, say - and the session would
        # build without ever applying it.
        if slot.get("params"):
            merged = dict(entry.get("params") or {})
            merged.update(slot["params"])
            entry["params"] = merged
        out.append(entry)
    return out


def self_test():
    # Every slot must resolve to a plugin under BOTH amp engines, or the
    # session would build a chain with a hole in it.
    for engine in plugins.AMP_ENGINES:
        for track, chain in CHAINS.items():
            for slot in resolve(chain, engine):
                assert slot["uri"], "%s/%s has no plugin under %s" % (
                    track, slot["name"], engine)

    # Swapping the engine must not change the chain's shape, or the FX
    # page's chips and the signal order would depend on the engine.
    for track, chain in CHAINS.items():
        a = [s["name"] for s in resolve(chain, "guitarix")]
        b = [s["name"] for s in resolve(chain, "nam")]
        assert a == b, "%s changes shape between engines: %s vs %s" % (
            track, a, b)

    # NAM captures are amp-only, so a cab must follow the amp slot.
    gtr = resolve(CHAINS["GTR1"], "nam")
    names = [s["name"] for s in gtr]
    assert names.index("CAB") == names.index("AMP") + 1, \
        "a NAM capture with no cab after it is only half an amp"

    # Order rules that matter sonically, asserted rather than trusted.
    g = [s["name"] for s in CHAINS["GTR1"]]
    # The tuner is deliberately NOT in the chain: it is a separate
    # client, so assert its absence rather than its position. It cost
    # 190us per instance - the most expensive plugin in the desk - to sit
    # bypassed in a chain waiting for someone to tune.
    assert "TUNE" not in g, "the tuner belongs outside the chain"
    assert g.index("OD") < g.index("AMP"), "drive goes into the amp"
    assert g.index("AMP") < g.index("CAB"), "the cab follows the amp"
    assert g.index("CAB") < g.index("EQ"), "EQ shapes the finished tone"
    m = [s["name"] for s in CHAINS["MASTER"]]
    assert m[-1] == "LIMIT", "nothing may follow the limiter"
    v = [s["name"] for s in CHAINS["MIC"]]
    assert v.index("COMP") > v.index("EQ") - 2, "hi-pass before dynamics"

    # The FX page draws at most four chips, so a chain longer than that
    # must still be navigable: PREV/NEXT page through it.
    longest = max(len(c) for c in CHAINS.values())
    assert longest <= 9, "chain too long to navigate four at a time"
    print("chains self-test PASS: %d tracks, longest chain %d, every slot "
          "resolves, signal order asserted" % (len(CHAINS), longest))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        for track, chain in CHAINS.items():
            if not chain:
                continue
            print("%-8s %s" % (track, " -> ".join(
                "%s%s" % (s["name"], "*" if s.get("bypass") else "")
                for s in chain)))
        print("\n* = present but bypassed by default")
