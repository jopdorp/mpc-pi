#!/usr/bin/env python3
"""Find floppy images the MPC can be given, and remember where you were.

Separated from the panel and from MAME on purpose: listing a directory,
deciding what counts as a disk, and tracking a cursor are all things worth
testing without a controller plugged in or an emulator running.

WHAT COUNTS AS A DISK. The MPC2000XL reads 1.44MB DD/HD floppies, so a
raw image is 1474560 bytes. Anything else with a disk-ish extension is
still listed - the emulator is the authority on what it can mount, and a
browser that silently hides files is a browser you stop trusting - but a
wrong-sized image is marked, so a 5MB .iso does not look like a floppy.

SOURCES ARE SHOWN EVEN WHEN THEY ARE NOT READABLE. A USB stick that is
plugged in but not mounted is a fact the player needs; omitting it makes
the panel look broken rather than the stick.
"""
import os

FLOPPY_BYTES = 1474560
DISK_EXT = (".img", ".ima", ".dsk", ".iso", ".mfm", ".hfe")

# Where to look. The first is the appliance's own library; the rest are
# where a removable volume shows up once something has mounted it.
DEFAULT_ROOTS = (
    ("LIBRARY", "/opt/mpc-media"),
    ("USB", "/media"),
    ("USB2", "/mnt"),
    ("RUN", "/run/media"),
)


class Entry:
    """One row in the listing: a directory, a disk, or a dud."""

    def __init__(self, name, path, kind, size=0):
        self.name = name
        self.path = path
        self.kind = kind          # "dir" | "disk" | "other"
        self.size = size

    @property
    def exact(self):
        """A disk of exactly the right size for the emulated drive."""
        return self.kind == "disk" and self.size == FLOPPY_BYTES

    def label(self):
        if self.kind == "dir":
            return self.name[:18] + "/"
        if self.kind == "disk" and not self.exact:
            return self.name[:18]
        return self.name[:18]

    def __repr__(self):
        return "<%s %s %d>" % (self.kind, self.name, self.size)


def classify(path, name, size):
    if name.lower().endswith(DISK_EXT):
        return Entry(name, path, "disk", size)
    return Entry(name, path, "other", size)


def listing(directory, show_hidden=False):
    """Directories first, then disks, each alphabetical.

    Sorted this way because you navigate with a single wheel: grouping
    means one long turn rather than hunting past interleaved names.
    """
    dirs, disks, others = [], [], []
    try:
        names = sorted(os.listdir(directory), key=str.lower)
    except OSError:
        return []
    for n in names:
        if not show_hidden and n.startswith("."):
            continue
        p = os.path.join(directory, n)
        try:
            if os.path.isdir(p):
                dirs.append(Entry(n, p, "dir"))
                continue
            size = os.path.getsize(p)
        except OSError:
            continue
        e = classify(p, n, size)
        (disks if e.kind == "disk" else others).append(e)
    return dirs + disks + others


