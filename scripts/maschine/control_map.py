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
# One rule, no cycling: **each mode has its own button, and holding that
# button is the mode.** Release and the pads are the MPC's again. There
# is nothing to step through and nothing to remember, because the panel's
# own printed labels say which button does what.
#
# Why hold rather than toggle: a held mode cannot be forgotten - the
# muscular effort is the reminder - so a performer can never look down
# mid-bar and wonder what the pads currently are. A latched mode can, and
# that is how you clear a loop while reaching for a kick drum.
#
# Latching still exists for when you want both hands free: hold the mode
# button and press Button 1, which the screen labels PIN. The button then
# stays lit until you press it again. That is Maschine's own idiom, and
# the gesture is self-documenting because the screen names it.
#
# Whenever a mode button is held, the screen draws that mode's 4x4 pad
# map over the current page, so you see what the pads mean *before* you
# hit one. Release restores the page underneath.

MODES = {
    "MPC": {
        "button": None,          # the resting state, nothing held
        "pads": "mpc",
        "help": "the MPC's own pads, banked by Group A-D",
    },
    "LOOP": {
        "button": "pad_mode",    # 1st-gen panels print this KEYBOARD
        "pads": "loops",
        "help": "hold PAD MODE: 4 lanes x REC/PLAY/STOP/CLEAR",
    },
    "MUTE": {
        "button": "mute",
        "pads": "mute",
        "help": "hold MUTE: each pad mutes its lane",
    },
    "SOLO": {
        "button": "solo",
        "pads": "solo",
        "help": "hold SOLO: each pad solos its lane",
    },
}
DEFAULT_MODE = "MPC"
PIN_BUTTON = "display1"          # held mode + this = latch, labelled PIN

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
    # WAVE is a drill-in editor, not a top-level page: SELECT + pad opens
    # the take under that pad, NAVIGATE opens the focused lane's take,
    # and BACK returns to wherever the performer came from.
    "WAVE": ("TRIM", "NORM", "UNDO", "BACK"),
    # EDIT is the track/arrangement editor: split at the playhead, step
    # region selection, and back out. Nudge, copy, paste, clear and undo
    # ride the MPC's printed shift-pad functions, which are exactly the
    # editing verbs - the silkscreen stays true.
    "EDIT": ("SPLIT", "PREV", "NEXT", "BACK"),
}

# Transport maps one-for-one onto the MPC's, because that is the muscle
# memory most worth preserving. SHIFT reaches the bar-level moves, which
# is also where the MPC puts them.
TRANSPORT = {
    # SHIFT+PLAY is STOP, not PLAY START. There was no stop anywhere on the
    # controller - the MK1 has no dedicated stop button, and the MPC's STOP key
    # was reachable from nothing, so a running sequence could only be stopped
    # from the emulator itself. PLAY START is not lost: RESTART already sends
    # it, which is what that button is for.
    "play":            ("mpc:play", "mpc:stop"),
    "rec":             ("mpc:record", "mpc:over_dub"),
    "erase":           ("mpc:erase", "mpc:undo"),
    # LOOP, not "restart": there is no button called restart on an MK1 - it is
    # not in MK1_BUTTONS - so this entry was unreachable and PLAY START could
    # not be pressed at all. LOOP is the natural home for "start from the top".
    "loop":            ("mpc:play_start", "mpc:go_to"),
    "transport_left":  ("mpc:step_left", "mpc:bar_left"),
    "transport_right": ("mpc:step_right", "mpc:bar_right"),
    "grid":            ("mpc:sixteen_levels", "mpc:full_level"),
    "shift":           ("modifier", None),
}

