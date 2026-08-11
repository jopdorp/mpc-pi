#!/usr/bin/env python3
"""Compare MPC DSP key-on timestamps with the sequence's theoretical tick grid."""

from __future__ import annotations

import argparse
import math
import re
from dataclasses import dataclass
from pathlib import Path
from statistics import median


KEYON_RE = re.compile(
    r"MPC_KEYON tick48m=(?P<time>\d+) channel=(?P<channel>\d+) start=(?P<start>[0-9a-fA-F]+)"
)
SEQUENCE_RE = re.compile(
    r"sequence,index=(?P<index>\d+),.*tempo_tenths=(?P<tempo>\d+),ticks_per_beat=(?P<ppqn>\d+)"
)
NOTE_RE = re.compile(r"note,tick=(?P<tick>\d+),track=(?P<track>\d+),")


@dataclass(frozen=True)
class KeyOn:
    trace_tick: int
    channel: int
    start: int


def percentile(values: list[float], percentage: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * percentage / 100.0
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def parse_track_set(value: str) -> set[int]:
    try:
        tracks = {int(item) for item in value.split(",")}
    except ValueError as error:
        raise argparse.ArgumentTypeError("tracks must be comma-separated integers") from error
    if not tracks or min(tracks) < 0:
        raise argparse.ArgumentTypeError("tracks must contain non-negative integers")
    return tracks


def read_expected(path: Path, tracks: set[int]) -> tuple[int, int, list[tuple[int, int]]]:
    active_sequence: int | None = None
    master_tempo: int | None = None
    tempo_source: str | None = None
    sequences: dict[int, tuple[int, int, list[int]]] = {}
    current_sequence: int | None = None

    for line in path.read_text().splitlines():
        if line.startswith("active_sequence="):
            active_sequence = int(line.split("=", 1)[1])
        elif line.startswith("master_tempo_tenths="):
            master_tempo = int(line.split("=", 1)[1])
        elif line.startswith("tempo_source="):
            tempo_source = line.split("=", 1)[1]
        elif match := SEQUENCE_RE.match(line):
            current_sequence = int(match.group("index"))
            sequences[current_sequence] = (
                int(match.group("tempo")),
                int(match.group("ppqn")),
                [],
            )
        elif (match := NOTE_RE.match(line)) and current_sequence is not None:
            if int(match.group("track")) in tracks:
                sequences[current_sequence][2].append(int(match.group("tick")))

    if active_sequence is None or active_sequence not in sequences:
        raise ValueError("dump does not identify a valid active sequence")
    if tempo_source not in {"master", "sequence"}:
        raise ValueError("dump does not identify the tempo source")
    sequence_tempo, ppqn, note_ticks = sequences[active_sequence]
    tempo = master_tempo if tempo_source == "master" else sequence_tempo
    if tempo is None or tempo <= 0 or ppqn <= 0:
        raise ValueError("dump contains an invalid tempo or PPQN")

    groups: list[tuple[int, int]] = []
    for tick in note_ticks:
        if groups and groups[-1][0] == tick:
            groups[-1] = (tick, groups[-1][1] + 1)
        else:
            groups.append((tick, 1))
    if not groups:
        raise ValueError("selected tracks contain no note events")
    return tempo, ppqn, groups


def read_keyons(path: Path) -> list[KeyOn]:
    keyons = []
    for line in path.read_text().splitlines():
        if match := KEYON_RE.search(line):
            keyons.append(
                KeyOn(
                    int(match.group("time")),
                    int(match.group("channel")),
                    int(match.group("start"), 16),
                )
            )
    if not keyons:
        raise ValueError(f"{path}: no MPC_KEYON records found")
    return keyons


def group_keyons(keyons: list[KeyOn], half_tick_trace_clocks: float) -> list[list[KeyOn]]:
    groups: list[list[KeyOn]] = []
    for keyon in keyons:
        if not groups or keyon.trace_tick - groups[-1][-1].trace_tick >= half_tick_trace_clocks:
            groups.append([keyon])
        else:
            groups[-1].append(keyon)
    return groups


def timing_stats(
    groups: list[list[KeyOn]],
    expected: list[tuple[int, int]],
    samples_per_tick: float,
    sample_rate: int,
    trace_clock: int,
) -> tuple[float, list[float]]:
    actual_samples = [group[0].trace_tick * sample_rate / trace_clock for group in groups]
    theoretical_samples = [tick * samples_per_tick for tick, _ in expected[: len(groups)]]
    offsets = [actual - theoretical for actual, theoretical in zip(actual_samples, theoretical_samples)]
    constant_offset = median(offsets)
    return constant_offset, [offset - constant_offset for offset in offsets]


def print_stats(label: str, residuals: list[float], sample_rate: int) -> None:
    absolute = [abs(value) for value in residuals]
    print(f"{label}_median_abs_samples={median(absolute):.6f}")
    print(f"{label}_p95_abs_samples={percentile(absolute, 95):.6f}")
    print(f"{label}_max_abs_samples={max(absolute):.6f}")
    print(f"{label}_max_abs_us={max(absolute) * 1_000_000 / sample_rate:.3f}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sequence_dump", type=Path)
    parser.add_argument("accurate_trace", type=Path)
    parser.add_argument("speed_trace", type=Path)
    parser.add_argument("--tracks", type=parse_track_set, default={0, 1, 2})
    parser.add_argument("--sample-rate", type=int, default=48_000)
    parser.add_argument("--trace-clock", type=int, default=48_000_000)
    parser.add_argument("--max-theoretical-us", type=float, default=1_100.0)
    parser.add_argument("--max-relative-us", type=float, default=900.0)
    args = parser.parse_args()

    tempo_tenths, ppqn, expected = read_expected(args.sequence_dump, args.tracks)
    samples_per_tick = args.sample_rate * 600.0 / (tempo_tenths * ppqn)
    half_tick_trace_clocks = samples_per_tick * args.trace_clock / args.sample_rate / 2.0
    accurate_keyons = read_keyons(args.accurate_trace)
    speed_keyons = read_keyons(args.speed_trace)
    accurate_groups = group_keyons(accurate_keyons, half_tick_trace_clocks)
    speed_groups = group_keyons(speed_keyons, half_tick_trace_clocks)

    if [(item.channel, item.start) for item in accurate_keyons] != [
        (item.channel, item.start) for item in speed_keyons
    ]:
        raise ValueError("speed mode changed DSP key-on order, channel, or sample address")
    if len(accurate_groups) != len(speed_groups):
        raise ValueError("accurate and speed modes produced different key-on group counts")
    if len(accurate_groups) > len(expected):
        raise ValueError("trace contains more key-on groups than expected sequence events")

    expected_sizes = [count for _, count in expected[: len(accurate_groups)]]
    for label, groups in (("accurate", accurate_groups), ("speed", speed_groups)):
        if [len(group) for group in groups] != expected_sizes:
            raise ValueError(f"{label} key-on group sizes do not match the sequence")

    accurate_offset, accurate_residuals = timing_stats(
        accurate_groups, expected, samples_per_tick, args.sample_rate, args.trace_clock
    )
    speed_offset, speed_residuals = timing_stats(
        speed_groups, expected, samples_per_tick, args.sample_rate, args.trace_clock
    )
    relative_residuals = [
        speed - accurate for speed, accurate in zip(speed_residuals, accurate_residuals)
    ]

    print(f"tempo_bpm={tempo_tenths / 10:.1f}")
    print(f"ppqn={ppqn}")
    print(f"samples_per_tick={samples_per_tick:.9f}")
    print(f"compared_tick_groups={len(accurate_groups)}")
    print(f"compared_keyons={len(accurate_keyons)}")
    print(f"accurate_constant_offset_samples={accurate_offset:.6f}")
    print(f"speed_constant_offset_samples={speed_offset:.6f}")
    print_stats("accurate_theoretical", accurate_residuals, args.sample_rate)
    print_stats("speed_theoretical", speed_residuals, args.sample_rate)
    print_stats("speed_vs_accurate", relative_residuals, args.sample_rate)

    speed_max_us = max(abs(value) for value in speed_residuals) * 1_000_000 / args.sample_rate
    relative_max_us = max(abs(value) for value in relative_residuals) * 1_000_000 / args.sample_rate
    if speed_max_us > args.max_theoretical_us:
        print("FAIL: speed mode exceeds the theoretical-grid timing limit")
        return 1
    if relative_max_us > args.max_relative_us:
        print("FAIL: speed mode differs too far from accurate mode after constant-offset removal")
        return 1
    print("PASS: speed mode preserves event identity and stays within both timing limits")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
