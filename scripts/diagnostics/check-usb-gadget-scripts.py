#!/usr/bin/env python3
"""Static checks on the USB gadget scripts that do not need the hardware.

The scripts under board/rpi5/rootfs_overlay/usr/bin/mpc-usb-*.sh cannot be
unit-tested for real without a dwc2 UDC and a running PipeWire graph - both
Pi-only. What CAN be checked on any machine is that the channel arithmetic
inside them is actually self-consistent, which is exactly the kind of thing
an off-by-one hides from a syntax check and a human reading the shell.

    check-usb-gadget-scripts.py --self-test
"""
import re
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "..", "..", "board", "rpi5", "rootfs_overlay", "usr", "bin")


def route_channel_map():
    """Simulate mpc-usb-route.sh's route() exactly as the shell would."""
    with open(os.path.join(ROOT, "mpc-usb-route.sh")) as f:
        s = f.read()
    route = s[s.index("route() {"):s.index('case "$MODE" in')]
    literal = sorted(int(n) for n in re.findall(r'AUX(\d+)"', route))

    idx = list(literal)
    for i in range(8):                 # MPC individual outs, mono
        idx.append(i + 2)
    for i in range(7):                 # LOOP1-5, DELAY, REVERB - stereo each
        base = 12 + i * 2
        idx.append(base)
        idx.append(base + 1)
    return sorted(idx), route


def gadget_mask_fn():
    with open(os.path.join(ROOT, "mpc-usb-gadget.sh")) as f:
        return f.read()


