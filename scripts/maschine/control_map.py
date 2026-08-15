#!/usr/bin/env python3
"""What every Maschine MK1 control does, as data.

Design position: **the MPC keeps its identity.** An MPC2000XL player's
muscle memory has to survive, so the transport, the pads and the banks
map straight onto their MPC equivalents and the DAW is reached through a
mode rather than by stealing controls. Nothing here is a chord the player
has to memorise from a manual: every non-obvious mapping is either
printed on the MPC's own panel or drawn on screen.

Hardware facts this depends on (docs/maschine-mk1-display-protocol.md):
  * Buttons 1-4 and Knobs 1-4 belong to the LEFT display, 5-8 to the
    RIGHT. Screen L is the MPC, screen R is the DAW, so each side's
    controls serve the screen above/below them.
  * MK1 has no jog encoder and no encoder push-switch; the three MASTER
    knobs (VOLUME, TEMPO, SWING) are separate controls.
  * Pad LEDs are single-colour with brightness only, so pad state is
    carried by brightness and by the on-screen pad map, never by hue.
  * The panel shipped in two silkscreen revisions, so cabl's names are
    authoritative and the printed ones are noted where they differ.
"""

# --- modes -----------------------------------------------------------
#
# Momentary by default, latched only by an explicit, labelled gesture:
# hold the mode button and press Button 1, which the screen labels PIN.
# That is Maschine's own idiom, and it matters because a held mode cannot
# be forgotten - the muscular effort is the reminder - whereas a latched
# one is a mode error waiting for the moment attention is on the music.

MODES = {
    "MPC": {
        "pads": "mpc",
        "screen_r": "LOOP",
        "help": "pads play the MPC; the DAW keeps running underneath",
    },
    "LOOP": {
        "pads": "loops",
        "screen_r": "LOOP",
        "help": "pads are 4 lanes x 4 slots, laid out like the screen",
    },
    "MUTE": {
        "pads": "mute",
        "screen_r": "MIX",
        "help": "pads mute their lane; hold to preview, release to revert",
    },
}
DEFAULT_MODE = "MPC"

# --- pads ------------------------------------------------------------
#
# In MPC mode the 4x4 grid is the MPC's own, bank-switched by Group A-D,
# exactly as the hardware does it.
#
# In LOOP mode the grid reads as four columns of four, one column per
# lane - the same arrangement as the four screen columns directly above,
# and the same convention Akai's own Clip programs use. Column = lane is
# therefore true on the pads, on the screen and in the MPC's own idiom.

PAD_ROLE_MPC = "pad %d (bank %s)"
LOOP_PAD_ROWS = ("REC", "PLAY", "STOP", "CLEAR")

# --- buttons ---------------------------------------------------------
#
# The MPC has six soft keys under its LCD but only four buttons sit above
# that screen, so F5 and F6 move onto SHIFT. This is the one place the
# hardware genuinely cannot match the MPC one-for-one.

BUTTONS_LEFT = {
    "display1": ("mpc:soft1", "mpc:soft5"),
    "display2": ("mpc:soft2", "mpc:soft6"),
    "display3": ("mpc:soft3", None),
    "display4": ("mpc:soft4", "daw:pin"),
}

# Screen R's four buttons are contextual: the page decides. The labels
# are drawn in the cells directly under each button.
BUTTONS_RIGHT_BY_PAGE = {
    "LOOP": ("REC", "ARM", "UNDO", "PIN"),
    "MIX":  ("MUTE", "SOLO", "BANK", "PIN"),
    "FX":   ("BYP", "PREV", "NEXT", "PIN"),
    "SONG": ("PREV", "NEXT", "MARK", "PIN"),
}

