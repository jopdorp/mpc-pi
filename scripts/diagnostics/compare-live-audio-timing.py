#!/usr/bin/env python3
"""Compare live PipeWire PCM with an offline MAME emulated-time render."""

from __future__ import annotations

import argparse
import math
import wave
from pathlib import Path

import numpy as np
from scipy.signal import correlate


def read_stereo(path: Path, offline: bool) -> tuple[int, np.ndarray]:
    with wave.open(str(path), "rb") as wav:
        if wav.getsampwidth() != 2:
            raise ValueError(f"{path}: expected signed 16-bit PCM")
        rate = wav.getframerate()
        channels = wav.getnchannels()
        pcm = np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2")
    pcm = pcm.reshape(-1, channels)
    if offline and channels >= 3:
        pcm = pcm[:, 1:3]
    elif channels >= 2:
        pcm = pcm[:, :2]
    else:
        pcm = np.repeat(pcm, 2, axis=1)
    return rate, pcm.astype(np.float64)


def first_active(pcm: np.ndarray, threshold: int = 8) -> int:
    active = np.flatnonzero(np.max(np.abs(pcm), axis=1) > threshold)
    if not len(active):
        raise ValueError("capture contains no active audio")
    return int(active[0])


def correlation_lag(reference: np.ndarray, candidate: np.ndarray, half_search: int) -> tuple[int, float, float]:
    ref = np.diff(reference, axis=0).reshape(-1)
    cand = np.diff(candidate, axis=0).reshape(-1)
    ref -= ref.mean()
    cand -= cand.mean()
    values = correlate(cand, ref, mode="valid", method="fft")[::2]
    peak = int(np.argmax(values))
    integer_lag = peak - half_search
    fractional_lag = 0.0
    if 0 < peak < len(values) - 1:
        denominator = values[peak - 1] - (2.0 * values[peak]) + values[peak + 1]
        if denominator:
            fractional_lag = 0.5 * (values[peak - 1] - values[peak + 1]) / denominator
    selected = candidate[integer_lag + half_search:integer_lag + half_search + len(reference)]
    selected = np.diff(selected, axis=0).reshape(-1)
    selected -= selected.mean()
    coefficient = float(np.dot(ref, selected) / ((np.linalg.norm(ref) * np.linalg.norm(selected)) + 1e-30))
    return integer_lag, fractional_lag, coefficient


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("offline", type=Path)
    parser.add_argument("live", type=Path)
    parser.add_argument("--seconds", type=float, default=17.0)
    parser.add_argument("--window-seconds", type=float, default=0.5)
    parser.add_argument("--step-seconds", type=float, default=0.5)
    parser.add_argument("--search-samples", type=int, default=1200)
    parser.add_argument("--max-fractional-samples", type=float, default=0.01)
    parser.add_argument("--min-correlation", type=float, default=0.95)
    args = parser.parse_args()

    offline_rate, offline = read_stereo(args.offline, True)
    live_rate, live = read_stereo(args.live, False)
    if offline_rate != live_rate:
        raise ValueError(f"sample-rate mismatch: offline={offline_rate}, live={live_rate}")
    rate = offline_rate
    offline_start = first_active(offline)
    live_start = first_active(live)

    alignment_frames = min(rate * 2, len(offline) - offline_start)
    alignment_guess = live_start - offline_start
    live_alignment_start = offline_start + alignment_guess - args.search_samples
    if live_alignment_start < 0:
        raise ValueError("not enough live preroll for alignment search")
    initial_lag, _, initial_correlation = correlation_lag(
        offline[offline_start:offline_start + alignment_frames],
        live[live_alignment_start:live_alignment_start + alignment_frames + (2 * args.search_samples)],
        args.search_samples,
    )
    constant_offset = alignment_guess + initial_lag

    window_frames = round(args.window_seconds * rate)
    step_frames = round(args.step_seconds * rate)
    end_frames = min(round(args.seconds * rate), len(offline) - offline_start - window_frames)
    observations: list[tuple[float, int, float, float]] = []
    for relative in range(step_frames, end_frames + 1, step_frames):
        offline_position = offline_start + relative
        live_position = offline_position + constant_offset
        if live_position < args.search_samples or live_position + window_frames + args.search_samples > len(live):
            break
        integer, fractional, coefficient = correlation_lag(
            offline[offline_position:offline_position + window_frames],
            live[live_position - args.search_samples:live_position + window_frames + args.search_samples],
            args.search_samples,
        )
        observations.append((relative / rate, integer, fractional, coefficient))

    good = [row for row in observations if row[3] >= args.min_correlation]
    if len(good) < 8:
        raise ValueError(f"only {len(good)} trustworthy alignment windows; initial correlation={initial_correlation:.6f}")

    integer_lags = sorted({row[1] for row in good})
    fractional_offsets = [row[2] for row in good]
    fitted_fractional_offset = float(np.median(fractional_offsets))
    fractional_residuals = [value - fitted_fractional_offset for value in fractional_offsets]
    max_fractional = max(abs(value) for value in fractional_residuals)
    rms_fractional = math.sqrt(sum(value * value for value in fractional_residuals) / len(fractional_residuals))

    print(f"sample_rate={rate}")
    print(f"constant_capture_offset_samples={constant_offset}")
    print(f"initial_correlation={initial_correlation:.9f}")
    print(f"trusted_windows={len(good)}/{len(observations)}")
    print(f"integer_timeline_lags={','.join(str(value) for value in integer_lags)}")
    print(f"fitted_fractional_offset_samples={fitted_fractional_offset:.9f}")
    print(f"fractional_residual_rms_samples={rms_fractional:.9f}")
    print(f"fractional_residual_max_samples={max_fractional:.9f}")
    for seconds, integer, fractional, coefficient in observations:
        print(f"window={seconds:.3f}s lag={integer:+d}{fractional:+.6f} correlation={coefficient:.6f}")

    failed = False
    if integer_lags != [0]:
        print("FAIL: live pipeline inserted or removed whole samples")
        failed = True
    if max_fractional > args.max_fractional_samples:
        print(
            f"FAIL: fractional residual {max_fractional:.9f} exceeds "
            f"{args.max_fractional_samples:.9f} samples"
        )
        failed = True
    if any(row[3] < args.min_correlation for row in observations):
        print("FAIL: one or more timeline windows do not match the theoretical PCM")
        failed = True
    if failed:
        return 1
    print("PASS: live PCM has no timeline steps and remains within the fractional timing limit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
