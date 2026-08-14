#!/usr/bin/env python3
"""Bridge Maschine MK1 pads, buttons and encoders to the emulator as MIDI.

Report formats follow shaduzlabs/cabl (MaschineMK1.cpp):

  endpoint 0x84: pad data. Pairs of bytes; high nibble of the first byte is
      the pad index, the remaining 12 bits are pressure. cabl treats >200 as
      pressed.
  endpoint 0x81: byte 0 selects the report: 0x02 encoders (11 16-bit values),
      0x04 buttons (bitfield; byte 6 bit 6 gates validity).

Output is MIDI bytes written to a raw ALSA MIDI port (a snd-virmidi port on
the appliance). The emulator opens the matching port as -midiin1 and patch
0020 turns the messages into panel events:

  pads     -> notes 36-51, velocity from pad pressure
  buttons  -> notes 52-97, one per MPC panel key (see BUTTON_TO_KEYCODE)
  encoder  -> mapped onto the DATA wheel keys is not possible over MIDI, so
              the main encoder emits the panel key codes for Step </> as a
              stand-in until a dedicated mapping exists.

The MPC key codes and their note mapping are documented in
docs/mpc2000xl-panel-protocol.md: note = 52 + keycode - 1.
"""

import argparse
import sys
import time

MK1_VENDOR = 0x17CC
EP_PADS = 0x84
EP_CTRL = 0x81
PAD_THRESHOLD = 200

# MPC panel key codes (docs/mpc2000xl-panel-protocol.md). A button press sends
# note 52 + code - 1 so the emulator's note-to-key mapping lands on the code.
KEY = {
    'soft1': 0x01, 'soft2': 0x02, 'soft3': 0x03, 'soft4': 0x04,
    'soft5': 0x05, 'soft6': 0x06,
    'midi_sync': 0x07, 'enter': 0x08, 'load': 0x09, 'program': 0x0a,
    'main_screen': 0x0b, 'window': 0x0c, 'other': 0x0d, 'misc': 0x0e,
    'song': 0x0f, 'trim': 0x10, 'sample': 0x11, 'mixer': 0x12,
    'shift': 0x13, 'zero': 0x14, 'after': 0x15, 'tap_tempo': 0x16,
    'undo': 0x17, 'erase': 0x18,
    'step_left': 0x19, 'step_right': 0x1a, 'go_to': 0x1b,
    'record': 0x1c, 'over_dub': 0x1d, 'stop': 0x1e, 'play': 0x1f,
    'bar_left': 0x20, 'down': 0x21, 'right': 0x22, 'left': 0x23,
    'up': 0x24, 'bank_a': 0x25, 'full_level': 0x26, 'sixteen_levels': 0x27,
    'bar_right': 0x28, 'play_start': 0x29, 'next_seq': 0x2a,
    'track_mute': 0x2b, 'bank_b': 0x2c, 'bank_c': 0x2d, 'bank_d': 0x2e,
}

# Maschine MK1 button bit positions (cabl Button enum order) to MPC keys.
# Only the confidently useful ones are pre-mapped; everything else emits
# nothing until mapped here deliberately. Bit positions follow cabl's
# processButtons: position = byte_index * 8 + bit, starting at report byte 1.
BUTTON_TO_KEYCODE = {
    # cabl name          mpc key
    'play':      KEY['play'],
    'rec':       KEY['record'],
    'erase':     KEY['erase'],
    'shift':     KEY['shift'],
    'grid':      KEY['sixteen_levels'],
    'transport_right': KEY['bar_right'],
    'transport_left':  KEY['bar_left'],
    'group_a':   KEY['bank_a'],
    'group_b':   KEY['bank_b'],
    'group_c':   KEY['bank_c'],
    'group_d':   KEY['bank_d'],
    'browse':    KEY['main_screen'],
    'sampling':  KEY['sample'],
    'note_repeat': KEY['after'],
    'f1':        KEY['soft1'],
    'f2':        KEY['soft2'],
    'f3':        KEY['soft3'],
}