# Transport maps one-for-one onto the MPC's, because that is the muscle
# memory most worth preserving. SHIFT reaches the bar-level moves, which
# is also where the MPC puts them.
TRANSPORT = {
    "play":            ("mpc:play", "mpc:play_start"),
    "rec":             ("mpc:record", "mpc:over_dub"),
    "erase":           ("mpc:erase", "mpc:undo"),
    "restart":         ("mpc:play_start", "mpc:go_to"),
    "transport_left":  ("mpc:step_left", "mpc:bar_left"),
    "transport_right": ("mpc:step_right", "mpc:bar_right"),
    "grid":            ("mpc:sixteen_levels", "mpc:full_level"),
    "shift":           ("modifier", None),
}

# Group A-D are the MPC's pad banks - a direct analogue, same letters.
# E-H select the DAW page, so the eight group buttons split cleanly into
# "which MPC bank" and "which DAW view" with nothing to remember.
GROUPS = {
    "group_a": "mpc:bank_a", "group_b": "mpc:bank_b",
    "group_c": "mpc:bank_c", "group_d": "mpc:bank_d",
    "group_e": "daw:page:LOOP", "group_f": "daw:page:MIX",
    "group_g": "daw:page:FX", "group_h": "daw:page:SONG",
}

# Mode buttons down the left of the pads. Their MPC-side equivalents are
# used where one exists so the button keeps meaning something familiar.
PAD_SECTION = {
    "pad_mode": "mode:cycle",       # 1st-gen panels print this KEYBOARD
    "mute": "mode:MUTE",
    "solo": "daw:solo",
    "select": "daw:select",         # select without triggering
    "duplicate": "daw:duplicate",
    "navigate": "daw:navigate",
    "pattern": "mpc:main_screen",
    "scene": "mpc:song",
}

# The MPC prints a shift function beside every pad. Honouring them costs
# nothing and means the printing on a real MPC panel stays true.
SHIFT_PADS = {
    1: "mpc:undo", 2: "daw:redo", 3: "daw:compare", 4: "daw:split",
    5: "daw:quantize", 6: "daw:quantize50", 7: "daw:nudge_back",
    8: "daw:nudge_fwd", 9: "daw:clear", 10: "daw:clear_automation",
    11: "daw:copy", 12: "daw:paste", 13: "mpc:semitone_down",
    14: "mpc:semitone_up", 15: "mpc:octave_down", 16: "mpc:octave_up",
}

# --- encoders --------------------------------------------------------
#
# Knobs 1-4 sit under the MPC screen and drive MPC-side continuous
# controls; the MPC's DATA wheel is the obvious home for Knob 1. Knobs
# 5-8 sit under the DAW screen and follow the page.

KNOBS_LEFT = ("mpc:data_wheel", "mpc:note_variation", "mpc:rec_gain",
              "mpc:main_volume")

KNOBS_RIGHT_BY_PAGE = {
    "LOOP": "lane level",
    "MIX": "channel gain",
    "FX": "plugin parameter",
    "SONG": "scrub",
}

# MK1's three MASTER knobs are separate hardware, not a jog encoder.
MASTER_KNOBS = {
    "volume": "appliance output level",
    "tempo": "mpc:tempo (via the DATA wheel on the tempo field)",
    "swing": "mpc:swing",
}


def describe():
    """Human-readable dump, used by the docs and by bring-up."""
    out = []
    out.append("MODES: " + ", ".join(
        "%s (%s)" % (k, v["help"]) for k, v in MODES.items()))
    out.append("TRANSPORT:")
    for name, (plain, shifted) in sorted(TRANSPORT.items()):
        out.append("  %-16s %-20s shift: %s" % (name, plain, shifted or "-"))
    out.append("GROUPS:")
    for name, target in sorted(GROUPS.items()):
        out.append("  %-10s %s" % (name, target))
    out.append("KNOBS 1-4 (MPC side): " + ", ".join(KNOBS_LEFT))
    out.append("KNOBS 5-8 (DAW side): " + ", ".join(
        "%s=%s" % (p, v) for p, v in KNOBS_RIGHT_BY_PAGE.items()))
    return "\n".join(out)


if __name__ == "__main__":
    print(describe())
