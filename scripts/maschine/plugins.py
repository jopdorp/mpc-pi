#!/usr/bin/env python3
"""The effect set, and which panel view each one gets.

Every entry names a **role** the rig needs, an ordered list of LV2 URIs
to try, and the micro-view that draws it. Ordered lists rather than a
single URI because the appliance must come up usable on whatever is
installed: the first choice is the good one, the last is something that
ships inside Ardour so a bare install still works.

On UIs: a plugin's own GUI is an X11 window and cannot exist on a 255x64
5-bpp panel, so **every plugin gets a custom view here** — which is also
what Push, Elektron and Maschine do, for the same reason. A view is
chosen by `kind`, and kinds are shared: every compressor draws the same
way, so adding a compressor costs nothing.

URIs marked "verified" were read out of the installed .ttl files on the
build host; the rest are from the upstream projects and are checked at
session build time by trying them in order.
"""

# kind -> which micro-view in daw_ui renders it
KINDS = ("eq", "comp", "limiter", "multiband", "delay", "reverb",
         "drive", "amp", "mod", "chop", "params")

ROLES = [
    {
        "role": "Parametric EQ / hi-pass / lo-pass",
        "kind": "eq",
        "uris": [
            # 16 bands, each switchable to bell/shelf/hi-pass/lo-pass, so
            # one plugin answers all three of those requirements.
            "http://lsp-plug.in/plugins/lv2/para_equalizer_x16_stereo",  # verified
            "http://gareus.org/oss/lv2/fil4#stereo",
            "urn:ardour:a-eq",
        ],
        "knobs": ("FREQ", "GAIN", "Q", "TYPE"),
        "note": "encoders edit the focused band; band buttons step bands",
    },
    {
        "role": "Compressor (with sidechain)",
        "kind": "comp",
        "uris": [
            "http://lsp-plug.in/plugins/lv2/sc_compressor_stereo",       # verified
            "http://gareus.org/oss/lv2/darc#stereo",
            "urn:ardour:a-comp#stereo",
        ],
        "knobs": ("THRSH", "RATIO", "ATT", "REL"),
        "note": "real sidechain port; MPC kick ducking the loops",
    },
    {
        "role": "Limiter",
        "kind": "limiter",
        "uris": [
            "http://lsp-plug.in/plugins/lv2/limiter_stereo",             # verified
            "http://gareus.org/oss/lv2/dpl#stereo",
            "urn:ardour:a-comp#stereo",
        ],
        "knobs": ("THRSH", "CEIL", "REL", "OVER"),
        "note": "master-bus safety; the view is ceiling plus GR",
    },
    {
        "role": "Multiband compressor / limiter",
        "kind": "multiband",
        "uris": [
            "http://lsp-plug.in/plugins/lv2/mb_compressor_stereo",       # verified
            "http://lsp-plug.in/plugins/lv2/mb_clipper_stereo",
            "urn:ardour:a-comp#stereo",
        ],
        "knobs": ("BAND", "THRSH", "RATIO", "MAKEUP"),
        "note": "per-band GR bars; BAND selects which band the others edit",
    },
    {
        "role": "Delay",
        "kind": "delay",
        "uris": [
            "urn:ardour:a-delay",
            "http://zamaudio.com/lv2/zamdelay",
        ],
        "knobs": ("TIME", "FDBK", "MIX", "TONE"),
        "note": "time shown in both ms and note division against MPC tempo",
    },
    {
        "role": "Reverb",
        "kind": "reverb",
        "uris": [
            # Dragonfly is the best-sounding free reverb set and ships
            # four algorithms. Verified installed; guitarix also carries
            # zita-rev1, which is the other genuinely good free hall.
            "https://github.com/michaelwillis/dragonfly-reverb",         # verified
            "http://guitarix.sourceforge.net/plugins/gx_zita_rev1_stereo#_zita_rev1_stereo",  # verified
            "urn:ardour:a-reverb",
        ],
        "knobs": ("SIZE", "DECAY", "MIX", "TONE"),
        "note": "decay drawn as a tail; size as room depth",
    },
    {
        "role": "Overdrive (Tube Screamer voicing)",
        "kind": "drive",
        "uris": [
            # guitarix ships a literal TS-9 model.
            "http://guitarix.sourceforge.net/plugins/gxts9#ts9sim",      # verified
            "http://zamaudio.com/lv2/zamtube",
        ],
        "knobs": ("DRIVE", "TONE", "LEVEL", "MIX"),
        "note": "mid-humped soft clip; the curve view shows the knee",
    },
    {
        "role": "Distortion (DS-1 voicing)",
        "kind": "drive",
        "uris": [
            # And a literal Boss DS-1 model, which is exactly the pedal
            # asked for rather than a generic distortion.
            "http://guitarix.sourceforge.net/plugins/gx_bossds1_#_bossds1_",  # verified
            "http://guitarix.sourceforge.net/plugins/gx_mxrdist_#_mxrdist_",  # verified
            "http://zamaudio.com/lv2/zamtube",
        ],
        "knobs": ("DIST", "TONE", "LEVEL", "MIX"),
        "note": "harder clip than the overdrive; same view, different curve",
    },
    {
        "role": "Chorus",
        "kind": "mod",
        "uris": [
            "http://guitarix.sourceforge.net/plugins/gx_chorus_stereo#_chorus_stereo",  # verified
            "urn:ardour:a-chorus",
        ],
        "knobs": ("RATE", "DEPTH", "MIX", "DELAY"),
        "note": "the LFO is drawn moving, so rate is seen not read",
    },
    {
        "role": "Flanger",
        "kind": "mod",
        "uris": [
            "http://guitarix.sourceforge.net/plugins/gx_flanger#_flanger",  # verified
            "http://guitarix.sourceforge.net/plugins/gx_phaser#_phaser",    # verified
            "urn:ardour:a-chorus",
        ],
        "knobs": ("RATE", "DEPTH", "FDBK", "MIX"),
        "note": "same view as chorus; feedback is what separates them",
    },
    {
        "role": "Chopper / repeater (gate stutter)",
        "kind": "chop",
        "uris": [
            # A *switched* tremolo is a hard on/off gate rather than a
            # smooth one, which is exactly the on-off-on-off effect.
            "http://guitarix.sourceforge.net/plugins/gx_switched_tremolo_#_switched_tremolo_",  # verified
            "http://guitarix.sourceforge.net/plugins/gx_tremolo#_tremolo",  # verified
            "urn:ardour:a-chorus",
        ],
        "knobs": ("DIV", "DEPTH", "SHAPE", "MIX"),
        "note": "rate snaps to note divisions of the MPC tempo, so the "
                "chop always lands on the grid; one knob owns it live",
    },
    {
        "role": "Guitar amp + cab (combo models)",
        "kind": "amp",
        "uris": [
            "http://guitarix.sourceforge.net/plugins/gx_amp_stereo#GUITARIX_ST",  # verified
            "http://guitarix.sourceforge.net/plugins/gx_amp#GUITARIX",   # verified
            "http://zamaudio.com/lv2/zamtube",
        ],
        # The amp is followed by a cabinet stage; guitarix models the cab
        # separately, which is what makes the combo voicings work.
        "cab_uri": "http://guitarix.sourceforge.net/plugins/gx_cabinet#CABINET",
        "knobs": ("GAIN", "BASS", "MID/TRB", "MASTER"),
        "note": "MODEL button steps the combo voicings below",
    },
]

