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
import os


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

# A MODE RETARGETS THE DISPLAY BUTTONS, NOT THE PADS.
#
# The pads stay wired to the MPC in every mode and on both surfaces. That is
# the point: you can keep playing while you mix, and the instrument never goes
# quiet because the panel is in a mixer mode. Modes used to steal the grid -
# hold MUTE and the pads became strip selectors - which meant reaching for the
# mixer took the drums away.
#
# Seven strips need muting and there are exactly seven display buttons free,
# because display8 is the surface toggle and the master needs neither: soloing
# it does nothing and muting it kills the whole desk from a button beside the
# loop tracks.
MODES = {
    "MPC": {
        "button": None,          # the resting state, nothing held
        "pads": "mpc",
        "help": "the MPC's own pads, banked by Group A-D",
    },
    "MUTE": {
        # SHIFT + MUTE. The bare key is STOP on both surfaces now, so the
        # mixer's mute moves under SHIFT rather than fighting it. SOLO needs
        # no modifier - nothing else wants that key.
        "button": "mute",
        "shift": True,
        "pads": "mpc",
        "help": "hold SHIFT+MUTE: display 1-7 mute LOOP1..REVERB",
    },
    "SOLO": {
        "button": "solo",
        "pads": "mpc",
        "help": "hold SOLO: display 1-7 solo LOOP1..REVERB",
    },
}
DEFAULT_MODE = "MPC"
PIN_BUTTON = "group_f"           # held mode + this = latch, labelled PIN
                                 # (was display1, which is now LOOP1's
                                 #  mute button; group_f came free when
                                 #  the MIX page was merged into LOOP)

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
# The loop verbs. No longer a pad grid - the pads stay the MPC's - so these
# ride the page's own REC and ARM buttons instead.
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
    # One strips page, so these four no longer change underneath the hand.
    # MUTE and SOLO are absent on purpose: they have their own dedicated
    # buttons on the panel, and duplicating them here spent two of the four
    # slots on controls that were already reachable.
    # BANK is absent because there is nothing to bank - all eight knobs
    # address all eight strips at once.
    "LOOP": ("REC", "ARM", "UNDO", "PIN"),
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
# WHICH INSTRUMENT THE PANEL DRIVES.
#
# The MPC has six function keys and the MK1 has eight display buttons, so the
# top-right one is spare on the MPC side and is the obvious home for "what am I
# controlling". DISPLAY 8 toggles it and lights its own LED in DAW mode.
# THE DESK, in knob order: five individual loop tracks, delay, reverb, master.
#
# One place to rename them. session-template.lua builds the same names from
# MPCPI_STRIPS/MPCPI_SENDS and must agree with this list - a knob pointed at a
# strip that does not exist moves nothing and reports nothing, so a rename that
# only lands on one side fails silently.
def _names(env, fallback):
    """Read a comma-separated name list from the environment.

    Same env vars and same defaults as session-template.lua's names_from, so
    ONE setting renames the desk on both sides at once. Set
    MPCPI_STRIPS=DRUMS,BASS,KEYS,GTR,VOX in the unit and the panel, the
    session and daw-ctl all agree without touching source.
    """
    v = os.environ.get(env, "").strip()
    if not v:
        return list(fallback)
    return [w.strip() for w in v.split(",") if w.strip()]


# Five loop tracks, two sends, master - eight names for eight knobs.
STRIPS = (_names("MPCPI_STRIPS", ["LOOP1", "LOOP2", "LOOP3", "LOOP4", "LOOP5"])
          + _names("MPCPI_SENDS", ["DELAY", "REVERB"])
          + ["MASTER"])


# The strips the display buttons address while MUTE or SOLO is held, in button
# order: display1 is the first, display7 the last. Master is absent on purpose -
# see MODES. Derived, so renaming or resizing the desk carries through.
MUTE_STRIPS = [n for n in STRIPS if n != "MASTER"]

# BUTTONS THAT REACH THE MPC ON BOTH SURFACES.
#
# The instrument never goes away. The pads already work like this; transport
# joins them, because having to leave the mixer to stop the beat is the kind of
# thing that only reads as reasonable when you are not playing.
#
# REC is deliberately NOT here. On the MPC surface it is the MPC's record; on
# the DAW surface it arms loop recording, which is the verb that button means
# in both worlds. MPC sequences get recorded from the MPC surface.
ALWAYS = {
    "play": "mpc:play",
    "mute": "mpc:stop",
    "loop": "mpc:play_start",
}

SURFACE_TOGGLE = "display8"
SURFACES = ("MPC", "DAW")


