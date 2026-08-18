#!/usr/bin/env python3
"""Hit MPC2000XL pads over VirMIDI 0-0 so the monitor capture has continuous
sounding audio to judge. Writing to the virmidi RAW device is what puts events
on the sequencer port MAME subscribes to; sending TO the port does not."""
import os, sys, time
dur = float(sys.argv[1]) if len(sys.argv) > 1 else 25.0
fd = os.open("/dev/snd/midiC0D0", os.O_WRONLY)
end = time.monotonic() + dur
note, i = 36, 0
while time.monotonic() < end:
    n = 36 + (i % 16)
    os.write(fd, bytes([0x99, n, 110]))
    time.sleep(0.055)
    os.write(fd, bytes([0x89, n, 0]))
    time.sleep(0.070)
    i += 1
os.close(fd)
