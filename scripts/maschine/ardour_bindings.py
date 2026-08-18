#!/usr/bin/env python3
"""Which Ardour operation every DAW-side control actually performs.

`control_map.py` says what a control *means* ("daw:page:LOOP", "lane
level"). This file says what daw-ctl *does* about it: the OSC path or Lua
call, and its argument. Keeping the two apart matters because the meaning
is a design decision and the binding is an interface detail - Ardour can
rename a path without the panel design changing.

Transport is deliberately absent: the Maschine's transport buttons drive
the **MPC**, not Ardour. Ardour's transport free-runs (see the design
doc's Synchronization section), so binding PLAY to Ardour would fight the
one clock the whole system agrees on.

Every OSC path below was verified present in this Ardour build:
    strings /usr/lib/ardour9/surfaces/libardour_osc.so

Addressing: OSC strip ids ("ssid") are 1-based positions in the surface's
bank. daw-ctl calls /set_surface/bank_size with the full strip count once
at startup so ssid is stable and equal to the mixer column index + 1 -
the same column the panel draws. One number means the same thing in the
UI, in the OSC layer and on the encoder.
"""

# The four encoders own a moving four-strip focus frame; FOCUS is its
# left edge, so knob k (0..3) addresses strip FOCUS + k.
KNOB_COUNT = 4


def ssid(strip_index):
    """Panel column index (0-based) -> OSC strip id (1-based)."""
    return strip_index + 1


# --- encoders ---------------------------------------------------------
#
# Each entry: what the knob turns, and the operation it performs. "delta"
# means the knob is endless and daw-ctl accumulates, then sends absolute -
# MK1 knobs report absolute position (~1000 steps/rev) so daw-ctl always
# has the true value and never needs a pickup mode.

KNOBS = {
    # page:  (label, operation, argument)
    "MIX": [
        ("gain", "osc", "/strip/gain {ssid} {db}",
         "-193..+6 dB; SHIFT gives 0.1 dB steps"),
    ] * KNOB_COUNT,
    "LOOP": [
        ("lane level", "osc", "/strip/gain {ssid} {db}",
         "the loop lane is an ordinary strip, so this is the same call"),
    ] * KNOB_COUNT,
    "FX": [
        ("plugin parameter", "osc",
         "/strip/plugin/parameter {ssid} {plugin} {param} {value}",
         "param index comes from /strip/plugin/descriptor at focus time"),
    ] * KNOB_COUNT,
    "SONG": [
        ("scrub", "osc", "/locate {samples} 0", "0 = do not roll"),
        ("zoom", "local", "daw-ctl view state", "no Ardour call"),
        ("section", "local", "daw-ctl view state", "no Ardour call"),
        (None, None, None, None),
    ],
    "WAVE": [
        ("trim start", "lua", "region:trim_front(pos)", None),
        ("trim end", "lua", "region:trim_end(pos)", None),
        ("zoom", "local", "daw-ctl view state", "no Ardour call"),
        ("gain", "lua", "region:set_scale_amplitude(gain)", None),
    ],
    "EDIT": [
        ("move", "lua", "region:set_position(pos)",
         "snapped by daw-ctl to the grid shown on screen"),
        ("zoom", "local", "daw-ctl view state", "no Ardour call"),
        ("crossfade", "lua", "region:set_fade_out_length(n)",
         "the neighbour's fade-in is set to match, so the overlap is "
         "symmetric unless SHIFT is held"),
        ("gain", "lua", "region:set_scale_amplitude(gain)", None),
    ],
}

# Sends live on a shift layer of the MIX encoders rather than their own
# page: two sends is not worth a page, and the strip already draws them.
KNOBS_SHIFTED = {
    "MIX": [("send A/B", "osc", "/strip/send_gain {ssid} {send} {db}",
             "SHIFT selects send A, SHIFT+BANK selects send B")]
           * KNOB_COUNT,
}

# --- buttons ----------------------------------------------------------
#
# Screen R's four buttons, per page. "engine" means the call goes to
# daw-ctl's own loop engine (daw_ctl.Engine), which owns bar quantisation
# and only then talks to Ardour - binding these straight to Ardour would
# lose the bar grid.