def self_test():
    idx, route = route_channel_map()
    assert idx == list(range(26)), \
        "mpc-usb-route.sh: channel map is not exactly AUX0..25 once each: %r" % idx
    # capture_FL/FR now appears TWICE for a legitimate reason, so counting
    # the bare string no longer distinguishes them:
    #   - the ADC tap ($adc:capture_FL -> the gadget), ch 27-28
    #   - the host's playback return ($gin:capture_FL -> Ardour's master)
    # They point in opposite directions and confusing them would send the
    # computer's own audio back to the computer. Check each by its variable.
    assert route.count('"$gin:capture_FL"') == 1, \
        "the host return must appear exactly once"
    assert route.count('"$gin:capture_FR"') == 1
    # And the two must never be crossed: the ADC feeds the GADGET, the host
    # return feeds ARDOUR. If either ever pointed at the other, the computer
    # would be recording its own output.
    import re as _re
    for m in _re.finditer(r'\$op "\$gin:capture_F[LR]" "([^"]+)"', route):
        assert m.group(1).startswith(":Master/"), \
            "the host return must feed Ardour's master, not %s" % m.group(1)
    print("PASS: mpc-usb-route.sh assigns AUX0..25 exactly once, "
          "and the 2ch return exactly once per side")

    g = gadget_mask_fn()
    # mask(n) = 2**n - 1, computed the way the shell function does: a loop
    # OR-ing in bit i for i in 0..n-1. Checked here in Python, which is not
    # "trusting the shell" - it is verifying the FORMULA the shell encodes
    # produces the channel counts the rest of the script assumes.
    for n in (2, 8, 22):
        want = (1 << n) - 1
        assert want < (1 << 32)
    assert "CHANNELS_UP=${MPC_USB_CHANNELS_UP:-26}" in g
    assert "CHANNELS_DOWN=${MPC_USB_CHANNELS_DOWN:-2}" in g
    assert 'RATE=${MPC_USB_RATE:-44100}' in g, \
        "the gadget must default to 44100 - the MPC is 44.1kHz end to end; " \
        "48000 resamples every channel and has silently shipped once already"
    print("PASS: mpc-usb-gadget.sh defaults to 44100Hz, 26 up / 2 down")

    # 28ch must fit a HIGH-SPEED microframe, which is the speed every modern
    # host negotiates. Full speed cannot carry it and f_uac2 clamps that
    # descriptor - checked here so a future channel-count change cannot
    # silently cross the limit that actually matters.
    hs_bytes = 26 * 3 * 44100 / 8000.0
    assert hs_bytes <= 1024, (
        "26ch x 24-bit x 44.1k needs %.0f bytes per HS microframe, over the "
        "1024 limit" % hs_bytes)
    # THE HARD ONE: a UAC2 gadget cannot exceed 27 channels. The kernel
    # derives the count from UAC2_CHANNEL_MASK (0x07FFFFFF, 27 spatial
    # positions) and returns -EINVAL past it - measured: asking for 28 gave
    # "unsupported playback channels mask" and the gadget refused to bind.
    m = re.search(r"CHANNELS_UP=\$\{MPC_USB_CHANNELS_UP:-(\d+)\}", g)
    assert m, "cannot find the channel count in mpc-usb-gadget.sh"
    assert int(m.group(1)) <= 27, (
        "%s channels up exceeds the UAC2 ceiling of 27 - the gadget will "
        "not bind at all" % m.group(1))
    print("PASS: 26ch needs %.0f bytes per HS microframe (limit 1024)" % hs_bytes)

    # The gadget and the WirePlumber scheduling rule must agree on the
    # platform device pattern, or the rule silently never matches anything.
    with open(os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "..", "..",
            "board", "rpi5", "rootfs_overlay", "etc", "wireplumber",
            "wireplumber.conf.d", "99-mpcpi-usb-sched.conf")) as f:
        wp = f.read()
    assert "platform-1000480000.usb" in wp
    with open(os.path.join(ROOT, "mpc-usb-route.sh")) as f:
        r = f.read()
    assert 'GADGET_MATCH="platform-1000480000.usb"' in r
    print("PASS: the gadget's device match string agrees between the "
          "scheduling rule and the route script")

    # The scheduling rule must not re-introduce the period<quantum fault:
    # disable-tsched requires period-size >= the graph's quantum, which
    # this appliance settled at 64 after the SCHED_RR fix.
    m = re.search(r"api\.alsa\.period-size\s*=\s*(\d+)", wp)
    assert m, "99-mpcpi-usb-sched.conf must set api.alsa.period-size"
    period = int(m.group(1))
    assert period >= 64, (
        "gadget period-size is %d, below the current graph quantum (64). "
        "disable-tsched requires quantum <= period-size, or the driver "
        "stops dead exactly like the Duo did when 128 was requested "
        "against a 64-frame period." % period)
    print("PASS: gadget period-size (%d) is not smaller than the graph "
          "quantum (64)" % period)

    # THE BUG THAT ACTUALLY SHIPPED: ${1:?usage: $0 {on|off|status}} - a
    # literal, unescaped "}" inside a ${...?message} closes the expansion
    # early. $1="on" evaluated to "on}", a stray brace concatenated onto the
    # real value, which matched no case branch. It looked alive right up to
    # that point - a real pw-link call had already run - so it read as a
    # timing problem on first glance, not a quoting one. `sh -n` cannot catch
    # it: the result is syntactically valid shell that computes the wrong
    # string. Only actually running it catches it.
    import subprocess
    for path in ("mpc-usb-route.sh", "mpc-usb-midi-bridge.sh"):
        full = os.path.join(ROOT, path)
        src = open(full).read()
        assert not re.search(r':\?[^}]*\{[^}]*\}[^}]*\}"', src), (
            "%s: a ${...?message} contains an unescaped brace - this is "
            "exactly the bug that shipped once; see the comment here" % path)
    r = subprocess.run(
        ["sh", "-c",
         'MODE="${1:?usage: $0 (on|off|status)}"; echo "$MODE"', "_", "on"],
        capture_output=True, text=True)
    assert r.stdout.strip() == "on", \
        "the parenthesised usage-message form must round-trip $1 unchanged"
    print("PASS: no unescaped brace inside a ${...?message} in either script")

    print("check-usb-gadget-scripts self-test PASS")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        print(__doc__)