# ONE FUNCTION PER BUTTON. No shift layer.
#
# The MK1 has 41 buttons and the MPC needs 35 keys that are not digits, so
# there is no reason to hide anything behind a modifier - and every reason not
# to. SHIFT on this panel is a real MPC key as well as our modifier, so a
# "shift+shift" does not exist, and a shifted binding is a binding you have to
# remember rather than read.
#
# The ONLY shift layer is SHIFT+pad, which types the MPC's ten digits. Those
# ten keys are the MPC's mode keys too - its panel prints "1 SONG", "2 MISC" -
# so putting them on the pads reaches both without spending a button on either.
#
# Where the MK1's own printed label matches an MPC idea, it wins: NOTE REPEAT
# prints TAP TEMPO above it, so that is what it sends.
MPC_BUTTONS = {
    # --- the six soft keys under the LCD, and the two spare display buttons --
    "display1":       "mpc:soft1",
    "display2":       "mpc:soft2",
    "display3":       "mpc:soft3",
    "display4":       "mpc:soft4",
    "display5":       "mpc:soft5",
    "display6":       "mpc:soft6",
    # F7 is spare on the MPC side - it only has six - so FULL LEVEL lives here
    # and keeps its own lamp. It cannot sit on SHIFT+GRID: SHIFT is itself an
    # MPC key, so a shifted binding costs the key it shadows.
    "display7":       "mpc:full_level",
    # display8 is SURFACE_TOGGLE and sends nothing to the MPC.

    # --- left column ------------------------------------------------------
    "control":        "mpc:bar_left",
    "step":           "mpc:enter",
    "browse":         "mpc:window",
    "sampling":       "mpc:after",        # the MPC's note-repeat key
    "browse_left":    "mpc:left",
    "browse_right":   "mpc:right",
    "snap":           "mpc:bar_right",
    "auto_write":     "mpc:track_mute",
    # NOTE REPEAT prints TAP TEMPO above it, and that is the scarcer function:
    # the MPC's own note repeat is AFTER, which is on SAMPLING beside it.
    "note_repeat":    "mpc:tap_tempo",

    # --- transport --------------------------------------------------------
    "loop":           "mpc:play_start",   # the button the panel prints RESTART
    "transport_left": "mpc:step_left",
    "transport_right":"mpc:step_right",
    "grid":           "mpc:sixteen_levels",
    "play":           "mpc:play",
    "rec":            "mpc:record",
    "erase":          "mpc:erase",
    # SHIFT IS SHIFT. It sends the MPC's own SHIFT key, held for as long as the
    # button is held, so every shifted function on the machine works the way
    # its own panel prints it - and we never invent a second meaning for a
    # button, which is a thing to memorise rather than read.
    #
    # It is still our modifier for the pad layer as well: SHIFT+pad sends the
    # MPC's numeric keys, and because the machine sees SHIFT held at the same
    # time it reads them as its MODE keys, exactly as pressing SHIFT and a
    # number does on the real panel.
    "shift":          "mpc:shift",

    # --- the pad banks ----------------------------------------------------
    "group_a":        "mpc:bank_a",
    "group_b":        "mpc:bank_b",
    "group_c":        "mpc:bank_c",
    "group_d":        "mpc:bank_d",
    # GROUP E-H are deliberately empty in MPC mode: every MPC key already has a
    # button, and inventing duplicates to fill them would make the panel harder
    # to read, not easier. They are the DAW's page buttons in DAW mode.

    # --- the column beside the pads ---------------------------------------
    "scene":          "mpc:up",
    "pattern":        "mpc:down",
    # The panel reports this key as "keyboard" - 1st-gen MK1s silkscreen it
    # KEYBOARD, later ones PAD MODE. It was bound as "pad_mode", which the
    # decoder never sends, so OVER DUB could not be pressed at all.
    "keyboard":       "mpc:over_dub",
    "navigate":       "mpc:main_screen",
    "duplicate":      "mpc:go_to",
    "select":         "mpc:undo",
    "solo":           "mpc:next_seq",
    "mute":           "mpc:stop",
}

# DAW mode. Only what Ardour actually understands today; the rest of the panel
# does nothing while the toggle is on the DAW, which is the point of the toggle.
DAW_BUTTONS = {
    "group_e":        "daw:page:LOOP",
    "group_g":        "daw:page:FX",
    "group_h":        "daw:page:SONG",
    "navigate":       "daw:page:EDIT",
    "duplicate":      "daw:duplicate",
    "select":         "daw:select",
    "mute":           "mode:MUTE",
    "solo":           "mode:SOLO",
    # Arms loop recording. While armed, display 1-7 punch in and out on their
    # strip instead of selecting it - which is why the pads never needed to be
    # involved in looping at all.
    "rec":            "daw:arm",
}

SHIFT_PADS = {
    1: "mpc:song",       2: "mpc:misc",      3: "mpc:load",   4: "mpc:sample",
    5: "mpc:trim",       6: "mpc:program",   7: "mpc:mixer",  8: "mpc:other",
    9: "mpc:midi_sync",  10: "mpc:zero",     11: "mpc:enter", 12: "mpc:main_screen",
    13: "mpc:semitone_down", 14: "mpc:semitone_up",
    15: "mpc:octave_down",   16: "mpc:octave_up",
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
    "LOOP": "strip level - all eight knobs, all eight strips, no banking",
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
