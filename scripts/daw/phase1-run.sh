#!/usr/bin/env bash
# Run the Phase 1 headless-Ardour proof of concept (see
# docs/maschine-daw-design.md). Gates on the PASS lines in the summary.
set -uo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
lua=${LUASESSION:-/usr/lib/ardour9/luasession}
base=$(mktemp -d /tmp/daw-phase1-XXXXXX)
# create_session wants to create the session directory itself
export PHASE1_DIR=${PHASE1_DIR:-$base/session}
# Environment the packaged /usr/bin/ardour wrapper normally provides.
ardour_prefix=$(dirname "$lua")
export ARDOUR_DATA_PATH=${ARDOUR_DATA_PATH:-/usr/share/$(basename "$ardour_prefix")}
export ARDOUR_CONFIG_PATH=${ARDOUR_CONFIG_PATH:-/etc/$(basename "$ardour_prefix")}
export ARDOUR_DLL_PATH=${ARDOUR_DLL_PATH:-$ardour_prefix}
export LD_LIBRARY_PATH=$ardour_prefix${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
echo "session dir: $PHASE1_DIR"
"$lua" "$repo_root/scripts/daw/phase1-poc.lua" 2>&1
