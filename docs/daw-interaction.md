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
   surfaces and in every mode. Mixing must never cost you the drums.
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
| — | `ERASE` | discard the take |
| — | `UNDO` | undo the last take, non-destructively |

Quantising the punch to the bar is what makes this usable at a keyboard's
distance, and it is why the countdown gets the largest glyphs on screen.

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
| `group_h` | EDIT | regions on the timeline | partial |
| `SELECT` | WAVE | drill into the focused track's take | partial |

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
| `SPLIT` | split the region at the cursor | missing |
| `browse_left` / `browse_right` | previous / next region | missing |
| K1 | slide the selected region in time | missing |
| K2 / K3 | fade in / fade out | missing |
| K4 | region gain | missing |
| `ERASE` | delete the selected region | missing |
| `DUPLICATE` | copy the selected region to the cursor | missing |
| `UNDO` | undo | missing |

**What "missing" means here, precisely.** Everything above that moves a
*position* is built: the page opens, the cursor moves under the jog, the
snap cycles and the screen draws all three. Everything that changes
*audio* is not, and it is all blocked on the same one thing — **nothing
publishes the region list.** The playlist belongs to the Lua side
(`session-governor.lua` and `loop-ops.lua`); `daw-ctl` owns the screen
state and has no channel to read regions back. So EDIT draws its bar
grid, its snap and its cursor over an **empty timeline**, and there is
nothing for `SPLIT` or `browse_left` to select.

The next piece of work on this page is not a button. It is a region
publisher on the Lua side, the mirror of the queue that already carries
`finalize` / `repeat` / `clear` the other way.

`DUPLICATE` is deliberately **unbound on the DAW surface** rather than
bound to a verb that does not exist. It used to send `daw:duplicate`,
which `daw-ctl` did not understand, so the press spent the status line on
`UNKNOWN COMMAND DUPLICATE`. An unbound button does nothing at all, which
is this surface's documented behaviour and is strictly better than one
that reports a fault. Bind it again with the region op, not before.

## WAVE: trimming a take

WAVE is a drill-in, not a page in the group row.

| control | action | status |
|---|---|---|
| `SELECT` | open the take on the **focused** lane, and drill back out | partial |
| K1 / K2 | trim start / trim end | built (state only) |
| K3 | zoom | built (state only) |
| K4 | gain | built (state only) |
| jog | nudge the selected handle | built |
| `NORM` | normalise | missing |
| `UNDO` | undo | missing |
| `BACK` | return to the page you came from | built |

**`SELECT`, not `SELECT` + `Dn`.** The specification reaches any lane's
take with a held modifier and a strip key; what is built opens the
**focused** lane, which is one press after `Dn` rather than a chord. That
is the focus model this panel is already built on — one press for the
common case, two to reach a track that is not focused — so it is a
smaller gesture than specified rather than a different one. The chord
needs `SELECT` to become a held modifier in `maschine-hub`'s button
dispatch, which is the one part of the panel a second surface has to
agree about.

**The way back cannot be D8.** D8 is the surface toggle and is never
rebound; a drill-in that exited through it would put you on the MPC when
you asked for the mixer. So `SELECT` drills back out — the way in is the
way out, the same idiom `SHIFT`+`NAVIGATE` already uses for the browser.

**"State only"** means the handles, zoom and gain are real, clamped,
remembered per drill-in and drawn on screen, and **no audio is touched**.
The trim handles are fractions of a take, and the take is not published
either — same missing region channel as EDIT — so the waveform is empty
and the handles have nothing to cut. Each drill-in resets them, because
carrying one lane's edit points onto another lane's audio is worse than
starting square.

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

**Why the one shifted button.** SHIFT+pad types the MPC's digits and was
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
| Mixer levels on all eight knobs, master fader | built |
| `SHIFT`+`MUTE` and `SOLO` per strip | built |
| Focus, arm, punch in / punch out | built |
| Page buttons on `group_e`–`group_h` | built |
| Jog follows the surface, and moves something on every page | built |
| `SNAP` cycles bar / beat / off | built |
| FILES: open, scroll, descend, select | built |
| **FILES: the chosen image is mounted in the running drive** | built |
| **The chosen image survives a reboot** | built |
| WAVE: drill in and out, trim handles, zoom, gain | built (no audio touched) |
| EDIT: region ops — split, select, slide, fades, gain, erase, undo | missing |
| WAVE: normalise, undo | missing |
| SONG: markers — `browse_left`/`browse_right`, `MARK` | missing |
| FX: slot selection, `BYP` | missing |
| FX: K1–K4 reach Ardour but always edit slot 1 | partial |
| Looping: `ERASE` / `UNDO` on a take | missing |

**One missing piece accounts for most of that column.** EDIT, WAVE and the
take-level `ERASE`/`UNDO` are all blocked on the same thing: **nothing
publishes the region list.** The playlist belongs to the Lua side, `daw-ctl`
owns the screen state, and there is no channel carrying regions back. Until
there is, those pages can draw a grid, a cursor and a pair of handles — which
they do — and cannot select or cut anything, because from `daw-ctl`'s point of
view the timeline is empty.

The channel to build is the mirror of the region queue that already carries
`finalize` / `repeat` / `clear` from `daw-ctl` to `loop-ops.lua`. One file,
published the other way, unblocks the whole column at once. It is a
considerably better next move than binding the buttons.

### A note on how three of these were found

The mixer knobs, the punch verbs and the jog all shipped dead in the same
shape: `maschine-hub` emitted a command, its own self-test asserted that it
emitted it, `daw-ctl` had never heard the word, and the panel test on the other
side was green about a screen it could draw. **Two green tests either side of a
gap do not test the gap.** Every control added here should assert the *join* —
press to Ardour, or press to published state — and the jog's self-test is
written that way deliberately.
