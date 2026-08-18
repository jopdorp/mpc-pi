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
    """Align to a multiple of four. The CALLER supplies the terminator.

    This was `4 - len(b) % 4`, which adds a whole extra word when the input is
    already aligned. Callers pass the string WITH its mandatory null, so an
    address of 11 characters arrives here as 12 bytes - aligned - and came back
    16. Same for a two-argument type tag: ",if" plus its null is 4, and came
    back 8.

    liblo, which is what Ardour parses with, drops a malformed packet without a
    word. So /strip/gain - eleven characters, two arguments, wrong twice over -
    was sent, accepted by the socket, and silently discarded. Ardour listened on
    3819 and did nothing, which reads exactly like a disabled surface.

    Only strings of length 3 mod 4 were affected, which is why the two vectors
    in the self-test both passed: "/x" and "/abc" are not.
    """
    return b + b"\0" * (-len(b) % 4)


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
    # pad word, because the null terminator is mandatory and pushes it over.
    assert encode("/abc") == b"/abc\0\0\0\0,\0\0\0"
    # THE CASE THAT WAS WRONG: length 3 mod 4, so the terminator lands exactly
    # on the boundary and NOTHING more may be added. Both the address and the
    # type tag hit it here, and Ardour's parser dropped the result in silence.
    assert encode("/save_state") == b"/save_state\0,\0\0\0", \
        encode("/save_state")
    assert encode("/strip/gain", 1, -6.5) == (
        b"/strip/gain\0" + b",if\0"
        + struct.pack(">i", 1) + struct.pack(">f", -6.5)), \
        encode("/strip/gain", 1, -6.5)
    # Every real path the panel sends must survive a round trip through a
    # decoder that is strict about it.
    for _p, _a in (("/strip/gain", (3, -6.5)), ("/strip/mute", (4, 1)),
                   ("/strip/recenable", (2, 1)), ("/save_state", ()),
                   ("/set_surface/bank_size", (0,))):
        _m = encode(_p, *_a)
        assert len(_m) % 4 == 0, "%s is not word aligned" % _p
        assert _m.startswith(_p.encode() + b"\0"), _p
        _addr = _m[:(len(_p) // 4 + 1) * 4]
        assert _addr.rstrip(b"\0") == _p.encode(), (_p, _addr)
    m = encode("/strip/gain", 3, -6.0)
    assert m.startswith(b"/strip/gain\0")
    assert b",if\0" in m
    # "/strip/gain" is 11 chars: +1 null = 12, ALREADY a multiple of 4, so
    # nothing more may be added. ",if" +1 null = 4, likewise. Arguments start
    # at 16.
    #
    # This assertion previously said 24, with a comment explaining that an
    # aligned string "still takes a whole extra pad word". It does not - that
    # is the bug, written down as the specification, which is why every vector
    # here passed while Ardour silently dropped the packets.
    assert struct.unpack(">i", m[16:20])[0] == 3
    assert abs(struct.unpack(">f", m[20:24])[0] + 6.0) < 1e-6
    m = encode("/access_action", "Editor/undo")
    assert m.endswith(_pad(b"Editor/undo\0"))
    print("osc self-test PASS: word alignment verified on every real path")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        print(__doc__)
