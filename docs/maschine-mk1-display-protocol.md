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


## Unresolved: display polarity

Two reverse-engineering sources disagree, and it matters because the DAW
pages use 32 grey levels as a hierarchy. cabl's `setPixel` stores the
**complement** of the 5-bit level, which would make `0x1F` the *darkest*
value and the panel dark-on-light — consistent with reviews describing
the MK1 as "inverse video" next to the MK2's white-on-black. Macchina
maps lit pixels straight to `0x1F` with no inversion.

If cabl is right, every page renders with its brightness upside down.
`scripts/maschine/mpc-mk1-display.py` therefore takes `MPC_MK1_INVERT=1`,
so bring-up flips one flag instead of editing the renderer. Send one
frame with a known gradient and record the answer here.

## Verified control inventory

Taken from cabl's `MaschineMK1.cpp`/`.h` (the same reference this display
protocol comes from), not from marketing copy — a lot of documentation
conflates MK1 with later models.

| Control | Count | Notes |
|---|---|---|
| Displays | 2 | 255x64, 5 bpp (32 grey levels) |
| Pads | 16 | 12-bit continuous pressure (velocity is synthesised from the leading edge), cabl's on-threshold is 200. LED brightness only, no colour channel - RGB per-pad is MK2. But see "LED colours" below: the panel is not one colour |
| Encoders | 11 | 8 display knobs + VOLUME/TEMPO/SWING. **No master/jog encoder and no encoder push-switch on MK1** - those are MK2. The knobs are endless absolute-position pots (~1000 steps/rev), not quadrature, and are **not touch-sensitive** (that is Studio/MK3) |
| Buttons | 41 | named below; **bit 8 of the report is unused** |

Buttons, in report bit order: Mute, Solo, Select, Duplicate, Navigate,
Keyboard, Pattern, Scene, *(bit 8 unused)*, Rec, Erase, Shift, Grid,
TransportRight, TransportLeft, Loop, GroupE, GroupF, GroupG, GroupH,
GroupD, GroupC, GroupB, GroupA, Control, Browse, BrowseLeft, Snap,
AutoWrite, BrowseRight, Sampling, Step, DisplayButton8..DisplayButton1,
NoteRepeat, Play.

Two consequences for the control map:

