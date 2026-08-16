#!/bin/bash
# The template must build the whole desk with no missing plugins: the
# panel addresses strips by position, so a track that failed to appear
# silently shifts every column after it.
set -uo pipefail
cd "$(dirname "$0")/../.."
. scripts/daw/ardour-env.sh
ardour_env || { echo "SKIP: no Ardour found"; exit 0; }
base=$(mktemp -d /tmp/sesstest-XXXXXX)
out=$(SESSION_DIR="$base/s" SESSION_NAME=t CHAINS_JSON="$PWD/scripts/daw/chains.json" \
  timeout 300 "$LUASESSION" scripts/daw/session-template.lua 2>/dev/null |
  grep -E "^PASS|^FAIL|placed|^MAX-LATENCY")
echo "$out"
rm -rf "$base"

# One graph period at the target quantum. A plugin above that is one the
# live monitor path cannot carry, however good it sounds.
lat=$(printf '%s' "$out" | grep -oE "MAX-LATENCY [0-9]+" | grep -oE "[0-9]+")
if [ -n "$lat" ] && [ "$lat" -gt "${MAX_LATENCY_SAMPLES:-64}" ]; then
	echo "FAIL: worst insert latency ${lat} samples exceeds the live budget"
	exit 1
fi
echo "$out" | grep -q "0 unavailable" && ! echo "$out" | grep -q "^FAIL"