class Browser:
    """A cursor over a directory tree, with the sources as its root."""

    def __init__(self, roots=None):
        self.roots = list(roots or DEFAULT_ROOTS)
        self.stack = []           # directories descended into
        self.cursor = 0
        self.message = ""

    # --- where we are ---

    def at_root(self):
        return not self.stack

    def cwd(self):
        return self.stack[-1] if self.stack else None

    def sources(self):
        """The root listing: one row per source, present or not.

        A source that does not exist is still a row. The player needs to
        see that USB is a thing that could hold a disk, and that this one
        is empty or unmounted, rather than wondering why it vanished.
        """
        out = []
        for label, path in self.roots:
            ok = os.path.isdir(path)
            n = len([e for e in listing(path) if e.kind in ("dir", "disk")]) if ok else 0
            e = Entry(label, path, "dir" if ok else "missing")
            e.size = n
            e.present = ok
            out.append(e)
        return out

    def rows(self):
        return self.sources() if self.at_root() else listing(self.cwd())

    def current(self):
        r = self.rows()
        if not r:
            return None
        return r[max(0, min(self.cursor, len(r) - 1))]

    # --- moving ---

    def move(self, delta):
        """Clamp, do not wrap.

        Wrapping on a wheel means overshooting the end silently puts you at
        the start, and on a 64px screen you cannot see enough context to
        notice. Clamping makes the end of the list feel like an end.
        """
        n = len(self.rows())
        if n == 0:
            self.cursor = 0
            return self.cursor
        self.cursor = max(0, min(self.cursor + delta, n - 1))
        return self.cursor

    def enter(self):
        """Descend into a directory, or return a disk to load.

        Returns ("load", path) for a disk, ("dir", path) after descending,
        or ("none", reason) when there is nothing to do - which the panel
        shows rather than beeping, because a silent no-op reads as broken.
        """
        e = self.current()
        if e is None:
            return ("none", "empty")
        if e.kind == "dir":
            if not os.path.isdir(e.path):
                return ("none", "not mounted")
            self.stack.append(e.path)
            self.cursor = 0
            return ("dir", e.path)
        if e.kind == "disk":
            return ("load", e.path)
        if e.kind == "missing":
            return ("none", "not mounted")
        return ("none", "not a disk")

    def up(self):
        if not self.stack:
            return False
        self.stack.pop()
        self.cursor = 0
        return True


def self_test():
    import tempfile, shutil
    tmp = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(tmp, "kits"))
        exact = os.path.join(tmp, "beat.img")
        with open(exact, "wb") as f:
            f.write(b"\0" * FLOPPY_BYTES)
        with open(os.path.join(tmp, "big.iso"), "wb") as f:
            f.write(b"\0" * 4096)
        with open(os.path.join(tmp, "notes.txt"), "w") as f:
            f.write("x")
        with open(os.path.join(tmp, ".hidden.img"), "wb") as f:
            f.write(b"\0" * FLOPPY_BYTES)

        rows = listing(tmp)
        # directories first, then disks, then everything else
        assert [e.kind for e in rows] == ["dir", "disk", "disk", "other"], rows
        assert rows[0].name == "kits"
        # hidden files stay hidden unless asked for
        assert all(not e.name.startswith(".") for e in rows)
        assert any(e.name == ".hidden.img" for e in listing(tmp, show_hidden=True))
        # a wrong-sized image is still listed, but is not "exact"
        by = {e.name: e for e in rows}
        assert by["beat.img"].exact, "a 1.44MB image must read as exact"
        assert not by["big.iso"].exact, "a 4KB iso must not read as a floppy"

        b = Browser(roots=[("LIB", tmp), ("USB", os.path.join(tmp, "nope"))])
        # the missing source is STILL a row - that is the whole point
        assert len(b.rows()) == 2
        assert b.rows()[1].present is False
        # and entering it says why instead of doing nothing
        b.cursor = 1
        assert b.enter() == ("none", "not mounted")
        # clamping, not wrapping
        b.cursor = 0
        b.move(-5)
        assert b.cursor == 0, "moving up past the top must clamp"
        b.move(99)
        assert b.cursor == 1, "moving down past the end must clamp"
        # descend, find the disk, load it
        b.cursor = 0
        assert b.enter()[0] == "dir"
        assert not b.at_root()
        names = [e.name for e in b.rows()]
        b.cursor = names.index("beat.img")
        kind, path = b.enter()
        assert kind == "load" and path == exact, (kind, path)
        # a text file is not loadable and says so
        b.cursor = names.index("notes.txt")
        assert b.enter() == ("none", "not a disk")
        assert b.up() and b.at_root()
        assert b.up() is False, "up from the root must be a no-op, not a crash"
        print("browser self-test PASS: listing order, hidden files, missing "
              "sources, clamping, descend and load")
    finally:
        shutil.rmtree(tmp)


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        b = Browser()
        for e in b.rows():
            print("%-10s %-6s %s" % (e.name, e.kind, e.path))
