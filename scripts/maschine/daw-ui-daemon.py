#!/usr/bin/env python3
"""Render screen R continuously and publish it for maschine-hub.

Reads the live state daw-ctl maintains, renders the current page with
daw_ui, and writes an MPCL frame to /dev/shm/daw-ui — the same format the
emulator uses for the MPC LCD, so maschine-hub treats both screens
identically.

Frames are only rewritten when the pixels actually change, matching the
emulator's own behaviour (patch 0033): the USB write is the expensive
part, and a looper's screen is static between bar lines.

  daw-ui-daemon.py [--state FILE] [--out /dev/shm/daw-ui] [--hz 30]

The state file is JSON in the shape daw_ui.render expects. It is written
by daw-ctl; when absent the daemon renders the sample state so the screen
is never blank during bring-up.
"""
import argparse
import json
import os
import struct
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import daw_ui  # noqa: E402

HEADER_FMT = "<4sIHHI"
TRANSPORT_PATH = "/dev/shm/mpc-transport"


def write_mpcl(path, frame, seq):
    header = struct.pack(HEADER_FMT, b"MPCL", seq, frame.w, frame.h, 0)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(header)
        f.write(bytes(frame.px))
    # Atomic replace: maschine-hub may read at any moment and a torn frame
    # is a visible glitch on stage.
    os.replace(tmp, path)


def read_state(path):
    if not path:
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def read_transport(path=TRANSPORT_PATH):
    """The emulator's transport export: playing, elapsed ms, emu seconds."""
    try:
        with open(path) as f:
            parts = f.read().split()
        return int(parts[0]), int(parts[1]), float(parts[2])
    except (OSError, ValueError, IndexError):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", default="/dev/shm/daw-ui-state.json")
    ap.add_argument("--out", default="/dev/shm/daw-ui")
    ap.add_argument("--hz", type=float, default=30.0)
    ap.add_argument("--once", action="store_true",
                    help="render a single frame and exit (for tests)")
    args = ap.parse_args()

    seq = 0
    last = None
    interval = 1.0 / args.hz
    while True:
        st = read_state(args.state)
        if st is None:
            st = daw_ui.sample_state("LOOP")
        # The transport export is authoritative for the play light even if
        # daw-ctl is mid-restart, so the screen never claims we are rolling
        # when the MPC has stopped.
        tr = read_transport()
        if tr is not None:
            st["playing"] = bool(tr[0])

        frame = daw_ui.render(st)
        if frame.px != last:
            seq += 1
            write_mpcl(args.out, frame, seq)
            last = bytearray(frame.px)
        if args.once:
            print("wrote %s seq=%d" % (args.out, seq))
            return
        time.sleep(interval)


if __name__ == "__main__":
    main()
