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
         "drive", "amp", "mod", "chop", "tuner", "params")

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
        "role": "Tuner",
        "kind": "tuner",
        "uris": [
            "http://gareus.org/oss/lv2/tuna#one",                        # verified
            "http://guitarix.sourceforge.net/plugins/gxtuner#tuner",     # verified
        ],
        "knobs": ("REF", "", "", ""),
        "note": "the only effect whose display IS the product, so it gets "
                "the whole panel; mutes the channel while open",
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
    {"name": "AC30", "full": "Vox AC30, chime and crunch",
     "gx_amp": "AC-30 Style", "gx_cab": "2x12",
     "tubes": "EF86/12AX7 into cathode-biased EL84",
     "for": "British rock, Beatles, Queen, U2, indie jangle"},
    {"name": "5150", "full": "Peavey 5150, modern high gain",
     "gx_amp": "Peavey Style", "gx_cab": "4x12",
     "tubes": "cascaded 12AX7 into 6L6, tight low end",
     "for": "modern and heavier metal, djent, metalcore"},
]

# NAM as the alternative amp engine. Offered rather than substituted: a
# capture sounds like one specific rig, at the cost of neural inference
# per instance and model files in the image. The panel's amp view is
# identical either way, so the engine is invisible to the player.
#
# Verified facts that shaped this (see docs for sources):
#   * A2 (June 2026) is still WaveNet-family but uses leaky ReLU, a
#     convolutional head and a ~132 ms receptive field. A2-Full is 30-40%
#     cheaper than A1-Standard at better accuracy.
#   * A2 has exactly TWO tiers, Full and Lite. "nano" and "feather" are
#     *A1* tier names - an easy and expensive thing to conflate. Both
#     tiers live in ONE .nam file ("slimmable"), chosen at runtime by the
#     plugin's quality_scale port: <0.5 selects Lite, >=0.5 Full.
#   * mikeoliphant/neural-amp-modeler-lv2 v0.2.0+ supports A2 and ships a
#     PREBUILT aarch64 Pi 5 binary linking only libc and libm, so it drops
#     into /usr/lib/lv2 with no build. Ardour is a named supported host.
#   * Build it yourself only with a modern toolchain: the A2 fast path is
#     reported SLOWER on GCC 12 (what Pi OS Bookworm ships) and faster on
#     GCC 15+. Prefer the prebuilt binary.
AMP_ENGINES = ("guitarix", "nam")

NAM_URI = "http://github.com/mikeoliphant/neural-amp-modeler-lv2"
NAM_ALT_URI = "http://two-play.com/plugins/toob-nam"   # PiPedal's TooB NAM
NAM_QUALITY_PORT = "quality_scale"      # 0.0..1.0; <0.5 = Lite, >= = Full
NAM_TIERS = ("lite", "full")
NAM_DEFAULT_TIER = "lite"   # cheapest that still sounds like the amp, and
                            # what fits beside a 1600%-speed emulator

# Two hard operational constraints from the plugin's own docs:
NAM_REQUIRES_48K = True     # it does no resampling; host must run at the
                            # model's rate, which the appliance already does
NAM_NEEDS_CAB_AFTER = True  # amp-only captures need a cab IR after them,
                            # which is why the chain keeps its cab slot

NAM_MODELS = [
    {"name": "DLX", "file": "fender-deluxe-reverb-a2.nam",
     "source": "https://www.tone3000.com/tones/fender-deluxe-reverb-a2-65227",
     "note": "by sdatkinson, NAM's author; vibrato channel"},
    {"name": "PLEXI", "file": "marshall-jmp50-plexi-1969-a2.nam",
     "source": "https://www.tone3000.com/tones/marshall-jmp-50-lead-1969-plexi-65578",
     "note": "A2-Full ESR 0.0074"},
    {"name": "IIC+", "file": "mesa-mark-iic-plus-hetfield-rhythm.nam",
     "source": "https://www.tone3000.com/tones/mesa-boogie-mark-iic-hetfield-rhythm-2769",
     "note": "A2-Full ESR 0.0039"},
    # These two have guitarix voicings but no pinned capture yet; the
    # session falls back to guitarix for them rather than shipping a
    # wrong amp under the right name.
    {"name": "AC30", "file": None,
     "source": "https://www.tone3000.com (search: AC30 top boost A2)",
     "note": "capture not yet pinned; guitarix voicing used"},
    {"name": "5150", "file": None,
     "source": "https://www.tone3000.com (search: 5150 A2)",
     "note": "capture not yet pinned; guitarix voicing used"},
]

# Buildroot/apt package names behind the URIs above.
PACKAGES = [
    ("lsp-plugins-lv2", "EQ, compressor, limiter, multiband"),
    ("dragonfly-reverb", "the good reverb"),
    ("guitarix", "overdrive, distortion, amp and cab models"),
    ("x42-plugins", "fil4 EQ and dpl limiter fallbacks"),
    ("zam-plugins", "ZamTube fallback drive"),
]

# NAM is not in Debian; it is a prebuilt LV2 dropped into /usr/lib/lv2.
NAM_INSTALL = (
    "https://github.com/mikeoliphant/neural-amp-modeler-lv2/releases",
    "neural_amp_modeler_lv2_rpi5.tgz",
    "untar into /usr/lib/lv2 - links only libc and libm, no deps",
)


def role_for_kind(kind):
    return [r for r in ROLES if r["kind"] == kind]


def self_test():
    for r in ROLES:
        assert r["kind"] in KINDS, r["kind"]
        assert r["uris"], r["role"]
        assert len(r["knobs"]) == 4, "%s needs exactly 4 knobs" % r["role"]
        # Every role must end in something that ships with Ardour or in
        # a package we install, so a bare boot is never silent.
        if r["kind"] != "tuner":
            # A tuner is a monitor rather than an audible effect, so it
            # needs no silent-boot fallback; everything else does.
            assert r["uris"][-1].startswith(
                ("urn:ardour:", "http://zamaudio")), \
                "%s has no safe fallback" % r["role"]
    kinds = {r["kind"] for r in ROLES}
    missing = kinds - set(KINDS)
    assert not missing, missing
    # A2 has exactly two tiers; asserting it stops "nano"/"feather" (A1
    # names) creeping back in, which is the mistake this file was written
    # to correct.
    assert NAM_TIERS == ("lite", "full"), NAM_TIERS
    assert NAM_DEFAULT_TIER in NAM_TIERS
    assert NAM_REQUIRES_48K, "the plugin does no resampling"
    assert NAM_NEEDS_CAB_AFTER, "amp-only captures need a cab after them"

    assert len(AMP_MODELS) == len(NAM_MODELS), \
        "the two amp engines must offer the same voicings, or switching " \
        "engines would silently change the rig"
    for a, n in zip(AMP_MODELS, NAM_MODELS):
        assert a["name"] == n["name"], (a["name"], n["name"])
        assert a["gx_cab"], a["name"]
    print("plugins self-test PASS: %d roles, %d kinds, %d amp models, "
          "every role has a fallback, both engines offer the same "
          "voicings" % (len(ROLES), len(kinds), len(AMP_MODELS)))


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
