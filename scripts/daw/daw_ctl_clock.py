#!/usr/bin/env python3
"""MPC MIDI-clock reader for daw-ctl: tempo estimate and bar grid.

The MPC emulator's MIDI out lands on a raw ALSA MIDI device (virmidi on the
appliance); this module reads the byte stream, extracts the System Realtime
bytes (which may legally appear in the middle of any other message), counts
24-PPQN clocks and derives:

  - running tempo estimate (median clock interval over a window)
  - bar boundaries every 96 clocks (4/4), phase-anchored at MIDI Start

daw-ctl uses the bar grid to quantize loop record start/stop; the Ardour
transport itself free-runs (see docs/maschine-daw-design.md,
"Synchronization").

Usage:
  daw_ctl_clock.py /dev/snd/midiC1D0        # follow a device, print events
  daw_ctl_clock.py --self-test              # synthetic verification
"""
import sys
import time

CLOCK, START, CONTINUE, STOP = 0xF8, 0xFA, 0xFB, 0xFC


class ClockTracker:
    """Consumes raw MIDI bytes; reports tempo and bar boundaries."""

    def __init__(self, ppqn=24, beats_per_bar=4, window=48,
                 on_bar=None, on_start=None, on_stop=None):
        self.ppqn = ppqn
        self.clocks_per_bar = ppqn * beats_per_bar
        self.window = window
        self.on_bar = on_bar
        self.on_start = on_start
        self.on_stop = on_stop
        self.running = False
        self.clock_count = 0
        self.bar_count = 0
        self._intervals = []
        self._last_clock_t = None

    def feed(self, data, now=None):
        """Feed raw bytes; `now` (seconds) defaults to time.monotonic()."""
        for byte in data:
            self._byte(byte, now if now is not None else time.monotonic())

    def _byte(self, b, now):
        if b < 0xF8:
            return  # channel/system-common traffic; realtime only here
        if b == START:
            self.running = True
            self.clock_count = 0
            self.bar_count = 0
            self._last_clock_t = None
            if self.on_start:
                self.on_start()
        elif b == CONTINUE:
            self.running = True
        elif b == STOP:
            self.running = False
            if self.on_stop:
                self.on_stop()
        elif b == CLOCK:
            if self._last_clock_t is not None:
                self._intervals.append(now - self._last_clock_t)
                if len(self._intervals) > self.window:
                    self._intervals.pop(0)
            self._last_clock_t = now
            if self.running:
                self.clock_count += 1
                if self.clock_count % self.clocks_per_bar == 0:
                    self.bar_count += 1
                    if self.on_bar:
                        self.on_bar(self.bar_count)

    @property
    def bpm(self):
        if len(self._intervals) < 4:
            return None
        xs = sorted(self._intervals)
        median = xs[len(xs) // 2]
        if median <= 0:
            return None
        return 60.0 / (median * self.ppqn)

    def samples_per_bar(self, rate=48000):
        b = self.bpm
        if b is None:
            return None
        return int(round(rate * 60.0 / b * 4))


def self_test():
    bars = []
    t = ClockTracker(on_bar=lambda n: bars.append(n))
    # Interleave clocks inside a note-on message: realtime bytes are legal
    # mid-message and must not confuse the tracker.
    bpm = 120.0
    dt = 60.0 / bpm / 24.0
    now = 0.0
    t.feed([START], now)
    stream = []
    # two bars of clocks with a note-on split across clock bytes
    for i in range(192):
        stream.append((CLOCK, now + i * dt))
        if i == 10:
            stream.append((0x90, now + i * dt + 0.001))
            stream.append((CLOCK, now + (i + 1) * dt))  # mid-message clock
            stream.append((60, now + i * dt + 0.002))
            stream.append((0x64, now + i * dt + 0.003))
            # skip the next loop clock to keep count at 192 total
    fed = 0
    for byte, ts in stream:
        t.feed([byte], ts)
        if byte == CLOCK:
            fed += 1
    assert fed == 193, fed  # 192 + 1 interleaved
    assert t.clock_count == 193, t.clock_count
    assert bars == [1, 2], bars
    est = t.bpm
    assert est is not None and abs(est - bpm) < 0.5, est
    spb = t.samples_per_bar()
    assert spb is not None and abs(spb - 96000) < 200, spb
    print(f"self-test PASS: bpm={est:.2f} samples_per_bar={spb} bars={bars}")


def follow(path):
    t = ClockTracker(
        on_bar=lambda n: print(f"bar {n} bpm={t.bpm and round(t.bpm, 2)}"),
        on_start=lambda: print("START"),
        on_stop=lambda: print("STOP"))
    with open(path, "rb", buffering=0) as f:
        while True:
            data = f.read(64)
            if data:
                t.feed(data)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    elif len(sys.argv) > 1:
        follow(sys.argv[1])
    else:
        print(__doc__)
        sys.exit(2)
