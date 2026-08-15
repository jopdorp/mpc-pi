#!/usr/bin/env python3
"""daw-ctl: the loop engine between the MPC emulator and headless Ardour.

Responsibilities (docs/maschine-daw-design.md):
  * follow the MPC's transport (tempo, bar position) from the emulator's
    shared-memory transport export, or from MIDI clock when an external
    device is the master;
  * quantize loop record arm/disarm to MPC bar boundaries;
  * keep loop lanes sounding by laying captured regions ahead of the
    playhead on Ardour's timeline;
  * expose a line protocol on a FIFO so the Maschine UI (and tests) can
    drive it.

Ardour itself is driven through its Lua session, which owns the audio
objects; daw-ctl sends it commands and never touches audio directly. The
Ardour transport free-runs: both it and the emulator share one hardware
clock, so bar positions are exact sample arithmetic, not a chase.

This module is the control core with no I/O side effects, so it is
testable without an emulator or a DAW:  daw_ctl.py --self-test
"""
import os
import sys
import time

# --- transport model -------------------------------------------------


class Transport:
    """The MPC's musical time, expressed in Ardour sample coordinates."""

    def __init__(self, rate=48000, beats_per_bar=4):
        self.rate = rate
        self.beats_per_bar = beats_per_bar
        self.bpm = None
        self.playing = False
        # Sample position of the most recent bar line, and its bar number.
        self.bar_anchor_sample = None
        self.bar_anchor_number = None

    def samples_per_bar(self):
        if not self.bpm:
            return None
        return int(round(self.rate * 60.0 / self.bpm * self.beats_per_bar))

    def update_from_export(self, playing, elapsed_ms, now_sample):
        """Feed one line of the emulator's transport export.

        The export carries elapsed playback milliseconds (see
        scripts/daw/transport-export.lua); combined with the session tempo
        that fixes the bar grid exactly, because playback starts on a bar
        line. `bpm` must already be set (from the UI or the project).
        """
        self.playing = bool(playing)
        spb = self.samples_per_bar()
        if spb is None or not self.playing:
            return
        samples_elapsed = int(round(elapsed_ms * self.rate / 1000.0))
        bars_elapsed, into_bar = divmod(samples_elapsed, spb)
        self.bar_anchor_sample = now_sample - into_bar
        self.bar_anchor_number = bars_elapsed + 1

    def update(self, bpm, bar, beat, tick, ticks_per_beat, now_sample):
        """Feed one transport observation with explicit musical fields."""
        self.bpm = bpm
        spb = self.samples_per_bar()
        if spb is None:
            return
        # Fraction of the current bar already elapsed.
        beat_fraction = (beat - 1 + tick / float(ticks_per_beat))
        into_bar = int(round(spb * beat_fraction / self.beats_per_bar))
        self.bar_anchor_sample = now_sample - into_bar
        self.bar_anchor_number = bar

    def next_bar_sample(self, after_sample):
        """First bar line at or after `after_sample`."""
        spb = self.samples_per_bar()
        if spb is None or self.bar_anchor_sample is None:
            return None
        delta = after_sample - self.bar_anchor_sample
        bars = -(-delta // spb) if delta > 0 else 0  # ceil for positives
        return self.bar_anchor_sample + bars * spb


# --- loop lanes ------------------------------------------------------


class Lane:
    """One loop lane: a base track and its overdub partner."""

    def __init__(self, name, bars=2):
        self.name = name
        self.bars = bars
        self.state = "idle"      # idle | armed | recording | looping
        self.layer = 0           # 0 = base, 1 = overdub
        self.start_sample = None
        self.length_samples = None
        # Samples up to which repetitions have been laid on the timeline.
        self.filled_to = None

    def arm(self, at_sample):
        self.state = "armed"
        self.start_sample = at_sample

    def begin(self):
        self.state = "recording"

    def finish(self, length_samples):
        self.state = "looping"
        self.length_samples = length_samples
        self.filled_to = self.start_sample + length_samples

    def repetitions_needed(self, playhead, lookahead_samples):
        """How many copies to lay so the lane stays sounding."""
        if self.state != "looping" or not self.length_samples:
            return 0
        target = playhead + lookahead_samples
        if self.filled_to >= target:
            return 0
        missing = target - self.filled_to
        return int(-(-missing // self.length_samples))  # ceil

    def note_filled(self, count):
        self.filled_to += count * self.length_samples


# --- self test -------------------------------------------------------


def self_test():
    rate = 48000
    t = Transport(rate=rate)
    # 120 BPM, 4/4: one bar = 96000 samples. Observed at bar 5, beat 3,
    # tick 48 of 96, with the DAW playhead at sample 1_000_000.
    t.update(bpm=120.0, bar=5, beat=3, tick=48, ticks_per_beat=96,
             now_sample=1_000_000)
    assert t.samples_per_bar() == 96000, t.samples_per_bar()
    # 2.5 beats into the bar = 60000 samples.
    assert t.bar_anchor_sample == 940_000, t.bar_anchor_sample
    assert t.next_bar_sample(1_000_000) == 1_036_000, t.next_bar_sample(1_000_000)
    assert t.next_bar_sample(940_000) == 940_000
    assert t.next_bar_sample(940_001) == 1_036_000

    lane = Lane("LOOP1", bars=2)
    lane.arm(t.next_bar_sample(1_000_000))
    lane.begin()
    lane.finish(2 * 96000)
    assert lane.filled_to == 1_036_000 + 192_000
    # Playhead approaching the end of what is laid out: needs more copies.
    need = lane.repetitions_needed(playhead=1_200_000, lookahead_samples=192_000)
    assert need == 1, need
    lane.note_filled(need)
    assert lane.repetitions_needed(1_200_000, 192_000) == 0

    # Export path: 4.5 bars of elapsed playback at 120 BPM puts the
    # playhead half a bar past a bar line.
    e = Transport(rate=rate)
    e.bpm = 120.0
    e.update_from_export(playing=1, elapsed_ms=4500 * 2, now_sample=5_000_000)
    assert e.playing
    assert e.bar_anchor_number == 5, e.bar_anchor_number
    assert e.bar_anchor_sample == 5_000_000 - 48000, e.bar_anchor_sample
    assert e.next_bar_sample(5_000_000) == 5_000_000 + 48000
    e.update_from_export(playing=0, elapsed_ms=9000, now_sample=6_000_000)
    assert not e.playing

    # Tempo change is reflected immediately.
    t.update(bpm=86.0, bar=6, beat=1, tick=0, ticks_per_beat=96,
             now_sample=2_000_000)
    assert t.samples_per_bar() == int(round(48000 * 60 / 86 * 4))
    assert t.bar_anchor_sample == 2_000_000
    print("daw-ctl self-test PASS: "
          f"spb@120={96000} anchor={940_000} lane-refill=ok "
          f"spb@86={t.samples_per_bar()}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        print(__doc__)
        sys.exit(2)
