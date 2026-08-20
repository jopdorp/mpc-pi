# AI handoff: desktop bundle, download page, and the desktop audio investigation (2026-08-19)

> **CORRECTED 2026-08-20, read before acting on anything below.** The next
> session bisected the central claim here and it is WRONG on this machine:
> installing the ACP-off WirePlumber rule alone stops the emulator creating
> any PipeWire nodes at all (~5% CPU, black window) — old and new binaries
> alike — and removing it restores a working machine immediately. Whatever
> made the ACP-off test read "perfect" that evening, the rule alone does not
> reproduce it. It now ships opt-in behind `MPCPI_DISABLE_ACP=1` (commit
> 823fb30). Also superseded: patch 0053 was committed, then REMOVED again —
> `:mic` appears without it, so the lazy-creation workaround was never
> needed; the queue's item 1 is void. Items 3/5/6 remain. The sampling
> investigation moved far past this doc: see patch 0055's header
> (circular record region, 3-bit send field, monitor voice pair 21/23) and
> `git log` from 823fb30 onward. The 9.6s-boot REGENIE build-time problem is
> fixed (conditional REGENIE, 20 min -> 1 min, commit a4d9c86).

Branch `perf/nec-opcode-fetch`. Everything below happened on the development
workstation `jopdorp-linux` (Intel Core Ultra 7 155H, 22 CPUs, Meteor Lake,
PipeWire 1.6.2 + WirePlumber, GNOME on Wayland). Session ran from the three
requests: merge status, package as a desktop app served from the home
cluster, install and play locally. It turned into a full desktop-audio
investigation. Read AGENTS.md first; its measurement discipline
("verify what the system did, not what you asked") decided most of this
session's findings.

## Delivered (5 commits, local, NOT pushed)

| commit | content |
|---|---|
| `460b747` | build-mame.sh now takes the whole ordered stack by sorted glob, like build-mame-rpi5.sh. It had a hand-frozen list ending at 0044 while `patches/mame/` grew to 0052 — the desktop build silently lacked 0045–0052 (panel-injection atomicity/queue fixes, MIDI CC wheel/slider, sampling input). |
| `e1cc120` | run-mpc.sh: `MAME_RT_PRIORITY=0` skips `chrt` for hosts whose users hold no realtime rlimit. Default unchanged (20). |
| `60ceb09` | `scripts/package-desktop.sh` + `scripts/k8s/`: redistributable Linux bundle, download page on the home k3s cluster at **https://mpc.jegor.nl/** (Traefik + cert-manager letsencrypt-prod ingress, nginx over a PVC, publish script regenerates the landing page from the volume). `dist/` gitignored. |
| `a394edd` | Bundle launchers run the appliance's `mpc-audio-thread-priority.sh` right after launch; CPU range from `/sys/devices/system/cpu/online` (nproc reports the caller's affinity mask and lies); real landing page; autoindex off; `--dirty` version suffix. |
| `71facd2` | Bundle self-configures audio: one-time WirePlumber ACP-off rule at `~/.config/wireplumber/wireplumber.conf.d/50-mpcpi-no-acp.conf`, graph rate-matched 48 kHz default, verified-clean 64-frame quantum default. |

Published bundle: `mpcpi-20260819-a394edd-linux-x86_64.tar.gz` (+sha256) on
the page. Locally installed (and currently running):
`~/Applications/mpcpi-20260819-60ceb09-linux-x86_64/` — one version OLDER
(no audio automation), so it needs explicit env vars (below).

Uncommitted, untouched deliberately: the user's DAW loop-record WIP
(`scripts/daw/*`, `tests/integration/loop_records.lua`,
`scripts/diagnostics/find-mpc-tempo*`, `test-daw-loop-record.sh`) and the
new **patch 0053** (untracked, see below).

## Verified working desktop configuration (user-audible verdict: "perfect, really low latency")

```
MAME_CPUSET=0-11 PIPEWIRE_RATE_HZ=48000 MPC_PIPEWIRE_FRAMES=64 \
  ./mpcpi -flop ~/development/mpc-pi/results/projects/mpc-tutor-logic-mpc2000xl.img
```

