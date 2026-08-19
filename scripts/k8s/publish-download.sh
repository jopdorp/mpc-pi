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
listing=$(
    kubectl --context "$kubectl_context" -n "$namespace" exec "$pod" -- \
        ls -1 /usr/share/nginx/html/files/ | sort
)
{
    printf '%s\n' '<!doctype html>'
    printf '%s\n' '<html><head><meta charset="utf-8"><title>MPC-Pi downloads</title>'
    printf '%s\n' '<style>body{font-family:sans-serif;max-width:40em;margin:2em auto;line-height:1.5}code{background:#f4f4f4;padding:0 .3em}</style>'
    printf '%s\n' '</head><body>'
    printf '%s\n' '<h1>MPC-Pi desktop bundles</h1>'
    printf '%s\n' '<p>Akai MPC2000XL / MPC3000 / MPC60 emulator: focused MAME build with the project low-latency patch stack. Linux only.</p>'
    printf '%s\n' '<p><strong>No ROMs included or hosted here</strong> — supply your own dumps in <code>roms/</code> inside the bundle.</p>'
    printf '%s\n' '<h2>Downloads</h2><ul>'
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        printf '<li><a href="files/%s">%s</a></li>\n' "$entry" "$entry"
    done <<<"$listing"
    printf '%s\n' '</ul>'
    printf '%s\n' '<p>Verify with <code>sha256sum -c</code> against the <code>.sha256</code> files.</p>'
    printf '%s\n' '<p>Quick start: extract, add ROMs to <code>roms/</code>, run <code>./mpcpi</code>. If <code>chrt</code> fails on your host: <code>MAME_RT_PRIORITY=0 ./mpcpi</code>.</p>'
    printf '%s\n' '<p><a href="files/">Raw file listing</a></p>'
    printf '%s\n' '</body></html>'
} | kubectl --context "$kubectl_context" -n "$namespace" create configmap download-site \
    --from-file=index.html=/dev/stdin --dry-run=client -o yaml \
    | kubectl --context "$kubectl_context" apply -f -

# nginx caches the mounted index at start; restart to serve the new page.
kubectl --context "$kubectl_context" -n "$namespace" rollout restart deployment/download
kubectl --context "$kubectl_context" -n "$namespace" rollout status \
    deployment/download --timeout=120s

printf 'Published %d file(s): https://%s/\n' "$#" "$site_host"
