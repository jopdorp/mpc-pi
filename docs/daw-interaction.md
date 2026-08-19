# The DAW surface: every interaction

What the Maschine MK1 does when the panel is driving Ardour rather than the
MPC. Written as a specification to build against, not a description of what
exists — the "Status" column at the end of each table says which is which.

## What the hardware actually gives us

| control | count | notes |
|---|---|---|
| Pads | 16 | **reserved: always the MPC** |
| Under-screen knobs | 8 | K1–K8, page-dependent |
| Master knobs | 3 | VOLUME, TEMPO, SWING |
| Display buttons | 8 | D1–D8, D8 is the surface toggle |
| Other buttons | 33 | 24 unbound in DAW mode |

**24 free buttons.** There is no shortage, and therefore no PIN latch. SHIFT
appears exactly once, on MUTE, and only because the bare MUTE key is the
transport's STOP on both surfaces — see "Transport, on both surfaces". On the
MPC surface SHIFT remains what it always was: the MPC's own SHIFT key.

## Three invariants

1. **The instrument never goes away.** The pads reach the MPC on both
   surfaces and in every mode — *all four banks of them*: `SHIFT` + the top
   pad row is `BANK A`–`D`, because `GROUP A`–`D` are bound on the MPC
   surface only and the grid used to be stuck in one bank whenever the
   panel was pointed at the mixer. Mixing must never cost you the drums.
2. **D8 is always the surface toggle.** The way back is in the same place
   whatever is on screen.
3. **One press to reach anything; two to reach anything on a track that is
   not focused.** Nothing needs three.

## The focus model

Per-track verbs need either a modifier or a focus. Seven tracks times four
verbs is 28 buttons, so a button each is not on the table.

So: **one track is focused**, and the global verbs act on it. Holding a
modifier and tapping a track button reaches any other track *without*
moving focus — the modifier is a shortcut over the focus model, not a
replacement for it, and every verb works both ways.

    D3                 focus LOOP3
    REC                arm loop recording
    SHIFT+MUTE + D5    mute LOOP5, focus unchanged

## The track row: D1–D7

Seven display buttons, seven strips — LOOP1–LOOP5, DELAY, REVERB. The
master is deliberately absent: soloing it does nothing and muting it kills
the desk from a button beside the loop tracks.

| gesture | action | status |
|---|---|---|
| `Dn` | focus strip *n* | built |
| `REC` then `Dn` | punch in / out on strip *n* | built |
| `SHIFT` + `MUTE` + `Dn` | mute strip *n* | built |
| `SOLO` + `Dn` | solo strip *n* | built |

`daw-ctl` acts on all four of `focus` / `arm` / `punch_in` / `punch_out`; the
punches are quantised to the MPC's bar grid by its loop engine. Downstream of
the punch, `finalize`, `repeat` and `clear` go on the region queue verbatim and
`scripts/daw/loop-ops.lua` — dofile'd by the session governor, which owns the
playlist — turns them into a region that repeats. Every lane keeps its own
length: LOOP1 can be four bars while LOOP2 is three.

D1–D4 sit under the *left* screen, which shows the MPC, so four of the
seven have no on-screen label. Their order is the mixer's own, and the same
as the knobs above them.

## Recording a loop

The transport belongs to the MPC — Ardour follows it, and binding PLAY to
Ardour would fight the one clock the system agrees on. So loop recording is
**punch in / punch out against a transport that is already running**, not a
transport action.

| step | control | what happens |
|---|---|---|
| 1 | `REC` | arm loop recording; the strip buttons stop selecting |
| 2 | `Dn` | punch in on strip *n* at the next bar; column fills |
| 3 | `Dn` | punch out; the loop closes and starts playing |
| — | `Dn` again | overdub onto the closed loop |
| — | `REC` | disarm; the strip buttons select again |
| — | `erase` | discard the take (**unbound** on the panel) |
| — | `undo` | undo the last take, non-destructively (**unbound**) |

Quantising the punch to the bar is what makes this usable at a keyboard's
distance, and it is why the countdown gets the largest glyphs on screen.

