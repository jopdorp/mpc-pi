#!/bin/sh
# Host the Ardour session for the appliance, headlessly.
#
# A wrapper rather than an ExecStart one-liner because ardour-env.sh has to
# FIND the Ardour installation: the version is baked into the paths
# (/usr/lib/ardour9, /usr/share/ardour9, /etc/ardour9), so hardcoding it in a
# unit file breaks on the next Ardour release.
#
# session-governor.lua is the session host, not a demo: it owns the session
# and drains daw-ctl's region-edit queue. Everything else - mixer, transport,
# plugin parameters - goes over OSC, but region editing needs the Lua API, so
# something has to hold the session open. This is it.
set -eu

SRC="${MPCPI_SRC:-/opt/mpc-pi-src}"
export SESSION_DIR="${MPCPI_SESSION:-/home/mpc/mpcpi}"
export SESSION_NAME="${MPCPI_SESSION_NAME:-live}"
# session-template.lua defaults MPCPI_COMPAT to a RELATIVE path,
# "scripts/daw/ardour-compat.lua", which only resolves when the cwd is the
# repository root. A service has no such cwd, and the failure is
# "Permission denied" rather than "not found", which sends you looking at file
# modes instead of at the path. Same for CHAINS_JSON.
export MPCPI_COMPAT="${MPCPI_COMPAT:-$SRC/scripts/daw/ardour-compat.lua}"
export CHAINS_JSON="${CHAINS_JSON:-$SRC/scripts/daw/chains.json}"
export SESSION_RATE="${SESSION_RATE:-44100}"
export DAW_QUEUE="${DAW_QUEUE:-/dev/shm/daw-region-queue}"
export DAW_REGIONS="${DAW_REGIONS:-/dev/shm/daw-regions}"

. "$SRC/scripts/daw/ardour-env.sh"
ardour_env || { echo "no Ardour installation found" >&2; exit 1; }

# Do NOT create $SESSION_DIR. Ardour's create_session() treats an existing
# directory as an existing session and returns nil with "Session already
# exists" - which is exactly what happened: the directory was empty, Ardour
# insisted the session was already there, and the service restarted twelve
# times. The passing integration test hands it a path that does not exist yet
# ("$base/s") and lets Ardour make it.
#
# Only the PARENT is ours to create.
mkdir -p "$(dirname "$SESSION_DIR")"

# BUILD the session if it does not exist, then host it.
#
# session-governor.lua hosts a session; session-template.lua CREATES one - the
# whole desk, 16 tracks and 27 inserts, and it is the path the integration test
# exercises ("the session template builds the whole desk"). Nothing was ever
# calling it, so the governor found no session, tried to create a bare one,
# failed, and restarted twelve times in a row.
if [ ! -f "$SESSION_DIR/$SESSION_NAME.ardour" ]; then
	echo "no session at $SESSION_DIR/$SESSION_NAME.ardour - building it"
	# An empty directory left by a previous failed attempt is enough to make
	# create_session refuse. Remove it if it is empty; never if it is not.
	[ -d "$SESSION_DIR" ] && rmdir "$SESSION_DIR" 2>/dev/null || true
	pw-jack "$LUASESSION" "$SRC/scripts/daw/session-template.lua" ||
		{ echo "session-template failed" >&2; exit 1; }
fi

# pw-jack, so Ardour's JACK backend lands on PipeWire instead of hunting for
# a jackd that is not running.
exec pw-jack "$LUASESSION" "$SRC/scripts/daw/session-governor.lua"
