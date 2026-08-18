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

`daw-ctl` now acts on all four of `focus` / `arm` / `punch_in` / `punch_out`;
the punches are quantised to the MPC's bar grid by its loop engine. What is
still missing is downstream of the punch: `finalize` and `repeat` are emitted
for the Lua side, which owns the playlist, and nothing consumes them yet, so a
take is captured but does not yet become a region that loops.

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

## Pages

| button | page | knobs do |
|---|---|---|
| `group_e` | MIX | K1–K8 = the eight strip levels |
| `group_f` | FX | the focused plugin's parameters |
| `group_g` | SONG | markers and arrangement |
| `group_h` | EDIT | regions on the timeline |
| `SELECT` + `Dn` | WAVE | drill into that track's take |

WAVE is a drill-in rather than a top-level page: you always open it *on*
something, and BACK returns you where you came from.

## The jog wheel

Cursor position, cut points and region moves all want a continuous
position control. The DAW has none today: all three master knobs are
hard-wired, `swing` to the MPC's DATA wheel, with no surface gating.

**Proposed: surface-gate `swing`.** MPC surface, it stays the DATA wheel.
DAW surface, it becomes the jog — playhead on SONG, cut point on EDIT,
trim handle on WAVE. It is the biggest knob and the MPC idiom already
teaches your hand that it means "move through the thing".

| page | jog moves |
|---|---|
| MIX | nothing |
| SONG | the playhead, snapped to bar |
| EDIT | the edit cursor, snapped per `SNAP` |
| WAVE | the selected trim handle, sample-accurate |

## EDIT: cutting and moving

| control | action |
|---|---|
| jog | move the edit cursor |
| `SNAP` | cycle snap: bar / beat / off |
| `SPLIT` | split the region at the cursor |
| `browse_left` / `browse_right` | previous / next region |
| K1 | slide the selected region in time |
| K2 / K3 | fade in / fade out |
| K4 | region gain |
| `ERASE` | delete the selected region |
| `DUPLICATE` | copy the selected region to the cursor |
| `UNDO` | undo |

## WAVE: trimming a take

| control | action |
|---|---|
| K1 / K2 | trim start / trim end |
| K3 | zoom |
| K4 | gain |
| jog | nudge the selected handle |
| `NORM` | normalise |
| `UNDO` | undo |
| `BACK` | return to the page you came from |

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
| `STEP` (the MPC's ENTER) | load the highlighted image | built (panel side) |
| `D8` | close | built |

"Built (panel side)" means the whole path works up to the drive: the panel
routes it, `daw-ctl` walks the tree and publishes the chosen image to
`/dev/shm/mpc-disk`, and **nothing reads that file yet**. Mounting an image at
runtime is MAME's side of the fence (`manager.machine.images[":fdc:0"]:load`)
and that plugin does not exist, so today the screen says `LOAD BEAT02.IMG` and
the drive does not change.

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