`erase` and `undo` are one path in the engine — a single `clear` — so both
take the lane off the timeline and both leave the captured audio on disk.
They mean "undo what this page does": the take on the strips page, the
region on EDIT and WAVE. One key that always undoes what you were just
doing beats two keys that each work on one page and fault on the other.

Which Ardour object carries which half is not arbitrary. `REC` engages the
**session** record-enable, which is global; `Dn` punches the **strip's**
rec-enable, which is per strip and therefore the only thing that can carry an
independent punch. `phase3-poc.lua` proved that shape against real Ardour:
keep the session record-engaged and rolling, and punch lanes with their
rec-enable alone. The session record-enable is a *toggle* with no setter
(`/rec_enable_toggle`, and Lua's `maybe_enable_record`), so `daw-ctl` tracks
what it sent — sending it blind would disengage recording on every second
press of `REC`.

The first take fixes the loop's length: punch out three bars after punching
in and it is a three-bar loop, whatever the lane was created with. A later
take on the same lane is an overdub layer over that length, not a new loop.
Lanes do not share a length — three bars on LOOP2 and eight on LOOP3 repeat
side by side, each on its own grid, because each is its own set of regions on
its own playlist rather than one transport loop range.

**What a punch-out costs.** Ardour turns a capture into a region only when the
transport stops (`loop-ops.lua` has the measurements; the punch-out alone
leaves the playlist empty and no wav on disk). So closing a take stops the
transport, waits for the region, and then *locates forward over the pause* so
the timeline resumes in phase with the drums instead of falling permanently
behind them. Measured on Ardour 9: 10–50 ms to the region, 55–60 ms to roll
again. The MPC never pauses, so the drums do not stutter; what drops out for
that ~100 ms is the loops already playing, and any lane still recording comes
back split into two regions either side of the hole. On the first take of a
set nothing else is playing yet, so nothing is audible at all.

The stop is a workaround, and it is the only one the stock Lua API leaves:
a locate while rolling does not finalise, and there is no binding that
builds a region from a source. One small Ardour patch exposing "finalize
captures now" removes it — see `docs/maschine-daw-design.md`, Phase 3.

## Pages

| button | page | knobs do | status |
|---|---|---|---|
| `group_e` | MIX | K1–K8 = the eight strip levels | built |
| `group_f` | FX | the focused plugin's parameters | partial |
| `group_g` | SONG | markers and arrangement | partial |
| `group_h` | EDIT | regions on the timeline | built (its keys are unbound) |
| `SELECT` | WAVE | held + `Dn`: drill into lane n's take; tapped: the focused lane | built |

All five **open and render** — that much has been true for a while, and it
is also the least interesting thing about them. What each one can then
*do* is in its own section below; "partial" here always means the page
draws and its position controls work, while the operations that change
audio do not.

FX is the exception to that pattern: its knobs do reach Ardour
(`/strip/plugin/parameter` on the focused strip), but the plugin slot is
hardcoded to the first one and `browse_left`/`browse_right` are unbound,
so K1–K4 always edit slot 1 whatever the chain holds, and `BYP` does not
exist. That is a knob that moves the wrong plugin rather than a knob that
moves nothing, which is the more dangerous of the two.

WAVE is a drill-in rather than a top-level page: you always open it *on*
something, and `SELECT` both opens it and backs out of it.

## The jog wheel

Cursor position, cut points and region moves all want a continuous
position control, and `swing` is surface-gated to be it: MPC surface it
stays the DATA wheel, DAW surface it is the jog. It is the biggest knob
and the MPC idiom already teaches your hand that it means "move through
the thing".

| page | jog moves | status |
|---|---|---|
| MIX | nothing | built |
| SONG | the playhead, snapped to bar | built |
| EDIT | the edit cursor, snapped per `SNAP` | built |
| WAVE | the selected trim handle, sample-accurate | built |

This section read "Proposed" long after the panel half shipped, and the
panel half was the half that did not matter. `maschine-hub` gated the
knob and asserted the gating in its own self-test, so the feature looked
built from both the code and the tests — while `daw-ctl` had never heard
the word `jog`, answered `UNKNOWN COMMAND JOG` on every page, and the
biggest knob on the instrument moved nothing anywhere.

That is the third control to ship in exactly that shape here, after the
mixer knobs and the punch verbs: a green test on each side of a gap that
neither one crosses. The jog's self-test therefore asserts the **join**,
page by page, against the table above.

On MIX the jog is *silent*, which is a behaviour and not an absence: a
knob with no job on a page is not a fault, and answering `UNKNOWN
COMMAND` to it is how a working panel comes to look broken.

## EDIT: cutting and moving

| control | action | status |
|---|---|---|
| `group_h` | open the page | built |
| jog | move the edit cursor | built |
| `SNAP` | cycle snap: bar / beat / off | built |
| the timeline itself | regions drawn from the published list | built |
| `split` | split the region at the cursor | built — **unbound** |
| `region prev` / `region next` | previous / next region | built — **unbound** |
| K1 | slide the selected region in time | built |
| K2 / K3 | fade in / fade out | built |
| K4 | region gain | built |
| `erase` | delete the selected region | built — **unbound** |
| `duplicate` | copy the selected region to the cursor | built — **unbound** |
| `undo` | undo the last region edit | built — **unbound** |

**The channel exists now, and the page draws.** `loop-ops.lua` publishes
the playlist to `$DAW_REGIONS` (`/dev/shm/daw-regions`) after every drain
and twice a second besides; `daw-ctl` re-reads it whenever it changes and
addresses regions **by name**, because editing renames — a split makes two
regions neither side chose, and a clone comes back called after its
source. Verified on the appliance: a take recorded onto LOOP1 appears on
the EDIT page, `region next` selects it, `split` at the cursor makes two
regions, `undo` puts the original back.

**"Unbound" is what is left, and it is the panel's half, not `daw-ctl`'s.**
Every verb above works when its line reaches `/run/daw-ctl.fifo` — that is
the protocol `maschine-hub` writes and the way each one was exercised on
the running appliance. What no button sends yet is the line. The bindings
`control_map.DAW_BUTTONS` still needs, in the `daw:` form the hub turns
into a command by replacing colons with spaces:

    daw:split           split the selected region at the cursor
    daw:region:prev     browse_left
    daw:region:next     browse_right
    daw:duplicate       copy to the cursor
    daw:erase           delete the region (the take, on the strips page)
    daw:undo            undo the region edit (the take, on the strips page)
    daw:norm            normalise (WAVE)

`DUPLICATE` was left unbound rather than sending `daw:duplicate` to a
`daw-ctl` that did not understand it, which spent the status line on
`UNKNOWN COMMAND DUPLICATE`. There is a region op behind it now, so that
reason has gone. The MK1 has no key printed SPLIT, NORM or UNDO — those
names are the labels drawn under the right-hand screen, and those four
buttons are the strip row in DAW mode — so each needs a free bare button
chosen on the panel side.

**The cursor is in Ardour's coordinates, not the MPC's.** The published
header carries Ardour's sample rate and transport position, and EDIT draws
its playhead from that rather than from `daw-ctl`'s count of the emulator's
elapsed milliseconds. The two free-run against each other by an unknown
constant — `loop-ops.lua` ignores `daw-ctl`'s positions in `repeat at` for
exactly this reason — and a cursor in the wrong coordinates does not draw
slightly wrong, it splits a region somewhere else entirely.

**The knobs are deferred.** The MK1 reports an absolute encoder angle many
times a second, so one fade gesture would otherwise be thirty region
edits, thirty republishes and thirty presses of `UNDO` to take back. The
last value of a gesture goes out, a quarter of a second after the hand
stops, and a *press* flushes whatever is pending first so the queue
carries the gestures in the order they were made.

## WAVE: trimming a take

WAVE is a drill-in, not a page in the group row.

| control | action | status |
|---|---|---|
| `SELECT` + `Dn` | open the take on **lane n** | built |
| `SELECT` (tapped) | open the take on the **focused** lane, and drill back out | built |
| K1 / K2 | trim start / trim end — **the audio is cut** | built |
| K3 | zoom | built (state only, and rightly: zoom touches no audio) |
| K4 | gain | built |
| jog | nudge the selected handle | built |
| `norm` | normalise | built — **unbound** |
| `undo` | undo the last region edit | built — **unbound** |
| `BACK` | return to the page you came from | built |

**`SELECT` + `Dn`, and `SELECT` alone.** `SELECT` is a held modifier over
the strip row now — the same shape as `SOLO` and `SHIFT`+`MUTE`, which is
the shape this panel already teaches — so the chord in the specification
works: hold it and press `Dn` to open lane n's take. This used to read
"`SELECT`, not `SELECT` + `Dn`": `SELECT` fired on its own press, so the
panel had no way to know a strip key came after it, and what shipped
could only open the lane that was already focused.

The tap is that fallback, kept. Press and release `SELECT` with no strip
key in between and it drills into the focused lane and back out, so the
cheap gesture for the common case survives and the chord is there for the
lane you are not on.

The chord sends three verbs `daw-ctl` already had — `back`, `focus`,
`select` — rather than a new one. `back` is documented as a no-op on a
top-level page, so the same gesture means the same thing from anywhere,
*including from another lane's take*, which a bare `focus`+`select` would
have toggled straight out of instead of switching lanes. Nothing on the
panel side mirrors `daw-ctl`'s page to decide: one cursor, one owner.

On the MPC surface `SELECT` is still the MPC's `UNDO` key, exactly as
`SOLO` is still `NEXT SEQ` there.

**The way back cannot be D8.** D8 is the surface toggle and is never
rebound; a drill-in that exited through it would put you on the MPC when
you asked for the mixer. So `SELECT` drills back out — the way in is the
way out, the same idiom `SHIFT`+`NAVIGATE` already uses for the browser.

**The handles cut now.** They were "state only" — real, clamped, drawn,
and touching nothing — for as long as there was no published take to point
them at. Drilling in reads the selected region off the region list, and
the two handles become a `trim` on the queue a quarter-second after the
hand stops moving.

**Against the take's bounds at drill-in, not against the last trim.** The
handles are fractions, and fractions of an already-trimmed region can only
ever eat further inward: a handle pulled back out would never restore the
audio it had just hidden. So the drill-in remembers where the take started
and how long it was, and every trim is computed from that. Ardour clamps
the result to what the source actually holds. Each drill-in resets the
handles, because carrying one lane's edit points onto another lane's audio
is worse than starting square.

**NORM is arithmetic here, and UNDO is ours.** Neither
`AudioRegion:normalize` nor `Session:undo` is bound in Ardour's Lua on
either version this project runs — measured on the appliance's Ardour 8
and the build host's 9, against a real captured region. So `norm` computes
the factor from the region's own peak and sets its gain, and the answer
comes back through the published list onto the K4 readout, which is the
channel closing: the knob shows what actually happened rather than what
was asked for. Normalising a silent region **refuses** rather than
dividing by a zero peak. `undo` pops an inverse-op stack that
`loop-ops.lua` keeps for region edits only, bounded at 32 — take-level
UNDO is a different stack and a different key.

## Transport, on both surfaces

Resolved: **the transport is always reachable.** PLAY, STOP and RESTART reach
the MPC whichever surface the panel is driving, exactly like the pads. Leaving
the mixer to stop the beat only sounds reasonable when you are not playing.

That takes the MUTE key, because MUTE *is* STOP. So the mixer's mute moves
under SHIFT, where nothing else wants it:

| gesture | action | surface |
|---|---|---|
| `PLAY` | MPC play | both |
| `MUTE` | MPC stop | both |
| `LOOP` | MPC play-from-start | both |
| `SHIFT` + `MUTE` + `Dn` | mute strip *n* | DAW |
| `SOLO` + `Dn` | solo strip *n* | DAW — needs no modifier, nothing else wants that key |

`REC` is deliberately not panel-wide: on the MPC surface it is the MPC's
record, on the DAW surface it arms loop recording. That is the verb the button
means in both worlds, and MPC sequences get recorded from the MPC surface.

The self-test now asserts that any mode sitting on a panel-wide transport key
must be shifted, so the transport cannot be quietly stolen back.

## Looping without the pads

The pads are never involved. The row that already names the tracks does the
recording too:

| state | `Dn` does |
|---|---|
| resting | focus strip *n* |
| `REC` armed | punch in on strip *n* |
| armed, strip rolling | punch out — the loop closes and plays |
| `SHIFT`+`MUTE` held | mute strip *n* |
| `SOLO` held | solo strip *n* |

So a take is: `REC`, `Dn`, play it, `Dn`. Press `Dn` again to overdub. `REC`
again disarms and clears any rolling state.

One row of seven buttons, one modifier-free path for the common case, and the
instrument still under your hands throughout.

## FILES — loading a floppy

There is no keyboard on this appliance. MAME is handed `-flop` once at startup
and never asked again, and the MPC's own LOAD screen can only see what is
already in the drive — so choosing a different disk is a job for this panel or
for nobody. `scripts/daw/browser.py` finds the images; this is how a finger
reaches it.

| gesture | action | status |
|---|---|---|
| `SHIFT` + `NAVIGATE` | open the browser (and close it again) | built |
| jog / DATA wheel | move the cursor, one row per detent | built |
| `browse_left` | up one directory | built |
| `browse_right` | into the highlighted directory | built |
| `STEP` (the MPC's ENTER) | load the highlighted image | built |
| `D8` | close | built |

**The drive actually changes now.** `daw-ctl` publishes the chosen image to
`/dev/shm/mpc-disk` and `scripts/daw/mpcpi-autoplay.lua` — which is already
MAME's autoboot script, already running Lua inside the machine — polls that
path and calls the drive's own `load()`. No MAME patch and no rebuild were
needed: the Lua image interface is the supported way to swap media at runtime,
and an autoboot script is a place it can be called from. The drive is found by
instance name (`floppydisk`, what `-listmedia` publishes) rather than a
hardcoded `:fdc:0`, which resolves to `:fdc:0:35hd` on this driver.

**The panel reports the machine's answer, not its own keypress.** ENTER prints
`LOADING BEAT02.IMG`; the emulator writes back to `/dev/shm/mpc-disk-status`
and the screen becomes `LOADED BEAT02.IMG`, or the drive's own refusal in the
drive's own words — an `.iso` comes back as `UNABLE TO IDENTIFY IMAGE FILE
FORMAT`. The browser lists anything disk-shaped on purpose, because the
emulator is the authority on what it can mount, which makes a refusal an
ordinary outcome on this page rather than an exceptional one.

A swap **ejects, waits, and inserts**, because the guest's disk-change line is
edge-triggered and loading straight over a mounted image can leave the MPC
believing the old directory is still good. A refused load **puts back what was
in the drive**: the eject has already happened by then, and an empty drive is
strictly worse than the disk you had.

**The choice survives a power cycle.** `/dev/shm` is a tmpfs, so without this
the drive silently reverts to the unit's hardcoded `-flop` on every boot. Only
a load the emulator has **confirmed** is remembered — writing the choice at
keypress time instead put refused images into the boot seed, so one ENTER on an
unreadable file made every subsequent boot come up with an empty drive and an
error, with no way back except picking something else.

It opens from **either surface**. Wanting another kit is not a reason to change
surfaces first, and `NAVIGATE` is unbound in DAW mode, so nothing is taken away
there.

**Why the one shifted button.** SHIFT+pad reaches the MPC's keypad and was
supposed to be the only shift layer; this is the second and last. Every bare
button already carries an MPC key, and "list the host's filesystem" is not an
MPC function at all — the machine has no such key — so a bare button could only
be had by making a real key unreachable. `NAVIGATE` is the one to shift because
its bare press is MAIN SCREEN, "show me where I am"; shifted it is "show me
where the disks are". The MPC never sees the MAIN SCREEN key when the browser
opens, only the SHIFT already held, which alone does nothing.

**`browse_right` navigates; `ENTER` loads.** They are one finger apart, and a
right-arrow that swaps the media under a running instrument is a foot-gun. On a
disk, `browse_right` answers `ENTER TO LOAD` instead.

**The invariants hold.** The pads are still the MPC's, both layers of them; the
transport still reaches the MPC, so the beat can be stopped with a listing up;
and `D8` is still the way back — it closes the browser, and the next press
toggles the surface as always. The browser is an overlay on the right-hand
screen, not a page in the group row, so closing it puts back the page that was
underneath.

**On screen.** Five rows, the path on the status line, and the kind of each row
carried as a *shape* — a filled block is a disk the drive can take, a hollow
one is a disk-shaped file of the wrong size, a wedge is a directory, and a file
that is neither gets no marker. Shape survives the cursor row, which inverts
every brightness on it. A refusal ("NOT MOUNTED", "NOT A DISK") replaces the
path in bright text until the next move, because a key that appears to do
nothing is indistinguishable from a key that has broken.

## What is actually built

Honest status, because a specification that quietly describes itself as
finished is worse than no specification. Every row below was checked
against the **running appliance** rather than against this file — both
this document and the artifact it mirrors had drifted, and in both
directions: the jog was still marked "Proposed" months after its panel
half shipped, and the panel half turned out to be the half that did not
matter.

| area | state |
|---|---|
| Surface toggle, page memory, pads always MPC, transport panel-wide | built |
| SHIFT+pad: the ten mode keys, `ENTER`, `MAIN SCREEN`, `BANK A`–`D`, identical on both surfaces | built |
| Mixer levels on all eight knobs, master fader | built |
| `SHIFT`+`MUTE` and `SOLO` per strip | built |
| Focus, arm, punch in / punch out | built |
| Page buttons on `group_e`–`group_h` | built |
| Jog follows the surface, and moves something on every page | built |
| `SNAP` cycles bar / beat / off | built |
| FILES: open, scroll, descend, select | built |
| **FILES: the chosen image is mounted in the running drive** | built |
| **The chosen image survives a reboot** | built |
| WAVE: `SELECT`+`Dn` into any lane, drill in and out, zoom | built |
| **The region list is published, and both pages draw it** | built |
| **EDIT: split, select, slide, fades, gain, erase, duplicate, undo** | built — no panel button sends them |
| **WAVE: trim and gain reach the audio; normalise; undo** | built — `norm` and `undo` unbound |
| Looping: `ERASE` / `UNDO` on a take | built — unbound |
| SONG: markers — `browse_left`/`browse_right`, `MARK` | missing |
| FX: slot selection, `BYP` | missing |
| FX: K1–K4 reach Ardour but always edit slot 1 | partial |
| The MPC's transport export | **not running** — see below |

**The channel is built; what is left is buttons.** `loop-ops.lua` publishes
the playlist to `/dev/shm/daw-regions` — the mirror of the queue that
already carries `finalize` / `repeat` / `clear` the other way — and
`daw-ctl` reads it, draws it and edits it. Every verb in the EDIT and WAVE
tables was exercised on the running appliance by writing its line to
`/run/daw-ctl.fifo`, which is the protocol `maschine-hub` writes: a take
recorded onto LOOP1 was selected, split, un-split, duplicated, gained,
faded, trimmed, erased and restored, and the published list and the screen
state agreed at every step. What no button yet *sends* is the line; the
`daw:` bindings each one needs are listed under "EDIT: cutting and moving".

**Two things that are not built and are not this work.** Nothing writes
`/dev/shm/mpc-transport` on the appliance — `mpcpi-autoplay.lua` is MAME's
autoboot script and does not export the transport, and
`scripts/daw/transport-export.lua`, which does, is not loaded — so
`daw-ctl` has no bar grid and its punch verbs answer `no-transport`. And
nothing rolls **Ardour's** transport, which a capture needs. Loop recording
therefore cannot produce a take from the panel alone today, whatever the
buttons do; the take used to verify all of the above was made by supplying
those two missing pieces by hand.

### A note on how three of these were found

The mixer knobs, the punch verbs and the jog all shipped dead in the same
shape: `maschine-hub` emitted a command, its own self-test asserted that it
emitted it, `daw-ctl` had never heard the word, and the panel test on the other
side was green about a screen it could draw. **Two green tests either side of a
gap do not test the gap.** Every control added here should assert the *join* —
press to Ardour, or press to published state — and the jog's self-test is
written that way deliberately.
