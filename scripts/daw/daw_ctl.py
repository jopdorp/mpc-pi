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


# --- the engine ------------------------------------------------------


class Engine:
    """Turns UI commands plus transport observations into DAW actions.

    Actions are emitted as plain strings for the Ardour Lua side to run;
    keeping them declarative is what makes the whole loop lifecycle
    testable without an audio graph. The Maschine UI drives the same
    commands, so what the tests exercise is what the hardware does.
    """

    LOOKAHEAD_BARS = 2

    def __init__(self, transport, lanes=None):
        self.transport = transport
        self.lanes = lanes or {}
        self.pending = []      # lanes armed, waiting for their bar line

    def add_lane(self, name, bars=2):
        self.lanes[name] = Lane(name, bars=bars)
        return self.lanes[name]

    def command(self, text, playhead):
        """Handle one UI command; returns the actions to perform."""
        parts = text.split()
        if not parts:
            return []
        verb, args = parts[0], parts[1:]
        if verb == "rec" and args:
            return self._rec(args[0], playhead)
        if verb == "stop" and args:
            return self._stop(args[0])
        if verb == "undo" and args:
            return self._undo(args[0])
        return ["error unknown-command " + verb]

    def _rec(self, name, playhead):
        lane = self.lanes.get(name)
        if lane is None:
            return ["error no-lane " + name]
        start = self.transport.next_bar_sample(playhead)
        if start is None:
            return ["error no-transport"]
        lane.arm(start)
        self.pending.append(lane)
        return ["arm %s at %d" % (name, start)]

    def _stop(self, name):
        lane = self.lanes.get(name)
        if lane is None or lane.state != "recording":
            return ["error not-recording " + name]
        length = lane.bars * self.transport.samples_per_bar()
        lane.finish(length)
        return ["disarm %s" % name,
                "finalize %s length %d" % (name, length)]

    def _undo(self, name):
        lane = self.lanes.get(name)
        if lane is None:
            return ["error no-lane " + name]
        lane.state = "idle"
        lane.filled_to = None
        lane.length_samples = None
        return ["clear %s" % name]

    def tick(self, playhead):
        """Call every UI frame: starts due recordings, tops up loops."""
        actions = []
        for lane in list(self.pending):
            if playhead >= lane.start_sample:
                lane.begin()
                self.pending.remove(lane)
                actions.append("record-start %s" % lane.name)
        spb = self.transport.samples_per_bar()
        if spb:
            lookahead = self.LOOKAHEAD_BARS * spb
            for lane in self.lanes.values():
                need = lane.repetitions_needed(playhead, lookahead)
                if need:
                    actions.append("repeat %s at %d times %d"
                                   % (lane.name, lane.filled_to, need))
                    lane.note_filled(need)
        return actions


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
    # Engine: a full loop lifecycle, quantized to bar lines.
    et = Transport(rate=rate)
    et.bpm = 120.0
    et.update_from_export(playing=1, elapsed_ms=0, now_sample=0)
    eng = Engine(et)
    eng.add_lane("LOOP1", bars=2)
    acts = eng.command("rec LOOP1", playhead=10_000)
    assert acts == ["arm LOOP1 at 96000"], acts
    # Nothing happens until the bar line arrives.
    assert eng.tick(50_000) == []
    assert eng.tick(96_000) == ["record-start LOOP1"], "should start on the bar"
    acts = eng.command("stop LOOP1", playhead=96_000 + 192_000)
    assert acts == ["disarm LOOP1", "finalize LOOP1 length 192000"], acts
    # The lane now needs repetitions laid ahead of the playhead.
    # Lookahead is 2 bars, so from 300000 the lane must be filled to
    # 492000: two more copies of the 192000-sample loop.
    acts = eng.tick(300_000)
    assert acts == ["repeat LOOP1 at 288000 times 2"], acts
    assert eng.tick(300_000) == [], "must not re-lay the same region"
    assert eng.command("undo LOOP1", playhead=0) == ["clear LOOP1"]
    assert eng.tick(400_000) == [], "cleared lane stays silent"
    assert eng.command("rec NOPE", playhead=0) == ["error no-lane NOPE"]

    print("daw-ctl self-test PASS: "
          f"spb@120={96000} anchor={940_000} lane-refill=ok "
          f"spb@86={t.samples_per_bar()}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        print(__doc__)
        sys.exit(2)
