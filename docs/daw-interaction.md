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

**24 free buttons.** There is no shortage, and therefore no reason for a
PIN latch or a SHIFT layer in the DAW. SHIFT stays what it is on the MPC:
the MPC's own SHIFT key.

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
    ARM                arm the focused track
    MUTE + D5          mute LOOP5, focus unchanged

## The track row: D1–D7

Seven display buttons, seven strips — LOOP1–LOOP5, DELAY, REVERB. The
master is deliberately absent: soloing it does nothing and muting it kills
the desk from a button beside the loop tracks.

| gesture | action | status |
|---|---|---|
| `Dn` | focus strip *n* | **to build** |
| `MUTE` + `Dn` | mute strip *n* | built |
| `SOLO` + `Dn` | solo strip *n* | built |
| `ARM` + `Dn` | arm strip *n* for record | **to build** |

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
| 1 | `Dn` | focus the track |
| 2 | `ARM` | arm it; the column outlines |
| 3 | `REC` | punch in at the next bar; column fills |
| 4 | `REC` | punch out, loop closes and starts playing |
| — | `REC` again | overdub onto the closed loop |
| — | `CLEAR` | discard the take |
| — | `UNDO` | undo the last take, non-destructively |

Quantising the punch to the bar is what makes this usable at a keyboard's
distance, and it is why the countdown gets the largest glyphs on screen.

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

## The unresolved conflict

`mute` is **STOP** on the MPC surface and the **MUTE modifier** on the DAW
surface. Both are defensible and they cannot both hold if transport is to
work on both surfaces.

  * **Keep MUTE where the silkscreen says.** Transport stays MPC-surface
    only; D8 is one press away. Costs a toggle to stop the beat.
  * **Reserve transport panel-wide.** PLAY / REC / LOOP / STOP always reach
    the MPC, and the DAW's mute modifier moves to a free key. Costs the
    silkscreen matching what the button does.

This one is a taste call about how you actually play, so it is written down
rather than decided here.
