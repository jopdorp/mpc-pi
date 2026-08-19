# Sampling on the MPC2000XL: what the firmware actually does

Reverse-engineered from the v1.20 ROM (`mpc2000xl_120.bin`, the default BIOS
in MAME's `mpc2000xl` set) with `objdump -b binary -m i8086`. Written down
because the emulator's own source comment about this register is wrong in a
way that would send an implementation straight into a wall.

## The register

`WADCSN`, I/O port `0x00C0`, handled on real hardware by the Xilinx FPGA at
IC220. `mpc2000.cpp` maps it and stores writes; nothing acts on them.

## What the source comment gets wrong (and what it got right)

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

**The comment's values turned out to be correct anyway.** Tracing WADCSN on the
running machine with `MAME_MPC_SAMPLE_DEBUG=1` while the SAMPLE screen is open
shows exactly the bytes it names:

    wadcsn: 1a   00011010   stop - analog disabled, no channel
    wadcsn: 12   00010010   the bit-3 pulse cleared again
    wadcsn: d2   11010010   START - both channels on, analog enabled

`0xD2` is `0x12 | 0xC0`, which is precisely `si = (shadow & 0x3b) | di` from
the start sequence below with `di = 0xC0` for stereo. So the comment was
describing real behaviour and only the *method* of finding it was wrong:
searching for immediates cannot find a value the firmware assembles at
runtime, and concluding from that search that the value was a guess was the
wrong inference. Decoding by BIT is still the right implementation, because
`0xD2` is only the stereo case - mono writes `0x52` or `0x92`.

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
2. **Bit 3 is pulsed here, but it is still a level.** This sequence writes it
   high and clears it two instructions later, which reads like an
   edge-triggered strobe and was first written down as one. The rest of the
   module settles it: the digital path (`0x4915e`) HOLDS bit 3 set for the
   whole take, and so does the stop path (`0x491bc`). So the source comment's
   "analog input disable" is right, and what this sequence is doing is muting
   the analog front end, re-enabling it, and then waiting ~93 delay units for
   it to settle before any channel is switched on.
3. **Bits 7 and 6 are masked off (`and al,0x3f`) at the start of the
   sequence**, consistent with them being the L/R channel enables the
   comment describes - the code clears them and then ORs in whatever the
   user selected elsewhere.

## Where the recorded words actually go

The section that used to sit here said this was unknown and guessed that
sampling reused DMA channel 3, the channel that already moves sample data
between the CPU and wave RAM. **That guess was wrong**, and it is worth
recording why, because it produced a patch that looked complete and sampled
nothing.

Disassembling the whole module (`0x49000`-`0x497ff`) shows two DMA channels,
not one:

    0x490e2 / 0x49123   out 0xC031, 2      ; DMAU channel register <- ch 2
                        address <- 0x0007F000  (helper at 0x4E4EE)
                        out 0xC032, 0x3FF  ; count, 1024 words
                        out 0xC03A, 0x55   ; mode
    0x492ba             out 0xC031, 3      ; channel 3
                        address <- 0x0007F000
                        out 0xC032, 0x3FF
                        out 0xC03A, 0x59   ; mode

The V53's DMAU registers sit at `0xC030`-`0xC03F` (OPHA `0xC0`, DULA `0x30`),
and MAME's `upd71071_device` decodes the mode byte as: bits 7-6 transfer mode
(`0x40` = single), bit 5 direction, bit 4 auto-initialise, bits 3-2 transfer
type (`0x04` = I/O->memory, `0x08` = memory->I/O), bit 0 = 16-bit. So:

  * **channel 2, mode `0x55`** - single, auto-init, 16-bit, **I/O to memory**.
    This is the ADC filling a 2KiB ring at linear `0x7F000`. The buffer is
    zeroed first at `0x49092` (`mov cx,0x400 / mov dx,0x7f00 / rep stosw`).
  * **channel 3, mode `0x59`** - the same buffer, **memory to I/O**, pushing
    blocks of it into the L7A1045's wave RAM.

Channel 3 during sampling therefore runs in the *write* direction, through
`dma_w16_cb`. `dma_r16_cb` is not called at all, which is why serving captured
audio from it recorded nothing and could only have corrupted sample *loading*.

## The level meter, and why it was the visible symptom

The SAMPLE screen's input meter is not a register read. It is a scan of that
same `0x7F000` ring, at `0x497aa` (mono) and `0x4975c` (stereo):

    mov dx,0x7f00 / mov es,dx
    mov ax,es:[bx] / cwd / xor ax,dx / sub ax,dx   ; abs()
    ...                                            ; keep the maximum
    cmp si,0x400 / jb ... / xor si,si              ; wrap at 1024 words
    cmp ds:0x8c12,si / jne ...                     ; stop at the write pointer

and `ds:0x8c12` - the write pointer it scans up to - comes from `0x491d4`:

    mov ax,2 / mov dx,0xc031 / out dx,al   ; select DMA channel 2
    mov dx,0xc034 / in ax,dx               ; its CURRENT ADDRESS register
    lea ax,[si+0x1000] / shr ax,1          ; -> word index 0..0x3FF

So the meter reads **DMA channel 2's address register**. In MAME the machine
wired only channels 1 (FDC/ATA) and 3 (DSP): channel 2 had no DRQ source and
no `in_io16r_cb` at all. Nothing ever transferred, the address register never
moved, the ring stayed zero - and the meter could not even tell that time had
passed. That, not the missing input stream alone, is why the SAMPLE screen
showed no input level.

The stereo scan reads **two consecutive words per frame** and forces an even
word index, so the ring must hold **interleaved L,R** words when both channels
are enabled - one word per enabled channel otherwise. Summing L+R to mono
would make the stereo meter read alternate samples of one signal as if they
were two channels.

## What ends a take, and why it ended instantly

The firmware does not time a recording with a clock. It polls the DSP, at
`0x49668`:

    xor ax,ax / out 0x80,ax     ; select voice 0
    in  ax,0x84                 ; voice 0 position, low
    mov ax,ds:0x8bc2            ; target length, 32-bit at 0x8bc2/0x8bc4
    in  ax,0x86                 ; voice 0 position, high
    ...                         ; target - position, compared against 0xa5

So the take ends when **voice 0's position reaches the target length**. That
position is advanced by `dma_w16_cb` - one increment per word channel 3 writes
into wave RAM. The DMA rate is therefore the recording speed, and any DMA that
runs faster than the audio arrives finishes the take early.

The L7A1045's DRQ for that transfer comes from `m_dma_timer`, armed in
`control_w` at 64 clock ticks: 33.8688MHz / 64 = **529kHz**, twelve times the
sample rate. `MAME_MPC_DSP_DMA_TURBO`, which the appliance sets to 8, makes it
**4.23MHz** - ninety-six times. A five-second take reaches its target length in
about fifty milliseconds, which is why pressing record jumped straight to
"name the file" with nothing recorded.

Turbo is correct for LOADING and that is what it was added for: a sample coming
off disk has no natural rate and the firmware only waits for terminal count.
Recording is the opposite case. `arm_dma_timer()` therefore keeps the turbo
behaviour when idle and switches to `sample_rate x channels` while `m_rec_on`,
one wave-RAM word per captured word.

`MAME_MPC_SAMPLE_DEBUG` reports `wave_words` (channel 3) beside `adc_words`
(channel 2) so the two can be compared directly: they should climb together at
the capture rate. `wave_words` racing ahead of `adc_words` is this bug.

The `x channels` factor is **measured correct**. With both channels enabled the
live trace advances `adc_words` by 1,633,920 in 18.529 s, which is 88,181
words/s against the 88,200 that stereo at 44,100 needs - 0.02% low, i.e. the
emulated machine running very slightly under real time. One word per enabled
channel per frame is what the DMA moves and what the ring produces.

That leaves the take-length question, and the answer is not the DMA rate.

## A stereo take is TWO MONO VOICES, and that is why it played back fast

The target at `ds:0x8bc2` does **not** count DMA words. It counts words in ONE
channel, because the firmware splits a stereo take into two separate mono
buffers and times it against the first one alone.

Three places in the module say so, and they agree:

  * `0x49432` computes the requested length in words - `frames x channels`,
    with `channels` chosen as 2 when `ds:0xd7cd == 2` - and stores it at
    `ds:0x95fc`.
  * `0x494c8`, **for stereo only**, calls `0x35b0:0x1e6` on that value with 2.
    That helper is a wrapper around the signed 32-bit **divide** at
    `0x35b0:0x00ac`, not a multiply: it loads the pointer from `[bp+6]`, pushes
    the divisor and `*ptr`, and stores the quotient back. So the length is
    HALVED, back to frames - the length of one channel.
  * `0x4952f` forms the target as `(destination_base + that halved length) /
    0x10`, and `0x49602` then programs the voice registers **twice** for a
    stereo take: channel `0` from `ds:0x8bba` and channel `0x10` from
    `ds:0x8be6`, whose start is the first buffer's end. Mono programs channel
    `0` only, guarded by the same `cmp byte [0xd7cd],2`.

And `0x492ba` arms the DSP for the take with **`0x58` for stereo against
`0x40` for mono** - control bits 4 and 3 on top of bit 6, DMA start. Bit 3 is
also set for ordinary wave DMA transfers, so bit 4 is the one that means
"stereo recording" on its own.

So the DSP demultiplexes: left words advance voice `0`, right words advance
voice `0x10`, and **each voice's position advances at the FRAME rate, not the
word rate**. Sending every word into voice 0 - which is what `dma_w16_cb` did
for every other kind of transfer - made voice 0 reach `base + length/2` in half
the wall-clock time. A take half as long as asked for is a take that plays back
at double speed, which is what "not paced tempo" sounds like.

The fix belongs in the DSP, not in the DMA pacing. Slowing the transfer to one
word per frame would have made voice 0 count correctly by throwing away half
the audio.

## The take that ends on its first poll

The poll at `0x49668` reads voice 0's register 0 back as a plain 32-bit
position - word 1 (bits 16-31) low, word 2 (bits 32-47) high - and compares it
against the target, whose high word it masks with `0x000f`. Four bits, which is
exactly how much of the 24-bit address reaches bits 32-35 and no more.

MAME's read-back preserved bits 36-47, the type and flags fields the CPU wrote,
and the firmware writes `0x0100` into that word itself: `0x49519` does
`mov ax,[bp-2] / or ah,1` on the third word of the start register before
programming it - the "flags? always 01" byte the device's own register map
documents.

Preserved into the read-back, that flag makes `cmp dx,ax / ja` at `0x49685`
unable to fire and the following `sbb dx,ax` leave the remaining length
negative, so the `jl` at `0x4969a` reports the target already passed on the
**first poll of every take**. The firmware masking its target to four bits is
the evidence that the hardware returns no flags on a position read: it would
have no reason to mask otherwise.

The read-back is therefore stripped to the bare position, scoped to the two
voices a take records into while a take is armed, so playback read-back - the
`roadedge` case the preserving mask was written for, and pad voices triggered
while the SAMPLE screen is open - is untouched.

## Analog vs digital: what WADCSN really carries

Both paths end at the same instruction, `0x49198`, writing `si`:

    0x49145  cmp BYTE ds:0xd7cc, 0     ; 0 = analog, non-zero = S/PDIF
    ; --- analog ---
    0x4914c  call 0x4904a              ; pulse bit 3, settle, clear it
    0x49150  ax = shadow; and al,0x3b  ; clear bits 7,6,2
    0x49159  si = ax | di              ; di = 0x40 / 0x80 / 0xC0
    ; --- digital ---
    0x4915e  ax = shadow; and al,0x1f  ; clear bits 7,6,5
    0x49163  or al,0x0c                ; SET bit 3 AND bit 2
    0x4916e  si = ax | di
    ; --- both ---
    0x49198  out 0xC0, al              ; the enable

`di` is `0x40`, `0x80` or `0xC0`, selected from `ds:0xd7cd` (L / R / stereo) by
the table at `0x490ac`. The stop path at `0x491bc` does `and al,0x3b; or
al,0x08` - bits 7, 6 and 2 clear, bit 3 set.

Two consequences for the gate in `wadcn_w`:

1. On the **analog** path the enable has bits 6/7 set and bit 3 clear, so
   "a channel is enabled and analog is not disabled" is a correct reading.
2. On the **digital** path the enable has bits 6/7 set and **bit 3 set as
   well**, together with bit 2. A gate that requires `!BIT(data, 3)` switches
   capture off exactly when the user selects S/PDIF. Bit 2 has to count as
   "recording" in its own right.

## The digital path has a second gate

Before the final enable, the digital branch checks a status bit:

    0x4917c  call 0x4907e   ; mov ax,7 / out 0xC002,al ; delay ; mov ax,5 / out 0xC002,al
    0x49181  call 0x49070   ; in al,0xC002 / and al,0x80 -> returns 0 iff bit 7 SET
    0x49184  or ax,ax
    0x49186  je  0x4918c    ; proceed only when bit 7 was SET
    0x49188  xor ax,ax      ; otherwise give up: ds:0x8b58 = 0, not recording

`0xC002` is inside the V53's own internal I/O page (OPHA `0xC0`), below the
DMAU at `0xC030`, and the written values `0x07` then `0x05` are 8251 command
bytes (TxEN|DTR|RxEN, then TxEN|RxEN). So this is the V53's **SCU**, and
`i8251_device::read()` returns `status_r()` for any non-zero offset, whose
**bit 7 is DSR**.

`mpc2000.cpp` says what DSR is, in a FIXME it already carried:

    m_maincpu->set_tclk(4'000'000); // FIXME: DAWCK generated by DSP
                                    // (also tied to V53 DSR input)

So the firmware is checking that the DSP's audio word clock is running before
it will start a digital take - a sensible thing to require of a clock-recovered
input, and nothing to do with WADCSN.

Nothing in the driver drives that pin. That turns out to be survivable rather
than fatal: `i8251_device` initialises `m_dsr(1)` and `write_dsr()` inverts, so
with no one driving it the status reads back with bit 7 SET and the firmware's
check passes. **This is by accident, not by design**, and it is the part of the
digital path most likely to be wrong if S/PDIF still misbehaves - so it is
written down here rather than left to be rediscovered.

## Implementation (patch 0051)

1. `stream_alloc(0, 10, ...)` becomes `stream_alloc(2, 10, ...)` and a
   `MICROPHONE` is added to the machine, routed into those two inputs. The
   device had no inputs at all, so `stream.get()` had nothing to read.
2. `sound_stream_update` captures into a ring, **interleaved per enabled
   channel**, before the voice loop - the machine can sample while it plays.
3. A second DRQ, `adc_drq_handler_cb`, and a second read callback,
   `adc_dma_r16_cb`, wired to **DMA channel 2**. DRQ is level, not a paced
   pulse: held while the ring has data, so the DMAC takes exactly as many
   words as the sound stream produced and the transfer is self-pacing. A
   timer at the ADC rate drifts against the block writer and starves at every
   block boundary.
4. `wadcn_w` decodes by BIT, not by value, and treats bit 2 (S/PDIF) as a
   record source in its own right alongside the analog gate.
5. `arm_dma_timer()` paces the wave-RAM DMA at the capture rate while
   recording, and keeps `MAME_MPC_DSP_DMA_TURBO` for everything else.

## Verifying it

`MAME_MPC_SAMPLE_DEBUG=1` makes the emulator trace, on stderr and so into the
journal:

    mpc2000xl wadcsn: <byte>  L=.. R=.. spdif=.. analog_off=.. -> rec=.. cap=(..,..)
    mpc2000xl sampler: set_record_enable on=.. L=.. R=..
    mpc2000xl sampler: rec=.. L=.. R=.. in_peak=.. ring_depth=.. adc_words=.. wave_words=.. ctl=.. pos0=.. posR=..
    mpc2000xl sampler: control <old> -> <new> (ch .., rec=..)
    mpc2000xl sampler: ch .. reg .. <- <48-bit> (start .. end ..)
    mpc2000xl sampler: poll ch .. start .. pos .. addr .. reg ..

`in_peak` is the loudest captured sample in the last report period: **zero
means the audio never reached MAME**, which on this appliance almost always
means `:mic` is linked to `mpcpi-clock`'s monitor instead of the USB gadget
(see docs/audio-chain.md). `adc_words` advancing means the guest's DMA is
draining the ring, i.e. the firmware really is running channel 2.

For the digital path, watch which WADCSN bytes arrive. A byte with bit 2 set
and bits 6/7 clear, followed by a stop, means the firmware gave up at the DSR
check above; a byte with bit 2 set **and** bits 6/7 set is the final enable at
`0x49198`, which means it started.

## Status

Analog capture is confirmed working end to end on the appliance: audio from
the host reaches the emulated sampler and registers on the record screen's
level meter.

The DMA pacing is confirmed by measurement: 88,181 words/s against 88,200
expected for stereo, with `adc_words` and `wave_words` in lockstep at a
constant offset.

The stereo two-voice split and the position read-back are reasoned from the
disassembly above and traced, but **take length is still not confirmed on the
machine**: it needs someone at the SAMPLE screen recording a take of a known
length and checking it comes out that long. The trace now prints `ctl`, `pos0`
and `posR` for exactly this - during a stereo take `ctl` should read `0158`,
and `pos0` and `posR` should climb TOGETHER at half the rate `wave_words`
does.

The digital gate fix is reasoned from the disassembly above and is traced, but
**S/PDIF is not confirmed working**. Confirming it needs someone at the SAMPLE
screen switching the input to DIGITAL while `MAME_MPC_SAMPLE_DEBUG=1`, and then
reading the WADCSN bytes back out of the journal as described above.
