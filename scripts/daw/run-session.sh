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
export DAW_QUEUE="${DAW_QUEUE:-/dev/shm/daw-region-queue}"
export DAW_REGIONS="${DAW_REGIONS:-/dev/shm/daw-regions}"

. "$SRC/scripts/daw/ardour-env.sh"
ardour_env || { echo "no Ardour installation found" >&2; exit 1; }

mkdir -p "$SESSION_DIR"

# pw-jack, so Ardour's JACK backend lands on PipeWire instead of hunting for
# a jackd that is not running.
exec pw-jack "$LUASESSION" "$SRC/scripts/daw/session-governor.lua"
