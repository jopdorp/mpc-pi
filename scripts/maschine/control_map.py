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
# button is the mode.** Release and the display row is a strip selector
# again. There is nothing to step through and nothing to remember, because
# the panel's own printed labels say which button does what.
#
# Why hold rather than toggle: a held mode cannot be forgotten - the
# muscular effort is the reminder - so a performer can never look down
# mid-bar and wonder what the panel currently is. A latched mode can, and
# that is how you clear a loop while reaching for a kick drum.
#
# NOTHING LATCHES. The two paragraphs that used to sit here described a PIN
# button that held a mode after release, and a 4x4 pad map drawn over the
# page while a mode was held. Both belonged to the design where a mode took
# the PADS: the chord needed two hands, so it had to be possible to put it
# down, and the grid had changed meaning, so it had to be shown. A mode
# retargets seven display buttons now and the pads never move, so there is
# nothing to draw and nothing to pin - see PIN_BUTTON below, which is None.
# The screen names the engaged mode in the status line, which is the whole
# of what is left to say.

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
    # THE WAVE DRILL-IN, as docs/daw-interaction.md specifies it: SELECT + Dn
    # opens the take on lane n. It is the same shape as SOLO - a held button
    # over the display row, reaching any strip without moving focus first -
    # because that is the shape this panel already teaches.
    #
    # It could not be built before: SELECT was a plain DAW_BUTTONS entry that
    # fired on its press, so the panel had no way to know a strip key was
    # pressed WHILE it was down. What shipped instead acted on the already
    # focused lane, which is one press after Dn rather than a chord.
    #
    # THE TAP IS THAT FALLBACK, kept. A bare SELECT - pressed and released
    # with no strip key in between - still drills into the focused lane and
    # back out, so the cheap gesture for the common case survives and the
    # chord is there for the lane you are not on. "tap" is the general
    # mechanism: a held mode may declare an action for a press that turned
    # out not to be a chord.
    #
    # On the MPC surface SELECT is the MPC's UNDO key and stays it. Same as
    # SOLO, which is NEXT SEQ over there.
    "SELECT": {
        "button": "select",
        "pads": "mpc",
        "tap": "select",
        "help": "hold SELECT: display 1-7 open that lane's take; tap: the "
                "focused lane",
    },
}
DEFAULT_MODE = "MPC"
# NO PIN. Modes are held, not latched: SHIFT+MUTE and SOLO do their work while
# you hold them and end when you let go, which is one less piece of state to
# read off a panel mid-phrase. PIN was a leftover from when the pads were the
# strip selector and a chord needed both hands.
PIN_BUTTON = None


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

# WHAT THE FOUR BUTTONS UNDER THIS SCREEN ACTUALLY DO.
#
# Not a page menu. This was a per-page table - EDIT printed
# "SPLIT PREV NEXT BACK", LOOP printed "REC ARM UNDO PIN" - naming a
# dispatch that COULD NOT RUN. display1-7 are the strip row on the DAW
# surface and display8 is the surface toggle, both handled before the
# page branch is ever reached, so every one of those words was a label
# on a button that did something else. Verified on the appliance: the
# three buttons under "PREV NEXT BACK" focus LOOP5, DELAY and REVERB.
#
# The row is the same on every page because the strip row is the same on
# every page - that is the point of the focus model, and a legend that
# changed with the page would be describing a selector we deliberately
# do not have. Only display5-8 sit under this screen; display1-4 are
# under the LEFT one, which is showing the MPC.
#
# Derived from MUTE_STRIPS rather than typed out, so the legend cannot
# drift from the row it names - which is exactly how it came to lie.
BUTTONS_RIGHT = tuple(MUTE_STRIPS[4:]) + ("MPC",)

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


# --- the file browser ------------------------------------------------
#
# A floppy has to be chosen from somewhere. The appliance has no keyboard, the
# emulator is started with -flop and never asked again, and the MPC's own LOAD
# screen can only see what is already in the drive - so picking an image is a
# job for this panel or for nobody.
#
# THE SECOND AND LAST SHIFTED BUTTON, and shifted for the same reason SHIFT+pad
# is: there is no key to spare. Every bare button already carries an MPC key
# (see MPC_BUTTONS), and "list the host's filesystem" is not an MPC function at
# all - the machine has no such key - so it cannot take a bare button without
# making a real key unreachable.
#
# NAVIGATE is the button because its bare press is MAIN SCREEN, "show me where
# I am"; shifted it is "show me where the disks are". The MPC never sees the
# MAIN SCREEN key when the browser opens - only the SHIFT that was already
# held, which alone does nothing.
FILES_BUTTON = "navigate"

