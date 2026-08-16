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
  grep -E "^PASS|^FAIL|placed")
echo "$out"
rm -rf "$base"
echo "$out" | grep -q "0 unavailable" && ! echo "$out" | grep -q "^FAIL"
