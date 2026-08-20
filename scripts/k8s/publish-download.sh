#!/usr/bin/env bash
set -euo pipefail

# Publish desktop bundles to the download page: copy the given files onto
# the volume, then regenerate the landing page from what is actually there.
# Usage: scripts/k8s/publish-download.sh FILE [FILE...]
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
kubectl_context=${KUBE_CONTEXT:-microk8s}
namespace=mpcpi
site_host=${MPCPI_SITE_HOST:-mpc.jegor.nl}

if (( $# == 0 )); then
    printf 'usage: %s FILE [FILE...]\n' "$0" >&2
    exit 2
fi
for publish_file in "$@"; do
    if [[ ! -f "$publish_file" ]]; then
        printf 'error: no such file: %s\n' "$publish_file" >&2
        exit 1
    fi
done

kubectl --context "$kubectl_context" apply -f "$repo_root/scripts/k8s/download-page.yaml"
kubectl --context "$kubectl_context" -n "$namespace" rollout status \
    deployment/download --timeout=120s

pod=$(kubectl --context "$kubectl_context" -n "$namespace" get pod \
    -l app=download -o jsonpath='{.items[0].metadata.name}')
for publish_file in "$@"; do
    kubectl --context "$kubectl_context" -n "$namespace" cp \
        "$publish_file" "$namespace/$pod:/usr/share/nginx/html/files/"
done

# The page lists what the volume holds, not what this script was handed, so
# an interrupted publish cannot advertise a file that is not downloadable.
# lost+found is filesystem housekeeping on the volume, not a download.
listing=$(
    kubectl --context "$kubectl_context" -n "$namespace" exec "$pod" -- \
        ls -1 /usr/share/nginx/html/files/ | sort | grep -v '^lost+found$' || true
)

page_head() {
    cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MPC-Pi — the Akai MPC on your desktop</title>
<style>
  :root{
    --bg:#0e0f12;--panel:#171a1f;--panel2:#1d2128;--text:#e8e6e1;
    --dim:#9aa0a8;--accent:#c8e64a;--accent2:#7fb069;--line:#2a2f37;
    --code-bg:#11141a;--warn:#e0a458;--err:#e5644e;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);
    font:16px/1.65 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
  .wrap{max-width:52rem;margin:0 auto;padding:0 1.5rem}
  header{border-bottom:1px solid var(--line);padding:3rem 0 2rem;
    background:linear-gradient(180deg,#14161b 0%,var(--bg) 100%)}
  h1{font-size:2.2rem;margin:0;letter-spacing:-.02em}
  h1 .accent{color:var(--accent)}
  .tagline{color:var(--dim);font-size:1.15rem;margin:.6rem 0 0;max-width:38rem}
  h2{font-size:1.15rem;margin-top:2.6rem;letter-spacing:.02em;
    text-transform:uppercase;color:var(--accent)}
  section{margin-bottom:1rem}
  a{color:var(--accent);text-decoration:none}
  a:hover{text-decoration:underline}
  code{background:var(--code-bg);border:1px solid var(--line);border-radius:4px;
    padding:.1rem .35rem;font-size:.9em;color:#d3d7de}
  pre{background:var(--code-bg);border:1px solid var(--line);border-radius:8px;
    padding:.9rem 1.1rem;overflow-x:auto}
  pre code{border:0;padding:0;background:none}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;
    padding:1.1rem 1.4rem;margin:.8rem 0}
  dl.downloads{margin:0}
  dl.downloads dt{font-weight:600;margin-top:.9rem}
  dl.downloads dd{margin:0;color:var(--dim)}
  dl.downloads dd .size{color:var(--text)}
  table{border-collapse:collapse;width:100%;margin:.6rem 0}
  th,td{border:1px solid var(--line);padding:.5rem .8rem;text-align:left;
    vertical-align:top}
  th{background:var(--panel2);font-weight:600}
  .note{border-left:3px solid var(--warn);padding:.6rem 1rem;
    background:var(--panel);border-radius:0 8px 8px 0}
  footer{border-top:1px solid var(--line);margin-top:3.5rem;padding:1.8rem 0;
    color:var(--dim);font-size:.9rem}
</style>
</head>
<body>
<header>
  <div class="wrap">
    <h1>MPC-<span class="accent">Pi</span></h1>
    <p class="tagline">The Akai MPC2000XL, MPC3000 and MPC60 — running their
    original firmware through a focused MAME build, tuned for low-latency
    play on Linux.</p>
  </div>
</header>
<div class="wrap">

<section id="downloads">
<h2>Downloads</h2>
<div class="card">
<dl class="downloads">
HTML
}

page_tail() {
    cat <<'HTML'
</dl>
<p style="color:var(--dim);margin-top:1.2rem">
Verify with <code>sha256sum -c *.sha256</code> after downloading.
Linux x86-64 (PipeWire audio) and Windows 10/11 x86-64 (stock MAME
audio; the audio-clock pacing port is the planned follow-up).
ROMs are not included and never will be.</p>
</div>
</section>

<section id="what">
<h2>What this is</h2>
<p>A dedicated MAME build containing only the Akai machines, carrying this
project's ordered stack of 52 measured patches: an audio-clocked PipeWire
backend that paces emulation from the sound card, event-driven panel and
MIDI UARTs, and V53 fast paths that keep the machine's timing while taking
it from ~11% of one core to hundreds of percent of real time. The result
boots the actual MPC firmware, loads real floppy projects, samples, and
sequences — with a 32-frame (~0.7&nbsp;ms) audio quantum.</p>
<p>The panel on screen is the complete MPC2000XL front panel: buttons are
clickable, the pads respond, and the knobs and sliders are mouse-controlled
through the bundled layout plugin.</p>
</section>

<section id="quickstart">
<h2>Quick start</h2>
<pre><code>tar -xzf mpcpi-*-linux-x86_64.tar.gz
cd mpcpi-*/
cp /path/to/your/mpc2000xl.zip roms/     # your own legally dumped ROMs
./mpcpi                                  # play
./mpcpi -flop myproject.img              # with a floppy project</code></pre>
<p>Other machines: <code>./mpcpi-accurate mpc3000</code>,
<code>./mpcpi-accurate mpc60</code>. If your user holds no realtime
scheduling rlimit: <code>MAME_RT_PRIORITY=0 ./mpcpi</code>. On a hybrid
P/E-core CPU, pin to the P-cores for the tuned latency:
<code>MAME_CPUSET=0-11 ./mpcpi</code>.</p>
</section>

<section id="controllers">
<h2>Pad controllers</h2>
<p>Any class-compliant USB-MIDI pad controller (Akai MPD18, MPD218, &hellip;)
becomes the MPC's <em>own</em> pads — not its MIDI input — through the
low-latency internal-pads path:</p>
<pre><code>./mpcpi -listmidi                            # find your controller's port
MPC_MIDI_INPUT_MODE=internal-pads \
  ./mpcpi -midiin1 'PORT NAME' -flop myproject.img</code></pre>
<table>
  <tr><th>MIDI</th><th>Becomes</th><th>Notes</th></tr>
  <tr><td>Notes 36&ndash;51</td><td>Pads 1&ndash;16 (bank A)</td>
      <td>Note-on velocity is pad velocity</td></tr>
  <tr><td>CC 1</td><td>DATA wheel</td>
      <td>Relative: 3 = three clicks up, 125 = three down</td></tr>
  <tr><td>CC 2</td><td>NOTE VARIATION slider</td>
      <td>Absolute 0&ndash;127</td></tr>
</table>
</section>

<section id="maschine">
<h2>Maschine MK1 as the front panel</h2>
<div class="note">
<p><strong>Experimental on desktop.</strong> This is the appliance's proven
configuration — both MK1 screens, lamps, pads and encoders driven by the
bundled hub — but the desktop wiring is new and not yet hardware-verified.</p>
</div>
<pre><code>sudo modprobe snd-virmidi
sudo setfacl -m u:$USER:rw /dev/snd/midiC*D0
./mpcpi-maschine</code></pre>
</section>

<section id="accuracy">
<h2>Speed vs. accuracy</h2>
<p><code>./mpcpi</code> enables every <em>accepted</em> fast path — the ones
whose PCM output and event timing are measured identical to the accurate
implementation. The panel runs the accurate path by default: the faster
event-driven panel UART still ghosts occasional button presses on desktop,
so the bundle stays on the accurate one until that is fixed.
<code>./mpcpi-accurate</code> gives you the stock reference paths
everywhere. The project's measurements live in its repository.</p>
</section>

<footer>
  <div class="wrap" style="padding:0">
  <p>Source and licence: GPL-2.0+ MAME with local modifications, full patch
  stack and launchers at <a href="https://github.com/jopdorp/mpc-pi">github.com/jopdorp/mpc-pi</a>.
  Akai firmware is copyrighted and is not distributed here — bring your own
  dumps.</p>
  </div>
</footer>
</div>
</body>
</html>
HTML
}

{
    page_head
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        size=$(kubectl --context "$kubectl_context" -n "$namespace" exec "$pod" -- \
            stat -c %s "/usr/share/nginx/html/files/$entry" 2>/dev/null || echo '?')
        printf '<dt><a href="files/%s" download>%s</a></dt>\n' "$entry" "$entry"
        printf '<dd>%s bytes</dd>\n' "$size"
    done <<<"$listing"
    page_tail
} | kubectl --context "$kubectl_context" -n "$namespace" create configmap download-site \
    --from-file=index.html=/dev/stdin --dry-run=client -o yaml \
    | kubectl --context "$kubectl_context" apply -f -

# nginx caches the mounted index at start; restart to serve the new page.
kubectl --context "$kubectl_context" -n "$namespace" rollout restart deployment/download
kubectl --context "$kubectl_context" -n "$namespace" rollout status \
    deployment/download --timeout=120s

printf 'Published %d file(s): https://%s/\n' "$#" "$site_host"
