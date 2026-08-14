# MPC2000XL panel serial protocol

Captured from the emulated uPD78C10 panel firmware (`PAD CPU V1.00
Feb.15,1999`) with `MAME_MPC_PANEL_TX_LOG=1`, using
`scripts/diagnostics/map-panel-keycodes.lua` and `map-panel-analog.lua`.
The link is one way: the panel's `rxd_func` is never bound, so the panel
only ever transmits. LEDs are driven by the V53's own latches, not the panel.

## Message framing

Every message is two bytes: a status byte and one data byte.

| Status | Data | Meaning | Cadence |
|---|---|---|---|
| `e0` | `11` | boot handshake | every 19,966 panel cycles (200 Hz) until ~4.0 M cycles |
| `83` | `05` | boot complete | once, at ~4.0 M cycles |
| `86` | `00` | idle heartbeat, no key down | every ~156,157 cycles (25.6 Hz) |
| `84` | keycode | key down | on event |
| `85` | keycode | key up | on event |
| `9n` | velocity | pad `n` struck (patch 0020 already emits this form) | on event |
| `81` | detents | data encoder incremented | on event |
| `80` | detents | data encoder decremented | on event |
| `ff` | ASCII | version banner `"PAD CPU V1.00 Feb.15,1999"` follows | once |

Panel cycles are uPD78C10 machine cycles at 12 MHz / 3 = 4 MHz.

## Key codes

| Port | Key | Code |
|---|---|---|
| `Y0` | Soft Key 1 | `01` |
| `Y1` | Soft Key 2 | `02` |
| `Y2` | Soft Key 3 | `03` |
| `Y3` | Soft Key 4 | `04` |
| `Y4` | Soft Key 5 | `05` |
| `Y5` | Soft Key 6 | `06` |
| `Y0` | 9 / MIDI/Sync | `07` |
| `Y1` | Enter | `08` |
| `Y2` | 3 / Load | `09` |
| `Y3` | 6 / Program | `0a` |
| `Y4` | Main Screen | `0b` |
| `Y5` | Window | `0c` |
| `Y0` | 8 / Other | `0d` |
| `Y1` | 2 / Misc | `0e` |
| `Y2` | 1 / Song | `0f` |
| `Y3` | 5 / Trim | `10` |
| `Y4` | 4 / Sample | `11` |
| `Y5` | 7 / Mixer | `12` |
| `Y0` | Shift | `13` |
| `Y1` | 0 | `14` |
| `Y2` | After | `15` |
| `Y3` | Tap Tempo | `16` |
| `Y4` | Undo | `17` |
| `Y5` | Erase | `18` |
| `Y0` | Step < | `19` |
| `Y1` | Step > | `1a` |
| `Y2` | Go To | `1b` |
| `Y3` | Record | `1c` |
| `Y4` | Over Dub | `1d` |
| `Y5` | Stop | `1e` |
| `Y0` | Play | `1f` |
| `Y1` | << Bar | `20` |
| `Y2` | Down Arrow | `21` |
| `Y3` | Right Arrow | `22` |
| `Y4` | Left Arrow | `23` |
| `Y5` | Up Arrow | `24` |
| `Y6` | Bank A | `25` |
| `Y7` | Full Level | `26` |
| `Y7` | 16 Levels | `27` |
| `Y3` | Bar >> | `28` |
| `Y4` | Play Start | `29` |
| `Y6` | Next Seq | `2a` |
| `Y6` | Track Mute | `2b` |
| `Y6` | Bank B | `2c` |
| `Y7` | Bank C | `2d` |
| `Y7` | Bank D | `2e` |

## Pad fields

The drum-pad inputs are analog (AN0-AN3, multiplexed by the drum scan row),
so the digital test fields below exercise the pad path rather than defining
it. The authoritative pad encoding is patch 0020's injection:
`0x90 | pad`, then velocity.

| Port | Field | Observed |
|---|---|---|
| `PB0` | Pad 13 | `94 7f` |
| `PB0` | Pad 14 | `94 00` |
| `PB0` | Pad 15 | `95 7f` |
| `PB0` | Pad 16 | `95 00` |
| `PB1` | Pad 10 | `96 7f` |
| `PB1` | Pad 11 | `96 00` |
| `PB1` | Pad 12 | `97 7f` |
| `PB1` | Pad 9 | `97 00` |
| `PB2` | Pad 5 | `90 7f` |
| `PB2` | Pad 6 | `90 00` |
| `PB2` | Pad 7 | `91 7f` |
| `PB2` | Pad 8 | `91 00` |
| `PB3` | Pad 1 | `92 7f` |
| `PB3` | Pad 2 | `92 00` |
| `PB3` | Pad 3 | `93 7f` |
| `PB3` | Pad 4 | `93 00` |

## Data encoder

A sweep of eight `DATAENTRY` steps of four units in each direction produced
exactly 32 `81 01` messages followed by 32 `80 01`, so the encoder reports one
message per detent with the count in the data byte: `81` for increment, `80`
for decrement.

## Unresolved: the NOTE VARIATION slider

Driving the `VARIATION` adjuster from Lua produced no serial traffic at all.
That is most likely a harness artifact rather than a protocol fact: the driver
only updates `m_variation_slider` from its `PORT_CHANGED_MEMBER`
(`variation_changed`), and a scripted `set_value()` on a `PORT_ADJUSTER` does
not necessarily raise that callback, so the panel's AN4 reading never moved.
Before an HLE can claim slider coverage this needs re-testing by driving the
adjuster through a real input event, or by writing `m_variation_slider`
directly and confirming a message appears.