# cabl Button enum for the MK1, in bit order. Names lowered; entries we do
# not map still consume their bit position.
MK1_BUTTONS = [
    'mute', 'solo', 'select', 'duplicate', 'navigate', 'keyboard', 'pattern',
    'scene', 'shift', 'erase', 'grid', 'transport_right', 'rec', 'play',
    'f3', 'f2', 'f1', 'control', 'nav_right', 'nav_left', 'main',
    'group_h', 'group_g', 'group_f', 'group_e', 'group_d', 'group_c',
    'group_b', 'group_a', 'auto_write', 'snap', 'note_repeat', 'sampling',
    'browse', 'step', 'transport_left', 'restart',
]


def open_midi(port_path):
    return open(port_path, 'wb', buffering=0)


class Bridge:
    def __init__(self, midi, verbose=False):
        self.midi = midi
        self.verbose = verbose
        self.pad_state = [0] * 16
        self.button_state = 0

    def send(self, *data):
        self.midi.write(bytes(data))

    def note(self, note, velocity):
        if velocity:
            self.send(0x90, note & 0x7F, velocity & 0x7F)
        else:
            self.send(0x80, note & 0x7F, 0)

    def pads(self, report):
        # Pairs: index in the high nibble, 12-bit pressure below it.
        for i in range(0, len(report) - 1, 2):
            pad = (report[i] & 0xF0) >> 4
            pressure = ((report[i] & 0x0F) << 8) | report[i + 1]
            was = self.pad_state[pad]
            if pressure > PAD_THRESHOLD and not was:
                velocity = max(1, min(127, pressure >> 5))
                self.note(36 + pad, velocity)
                self.pad_state[pad] = pressure
                if self.verbose:
                    print(f"pad {pad + 1} down p={pressure} v={velocity}")
            elif pressure <= PAD_THRESHOLD and was:
                self.note(36 + pad, 0)
                self.pad_state[pad] = 0
                if self.verbose:
                    print(f"pad {pad + 1} up")

    def buttons(self, report):
        if len(report) < 7 or not (report[6] & 0x40):
            return
        bits = 0
        for byte_index in range(1, 6):
            bits |= report[byte_index] << ((byte_index - 1) * 8)
        changed = bits ^ self.button_state
        self.button_state = bits
        for position, name in enumerate(MK1_BUTTONS):
            if not (changed >> position) & 1:
                continue
            code = BUTTON_TO_KEYCODE.get(name)
            down = (bits >> position) & 1
            if self.verbose:
                print(f"button {name} {'down' if down else 'up'}"
                      f"{'' if code else ' (unmapped)'}")
            if code is None:
                continue
            self.note(52 + code - 1, 0x7F if down else 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--midi", default="/dev/snd/midiC1D0",
                    help="raw MIDI device to write into (virmidi port)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    import usb.core
    dev = usb.core.find(idVendor=MK1_VENDOR)
    if dev is None:
        sys.exit("no Maschine MK1 found (vendor 0x17cc)")
    if dev.is_kernel_driver_active(0):
        dev.detach_kernel_driver(0)
    dev.set_configuration()

    bridge = Bridge(open_midi(args.midi), verbose=args.verbose)
    print(f"bridging MK1 input -> {args.midi}")
    while True:
        for endpoint, handler in ((EP_PADS, bridge.pads),
                                  (EP_CTRL, None)):
            try:
                data = dev.read(endpoint, 64, timeout=5)
            except Exception:
                continue
            if endpoint == EP_PADS:
                handler(bytes(data))
            else:
                payload = bytes(data)
                if payload and payload[0] == 0x04:
                    bridge.buttons(payload)
                # 0x02 encoder reports: deliberately unhandled until measured
                # against real hardware; see the module docstring.


if __name__ == "__main__":
    main()
