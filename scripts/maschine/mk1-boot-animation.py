#!/usr/bin/env python3
"""Power-on animation for the Maschine MK1's two displays.

Stars gather into orbit, collapse, and go supernova.

Both panels show the same frame. They sit side by side with a bezel
between them, so a single wide canvas would bury the star's core in the
gap; identical mirrored scenes read as one instrument lighting up, and
cost one render instead of two.

Two things make this fast enough to animate in pure Python on a boot path
that is otherwise being measured in seconds:

  * SPARSE rendering. The scene is stars, a glow and a ring - a few
    hundred lit pixels on a dark field. Packing walks only the lit ones
    instead of all 16,320, so frame cost tracks what is drawn rather than
    the panel size. The one full-bright frame (the flash) is packed once
    at import and reused.

  * OPTIMISTIC writes. The device refuses output while input is queued,
    but draining before every write costs more than the write does. A
    healthy device takes over a thousand consecutive writes without a
    single failure, so this writes first and only drains after a timeout.

Usage:
    mk1-boot-animation.py            play once
    mk1-boot-animation.py --bench    report achievable frame rate
    mk1-boot-animation.py --loop     play repeatedly (for tuning)
"""
import math
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mk1_display                                          # noqa: E402
import mk1_leds as L                                        # noqa: E402

EP_DISPLAY = 0x08
W, H = 255, 64
ROW_BYTES = 170
FRAME_BYTES = 21 * 502 + 338
CONTRAST = int(os.environ.get("MPC_MK1_CONTRAST", "0x10"), 0) & 0x3F
CX, CY = W // 2, H // 2

# A full-brightness frame, built once. Every 5-bit field set to 0x1F is
# every byte 0xFF, so the flash needs no packing at all.
FRAME_WHITE = b"\xff" * FRAME_BYTES
FRAME_BLACK = b"\x00" * FRAME_BYTES


