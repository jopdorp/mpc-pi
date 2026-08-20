#!/usr/bin/env python3
"""Report how much of each probe tone reached each output, per stage.

The probe is 440 Hz on the LEFT input and 660 Hz on the RIGHT, so a correct
STEREO path puts 440 in the left output only and 660 in the right output only.
A single-bin DFT per short window measures exactly that, and taking the peak
over the windows rather than the mean keeps short one-shots - a pad hit is a
fraction of a second - from being averaged into the noise.

    analyze-sample-rig.py <capture.wav> <marks>

<marks> is the file run-sample-rig.sh writes: "<STAGE> <seconds into capture>".
"""

import sys
import wave

import numpy as np

WINDOW = 0.25
LEFT_TONE = 440.0
RIGHT_TONE = 660.0


def tone(seg, freq, rate):
    t = np.arange(len(seg)) / rate
    return 2 * abs(np.sum(seg * np.exp(-2j * np.pi * freq * t))) / len(seg)


def peak(x, rate, lo, hi):
    """Strongest window of each tone in each channel over [lo, hi) seconds."""
    n = int(WINDOW * rate)
    best = [0.0, 0.0, 0.0, 0.0]
    for start in range(int(lo * rate), max(int(hi * rate) - n, int(lo * rate)), n):
        seg = x[start:start + n]
        if len(seg) < n:
            break
        for i, (ch, freq) in enumerate(
                ((0, LEFT_TONE), (0, RIGHT_TONE), (1, LEFT_TONE), (1, RIGHT_TONE))):
            best[i] = max(best[i], tone(seg[:, ch], freq, rate))
    return best


def main():
    wav, marks_path = sys.argv[1], sys.argv[2]
    with wave.open(wav) as w:
        rate = w.getframerate()
        frames = w.getnframes()
        x = np.frombuffer(w.readframes(frames), dtype="<i2")
    x = x.astype(np.float64).reshape(-1, 2) / 32768.0

    marks = {}
    with open(marks_path) as handle:
        for line in handle:
            stage, _, when = line.partition(" ")
            marks[stage.strip()] = float(when)

    print(f"{wav}  {frames / rate:.1f}s @ {rate} Hz")
    print("stage       L@440   L@660   R@440   R@660   separation")
    for stage in ("MONITOR", "RECORD", "PLAYBACK", "PAD"):
        lo = marks.get(stage + "_BEGIN")
        hi = marks.get(stage + "_END", None if lo is None else lo + 6.0)
        if lo is None:
            print(f"{stage:<10}  (no marks)")
            continue
        l440, l660, r440, r660 = peak(x, rate, lo, min(hi, frames / rate))
        # The left input must appear in the left output and nowhere else, and
        # the right input in the right output and nowhere else. Report the
        # worse of the two ratios: one good channel is not stereo.
        left = l440 / r440 if r440 > 0 else float("inf")
        right = r660 / l660 if l660 > 0 else float("inf")
        sep = min(left, right)
        print(f"{stage:<10} {l440:7.4f} {l660:7.4f} {r440:7.4f} {r660:7.4f}"
              f"   {sep:8.1f}x")


if __name__ == "__main__":
    main()
