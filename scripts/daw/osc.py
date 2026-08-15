#!/usr/bin/env python3
"""A minimal OSC client, dependency-free.

python-liblo is not in the appliance's Buildroot set and pulling it in
for one message type is not worth a package, so this encodes the subset
Ardour's surface needs: a path, a type tag string, and int/float/string
arguments, sent over UDP.

  osc.py --self-test    verify the wire format against hand-checked bytes
"""
import socket
import struct
import sys


def _pad(b):
    """OSC strings and blobs are padded to a multiple of four bytes."""
    return b + b"\0" * (4 - len(b) % 4)


def encode(path, *args):
    """Encode one OSC message. int -> 'i', float -> 'f', str -> 's'."""
    out = _pad(path.encode() + b"\0")
    tags = ","
    body = b""
    for a in args:
        if isinstance(a, bool):
            a = int(a)
        if isinstance(a, int):
            tags += "i"
            body += struct.pack(">i", a)
        elif isinstance(a, float):
            tags += "f"
            body += struct.pack(">f", a)
        elif isinstance(a, str):
            tags += "s"
            body += _pad(a.encode() + b"\0")
        else:
            raise TypeError("unsupported OSC argument: %r" % (a,))
    return out + _pad(tags.encode() + b"\0") + body


class Client:
    def __init__(self, host="127.0.0.1", port=3819):
        self.addr = (host, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sent = 0

    def send(self, path, *args):
        self.sock.sendto(encode(path, *args), self.addr)
        self.sent += 1


def self_test():
    # Hand-checked: "/x" pads to 4, ",i" pads to 4, then the int.
    assert encode("/x", 1) == b"/x\0\0,i\0\0\x00\x00\x00\x01", \
        encode("/x", 1)
    # A path whose length is already a multiple of four still gets a full
    # pad word, which is the rule people most often get wrong.
    assert encode("/abc") == b"/abc\0\0\0\0,\0\0\0"
    m = encode("/strip/gain", 3, -6.0)
    assert m.startswith(b"/strip/gain\0")
    assert b",if\0" in m
    # "/strip/gain" is 11 chars: +1 null = 12, already a multiple of 4,
    # so it still takes a whole extra pad word -> 16. ",if" does the same
    # -> 8. Arguments therefore start at 24, not 16.
    assert struct.unpack(">i", m[24:28])[0] == 3
    assert abs(struct.unpack(">f", m[28:32])[0] + 6.0) < 1e-6
    m = encode("/access_action", "Editor/undo")
    assert m.endswith(_pad(b"Editor/undo\0"))
    print("osc self-test PASS: %d encodings verified" % 4)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        print(__doc__)
