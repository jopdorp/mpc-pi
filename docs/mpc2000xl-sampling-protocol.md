# Sampling on the MPC2000XL: what the firmware actually does

Reverse-engineered from the v1.20 ROM (`mpc2000xl_120.bin`, the default BIOS
in MAME's `mpc2000xl` set) with `objdump -b binary -m i8086`. Written down
because the emulator's own source comment about this register is wrong in a
way that would send an implementation straight into a wall.

## The register

`WADCSN`, I/O port `0x00C0`, handled on real hardware by the Xilinx FPGA at
IC220. `mpc2000.cpp` maps it and stores writes; nothing acts on them.

## What the source comment gets wrong

`mpc2000.cpp` says:

> C0 = WADCSN (D2 to start sampling, 1A to stop)

**`0xD2` never appears as an immediate operand anywhere in the v1.20 ROM.**
Searched exhaustively for `mov al, 0xD2` (`B0 D2`): one hit, at file offset
`0x60231`, and disassembling around it shows a data table, not code - the
byte pair falls inside a run of ascending values with no instruction
boundary. So a start value of `0xD2` cannot be taken as given; it is either
from a different firmware revision, from documentation, or a guess.

What the firmware really does is **compute the value at runtime**, which is
why no constant search finds it.

## The real write sites

Two addressing forms reach the port, and searching for only one misses most
of them:

  * `MOV DX,0x00C0` + `OUT DX,AL` - 3 sites, all at `0x00f11d`-`0x00f13d`,
    all writing constants `0x1A` or `0x1B`. These are the stop/disable
    paths. Three near-identical five-instruction wrappers.
  * `OUT 0xC0,AL` (immediate form, `E6 C0`) - **10 sites**, clustered around
    `0x049052`-`0x0491c3`, in a far-called segment (`retf`) that is
    evidently the sampling module. These are where the interesting work is.

## The start sequence, disassembled

At `0x04904e`:

    and  al,0x3f          ; clear bits 7 and 6 - the two channel-enable bits
    or   al,0x08          ; set bit 3
    out  0xc0,al          ; WADCSN <- computed value
    mov  si,ax
    mov  ds:0x989e,ax     ; shadow copy
    and  si,0xfff7        ; clear bit 3 again
    mov  ax,si
    out  0xc0,al          ; WADCSN <- value with bit 3 low
    mov  ds:0x989e,si     ; shadow updated

and at `0x049196`:

    mov  ax,si
    out  0xc0,al
    mov  ds:0x989e,si

Three facts fall out of this, none of which are in the source comment:

1. **The firmware keeps a shadow copy of WADCSN at `DS:0x989E`.** Every
   write is followed by storing the same value there. An implementation can
   read that address to know the intended state, and - more usefully - a
   correct emulation must not break the assumption that the register reads
   back what was written, because the firmware plainly does not re-read the
   port to find out.
2. **Bit 3 is pulsed, not set.** Written high, then immediately cleared in
   the very next instructions. That is an edge-triggered strobe, not a level
   - almost certainly "begin conversion" or a DMA/FIFO reset. The existing
   comment calls bit 3 "analog input disable", which does not fit a value
   that is set and cleared two instructions apart.
3. **Bits 7 and 6 are masked off (`and al,0x3f`) at the start of the
   sequence**, consistent with them being the L/R channel enables the
   comment describes - the code clears them and then ORs in whatever the
   user selected elsewhere.

## What is still unknown

The part that actually matters for making the SAMPLE screen work: **where
the recorded words are meant to land.** Nothing above shows the record
buffer address or the DMA trigger. The wave-DMA plumbing exists in the
L7A1045 device (it is how sample data moves for playback), but the record
direction has no stream at all - `stream_alloc(0, 10, ...)`, ten outputs and
zero inputs.

Next steps, in order:

1. Trace what the far-called routines around `0x049000` read and write
   besides the port - specifically any pointer set up before the bit-3
   strobe.
2. Find the interrupt or polling loop that consumes recorded data.
3. Only then wire `MICROPHONE` + an input stream, because until the
   destination is known there is nothing to connect it to.

Doing (3) first would produce a PipeWire input node that looks like progress
and samples nothing - which is worth stating plainly, because it is the
tempting shortcut here.

## Implementation (patch 0051)

Built on the finding above plus one more: **DMA channel 3 already carries
sample data between the CPU and the DSP's wave RAM** - `in_io16r_cb<3>` /
`out_io16w_cb<3>` in mpc2000.cpp, with the DSP raising DRQ. That is the
transfer the firmware already knows how to run for loading, and on real
hardware sampling is the same transfer with the words originating at the
ADC behind the FPGA instead of in wave RAM.

So the patch does three things:

1. `stream_alloc(0, 10, ...)` becomes `stream_alloc(2, 10, ...)`. The device
   had no inputs at all, which is the root reason sampling could not work -
   `stream.get()` had nothing to read.
2. `sound_stream_update` captures those inputs into a ring buffer when
   recording is enabled, summing L+R at half gain when both are selected
   (WADCSN bits 6/7 choose). Capture happens before the voice loop, because
   the machine can sample while it plays and a voice may be reading the RAM
   recording is about to fill.
3. `dma_r16_cb` returns captured words instead of wave RAM while recording.
   An empty ring returns silence rather than stalling: a DMA that never
   completes hangs the guest, and a gap in a recording is recoverable where
   a hung machine is not.

`wadcn_w` decodes bits rather than matching a value, because the start value
is computed at runtime - see above. The stop constants the firmware writes
(0x1A/0x1B) both have bits 7 and 6 clear, so "some channel enabled" already
means "recording" in the firmware's own terms.

**Status: applies cleanly, compiles pending, NOT yet verified against the
SAMPLE screen.** The open question is whether the firmware points voice[0]
at a record buffer and drives channel 3, which is what makes step 3 land in
the right place. If it does not, the capture path is still correct and only
the destination needs rework.