# The three combos, as concrete guitarix amp + cabinet selections. These
# model names were read out of the installed gx_amp/gx_cabinet .ttl files,
# so they are selectable values rather than aspirations.
#
# guitarix is a genuinely complete single-app chain - tube preamp stage,
# tone stack and a real cabinet model - which is why it is the default
# even now that NAM is wanted: one plugin pair covers amp and cab, it is
# analytic (no neural inference cost), and it is packaged for arm64.
AMP_MODELS = [
    {"name": "DLX", "full": "Fender Deluxe Reverb, clean",
     "gx_amp": "Fender Style", "gx_cab": "2x12",
     "tubes": "12AX7 preamp into 6V6",
     "for": "jazz, singer-songwriter, funk"},
    {"name": "PLEXI", "full": "Marshall Plexi, edge of breakup",
     "gx_amp": "JTM-45 Style", "gx_cab": "4x12",
     "tubes": "12AX7 preamp into EL34",
     "for": "Hendrix, RHCP, classic rock"},
    {"name": "IIC+", "full": "Mesa Boogie Mark IIC+, high gain",
     "gx_amp": "Mesa Boogie Style", "gx_cab": "4x12",
     "tubes": "cascaded 12AX7 into 6L6",
     "for": "Metallica, Slipknot, SOAD"},
]

# The same three as Neural Amp Modeler captures. NAM is offered as an
# ALTERNATIVE to guitarix rather than a replacement: it sounds closer to
# a specific rig because it is a capture of one, but it costs neural
# inference per instance and needs model files shipped with the image.
# The panel's amp view is identical either way - it draws the voicing
# name, the cab and the tone stack - so switching engines is invisible
# to the player.
AMP_ENGINES = ("guitarix", "nam")
NAM_MODELS = [
    {"name": "DLX", "file": "fender-deluxe-reverb-clean.nam"},
    {"name": "PLEXI", "file": "marshall-plexi-1959.nam"},
    {"name": "IIC+", "file": "mesa-mark-iic-plus.nam"},
]
NAM_TIER = "nano"      # A2 quality tier; nano is the cheapest that still
                       # sounds like the amp, and is what fits beside a
                       # 1600%-speed emulator on a Pi 5.

# Buildroot/apt package names behind the URIs above.
PACKAGES = [
    ("lsp-plugins-lv2", "EQ, compressor, limiter, multiband"),
    ("dragonfly-reverb", "the good reverb"),
    ("guitarix", "overdrive, distortion, amp and cab models"),
    ("x42-plugins", "fil4 EQ and dpl limiter fallbacks"),
    ("zam-plugins", "ZamTube fallback drive"),
]


def role_for_kind(kind):
    return [r for r in ROLES if r["kind"] == kind]


def self_test():
    for r in ROLES:
        assert r["kind"] in KINDS, r["kind"]
        assert r["uris"], r["role"]
        assert len(r["knobs"]) == 4, "%s needs exactly 4 knobs" % r["role"]
        # Every role must end in something that ships with Ardour or in
        # a package we install, so a bare boot is never silent.
        assert r["uris"][-1].startswith(("urn:ardour:", "http://zamaudio")), \
            "%s has no safe fallback" % r["role"]
    kinds = {r["kind"] for r in ROLES}
    missing = kinds - set(KINDS)
    assert not missing, missing
    assert len(AMP_MODELS) == 3
    print("plugins self-test PASS: %d roles, %d kinds, %d amp models, "
          "every role has a fallback" % (len(ROLES), len(kinds),
                                         len(AMP_MODELS)))


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        for r in ROLES:
            print("%-38s %-10s %s" % (r["role"], r["kind"], r["uris"][0]))
        print()
        for m in AMP_MODELS:
            print("%-6s %-34s %s" % (m["name"], m["full"], m["for"]))