- **Buttons 1-4 sit above the LEFT display and 5-8 above the RIGHT**, and
  knobs 1-4 / 5-8 divide the same way (NI's manual, and the kernel
  driver's own comments say "4 under the left screen" / "4 under the
  right screen"). So each screen owns four buttons and four encoders.
  NI's own software treats the pair as one eight-column strip in Control
  mode, but our screen L is the MPC LCD, so the DAW page is four columns
  of 62px - which fits ten characters instead of five.
- The eight display buttons are **unlabelled** on the panel; NI calls
  them Button 1-8. MK1 shipped in **two silkscreen revisions** (1st gen
  F1/F2/LOOP/KEYBOARD became SNAP/AUTO WRITE/RESTART/PAD MODE), same
  hardware and protocol, so printed names must not be trusted in docs.
- `Rec = 9` leaves bit 8 unused. An earlier version of
  `scripts/maschine/mpc-mk1-input.py` closed that gap, which shifted every
  button from Rec onwards by one position — Shift would have pressed Grid.
  Corrected against the enum above.

## LED output (62 bytes, and the screens depend on it)

Implemented in `scripts/maschine/mk1_leds.py`. Layout from cabl's
`enum class MaschineMK1::Led` and `sendLeds()`.

**The display backlight is an LED byte.** Index 58, `DisplayBacklight`,
which cabl sets to `0x5C` at the end of `init()`. Until the LED block is
written, both screens stay dark however correct the frame data is - so a
first bring-up with no LED code shows two dead displays and looks
exactly like a broken display protocol. This project had no LED code at
all until now, so that is the failure we were set up to hit.

Two blocks on endpoint `0x01` (the generic OUT endpoint - **not** the
display endpoint `0x08`):

```
{0x0C, 0x00} + leds[0..30]    ; 31 bytes, group 0
{0x0C, 0x1E} + leds[31..61]   ; 31 bytes, group 1
```

Group 1's header offset is `0x1E` (30) while its data starts at index
31. That asymmetry looks like an off-by-one and is not - it is what the
working implementation sends. Do not "fix" it without hardware.

Wire order (index = byte offset). Two traps, both of which look like
typos:

| Index | LEDs |
|---|---|
| 0-15 | Pad4,3,2,1 / Pad8,7,6,5 / Pad12,11,10,9 / Pad16,15,14,13 |
| 16-30 | Mute, Solo, Select, Duplicate, Navigate, Keyboard, Pattern, Scene, Shift, Erase, Grid, TransportRight, Rec, Play, *Unused1* |
| 31-48 | TransportLeft, Loop, GroupH, GroupG, GroupD, GroupC, GroupF, GroupE, GroupB, GroupA, AutoWrite, Snap, BrowseRight, BrowseLeft, Sampling, Browse, Step, Control |
| 49-56 | DisplayButton8, 7, 6, 5, 4, 3, 2, 1 |
| 57-61 | NoteRepeat, **DisplayBacklight**, *Unused2, Unused3, Unused4* |

- **Pads are reversed within each row of four.** Writing them in natural
  order mirrors every row horizontally - which on a 4x4 grid looks like
  a plausible mapping difference rather than a bug.
- **DisplayButton runs 8..1**, descending, unlike everything else.
- Group boundary falls at `Unused1` (30), not on any meaningful control.

Brightness only, `0x00`-`0x7F`, single colour. RGB pads are MK2. State
must therefore be expressed as brightness and time - dim/bright/blink -
never hue.

## Init handshake

Undocumented in every other write-up found. cabl's `init()` order:

1. `initDisplay(0)`, `initDisplay(1)` - the command sequences above
2. black both, `sendFrame(0)`, `sendFrame(1)`
3. **`{0x0B, 0xFF, 0x02, 0x05}` to endpoint `0x01`**
4. zero all 62 LEDs, send both groups
5. start reading endpoint `0x81`
6. set `DisplayBacklight = 0x5C`, resend group 1

Step 3 is issued unconditionally before any input is read. Treat it as
required: no source shows input reports arriving without it.

## The kernel will take this device first

`snd-usb-caiaq` claims `17cc:0808` - it is in the module's alias list,
and our RT kernel builds it (`CONFIG_SND_USB_CAIAQ=m`,
`CONFIG_SND_USB_CAIAQ_INPUT=y`). It exposes pads and buttons as a Linux
input device and drives **neither the displays nor the LED block**, so
it is useless here and must be kept off the device.

This is not theoretical. cabl issue #10 is someone running a Maschine
MK1 on a Raspberry Pi in January 2018, reporting:

```
libusb: error [submit_bulk_transfer] submiturb failed error -1 errno=16
[DeviceHandleLibUSB] write: error=-1 - transfer size: 33 written: 0
[MaschineMK1] sendLeds: error writing first block of leds
```

`errno 16` is `EBUSY`, and transfer size 33 is exactly a LED block
(2 header + 31 data). That is the kernel driver holding the interface.
The issue was closed with no solution and no follow-up.

Handled by `board/rpi5/rootfs_overlay/etc/modprobe.d/blacklist-caiaq.conf`
(`blacklist` *and* `install ... /bin/false`, since blacklist alone only
stops autoloading by alias) plus
`etc/udev/rules.d/71-maschine-mk1.rules`, which also grants the `mpc`
user access so the hub does not need root.

Note that `detach_kernel_driver(0)` in the Python code only covers
interface 0. caiaq binds per interface, so on a multi-interface device
that call can succeed while another interface stays held - failing later
as EBUSY, which reads like a permissions problem.

## Hardware findings (2026-08-17, first session with the device)

Everything above came from reading other people's source. This section is
what the hardware actually did, and three of these are in no published
write-up.

### Interface 0 has two alternate settings

```
alt 0:  ep 0x01 OUT, 0x81 IN
alt 1:  ep 0x01 OUT, 0x81 IN, 0x84 IN (pads), 0x08 OUT (display)
```

A USB device defaults to **alt 0**, where the pad and display endpoints
do not exist at all - reads from `0x84` fail EIO, and so do writes to
`0x08`. `set_interface_altsetting(0, 1)` is mandatory and was missing
from every script here. cabl does not mention it; its libusb layer must
do it incidentally.

### Output only flows while input is being drained

Writes to `0x01` return **ETIMEDOUT (errno 110)** - not EBUSY, not EPIPE -
whenever input reports are queued on `0x81`/`0x84`. Drain the IN
endpoints and the identical write succeeds.

The symptom points nowhere near the cause: a timeout on an OUT endpoint
reads as "the device is not listening", when it means "the host has
stopped listening". This is why cabl runs an async read loop and sends
output on a tick.

**Still unsolved:** even with draining before every write, roughly half
of all LED writes time out (77 ok / 75 failed over 24s). Retrying gets
them through and the panel responds correctly, but the I/O model needs to
be async before display frames - 22 chunks of 502 bytes per frame, per
screen - can be pushed reliably.

### LEDs are on 0x01, and 0x08 lies

The LED block belongs on `0x01`, as cabl says. Writing the identical
33-byte block to `0x08` is **accepted and silently discarded** - the
write returns success and nothing lights. That is the more dangerous of
the two failures, and it cost an hour: `0x08` looked like the answer
precisely because it did not complain.

### What lit up

- Pad LEDs: confirmed, **green**
- Group buttons A-H: confirmed, **blue**
- Other buttons: some **red**
- `DisplayBacklight` (index 58, 0x5C): confirmed, both screens backlit,
  **white**

So the LED index table is right where it has been exercised, and the
display backlight really is an LED byte.

### LED colours

Brightness is writable; colour is not. Each control has its own fixed
colour in hardware - green pads, blue groups, red elsewhere, white
backlight. A page may rely on a control's colour being constant and
carrying meaning; it can never choose one.

### Still unverified

- **Group button order.** cabl lists indices 33-40 as H,G,D,C,F,E,B,A -
  a strange order that has not yet been checked one button at a time.
- **Display frames.** Nothing has been drawn. The backlight is on and the
  screens flicker when LED data is sent, but no frame has been
  transmitted, so polarity and the 21x502+338 chunk count remain open.
