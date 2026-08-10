#!/usr/bin/env python3
"""Rewrite fixed-width sample names in an MPC2000 APS file.

Usage:
    rewrite-mpc2000-aps-sample-names.py INPUT OUTPUT OLD=NEW [OLD=NEW ...]

MPC2000 APS sample references are 16-byte, space-padded ASCII fields.  This is
useful when preparing a floppy audition copy of a CD project whose sample names
do not fit FAT 8.3 filenames.
"""

from pathlib import Path
import argparse


FIELD_WIDTH = 16


def encode_name(name: str) -> bytes:
    try:
        encoded = name.encode("ascii")
    except UnicodeEncodeError as error:
        raise argparse.ArgumentTypeError(f"sample name is not ASCII: {name!r}") from error
    if not 1 <= len(encoded) <= FIELD_WIDTH:
        raise argparse.ArgumentTypeError(
            f"sample name must contain 1 to {FIELD_WIDTH} ASCII bytes: {name!r}"
        )
    return encoded.ljust(FIELD_WIDTH, b" ")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("replacements", nargs="+")
    args = parser.parse_args()

    data = args.input.read_bytes()
    for replacement in args.replacements:
        if "=" not in replacement:
            parser.error(f"replacement must be OLD=NEW: {replacement!r}")
        old, new = replacement.split("=", 1)
        old_field = encode_name(old)
        new_field = encode_name(new)
        occurrences = data.count(old_field)
        if occurrences != 1:
            parser.error(
                f"expected exactly one {old!r} reference, found {occurrences}"
            )
        data = data.replace(old_field, new_field)

    args.output.write_bytes(data)


if __name__ == "__main__":
    main()