# What the four keys mean WHILE the browser is open. They are the MPC's own
# cursor left/right and ENTER when it is not, which is the same gesture on the
# same buttons: step through a list, go in, choose. Nothing has to be learnt
# that the silkscreen does not already say.
#
# browse_right is "into" and not "enter" on purpose. It descends into a
# directory and refuses to load a disk, because a right-arrow that swaps the
# media under a running instrument is a foot-gun; loading is ENTER's job, and
# ENTER is the key the MPC prints ENTER on.
FILES_BUTTONS = {
    "browse_left":  "files up",
    "browse_right": "files into",
    "step":         "files enter",
}

# Closing is display8 - the same button that toggles the surface. It is the
# panel's one universal "back out of what is on the right-hand screen", and the
# browser is the only thing that can sit on top of a page, so the first press
# closes it and the next toggles the surface as always. SHIFT+NAVIGATE closes
# it too: the way in is also a way out.
FILES_CLOSE = SURFACE_TOGGLE


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
    "group_f":        "daw:page:FX",
    "group_g":        "daw:page:SONG",
    "group_h":        "daw:page:EDIT",
    # SELECT IS A HELD MODIFIER over the display row - see MODES["SELECT"].
    # Held, display 1-7 drill into that lane's take; tapped, it drills into
    # the focused lane and back out again. The way in is the way out, the
    # same idiom SHIFT+NAVIGATE uses for the browser - and it cannot be D8,
    # which is the surface toggle and is never rebound.
    "select":         "mode:SELECT",
    # EDIT's snap grid, cycled: BAR / BEAT / OFF on one button, which is what
    # the key already means on the MPC side of the panel - SNAP is bar_right
    # there, "move by the grid". It decides how far one jog detent moves the
    # edit cursor.
    "snap":           "daw:snap",
    "mute":           "mode:MUTE",
    "solo":           "mode:SOLO",
    # Arms loop recording. While armed, display 1-7 punch in and out on their
    # strip instead of selecting it - which is why the pads never needed to be
    # involved in looping at all.
    "rec":            "daw:arm",

    # --- the region verbs: EDIT and WAVE ---------------------------------
    #
    # These were left unbound for as long as daw-ctl could not answer them.
    # It can: every one of them edits the published playlist, so the reason
    # for leaving them off - a key that spends the status line on UNKNOWN
    # COMMAND is worse than a key that does nothing - has gone.
    #
    # THE PANEL PRINTS NONE OF THESE WORDS except two. SPLIT, NORM and UNDO
    # are labels drawn under the RIGHT-HAND SCREEN, and the four buttons
    # under that screen are the strip row on this surface, so each verb
    # needs a free bare button picked here. Two dozen are free, so none of
    # them goes on a modifier: a shifted binding is one to remember rather
    # than read, and this panel spends its only two shift layers on
    # SHIFT+pad and SHIFT+NAVIGATE.
    #
    # WHERE THE PANEL SAYS THE WORD, THE PANEL WINS. Both of these are the
    # same verb in both worlds, so the silkscreen is true on either surface:
    # ERASE is the MPC's ERASE key over there and deletes the region here,
    # and DUPLICATE is GO TO over there and copies the region here.
    "erase":          "daw:erase",
    "duplicate":      "daw:duplicate",
    #
    # WHERE IT SAYS NOTHING, POSITION HAS TO CARRY IT. The remaining four
    # go in ONE 2x3 block - the left-hand cluster that already holds SNAP -
    # so EDIT's whole vocabulary is under one hand and can be learnt as a
    # shape rather than as four unrelated keys:
    #
    #     BROWSE  -> UNDO        SAMPLING   -> SPLIT
    #     <       -> REGION PREV >          -> REGION NEXT
    #     SNAP    -> SNAP        AUTO WRITE -> NORM
    #
    # The arrows are the specification's own choice and need no defence:
    # they are the MPC's cursor keys on the other surface and the browser's
    # up/into while a listing is open, which is the same gesture - step
    # through the thing in front of you. The browser is checked BEFORE this
    # table, so opening it takes them back for as long as it is up.
    "browse_left":    "daw:region:prev",
    "browse_right":   "daw:region:next",
    # SAMPLING is the least arbitrary of the three unprinted ones: it is the
    # key that opens the sample editor on the machine whose name is on the
    # panel, which is where audio gets chopped. AUTO WRITE is the only free
    # key whose printed word is about a level at all, and NORM sets one.
    # BROWSE carries UNDO because it is what is left in the block - said
    # plainly, because a mnemonic invented after the fact is worse than
    # admitting there is none.
    "sampling":       "daw:split",
    "auto_write":     "daw:norm",
    "browse":         "daw:undo",
    # ERASE and UNDO ARE PAGE-SENSITIVE, AND daw-ctl RESOLVES THAT - it is
    # the side that knows which page is up. ERASE deletes the region on EDIT
    # and WAVE and discards the take on the strips page; UNDO pops
    # loop-ops.lua's inverse-op stack on EDIT and WAVE and takes back the
    # take on the strips page. One key that always undoes what you were just
    # doing beats two keys that each work on one page and fault on the other,
    # and neither needs a modifier here to say which page it meant.
    #
    # THE BROWSE PAIR IS PAGE VOCABULARY THE SAME WAY: one word on the wire,
    # and daw-ctl steps whatever the page in front of you steps through -
    # chain slots on FX, markers on SONG, the region selection everywhere
    # else. Same gesture, pointed at the thing under the hand.
    #
    # --- FX's bypass and SONG's marker -----------------------------------
    #
    # Bound now that daw-ctl answers them; both were left off this table
    # for as long as they would have spent the status line on UNKNOWN
    # COMMAND. CONTROL heads the same left-hand cluster the browse pair
    # lives in, so the FX gesture is one hand shape - step to a slot with
    # < and >, take it in and out of the path with the key above them -
    # and its printed word is the nearest thing this panel has to a
    # plugin-control key. SCENE is the printed word nearest to what a
    # section marker is - a scene of the arrangement. On the MPC surface
    # they stay what they were, BAR< and UP; nothing is lost over there.
    "control":        "daw:byp",
    "scene":          "daw:mark",
}