P-cores only; accurate panel; full-panel view; layout plugin enabled;
audio threads raised to SCHED_FIFO 60 after start by the bundle; graph
rate-matched at 48 kHz (q64 ≈ 1.33 ms). This was verified with ACP **off**.
Note: at session end both experimental WirePlumber rules had been removed
from the machine during an ACP-on test that never completed (lease errors),
so the machine is currently ACP-on with this game config running — audio
quality in that exact combination is unverified. The ACP-off recipe is in
commit 71facd2's launcher (`mpcpi-audio-setup`).

## The audio investigation, with the evidence chain

1. **Wedged session**: three concurrent `package-desktop.sh` runs (user
   cancellations didn't kill children) spawned stray `wireplumber`
   processes that fought the session manager; `pactl` timed out; the
   audio-clocked emulator stalled at ~2% CPU → "black window". Fix: kill
   strays + `systemctl --user restart pipewire.socket pipewire wireplumber
   pipewire-pulse`. The packaging script now holds an flock so concurrent
   runs can't race. One stray-daemon spawn mechanism was never fully root-
   caused; not reproducible on healthy inputs.
2. **The codec has no 44.1 kHz at all**: `/proc/asound/card2/codec#0`
   reads `rates [0x540]: 48000 96000 192000`. Every 44.1-forcing attempt
   was futile at the hardware level. This is the fact that reframes the
   whole repo assumption "run the graph at 44.1 so nothing resamples" —
   impossible on this machine's analog path (smart-amp firmware).
3. **ACP pins the device and ignores graph settings**: with
   `api.alsa.use-acp = true`, the device sat at 48000/1024 while every
   forcing mechanism (`clock.force-rate/quantum`, `default.clock.rate` +
   `default.clock.allowed-rates = [44100 48000]`, suspend/resume cycles)
   verified "applied" in metadata and changed nothing in
   `/proc/asound/.../hw_params`. The resampler that ACP puts in the path
   is what stalls the audio clock at small quanta: silence at q32,
   crackle at q64, tolerable at q128 (44.1-forced).
4. **Rate-matched 48 kHz works**: ACP off + graph 48000 + q64 → clean,
   low latency. The crackle in one 48k/q64 test was stale force-rate
   44100 metadata from an earlier experiment.
5. **Recording host audio**: MAME's `:mic` input node is created LAZILY.
   Stock `src/osd/modules/sound/pipewire_sound.cpp` (~line 735,
   `stream_input_open`) creates the capture node only when the emulated
   machine first *reads* its input (i.e., when the MPC firmware arms
   sampling). This explained every ":mic missing" report; it is not a
   bug in the stack. Inbound resampling (48k graph → 44.1 machine input)
   is the mirror of the working output path and is expected to work.
6. **Feedback paths**: WirePlumber auto-connects the default capture
   device to `:mic` on every launch (room-mic → speakers feedback = the
   "peep"); a sink-monitor link loops the machine's own output back in
   while recording ("xrunny after recording"). Both were cut manually
   with `pw-link -d`. See watcher pattern:
   `while true; do pw-link -l | grep ':mic' && date; sleep 2; done`.
7. **Scheduling**: emulation RR 20; effects thread already FIFO/RR 60 via
   patch 0046; the remaining starvation risk is PipeWire's client
   `thread-loop` at RR 20 — it was granted its scheduling by a privileged
   helper and unprivileged `chrt` gets EPERM on it specifically (even +1).
   Workaround: `sudo chrt -f -p 60 <tid>`. Durable fix: self-raise inside
   MAME's pipewire module (as 0046 did for the effects thread).
8. **Tooling**: qpwgraph goes stale/deaf after server restarts and needed
   `rm -rf ~/.config/rncbc.org/qpwgraph.conf*`; helvum worked throughout.
   MAME's stream nodes carry no `application.name` and render as unlabeled
   `:speaker`/`:mic`/`:fdc…` boxes — naming patch queued.

## New patch 0053 (written, applies cleanly, NOT built/tested/committed)

`patches/mame/0053-mpc2000xl-open-sampling-input-at-start.patch` — makes
`l7a1045_sound_device::sound_stream_update` call a new
`warm_capture_input()` (reads both input channels, discards samples) when
the recorder is idle, so the OSD capture node exists from machine start
and routing into `:mic` doesn't depend on arming sampling first.
Verified `git apply --check` on top of the 52-stack. The MAME checkout is
left CLEAN (stack reversed). Next step:
`MAME_JOBS=16 ./scripts/build-mame.sh && ./scripts/test-mame.sh --require-roms`,
then repackage/publish, then commit separately.

## Also diagnosed: event-panel ghosting (unfixed)

`MPC_PANEL_MODE=event` (desktop fast preset) ghosts button presses —
presses revert or skip; the accurate panel path behaves, so the bundle
defaults to accurate panel (wrapper env), repo preset unchanged. Symptom
class matches the historical Maschine release-corruption bugs
(commits 5331f16, 3b4c6ce). Untried bisect arm:
`MPC_PANEL_MODE=event MPC_PANEL_TIMER_MODE=accurate ./mpcpi` (splits
event-UART vs coalesced-timer). Appliance unaffected (panel HLE).

## Open work queue (priority order)

1. Build/validate/commit patch 0053.
2. q32 at 48 kHz rate-matched listening test (never run; q64 verified).
3. Thread-loop self-raise patch (kills the sudo step).
4. Event-panel ghost fix (bisect arm above).
5. Name MAME's PipeWire streams (`application.name`) for graph tools.
6. `:mic` autoconnect opt-out (patch 0051 env-gate, appliance opts in) +
   re-create capture node on server restart.
7. Generic non-analog sink hiding for the bundle (this machine's version:
   WirePlumber rule matching `playback\.[3-9]\.0$`, NOT shipped).
8. SOF driver experiment for true 44.1 (codec supports it only via SOF):
   `sudo apt install sof-firmware && echo 'options snd-intel-dspcfg
   dsp_driver=3' | sudo tee /etc/modprobe.d/99-mpcpi-sof.conf && sudo
   update-initramfs -u && reboot`; verify `grep rates /proc/asound/card*/codec*`.
9. Windows port: MXE cross-build (patches apply at source level; PipeWire
   patches simply don't build on win32); the audio-clock pacing needs
   porting to WASAPI exclusive (3–6 ms) as the first target, MMCSS
   ("Pro Audio") replaces chrt, ASIO is opt-in only (PortAudio built
   without it; Steinberg SDK redistribution limits).
10. Push the 5 commits; merge to main is a clean fast-forward (main =
    initial plan commit only). Decide policy on existing `Co-Authored-By:
    Claude` trailers vs AGENTS.md's no-AI-attribution rule before anything
    public.
11. `docs/mame-patch-stack.md` is stale (stops at 0044).
12. Maschine MK1 desktop verification (`./mpcpi-maschine`; virmidi + hub +
    turbo-with-window; appliance-proven, desktop-untested).

## Key paths and commands

- Download page: https://mpc.jegor.nl/ — publish with
  `KUBECONFIG=~/mini-pc-kubeconfig KUBE_CONTEXT=default
  ./scripts/k8s/publish-download.sh dist/<tarball> dist/<sha256>`.
  Cluster: 3× k3s (`jegor-mini-pc-a/b/c`), longhorn PVC, namespace `mpcpi`.
- Package: `./scripts/package-desktop.sh` (flock-guarded; strips a copy,
  ldd-guards unresolved libs, ROM-less by policy, GPLv2 COPYING included).
- Play: see "Verified working desktop configuration" above. MPD mapping:
  notes 36–51 = pads 1–16 w/ velocity, CC1 = DATA wheel (relative),
  CC2 = NOTE VARIATION (absolute);
  `MPC_MIDI_INPUT_MODE=internal-pads ./mpcpi -midiin1 '<port from -listmidi>'`.
- Audio verification, always: `grep -E 'rate|period_size'
  /proc/asound/card2/pcm0p/sub0/hw_params` (card2 = the only card, HDA
  Intel PCH; card numbers can shuffle across module reloads — re-verify
  via `pactl list sinks | grep alsa.card`).
- The graph lease (`$XDG_RUNTIME_DIR/mpc-pi-pipewire-graph-$UID.lock`)
   is held for ~5–10 s after the emulator dies (PipeWire settings
   restore); a too-fast relaunch fails with "another MPC fast launch owns
   the PipeWire graph settings". Wait for the lock to be free.
- Restarting the user audio session under a running emulator kills its
   `:mic` (and can wedge streams): stop the emulator first.
