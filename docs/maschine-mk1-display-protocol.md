# Maschine MK1 display protocol (for the MPC LCD sink)

Extracted from `shaduzlabs/cabl` (`src/devices/ni/MaschineMK1.cpp`,
`src/gfx/displays/GDisplayMaschineMK1.cpp`) with `biappi/Macchina` and
`fzero/maschine-mk1` as corroborating references. Verified against cabl's
working implementation; to be confirmed on hardware.

## Device

- USB vendor `0x17cc` (Native Instruments), Maschine MK1 controller.
- Display endpoint: bulk OUT `0x08` (`kMASMK1_epDisplay`).
- LED endpoint: bulk OUT (`kMASMK1_epOut`), messages `{0x0C, 0x00} + 31
  bytes` and `{0x0C, 0x1E} + 31 bytes` for the two LED groups.
- Two monochrome-grayscale LCDs, **255 x 64** each. In all display packets
  the first byte is `d = displayIndex << 1` (0 for left, 2 for right); data
  continuation packets use `d + 1`.

## Pixel format

5 bits per pixel grayscale; **3 pixels pack into 2 bytes** (15 bits used of
16). `blockIndex = x % 3` selects the position within the pair. Full white
is `0x1F`, black `0x00`. A framebuffer row is 255 px = 85 triples = 170
bytes, and the window below is 64 rows, so a full frame is
**64 x 170 = 10,880 bytes**, transmitted as 21 chunks of 502 plus a final
338 (21 x 502 + 338 = 10,880 exactly).

An earlier revision of this document said 5,358 bytes (10 chunks + 338),
which is arithmetically impossible for a 64-row window at 170 bytes per
row - it covers only 31 rows. The bridge inherited that number and
silently dropped the bottom half of every frame, since its packing loop
breaks out once it runs past the end of the buffer. Corrected here and in
`scripts/maschine/mpc-mk1-display.py`; still unverified against hardware,
so confirm the chunk count during MK1 bring-up.

## Init sequence (per display, after claiming the interface)

Command packets are `{d, 0x00, length, bytes...}`:

```
{d, 00, 01, 30}
{d, 00, 04, CA 04 0F 00}
  sleep 20 ms
{d, 00, 02, BB 00}
{d, 00, 01, D1}
{d, 00, 01, 94}
{d, 00, 03, 81 1E 02}     ; contrast
  sleep 20 ms
{d, 00, 02, 20 08}
  sleep 20 ms
{d, 00, 02, 20 0B}
  sleep 20 ms
{d, 00, 01, A6}
{d, 00, 01, 31}
```

## Frame transmission (per display)

```
{d, 00, 03, 75 00 3F}          ; row window 0..63
{d, 00, 03, 15 00 54}          ; column window 0..84 (85 triples)
{d,   01, F7 5C} + 502 bytes   ; first chunk
{d+1, 01, F6}    + 502 bytes   ; middle chunks (repeat 20x)
{d+1, 01, 52}    + 338 bytes   ; final chunk
```

Total payload 21 x 502 + 338 = 10,880 bytes per display per frame.

## Mapping the MPC2000XL LCD

The emulated HD61830 panel is 248 x 60 at 1 bpp. It fits inside one MK1
display with a 7 px right / 4 px bottom margin: place at (0,0), map lit
pixels to 0x1F (or a chosen contrast level) and unlit to 0x00, leave the
margin black. No scaling required.

Frame source: the `MAME_MPC_LCD_EXPORT` shared file written by the emulator
on changed frames only (the 0033 changed-frame detector already computes
dirtiness), so USB traffic occurs only when the LCD content changes -
exactly the cadence a bulk display wants.

## Input (later phase)

Pads/knobs/buttons arrive on the IN endpoints (see cabl's `processReport`);
pad pressure is a 12-bit value per pad. Target mapping: pads -> the
launcher's `internal-pads` mode (patch 0020) through a virtual MIDI port.

## References

- https://github.com/shaduzlabs/cabl (MK1 device + display classes)
- https://github.com/biappi/Macchina (independent MK1 RE, display upload PoC)
- https://github.com/fzero/maschine-mk1 (Linux-focused MK1 notes)