# THE TOP ROW IS THE BANKS, AND THAT IS WHAT MAKES THE PADS THE MPC'S ON
# BOTH SURFACES.
#
# It used to read semitone_down / semitone_up / octave_down / octave_up.
# The MPC2000XL has no such keys - they are soft functions reached from a
# screen, not panel keys - so none of the four had a keycode, encode_midi
# returned b"" for all of them, and those four pads sent nothing at all.
# Aspiration, written where a mapping goes.
#
# What belongs there instead comes from the invariant this panel is built
# on: THE PADS ARE ALWAYS THE MPC'S, on both surfaces. They were not,
# quite. Which sixteen of the machine's sixty-four pads the grid plays is
# chosen by the BANK keys, and those sit on GROUP A-D, which are bound in
# MPC_BUTTONS only. On the DAW surface the pads played whatever bank you
# happened to leave them in and there was no way to change it, so three
# quarters of the instrument was unreachable whenever the panel was
# pointed at the mixer.
#
# SHIFT+pad reaches the MPC from either surface, so the top row of the
# grid carries the four banks, left to right - the same order as the GROUP
# buttons above the grid and as the BANK keys beside the MPC's own pads.
# A bank key on the pad grid is not a duplicate of a distant button; it is
# the grid's own control, on the grid.
#
# Verified on the appliance against the emulator's lamp export, which
# reports the machine's own BANK lamps:
#
#   bare BANK B        bank_a=0 bank_b=1 bank_c=0 bank_d=0
#   bare BANK D        bank_a=0 bank_b=0 bank_c=0 bank_d=1
#   SHIFT + BANK B     unchanged - the key is dropped
#
# which is why they are in the BARE half of the split below.
SHIFT_PADS = {
    1: "mpc:song",       2: "mpc:misc",      3: "mpc:load",   4: "mpc:sample",
    5: "mpc:trim",       6: "mpc:program",   7: "mpc:mixer",  8: "mpc:other",
    9: "mpc:midi_sync",  10: "mpc:zero",     11: "mpc:enter", 12: "mpc:main_screen",
    13: "mpc:bank_a",    14: "mpc:bank_b",   15: "mpc:bank_c", 16: "mpc:bank_d",
}