# Everything else the MK1 has. Twelve buttons that did nothing, and with them
# the MPC keys that had no way of being pressed - including the CURSOR, without
# which the machine's own UI cannot be navigated from the controller at all.
#
# The intent for some of these was already recorded in mpc-mk1-input.py's
# BUTTON_TO_KEYCODE (browse->main screen, sampling->sample, note repeat->after)
# but the hub reads THIS file, so that table was never wired to anything.
#
# Same (plain, shifted) shape as TRANSPORT.
PANEL = {
    # The cursor. BROWSE </> are the only left/right pair left on the panel,
    # and shift reaches up/down - the MPC's four arrows on two buttons.
    "browse_left":  ("mpc:left",       "mpc:up"),
    "browse_right": ("mpc:right",      "mpc:down"),
    # BROWSE is a file browser on both machines.
    "browse":       ("mpc:load",       "mpc:misc"),
    # SAMPLING is the MPC's sampler, and TRIM is where a sample goes next.
    "sampling":     ("mpc:sample",     "mpc:trim"),
    # CONTROL reaches the mixer, and the program it is mixing.
    "control":      ("mpc:mixer",      "mpc:program"),
    # STEP opens the MPC's WINDOW - the detail dialog for whatever field the
    # cursor is on - and shift confirms.
    "step":         ("mpc:window",     "mpc:enter"),
    # SNAP is timing: tap the tempo, or reach the sync settings.
    "snap":         ("mpc:tap_tempo",  "mpc:midi_sync"),
    # AUTO WRITE is performance state: mute a track, queue the next sequence.
    "auto_write":   ("mpc:track_mute", "mpc:next_seq"),
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
    # Hold-to-enter mode buttons; see MODES above. Each is momentary, and
    # each latches with + Button 1 (PIN).
    "pad_mode": "mode:LOOP",        # 1st-gen panels print this KEYBOARD
    "mute": "mode:MUTE",
    "solo": "mode:SOLO",
    "select": "daw:select",         # select without triggering
    "duplicate": "daw:duplicate",
    # NAVIGATE opens the track editor; from there SELECT+pad drills into
    # a single take's WAVE view.
    "navigate": "daw:page:EDIT",
    "pattern": "mpc:main_screen",
    "scene": "mpc:song",
    # NOTE REPEAT was unmapped, so the button did nothing and the MPC never
    # saw its AFTER key. On the 2000XL that key IS note repeat, and it is held
    # rather than toggled - which only works now that the hub sends a release.
    "note_repeat": "mpc:after",
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
# The MK1 has exactly eleven, in two physically distinct groups, and they
# map onto this instrument almost too neatly:
#
#   8 knobs under the screens (4 left, 4 right)  ->  the 8 mixer strips
#   3 master knobs (VOLUME / TEMPO / SWING)      ->  separate hardware
#
# Eight knobs, eight strips, and eight channels of the 22-channel USB
# interface. So a knob is a channel - no paging, no bank switching, no
# "which four am I on".
#
# This replaced a split where knobs 1-4 drove MPC-side controls and only
# 5-8 reached the mixer. That left LOOP, VERB, DLY and AUX with no knob,
# while four knobs duplicated controls the MPC's own front panel already
# has.
#
# The MPC-side controls move to SHIFT + knob, which is the right home for a
# second layer on a surface with no spare knobs.

KNOBS_LEFT = ("mpc:data_wheel", "mpc:note_variation", "mpc:rec_gain",
              "mpc:main_volume")

KNOBS_RIGHT_BY_PAGE = {
    "LOOP": "lane level",
    "MIX": "channel gain (buttons cycle gain / send A / send B)",
    "FX": "focused parameter bank (EQ: freq/gain/Q/type per band)",
    "SONG": "scrub",
    "WAVE": "trim start / trim end / zoom / gain",
    "EDIT": "move region / fade in / fade out / region gain",
}

# The three MASTER knobs are separate hardware, not a jog encoder, and they
# carry the three continuous controls that do not belong to a mixer strip:
#
#   VOLUME -> the DAW's master fader
#   TEMPO  -> the MPC's NOTE VARIATION slider
#   SWING  -> the MPC's DATA wheel
#
# That last one matters most. The DATA wheel is the MPC's primary value
# control - used constantly for browsing and entry - so it gets a dedicated
# physical knob rather than a modifier combination. Putting it on SHIFT +
# knob would make the most-used continuous control on the instrument
# two-handed.
#
# With DATA on its own knob, all eight under-screen knobs are free to be the
# eight DAW tracks, one each, and SHIFT is left unspent.
MASTER_KNOBS = {
    "volume": "daw:master",
    "tempo": "mpc:note_variation",
    "swing": "mpc:data_wheel",
}

def describe():
    """Human-readable dump, used by the docs and by bring-up."""
    out = []
    out.append("PAD MODES (hold the button; + Button 1 = PIN to latch):")
    for k, v in MODES.items():
        out.append("  %-5s %-9s %s" % (k, v["button"] or "(resting)",
                                       v["help"]))
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
