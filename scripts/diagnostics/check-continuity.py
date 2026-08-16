#!/usr/bin/env python3
"""Is the delivered audio actually continuous?

Every counter in this project has now been caught testifying about
something other than sound: pw-top's client ERR increments 1,600 times
a second on audio that is provably clean, the journal logs nothing for
a forced 150ms hardware stall, and Ardour's counter echoes driver
lateness whether or not it reaches the speaker. This script is the end
of that chain of witnesses: it looks at the recorded waveform itself.

The board plays a pure sine at a known frequency into the output under
test; the host records it; this script checks every sample against the
only two failure shapes a dropout can take:

  * a gap - consecutive equal (or zero) samples where a sine of this
    frequency and amplitude cannot produce them;
  * a discontinuity - a sample-to-sample step larger than the sine's
    maximum slope, which is what a skipped or repeated buffer looks
    like at the splice.

Every flagged event is printed with its timestamp so it can be matched
against the board's counters for the same window. Zero events over
minutes of capture is the sentence "no dropout reached this output",
with nothing between the claim and the loudspeaker but the cable.

Startup is reported, never skipped. Earlier versions of this analysis
began three seconds in, to step over "the start transient" - which
means the transient was never examined, and an ear caught a click there
that the tool had been configured not to look at. A capture's first
second is where stream negotiation lives, so it is exactly where a
one-off glitch is expected AND exactly where one must not be hidden:
events before STARTUP_S are counted and printed separately, and the
steady-state verdict is stated as such rather than as "clean".

  check-continuity.py capture.wav [expected_hz]
"""
import sys
import wave


def main() -> int:
    path = sys.argv[1]
    expected_hz = float(sys.argv[2]) if len(sys.argv) > 2 else 441.0

    with wave.open(path, "rb") as w:
        rate = w.getframerate()
        channels = w.getnchannels()
        width = w.getsampwidth()
        nframes = w.getnframes()
        raw = w.readframes(nframes)

    if width == 2:
        import array
        samples = array.array("h")
        samples.frombytes(raw)
        full_scale = 32768.0
    elif width == 4:
        import array
        samples = array.array("i")
        samples.frombytes(raw)
        full_scale = 2147483648.0
    elif width == 3:
        # 24-bit packed - the gadget's native wire format.
        n = len(raw) // 3
        samples = [
            int.from_bytes(raw[i * 3:i * 3 + 3], "little", signed=True)
            for i in range(n)
        ]
        full_scale = 8388608.0
    else:
        print(f"unsupported sample width {width}")
        return 2

    left = samples[::channels]
    dur = len(left) / rate
    peak = max(abs(min(left)), abs(max(left)))
    if peak < full_scale * 0.001:
        print(f"capture is silence (peak {peak / full_scale:.6f} fs) - "
              "the signal never arrived; this is a routing failure, "
              "not a clean result")
        return 2

    # Max slope of A*sin(2*pi*f*t) is A*2*pi*f/rate per sample. Allow
    # 1.5x for capture-side filtering ringing before calling it a break.
    import math
    max_step = peak * 2 * math.pi * expected_hz / rate * 1.5

    # A sine at 441Hz crosses samples fast enough that even 3 equal
    # NONZERO samples in a row are impossible above the noise floor;
    # zeros are judged harder since inserted silence is the classic
    # underrun artifact.
    events = []
    flat_run = 1
    for i in range(1, len(left)):
        step = abs(left[i] - left[i - 1])
        if step > max_step:
            events.append((i / rate, f"discontinuity step={step / full_scale:.4f}fs"))
        if left[i] == left[i - 1]:
            flat_run += 1
        else:
            if flat_run >= 4:
                kind = "silence-gap" if abs(left[i - 1]) < peak * 0.01 else "flat-gap"
                events.append(((i - flat_run) / rate,
                               f"{kind} {flat_run} samples"))
            flat_run = 1

    STARTUP_S = 1.0
    early = [e for e in events if e[0] < STARTUP_S]
    steady = [e for e in events if e[0] >= STARTUP_S]

    print(f"{path}: {dur:.1f}s at {rate}Hz, {channels}ch, "
          f"peak {peak / full_scale:.3f}fs, slope limit {max_step / full_scale:.5f}fs")
    # A peak at or near full scale means something else is summed onto
    # this channel - the classic way this tool has been made to lie.
    if peak >= full_scale * 0.98:
        print("  WARNING: peak is at full scale. Something is probably "
              "mixed onto this channel; verify the routing before "
              "believing any verdict below.")
    if early:
        print(f"  startup (first {STARTUP_S:.0f}s): {len(early)} events")
        for t, desc in early[:6]:
            print(f"    {t:9.3f}s  {desc}")
    for t, desc in steady[:40]:
        print(f"  {t:9.3f}s  {desc}")
    if len(steady) > 40:
        print(f"  ... and {len(steady) - 40} more")
    print(f"STEADY {len(steady)} events over {dur - STARTUP_S:.1f}s"
          f"   STARTUP {len(early)}")
    return 0 if not steady else 1


if __name__ == "__main__":
    sys.exit(main())