def uniform_frame(level):
    """A whole panel at one level.

    Built by packing a single row and tiling it. Ramping the entire field
    through pack_sparse would mean 16,320 pixels per frame - the one case
    where sparse packing is the wrong tool.
    """
    v = max(0, min(0x1F, int(level)))
    row = bytearray(ROW_BYTES)
    for x in range(W):
        bi = (x // 3) * 2
        block = x % 3
        if block == 0:
            row[bi] = (row[bi] & 0x07) | (v << 3)
        elif block == 1:
            row[bi] = (row[bi] & 0xF8) | (v >> 2)
            row[bi + 1] = (row[bi + 1] & 0x3F) | ((v & 0x03) << 6)
        else:
            row[bi + 1] = (row[bi + 1] & 0xC1) | (v << 1)
    return bytes(row) * H


def pack_sparse(lit):
    """Pack {(x, y): level} onto a black field.

    Levels are additive-clamped by the caller; this only writes the
    pixels given, which is what keeps a 16,320-pixel panel affordable at
    animation rates in pure Python.
    """
    out = bytearray(FRAME_BYTES)
    for (x, y), level in lit.items():
        if not 0 <= x < W or not 0 <= y < H:
            continue
        v = 0x1F if level > 0x1F else level
        if v <= 0:
            continue
        bi = y * ROW_BYTES + (x // 3) * 2
        block = x % 3
        if block == 0:
            out[bi] = (out[bi] & 0x07) | (v << 3)
        elif block == 1:
            out[bi] = (out[bi] & 0xF8) | (v >> 2)
            out[bi + 1] = (out[bi + 1] & 0x3F) | ((v & 0x03) << 6)
        else:
            out[bi + 1] = (out[bi + 1] & 0xC1) | (v << 1)
    return bytes(out)


def add(lit, x, y, level):
    """Accumulate brightness, so overlapping glows build up."""
    x, y = int(x), int(y)
    if 0 <= x < W and 0 <= y < H:
        cur = lit.get((x, y), 0) + level
        lit[(x, y)] = 0x1F if cur > 0x1F else cur


def glow(lit, x, y, level, radius):
    """A soft round blob. Cheap: only the disc is touched."""
    r = int(radius)
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            d = math.hypot(dx, dy)
            if d > radius:
                continue
            add(lit, x + dx, y + dy, int(level * (1.0 - d / (radius + 0.001))))


def blob(lit, x, y, level):
    """A star with a body. Centre plus a plus-shape at half level.

    One lit pixel is invisible on this panel - dim STN, 32 levels, and only
    64 rows - so every star is five pixels. It is the cheapest shape that
    actually reads.
    """
    add(lit, x, y, level)
    half = level >> 1
    add(lit, x + 1, y, half)
    add(lit, x - 1, y, half)
    add(lit, x, y + 1, half)
    add(lit, x, y - 1, half)


def ray(lit, angle, r0, r1, level, squash=1.0, taper=True, thick=2):
    """A straight beam from the core outwards.

    Rays are what make the disc read as *turning* rather than as a ring of
    dots that happens to change: at 64 pixels tall a moving point is one
    or two pixels of change per frame, which the eye does not track. A
    beam sweeping through the same angle is unmistakable.
    """
    steps = int(abs(r1 - r0) * 1.6) + 2
    ca, sa = math.cos(angle), math.sin(angle) * squash
    for i in range(steps):
        t = i / steps
        r = r0 + (r1 - r0) * t
        v = level * (1.0 - t) if taper else level
        x, y = CX + r * ca, CY + r * sa
        add(lit, x, y, int(v))
        # Widen the beam vertically. A one-pixel line across a 64-row panel
        # disappears; two or three rows is a beam.
        for o in range(1, thick):
            add(lit, x, y + o, int(v * 0.55))
            add(lit, x, y - o, int(v * 0.55))


def wavefront(lit, radius, level, squash=0.62, thickness=2):
    """One expanding elliptical shell of the shockwave."""
    if level <= 0 or radius <= 0:
        return
    steps = max(56, int(radius * 2.4))
    for k in range(steps):
        a = math.tau * k / steps
        ca, sa = math.cos(a), math.sin(a) * squash
        for th in range(thickness):
            add(lit, CX + (radius - th) * ca, CY + (radius - th) * sa,
                int(level * (1.0 - th / (thickness + 0.5))))


class Star:
    """One orbiting body. The vertical squash is deliberate: the panel is
    255x64, so a circular orbit in pixel space looks like a flat ellipse -
    orbiting in an ellipse that matches the aspect ratio reads as a disc
    seen almost edge-on, which is what a real accretion disc looks like."""

    __slots__ = ("radius", "angle", "speed", "level", "squash")

    def __init__(self, rng):
        self.radius = rng.uniform(14, 118)
        self.angle = rng.uniform(0, math.tau)
        # Inner orbits move faster, as gravity requires. Without this the
        # field rotates like a painted wheel.
        self.speed = 2.4 / math.sqrt(self.radius) * rng.uniform(0.85, 1.15)
        self.level = rng.randint(0x14, 0x1F)
        self.squash = rng.uniform(0.22, 0.30)

    def step(self, dt, shrink=1.0):
        self.angle += self.speed * dt
        self.radius *= shrink

    def pos(self):
        return (CX + self.radius * math.cos(self.angle),
                CY + self.radius * self.squash * math.sin(self.angle))

    def trail(self, lit, dt, n=4, gain=1.0):
        for k in range(1, n + 1):
            a = self.angle - self.speed * dt * k
            add(lit, CX + self.radius * math.cos(a),
                CY + self.radius * self.squash * math.sin(a),
                int((self.level >> (k + 1)) * gain))


# WHERE EVERY LAMP PHYSICALLY SITS, in normalised panel coordinates
# (x 0..1 left to right, y 0..1 top to bottom).
#
# Rays and waves have to travel across the *device*, not across an index
# list: a wave that lights LEDs in wire order crosses the panel in
# unrelated stripes. With real positions, one line of maths sweeps light
# over the hardware the way it sweeps over the screens.
#
# APPROXIMATE, and deliberately marked as such. It was laid out from the
# MK1's general arrangement - pads bottom right, group buttons in a 2x4
# block to their left, transport along the bottom, the eight unlabelled
# buttons above the screens - not measured off the panel. Nudge these while
# watching the device; nothing depends on them being exact.
def _pad_xy(pad):
    col, row = (pad - 1) % 4, (pad - 1) // 4      # pad 1 = bottom left
    return (0.615 + col * 0.113, 0.94 - row * 0.145)


LAMP_XY = {"Pad%d" % p: _pad_xy(p) for p in range(1, 17)}
LAMP_XY.update({
    # Group buttons: 2 columns x 4 rows, immediately left of the pads.
    "GroupA": (0.487, 0.94), "GroupB": (0.556, 0.94),
    "GroupC": (0.487, 0.795), "GroupD": (0.556, 0.795),
    "GroupE": (0.487, 0.650), "GroupF": (0.556, 0.650),
    "GroupG": (0.487, 0.505), "GroupH": (0.556, 0.505),
    # The eight unlabelled buttons, four above each screen.
    "DisplayButton1": (0.115, 0.075), "DisplayButton2": (0.185, 0.075),
    "DisplayButton3": (0.255, 0.075), "DisplayButton4": (0.325, 0.075),
    "DisplayButton5": (0.115, 0.075), "DisplayButton6": (0.185, 0.075),
    "DisplayButton7": (0.255, 0.075), "DisplayButton8": (0.325, 0.075),
    # Left-hand column.
    "Browse": (0.035, 0.24), "BrowseLeft": (0.035, 0.33),
    "BrowseRight": (0.035, 0.42), "Sampling": (0.035, 0.51),
    "Step": (0.035, 0.60), "Control": (0.035, 0.69),
    "Snap": (0.035, 0.78), "AutoWrite": (0.035, 0.87),
    # Mode buttons under the screens.
    "Mute": (0.150, 0.50), "Solo": (0.230, 0.50),
    "Select": (0.310, 0.50), "Duplicate": (0.390, 0.50),
    "Navigate": (0.150, 0.61), "Keyboard": (0.230, 0.61),
    "Pattern": (0.310, 0.61), "Scene": (0.390, 0.61),
    # Transport, along the bottom.
    "Play": (0.390, 0.95), "Rec": (0.310, 0.95),
    "Erase": (0.230, 0.95), "Shift": (0.150, 0.95),
    "Grid": (0.390, 0.84), "Loop": (0.310, 0.84),
    "TransportLeft": (0.230, 0.84), "TransportRight": (0.150, 0.84),
    "NoteRepeat": (0.070, 0.95),
})

# Panel centre, and everything measured from it once at import.
PX, PY = 0.5, 0.55
LAMP_ANGLE = {n: math.atan2(y - PY, (x - PX) * 2.6) % math.tau
              for n, (x, y) in LAMP_XY.items()}
LAMP_DIST = {n: math.hypot((x - PX) * 1.0, (y - PY) * 0.45)
             for n, (x, y) in LAMP_XY.items()}
_dmax = max(LAMP_DIST.values())
LAMP_DIST = {n: d / _dmax for n, d in LAMP_DIST.items()}
LAMP_NAMES = tuple(LAMP_XY)

# Phase boundaries as fractions of the whole, shared by the display
# renderer and the LED choreographer so the two cannot drift apart.
PHASES = ("ignition", "orbit", "collapse", "flash", "waves", "afterglow")


def build_frames(fps=18, rng=None):
    """Render the whole animation up front, tagging each frame's phase.

    Precomputed because playback must not compete with rendering for the
    core it is running on - this plays while the rest of the appliance is
    still starting, and a stutter would look like a fault rather than an
    effect.

    Returns [(packed_frame, phase, phase_t)].
    """
    rng = rng or random.Random(0xACE)
    stars = [Star(rng) for _ in range(96)]
    frames = []
    dt = 1.0 / fps

    def emit(lit, phase, t):
        frames.append((pack_sparse(lit), phase, t))

    # Rays sweep with the disc: a slow set at the outside, a faster pair
    # near the core, all rotating one way so the disc has a direction.
    n_rays = 7
    ray_phase = 0.0

    # 1. IGNITION - stars fade in where they already orbit.
    n = max(1, int(0.45 * fps))
    for i in range(n):
        t = i / n
        lit = {}
        for st in stars:
            x, y = st.pos()
            blob(lit, x, y, int(st.level * t * 0.9))
            st.step(dt)
        emit(lit, "ignition", t)

    # 2. ORBIT - the disc turns, rays sweep, the core grows.
    n = max(1, int(1.7 * fps))
    for i in range(n):
        t = i / n
        lit = {}
        for st in stars:
            x, y = st.pos()
            blob(lit, x, y, st.level)
            st.trail(lit, dt, n=5)
            st.step(dt)
        ray_phase += 2.6 * dt
        for k in range(n_rays):
            a = ray_phase + math.tau * k / n_rays
            ray(lit, a, 6, 30 + 90 * t, int(0x12 + 13 * t), squash=0.30, thick=3)
        glow(lit, CX, CY, int(6 + 12 * t), 3 + 3 * t)
        emit(lit, "orbit", t)

    # 3. COLLAPSE - orbits decay inward, rays whip round and shorten as
    # the material falls in, the core brightens hard.
    n = max(1, int(0.6 * fps))
    for i in range(n):
        t = i / n
        lit = {}
        for st in stars:
            x, y = st.pos()
            blob(lit, x, y, min(0x1F, int(st.level * (1 + 1.6 * t))))
            st.trail(lit, dt, n=6, gain=1 + t)
            st.step(dt * (1 + 2.5 * t), shrink=1.0 - 0.16 * t)
        ray_phase += (2.6 + 16.0 * t) * dt
        for k in range(n_rays):
            a = ray_phase + math.tau * k / n_rays
            ray(lit, a, 4, (110 * (1 - t)) + 14, 0x1F, squash=0.30, thick=4)
        glow(lit, CX, CY, 0x1F, 4 + 10 * t)
        emit(lit, "collapse", t)

    # 4. FLASH - full white, then one black frame. The blank is what makes
    # the waves read as an explosion instead of rings that were always
    # there.
    for _ in range(4):
        frames.append((FRAME_WHITE, "flash", 0.0))
    frames.append((FRAME_BLACK, "flash", 1.0))

    # 5. WAVES - a train of shells, each launched later and fading as it
    # goes, with debris thrown out along straight rays.
    debris = []
    for _ in range(64):
        a = rng.uniform(0, math.tau)
        debris.append([CX, CY, math.cos(a) * rng.uniform(45, 165),
                       math.sin(a) * rng.uniform(10, 38), rng.randint(0x16, 0x1F)])
    burst_rays = [rng.uniform(0, math.tau) for _ in range(14)]
    n = max(1, int(1.9 * fps))
    N_SHELLS = 6
    for i in range(n):
        t = i / n
        lit = {}
        for shell in range(N_SHELLS):
            # Each shell starts a little later than the one before it.
            st_t = t - shell * 0.13
            if st_t <= 0:
                continue
            radius = 5 + st_t * (W * 0.95)
            # Shells stay bright far longer than a linear fade allows.
            level = int(0x1F * (1.0 - st_t) ** 0.85)
            if shell:
                level = int(level * (0.85 ** shell))
            wavefront(lit, radius, level, squash=0.62,
                      thickness=4 if shell == 0 else 3)
        for a in burst_rays:
            ray(lit, a, 6 + t * 40, 6 + t * 170, int(0x1F * (1.0 - t) ** 1.1),
                squash=0.34, thick=3)
        for d in debris:
            d[0] += d[2] * dt
            d[1] += d[3] * dt
            blob(lit, d[0], d[1], int(d[4] * (1.0 - t)))
        glow(lit, CX, CY, int(0x1F * (1.0 - t) ** 2), 2 + 9 * (1.0 - t))
        emit(lit, "waves", t)

    # 6. AFTERGLOW - the panel fills with light and stays there.
    #
    # Ending bright rather than dark matters for an instrument: a screen
    # that fades to black at the end of its power-on looks like it gave up,
    # and the UI that takes over has to light the panel again anyway. This
    # hands over a lit screen.
    n = max(1, int(0.7 * fps))
    for i in range(n):
        t = i / n
        base = uniform_frame(0x1F * (t ** 0.7))
        # The last debris is still visible until the field overtakes it,
        # so the glow looks like it comes from the explosion rather than
        # from a separate fade-in.
        if t < 0.55:
            lit = {}
            for d in debris:
                d[0] += d[2] * dt * 0.35
                d[1] += d[3] * dt * 0.35
                blob(lit, d[0], d[1], int(0x1F * (1.0 - t / 0.55)))
            glow(lit, CX, CY, int(0x1F * (1.0 - t)), 4)
            over = bytearray(base)
            spark = pack_sparse(lit)
            for k in range(FRAME_BYTES):
                if spark[k] > over[k]:
                    over[k] = spark[k]
            frames.append((bytes(over), "afterglow", t))
        else:
            frames.append((base, "afterglow", t))
    # Hold the lit panel for a moment so the handover is not a flicker.
    for _ in range(3):
        frames.append((FRAME_WHITE, "afterglow", 1.0))

    return frames


# Brightness budget. This device is bus-powered and a Pi 5 caps TOTAL USB
# current at 600mA unless usb_max_current_enable=1 is set in config.txt.
#
# 0x7F on all 57 lamps plus two backlights, held indefinitely, is the state
# this animation used to finish in - and twice now the controller has gone
# unresponsive after heavy LED use: control transfers timing out, all
# endpoints failing, recoverable only by unplugging. No over-current is
# logged and throttled reads 0x0, so this is consistent rather than proven,
# but a decorative animation is the wrong place to find out.
#
# So FULL is used only for brief peaks - the detonation lasts four frames -
# and HOLD is what any sustained state settles to.
FULL = 0x7F                 # peak only, never held
HOLD = 0x38                 # sustained brightness, clearly lit
NEAR = 0x2A
FAINT = 0x0E


def _sweep(bank, ray_angle, n_rays, width, level=FULL, floor=0):
    """Rotating beams over the whole panel.

    Hard-edged on purpose. Each lamp has one fixed colour and brightness is
    the only channel, so a soft falloff reads as a vague glow; a sharp
    boundary reads as a beam actually passing over the panel.
    """
    for name in LAMP_NAMES:
        a = LAMP_ANGLE[name]
        best = 0
        for k in range(n_rays):
            beam = (ray_angle + math.tau * k / n_rays) % math.tau
            d = abs(a - beam)
            d = min(d, math.tau - d)
            if d < width:
                best = max(best, level if d < width * 0.55 else NEAR)
        bank.set(name, best or floor)


def _wave(bank, fronts, width=0.085, level=FULL):
    """Concentric shells crossing the panel outwards from the centre.

    `fronts` are normalised radii. A lamp is either in a shell or dark -
    no gradient - which is what makes the wave visible on hardware that
    cannot change colour.
    """
    for name in LAMP_NAMES:
        r = LAMP_DIST[name]
        v = 0
        for i, f in enumerate(fronts):
            if f <= 0:
                continue
            d = abs(r - f)
            if d < width:
                v = max(v, level if i == 0 else NEAR)
            elif d < width * 1.8:
                v = max(v, FAINT)
        bank.set(name, v)


def leds_for(phase, t, bank, ray_angle):
    """Choreograph every lamp on the panel against the screens' phases.

    Positions come from LAMP_XY, so rays rotate and waves expand across the
    physical device rather than across an index list.
    """
    if phase == "ignition":
        # Light gathers inward: outermost lamps first, then closer in.
        for name in LAMP_NAMES:
            r = LAMP_DIST[name]
            on = (1.0 - r) < t * 1.3
            bank.set(name, NEAR if on else 0)

    elif phase == "orbit":
        # Beams sweep, gaining rays and brightness as the disc spins up.
        n = 3 if t < 0.45 else 5
        _sweep(bank, ray_angle, n, width=0.85 - 0.3 * t,
               level=FULL, floor=FAINT if t > 0.6 else 0)

    elif phase == "collapse":
        # Beams whip round faster and the whole panel lifts off the floor.
        _sweep(bank, ray_angle * 2.6, 6, width=0.55,
               level=FULL, floor=int(FAINT + (NEAR - FAINT) * t))

    elif phase == "flash":
        bank.all(FULL)
        bank.backlight(0x7F)        # peak, four frames only
        return

    elif phase == "waves":
        # Four shells, launched in sequence, crossing the panel and beyond.
        _wave(bank, [(t - k * 0.16) * 1.65 for k in range(4)],
              width=0.075, level=FULL)

    else:                                   # afterglow
        # Rise to full and stay there, matching the screens.
        for name in LAMP_NAMES:
            r = LAMP_DIST[name]
            # Inner lamps arrive first, so the light spreads outwards
            # instead of the whole panel stepping on at once.
            up = max(0.0, min(1.0, (t * 1.6) - r * 0.5))
            bank.set(name, int(HOLD * up))
    bank.backlight(0x7F)


class Screens:
    def __init__(self):
        import usb.core
        import usb.util
        self.core = usb.core
        self.util = usb.util
        # Wait briefly for enumeration. This unit deliberately starts as
        # early as systemd can run it - right after udev - so the device may
        # not be on the bus yet. Exiting immediately would mean the animation
        # is skipped on exactly the boots it is meant for.
        deadline = time.time() + float(os.environ.get("MPC_MK1_WAIT", "6"))
        self.dev = None
        while True:
            self.dev = usb.core.find(idVendor=0x17CC, idProduct=0x0808)
            if self.dev is not None or time.time() >= deadline:
                break
            time.sleep(0.15)
        if self.dev is None:
            raise SystemExit("no Maschine MK1 (17cc:0808) after waiting")
        try:
            if self.dev.is_kernel_driver_active(0):
                self.dev.detach_kernel_driver(0)
        except (usb.core.USBError, NotImplementedError):
            pass
        # Ordered by what has ACTUALLY worked on this hardware, not by what
        # the documentation implies.
        #
        # set_configuration() is the problem. Every open that called it has
        # eventually failed with LIBUSB_ERROR_OTHER, and every probe that
        # skipped it - going straight to claim_interface then
        # set_interface_altsetting - has worked. The device is already
        # configured after enumeration, so setting the configuration again is
        # not merely redundant: it appears to disturb interface state that
        # cannot then be recovered without unplugging the cable.
        #
        # So claim and select the altsetting first. Only if that fails do we
        # try the heavier sequence, and only then a release and re-claim.
        last = None
        for attempt in range(3):
            if attempt == 1:
                try:
                    self.dev.set_configuration()
                except usb.core.USBError:
                    pass
            elif attempt == 2:
                try:
                    usb.util.release_interface(self.dev, 0)
                except usb.core.USBError:
                    pass
                time.sleep(0.4)
            try:
                usb.util.claim_interface(self.dev, 0)
            except usb.core.USBError:
                pass
            try:
                self.dev.set_interface_altsetting(
                    interface=0, alternate_setting=L.ALTSETTING)
                last = None
                break
            except usb.core.USBError as e:
                last = e
        if last is not None:
            raise SystemExit("cannot select altsetting %d: %s"
                             % (L.ALTSETTING, last))
        self.writes = 0
        self.recoveries = 0
        self.led_fails = 0

    def drain(self):
        for ep in L.IN_ENDPOINTS:
            for _ in range(8):
                try:
                    self.dev.read(ep, 512, timeout=2)
                except self.core.USBError:
                    break

    def w_sync(self, data, tries=40):
        """Write with the input queue emptied FIRST, every time.

        For initialisation, not frames. The device accepts writes while its
        input queue is backed up and then discards them, so an optimistic
        init silently fails: the 22-command sequence - including 0xAF,
        display on - never reaches the controller and the panel stays dark
        with no error to read.
        //
        This animation appeared to work for a while only because it was
        being run by hand AFTER mk1-screen-test.py had already initialised
        the panels. On a fresh boot it is the first thing to touch the
        device, and the screens stayed black while the lamps danced.
        """
        for _ in range(tries):
            self.drain()
            try:
                self.dev.write(EP_DISPLAY, data, timeout=250)
                self.writes += 1
                return
            except self.core.USBError:
                self.recoveries += 1
        raise RuntimeError("init write failed")

    def w(self, data, tries=30):
        """Write first, drain only if it fails.

        Draining before every write costs more than the write. A healthy
        device does not need it, and an animation cannot afford it: at 48
        transfers per frame the drain would dominate the frame time.
        """
        for attempt in range(tries):
            try:
                self.dev.write(EP_DISPLAY, data, timeout=200)
                self.writes += 1
                return
            except self.core.USBError:
                self.recoveries += 1
                self.drain()
        raise RuntimeError("display write failed after %d attempts" % tries)

    def init_display(self, index):
        """The shared 22-command sequence from mk1_display.

        Framing lives there, not here. This method used to build its own
        packets and inserted a length byte on top of the one it was passed,
        so every command - including 0xAF display-on - was malformed and the
        panel never initialised.
        """
        for pkt in mk1_display.packets(index, CONTRAST):
            if pkt is None:
                time.sleep(mk1_display.SLEEP_SECONDS)
            else:
                self.w_sync(pkt)

    def _sip(self):
        """One cheap read per endpoint. Called before every chunk.

        A frame is 24 writes and the pad stream delivers a report every
        ~24ms, so draining once per frame leaves the queue refilling
        part-way through and the rest of the chunks discarded. A single
        1ms read per chunk costs ~25ms a frame and keeps the pipe clear.
        """
        for ep in L.IN_ENDPOINTS:
            try:
                self.dev.read(ep, 512, timeout=1)
            except self.core.USBError:
                pass

    def send(self, index, frame):
        for pkt in mk1_display.frame_packets(index, frame, FRAME_BYTES):
            self._sip()
            self.w(pkt)

    def backlight(self, value=0x7F):
        bank = L.LedBank()
        bank.all(L.OFF)
        bank.backlight(value)
        bank.flush(lambda ep, data: self._led(ep, data), force=True)

    def _led(self, ep, data):
        """LED writes go to 0x01, which DOES need the input drained first.

        The display endpoint 0x08 tolerates optimistic writes; 0x01 does
        not, and getting this backwards cost 400ms per frame. Each attempt
        timed out at 200ms before retrying, and because the failures were
        not counted they did not show up as recoveries either - the
        animation simply ran at 2.4fps while the benchmark, which drives
        the screens alone, reported 16.5.
        """
        self.drain()
        for _ in range(8):
            try:
                self.dev.write(ep, data, timeout=60)
                self.writes += 1
                return
            except self.core.USBError:
                self.led_fails += 1
                self.drain()


def main():
    bench = "--bench" in sys.argv
    loop = "--loop" in sys.argv
    fps = int(os.environ.get("MPC_MK1_FPS", "18"))

    t0 = time.time()
    frames = build_frames(fps=fps)
    render = time.time() - t0
    print("rendered %d frames in %.2fs (%.1f ms/frame, %d KiB)"
          % (len(frames), render, render * 1000 / len(frames),
             len(frames) * FRAME_BYTES // 1024))

    s = Screens()
    s.backlight(0x7F)
    for i in (0, 1):
        s.init_display(i)

    if bench:
        n = 12
        t0 = time.time()
        for i in range(n):
            f = frames[i % len(frames)][0]
            s.send(0, f)
            s.send(1, f)
        el = time.time() - t0
        print("both screens: %.1f fps (%.1f ms/frame, %d writes, %d recoveries)"
              % (n / el, el * 1000 / n, s.writes, s.recoveries))
        return 0

    bank = L.LedBank()
    while True:
        t0 = time.time()
        ray_angle = 0.0
        for i, (frame, phase, pt) in enumerate(frames):
            # Drain ONCE per frame before sending it. Writes to 0x08 return
            # success while the device's input queue is backed up and then
            # discard the data - the same accept-and-discard that made the
            # display endpoint look like the right place for the LED block.
            # So "no errors, nothing on screen" is the expected symptom of
            # not draining, and the first version of this animation had
            # exactly that: the pads danced and the panels stayed black.
            # Once per frame, not once per write: 24 drains per frame is
            # what dropped the earlier bring-up tool to 3fps.
            s.drain()
            s.send(0, frame)
            s.send(1, frame)
            # Same sweep rate the display rays use, so the light on the
            # pads turns with the light on the screens.
            ray_angle = (ray_angle + 1.5 / fps) % math.tau
            # The flash must land on its exact frame; otherwise a third of
            # the display rate is plenty for lights this size.
            if phase == "flash" or i % 3 == 0:
                leds_for(phase, pt, bank, ray_angle)
                bank.flush(lambda ep, data: s._led(ep, data))
            slack = t0 + (i + 1) / fps - time.time()
            if slack > 0:
                time.sleep(slack)
        el = time.time() - t0
        print("played %d frames in %.2fs (%.1f fps, %d display recoveries, "
              "%d led retries)"
              % (len(frames), el, len(frames) / el, s.recoveries, s.led_fails))
        if not loop:
            # Leave it LIT, but at the sustained level rather than the
            # peak: this is the state the panel sits in until the UI takes
            # over, and it is held for minutes rather than frames.
            bank.all(HOLD)
            bank.backlight(L.BACKLIGHT_DEFAULT)
            bank.flush(lambda ep, data: s._led(ep, data), force=True)
            return 0


if __name__ == "__main__":
    sys.exit(main())