# WHICH OF THESE THE MACHINE WANTS SHIFT HELD FOR - AND WHICH IT REFUSES
# WHILE SHIFT IS DOWN.
#
# Measured on the appliance with MAME_MPC_LCD_EXPORT as the oracle, one key
# per line, bare and then with the SHIFT key held:
#
#   1/SONG        types "1" into the field under the cursor   ->  SONG mode
#   MAIN SCREEN   the MAIN screen                             ->  NOTHING
#   WINDOW        the parameter window                        ->  NOTHING
#   ERASE         the ERASE screen                            ->  NOTHING
#   DATA wheel    moves the field under the cursor            ->  NOTHING
#
# One fact, two consequences. The firmware only answers SHIFT on the keys
# that have a shifted function printed on them - the ten numeric mode keys -
# and IGNORES every other key while SHIFT is down. So the ten digits MUST
# arrive with SHIFT held or they type digits, and everything else MUST arrive
# without it or it arrives nowhere at all.
#
# This is why pads 11 and 12 did nothing on the MPC surface: ENTER and MAIN
# SCREEN are real keys with real keycodes, the bytes went out, and the
# machine dropped them because our own SHIFT was down. They only ever worked
# on the DAW surface, where SHIFT was not being sent - which is the same
# silent split that made the ten digits type numbers there instead of
# changing mode.
#
# The panel's SHIFT button is both our pad modifier and the machine's own
# SHIFT key, so the hub reconciles the two: it presses SHIFT for a mode key
# when the machine is not already holding it, and lifts it for a bare key
# when it is. Both are matched pairs inside one gesture - see Router.pad.
SHIFT_PADS_SHIFTED = frozenset((
    "song", "misc", "load", "sample", "trim", "program", "mixer", "other",
    "midi_sync", "zero"))

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
    "FX": "the focused slot's parameters P1-P4, absolute",
    "SONG": "scrub",
    "WAVE": "trim start / trim end / zoom / gain",
    "EDIT": "move region / fade in / fade out / region gain",
    "FILES": "the jog scrolls the listing - one detent per row",
}

# display8 closes the browser before it toggles the surface, so the one
# cell that genuinely changes says so. Every other page gets the row.
#
# Keyed off the knob table's own pages rather than a third list of page
# names: the coverage test exists because those lists used to be written
# out separately and drift apart, and two tables that cannot disagree
# need no test to notice when they do.
BUTTONS_RIGHT_BY_PAGE = dict(
    (page, BUTTONS_RIGHT[:3] + ("CLOSE",) if page == "FILES"
     else BUTTONS_RIGHT)
    for page in KNOBS_RIGHT_BY_PAGE)

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
# On the DAW surface these override MASTER_KNOBS. Only the big knob changes:
# it is the MPC's DATA wheel when driving the MPC and the DAW's jog when
# driving Ardour - the same gesture, "move through the thing", pointed at
# whichever thing is under the hand. VOLUME is the DAW master on both surfaces
# and TEMPO is the MPC's note variation on both, so neither is listed.
MASTER_KNOBS_BY_SURFACE = {
    "DAW": {"swing": "daw:jog"},
}

MASTER_KNOBS = {
    "volume": "daw:master",
    "tempo": "mpc:note_variation",
    "swing": "mpc:data_wheel",
}

def describe():
    """Human-readable dump, used by the docs and by bring-up."""
    out = []
    # MODES retarget the DISPLAY BUTTONS, never the pads, and there is no
    # PIN latch any more - both are load-bearing enough that the heading
    # said the opposite for a while and nobody noticed, because this
    # function crashed before reaching it.
    out.append("MODES (hold the button; the pads stay the MPC's):")
    for k, v in MODES.items():
        out.append("  %-5s %-9s %s" % (k, v["button"] or "(resting)",
                                       v["help"]))
    # TRANSPORT and GROUPS were separate tables once. They were folded into
    # the flat per-surface maps when the shift layer was removed, and this
    # dump was never updated - so it raised NameError on the first line of
    # the transport section and took the whole --self-test down with it.
    # Read the maps that actually exist instead of tables that do not.
    out.append("PANEL-WIDE (both surfaces):")
    for name, target in sorted(ALWAYS.items()):
        out.append("  %-16s %s" % (name, target))
    out.append("KNOBS 1-4 (MPC side): " + ", ".join(KNOBS_LEFT))
    out.append("KNOBS 5-8 (DAW side): " + ", ".join(
        "%s=%s" % (p, v) for p, v in KNOBS_RIGHT_BY_PAGE.items()))
    return "\n".join(out)


if __name__ == "__main__":
    print(describe())
