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

# TURN THE OSC SURFACE ON, or the panel cannot drive the mixer.
#
# Control protocols default to INACTIVE and nothing here ever enabled one. The
# Lua API of this build exposes no way to do it - there is no
# ARDOUR.ControlProtocolManager - and setting active="1" in the session file
# does not work either. luasession never writes a user config, so the directory
# existed with no config in it and every surface stayed off.
#
# The failure is quiet in the worst way: Ardour runs, daw-ctl sends, the UDP
# send succeeds because UDP always succeeds, and nothing is listening on 3819.
# Knobs move, the panel redraws, the mixer does not budge.
#
# Written here rather than shipped in the image because this appliance is
# provisioned by copying scripts/, not by the Buildroot overlay - a file under
# board/ would never arrive. Create-if-missing, and only flip the one flag if a
# config already exists, so a hand-tuned Ardour config is never clobbered.
ACFG="${HOME:-/home/mpc}/.config/ardour${ARDOUR_VERSION:-8}/config"
if [ ! -f "$ACFG" ]; then
	mkdir -p "$(dirname "$ACFG")"
	cat > "$ACFG" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Ardour>
	<Config/>
	<Metadata/>
	<ControlProtocols>
		<Protocol name="Open Sound Control (OSC)" active="1"/>
	</ControlProtocols>
</Ardour>
XML
	echo "wrote $ACFG with the OSC surface enabled"
elif grep -q 'name="Open Sound Control (OSC)" active="0"' "$ACFG"; then
	sed -i 's|name="Open Sound Control (OSC)" active="0"|name="Open Sound Control (OSC)" active="1"|' "$ACFG"
	echo "enabled the OSC surface in $ACFG"
fi

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
	# A missing state with rescue candidates: RESTORE, do not rebuild. The
	# governor's own recovery renames an unloadable live state to
	# .broken-<stamp> ("moved an unloadable session aside") and Ardour keeps
	# a .bak of the previous save, but nothing ever put either back - and
	# create_session below cannot rebuild into this non-empty directory, so
	# the service looped for two days between "no session" and "Session
	# already exists" while the takes sat intact on disk. The newest
	# quarantine is the state the machine itself chose to save last; copy
	# rather than move so the evidence stays whatever happens to the copy.
	# If the state is genuinely dead the governor re-quarantines the copy
	# and this restarts the search - visible in the journal as the same
	# candidate coming back, which is the operator's cue to intervene.
	cand=$(ls -t "$SESSION_DIR/$SESSION_NAME.ardour.broken-"* \
		"$SESSION_DIR/$SESSION_NAME.ardour.bak" 2>/dev/null | head -1)
	if [ -n "$cand" ]; then
		echo "no live state at $SESSION_DIR/$SESSION_NAME.ardour" \
			"- restoring $cand"
		cp -p "$cand" "$SESSION_DIR/$SESSION_NAME.ardour" ||
			echo "WARNING: restore of $cand failed" >&2
	else
		echo "no session at $SESSION_DIR/$SESSION_NAME.ardour - building it"
		# An empty directory left by a previous failed attempt is enough to
		# make create_session refuse. Remove it if it is empty; never if it
		# is not.
		[ -d "$SESSION_DIR" ] && rmdir "$SESSION_DIR" 2>/dev/null || true
		pw-jack "$LUASESSION" "$SRC/scripts/daw/session-template.lua" ||
			{ echo "session-template failed" >&2; exit 1; }
	fi
fi

# THE LOOP LANES MUST TAKE THE INSTRUMENT ON EVERY START, NOT ONLY AT BUILD.
#
# session-template.lua points the lanes at the emulator's ":speaker" when it
# BUILDS the desk, and that is the only place it has ever happened. A session
# that is LOADED keeps whatever its saved XML says instead - and what this
# one's XML said was the USB codec's capture ports, because Ardour auto-
# connects a new track's input to the first physical input it finds and that
# wiring got saved. Every take afterwards recorded the codec rather than the
# MPC. It has been repaired by a hand-run pw-link after a restart twice now,
# which is not a repair; this service restarting is enough to undo it again.
#
# From the shell with pw-link, deliberately, and not from the governor in
# Lua: IO:disconnect(nil) segfaults luasession outright - no error, no
# traceback, and pcall cannot catch it (measure-dsp.lua, "Unlinking the track
# inputs is done from the shell, not from here"). Cutting a link from outside
# the process costs an error message; cutting it from inside costs the
# session host.
#
# Ardour's ports take a SLASH between node and port (":LOOP1/audio_in 1")
# while MAME's take a COLON (":speaker:output_FL") - see mpc-usb-route.sh,
# where getting this wrong read as "No such file or directory" for ports that
# pw-link itself was listing.
#
# Disconnect before connect: connecting alone leaves the codec attached
# ALONGSIDE the emulator and sums the two, which is the same class of fault
# that once put 44 emulator links onto a measurement tone. Only physical
# captures are cut, so a deliberate non-physical source survives, and
# pw-link -d on a link that is not there is a no-op.
#
# Backgrounded with a retry because neither side exists yet: the lanes appear
# only once the governor below has loaded the session, and ":speaker" only
# once mpcpi-emulator has published it. It gives up after two minutes rather
# than leaving a poller behind for the life of the service.
lanes_take_the_instrument() {
	lanes=$(echo "${MPCPI_STRIPS:-LOOP1,LOOP2,LOOP3,LOOP4,LOOP5}" | tr ',' ' ')
	tries=0
	while [ "$tries" -lt 60 ]; do
		tries=$((tries + 1))
		sleep 2
		pw-link -o 2>/dev/null | grep -q '^:speaker:output_FL$' || continue
		pw-link -i 2>/dev/null | grep -q '/audio_in 1$' || continue
		caps=$(pw-link -o 2>/dev/null | grep '^alsa_input\.' || true)
		fed=0
		for lane in $lanes; do
			ch=0
			for src in FL FR; do
				ch=$((ch + 1))
				dst=":$lane/audio_in $ch"
				for cap in $caps; do
					pw-link -d "$cap" "$dst" 2>/dev/null || true
				done
				pw-link ":speaker:output_$src" "$dst" 2>/dev/null || true
			done
			fed=$((fed + 1))
		done
		echo "lanes take the emulator: $fed lane(s) on :speaker"
		return 0
	done
	echo "WARNING: gave up pointing the loop lanes at :speaker" >&2
}

if [ "${MPCPI_LANE_INPUTS:-1}" != "0" ]; then
	lanes_take_the_instrument &
fi

# pw-jack, so Ardour's JACK backend lands on PipeWire instead of hunting for
# a jackd that is not running.
exec pw-jack "$LUASESSION" "$SRC/scripts/daw/session-governor.lua"
