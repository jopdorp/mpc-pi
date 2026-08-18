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
        # Bar line a scheduled punch-out lands on; None when nothing is
        # closing. The punch is a *future* sample, not an act, which is what
        # makes it quantised - see Engine._punch_out.
        self.stop_at = None
        # Samples up to which repetitions have been laid on the timeline.
        self.filled_to = None
        # What to fall back to if an arm is cancelled before it starts.
        self._resume = None

    def arm(self, at_sample):
        # Remember what the lane was. Re-arming a lane that already holds a
        # loop is an overdub, and a punch-in/punch-out inside one bar is a
        # mis-hit that must put the loop back rather than throw it away.
        self._resume = (self.state, self.start_sample)
        self.state = "armed"
        self.start_sample = at_sample

    def cancel_arm(self):
        """Un-arm a take that never started, leaving earlier layers intact."""
        self.state, self.start_sample = self._resume or ("idle", None)
        self._resume = None

    def begin(self):
        self.state = "recording"

    def finish(self, length_samples):
        self.state = "looping"
        self.length_samples = length_samples
        # Never move the fill mark backwards. An overdub re-arms the lane, so
        # start_sample moves forward to the overdub's bar, and a plain
        # start+length would then sit behind repetitions the tick loop has
        # already laid - which it would dutifully lay again, on top.
        self.filled_to = max(self.start_sample + length_samples,
                             self.filled_to or 0)

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
        self.closing = []      # lanes punched out, waiting for their bar line

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
        if verb == "punch_out" and args:
            return self._punch_out(args[0], playhead)
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
        # Recording onto a lane that already holds a loop is an overdub, not a
        # second loop. The layer is what the panel draws as "dub", and the
        # base take keeps owning the loop's length - see tick().
        lane.layer = 1 if lane.length_samples else 0
        lane.arm(start)
        self.pending.append(lane)
        return ["arm %s at %d" % (name, start)]

    def _punch_out(self, name, playhead):
        """Schedule the end of a take on a bar line.

        Not immediate: the MPC is the clock the whole system agrees on, and a
        take that ends between bars produces a loop that will not line up with
        anything it plays against. Quantising the punch is the thing that
        makes recording usable at a keyboard's distance (docs/daw-interaction
        .md, "Recording a loop"), so it belongs here, next to the bar grid,
        rather than in whatever happens to be holding the button.
        """
        lane = self.lanes.get(name)
        if lane is None:
            return ["error no-lane " + name]
        if lane in self.pending:
            # Punched in and straight back out before the bar arrived. That
            # cancels the arm rather than closing a take. Without this the
            # lane sits armed with nothing able to close it: the panel has
            # already forgotten the strip was rolling, so no second press
            # reaches it, and it would start recording at the bar regardless.
            self.pending.remove(lane)
            lane.cancel_arm()
            return ["disarm %s" % name]
        if lane in self.closing:
            return ["error already-closing " + name]
        if lane.state != "recording":
            return ["error not-recording " + name]
        at = self.transport.next_bar_sample(playhead)
        spb = self.transport.samples_per_bar()
        if at is None or not spb:
            return ["error no-transport"]
        # At least one bar of take. Two quick taps of the same button would
        # otherwise close on the same bar line the take opened on, giving a
        # zero-length loop: silent, still drawn as a lane, and impossible to
        # tell on screen from one that never recorded.
        at = max(at, lane.start_sample + spb)
        lane.stop_at = at
        self.closing.append(lane)
        return ["punch-out %s at %d" % (name, at)]

    def _stop(self, name):
        lane = self.lanes.get(name)
        if lane is None or lane.state != "recording":
            return ["error not-recording " + name]
        length = lane.bars * self.transport.samples_per_bar()
        if lane in self.closing:
            self.closing.remove(lane)     # this stop wins over the punch
        lane.stop_at = None
        lane.finish(length)
        return ["disarm %s" % name,
                "finalize %s length %d" % (name, length)]

    def _undo(self, name):
        lane = self.lanes.get(name)
        if lane is None:
            return ["error no-lane " + name]
        # Drop any scheduled punch too. A cleared lane that was still in
        # pending would arm itself again at the next bar and record over the
        # silence the player just asked for.
        if lane in self.pending:
            self.pending.remove(lane)
        if lane in self.closing:
            self.closing.remove(lane)
        lane.state = "idle"
        lane.layer = 0
        lane.stop_at = None
        lane._resume = None
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
        for lane in list(self.closing):
            if playhead >= lane.stop_at:
                # The FIRST take fixes the loop's length; a later one is a
                # layer over it, so a two-bar dub must not shorten a four-bar
                # loop. Where the layer's region lands is the Lua side's
                # problem - it owns the playlist, we only say how long.
                length = (lane.length_samples
                          or lane.stop_at - lane.start_sample)
                self.closing.remove(lane)
                lane.stop_at = None
                lane.finish(length)
                bar = self.transport.samples_per_bar()
                if bar:
                    # The take's own length in bars, not the lane's nominal
                    # size: the player decides how long a loop is by when
                    # they punch out, and the panel counts down against this.
                    lane.bars = max(1, int(round(length / float(bar))))
                actions.append("disarm %s" % lane.name)
                actions.append("finalize %s length %d" % (lane.name, length))
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

    # Punch-out: the same bar grid, from the other end. `stop` closes where
    # it is asked to; `punch_out` closes where the music does.
    eng2 = Engine(et)
    eng2.add_lane("LOOP2", bars=4)
    assert eng2.command("rec LOOP2", playhead=10_000) == ["arm LOOP2 at 96000"]
    assert eng2.tick(96_000) == ["record-start LOOP2"]
    # Punched 100 samples into the fourth bar: closes on the NEXT bar line.
    acts = eng2.command("punch_out LOOP2", playhead=3 * 96_000 + 100)
    assert acts == ["punch-out LOOP2 at 384000"], acts
    assert eng2.tick(3 * 96_000 + 500) == [], "must not close between bars"
    # The closing tick also lays the first repetitions: a loop has to be
    # sounding by the bar after the punch, not by the next UI frame.
    acts = eng2.tick(384_000)
    assert acts == ["disarm LOOP2", "finalize LOOP2 length 288000",
                    "repeat LOOP2 at 384000 times 1"], acts
    lane2 = eng2.lanes["LOOP2"]
    # Three bars were played, so it is a three-bar loop - not the four the
    # lane was created with. The take decides.
    assert lane2.state == "looping" and lane2.bars == 3, lane2.bars

    # An overdub is a layer, and a mis-hit on it costs nothing: punching in
    # and out inside one bar cancels the arm and leaves the loop underneath.
    assert eng2.command("rec LOOP2", playhead=384_000) == \
        ["arm LOOP2 at 384000"]
    assert lane2.layer == 1, "recording over a loop is an overdub"
    assert eng2.command("punch_out LOOP2", playhead=384_000) == \
        ["disarm LOOP2"]
    assert lane2.state == "looping", lane2.state
    assert lane2.length_samples == 288_000, "cancel must not resize the loop"
    assert eng2.pending == [] and eng2.closing == []
    # A take shorter than a bar is not a take: closing on the bar it opened
    # on would give a zero-length loop, so the punch lands one bar later.
    assert eng2.command("rec LOOP2", playhead=384_000) == \
        ["arm LOOP2 at 384000"]
    assert eng2.tick(384_000) == ["record-start LOOP2"]
    acts = eng2.command("punch_out LOOP2", playhead=384_010)
    assert acts == ["punch-out LOOP2 at 480000"], acts
    # ...and the overdub keeps the base take's length rather than its own -
    # and lays no repetitions, because the ones ahead of the playhead are
    # already there. Re-laying them is what a naive start+length fill mark
    # did: two copies of the loop on top of each other, at double level.
    acts = eng2.tick(480_000)
    assert acts == ["disarm LOOP2", "finalize LOOP2 length 288000"], acts
    assert eng2.command("punch_out LOOP2", playhead=480_000) == \
        ["error not-recording LOOP2"]

    print("daw-ctl self-test PASS: "
          f"spb@120={96000} anchor={940_000} lane-refill=ok "
          f"spb@86={t.samples_per_bar()}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        print(__doc__)
        sys.exit(2)