BUTTONS = {
    "LOOP": [
        ("REC", "engine", "rec <lane>",
         "arms to the next MPC bar line; the engine issues the Ardour "
         "rec-enable at the bar"),
        ("ARM", "osc", "/strip/recenable {ssid} {0|1}",
         "plain record-arm without the loop lifecycle"),
        ("UNDO", "engine", "undo <lane>",
         "drops the overdub layer's regions; Ardour's own undo is "
         "SHIFT+Pad 1, the MPC's printed UNDO"),
        ("PIN", "local", "latch the held pad mode", None),
    ],
    "MIX": [
        ("MUTE", "osc", "/strip/mute {ssid} {0|1}", None),
        ("SOLO", "osc", "/strip/solo {ssid} {0|1}", None),
        ("BANK", "local", "slide the four-strip focus frame",
         "purely a panel concept; the OSC bank stays whole so ssid never "
         "shifts under the UI"),
        ("PIN", "local", "latch the held pad mode", None),
    ],
    "FX": [
        ("BYP", "osc",
         "/strip/plugin/activate | /strip/plugin/deactivate {ssid} {plugin}",
         None),
        ("PREV", "local", "focus the previous chain slot", None),
        ("NEXT", "local", "focus the next chain slot", None),
        ("PIN", "local", "latch the held pad mode", None),
    ],
    "SONG": [
        ("PREV", "lua", "locate to the previous section marker", None),
        ("NEXT", "lua", "locate to the next section marker", None),
        ("MARK", "lua", "Session:locations():add_mark(pos)", None),
        ("PIN", "local", "latch the held pad mode", None),
    ],
    "WAVE": [
        ("TRIM", "lua", "apply the trim as a region bound", None),
        ("NORM", "lua", "region:normalize()", None),
        ("UNDO", "osc", "/access_action Editor/undo", None),
        ("BACK", "local", "return to the previous page", None),
    ],
    "EDIT": [
        ("SPLIT", "lua", "playlist:split_region(region, playhead)", None),
        ("PREV", "local", "select the previous region", None),
        ("NEXT", "local", "select the next region", None),
        ("BACK", "local", "return to the previous page", None),
    ],
}

# --- pads -------------------------------------------------------------

PADS = {
    "MPC": ("midi", "note on/off to the MPC's virmidi input",
            "never reaches Ardour"),
    "LOOP": ("engine", "rec/play/stop/clear <lane> for the pad's column",
             "row = verb, column = lane"),
    "MUTE": ("osc", "/strip/mute {ssid} {0|1}", "pad n mutes strip n"),
    "SOLO": ("osc", "/strip/solo {ssid} {0|1}", "pad n solos strip n"),
}

# --- the MPC's printed shift-pad functions ----------------------------
#
# These are honoured so the silkscreen stays true; the ones that are DAW
# operations map onto Ardour's editor actions.

SHIFT_PAD_BINDINGS = {
    "undo": ("osc", "/access_action Editor/undo"),
    "redo": ("osc", "/access_action Editor/redo"),
    "split": ("lua", "playlist:split_region(region, playhead)"),
    "copy": ("osc", "/access_action Editor/copy"),
    "paste": ("osc", "/access_action Editor/paste"),
    "clear": ("lua", "playlist:remove_region(region)"),
    "nudge_back": ("lua", "region:set_position(pos - snap)"),
    "nudge_fwd": ("lua", "region:set_position(pos + snap)"),
    "quantize": ("osc", "/access_action Editor/quantize"),
}

# Startup handshake: fix the bank so ssid == column index + 1 and ask for
# the feedback we actually consume (meters and fader positions drive the
# strips view).
SETUP = [
    "/set_surface/bank_size 0",        # 0 = all strips in one bank
    "/set_surface/gainmode 0",         # dB rather than 0..1 position
    "/set_surface/feedback 19",        # strip buttons + meters + fader
    "/set_surface/strip_types 159",    # audio, midi, busses, master
]


def describe():
    out = ["ENCODERS (knobs 5-8, under screen R)"]
    for page, entries in KNOBS.items():
        out.append("  %s" % page)
        for i, e in enumerate(entries):
            if not e or not e[0]:
                out.append("    knob %d  -" % (i + 5))
                continue
            label, kind, call, note = e
            out.append("    knob %d  %-16s %-5s %s" % (i + 5, label, kind, call))
    out.append("BUTTONS (5-8, above screen R)")
    for page, entries in BUTTONS.items():
        out.append("  %s" % page)
        for i, (label, kind, call, _n) in enumerate(entries):
            out.append("    btn %d   %-16s %-6s %s" % (i + 5, label, kind, call))
    out.append("PADS")
    for mode, (kind, call, note) in PADS.items():
        out.append("  %-5s %-6s %s" % (mode, kind, call))
    return "\n".join(out)


def self_test():
    pages = set(BUTTONS) | set(KNOBS)
    for page in pages:
        assert page in BUTTONS, "%s has no button bindings" % page
        assert page in KNOBS, "%s has no knob bindings" % page
        assert len(BUTTONS[page]) == KNOB_COUNT, page
        assert len(KNOBS[page]) == KNOB_COUNT, page
    # Every OSC path used must be one this build actually exposes.
    # Only the leading token of a call is a path; "/access_action
    # Editor/undo" carries an argument that merely looks like one.
    paths = set()

    def add(call):
        for token in call.split("|"):
            token = token.strip()
            if token.startswith("/"):
                paths.add(token.split()[0])

    for entries in list(KNOBS.values()) + list(BUTTONS.values()):
        for e in entries:
            if e and e[1] == "osc" and e[2]:
                add(e[2])
    for kind, call in SHIFT_PAD_BINDINGS.values():
        if kind == "osc":
            add(call)
    known = {"/strip/gain", "/strip/mute", "/strip/solo", "/strip/recenable",
             "/strip/send_gain", "/strip/plugin/parameter",
             "/strip/plugin/activate", "/strip/plugin/deactivate",
             "/locate", "/access_action"}
    unknown = paths - known
    assert not unknown, "unverified OSC paths: %s" % sorted(unknown)
    print("ardour-bindings self-test PASS: %d pages, %d OSC paths verified"
          % (len(pages), len(known & paths)))


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        print(describe())
