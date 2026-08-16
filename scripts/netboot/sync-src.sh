#!/bin/sh
# Push the repo's scripts to /opt/mpc-pi-src on the board.
#
# Exists because the ad-hoc "rsync -a ./ board:/opt/mpc-pi-src/" that this
# replaces took twenty minutes and pushed 1.3MB. The time went entirely
# into building a file list across results/, which holds 16GB of captured
# diagnostics, and rsync stats every one of them before deciding it has
# nothing to send. It is worse than slow: the board netboots with its
# root on NFS served by THIS machine, so the stat storm crosses the link
# in both directions and lands as filesystem load on the board - during
# whatever audio measurement happens to be running. A measurement taken
# while the source tree is being scanned is not a measurement of the
# instrument.
#
# So: an allowlist, not a denylist. What the board runs is scripts and a
# little configuration; a new large directory added to the repo should
# not be able to make this slow again by default.
#
#   sync-src.sh [host]        default: the DHCP lease for mpc-pi
set -eu
HOST="${1:-${MPCPI_HOST:-192.168.7.110}}"
DEST="${MPCPI_DEST:-/opt/mpc-pi-src}"
here=$(cd -- "$(dirname -- "$0")/../.." && pwd)

SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=8"

$SSH "root@$HOST" "install -d $DEST" || {
	echo "cannot reach root@$HOST" >&2
	exit 1
}

# Only what the board actually executes. tests/ comes along because the
# suite is meant to run ON the board - that is the whole point of having
# it - and it is small.
for d in scripts tests; do
	rsync -rlpt --delete \
		--exclude '__pycache__' --exclude '*.pyc' \
		-e "$SSH" \
		"$here/$d/" "root@$HOST:$DEST/$d/"
done

$SSH "root@$HOST" "chmod +x $DEST/scripts/*/*.sh $DEST/scripts/*.sh 2>/dev/null; true"
echo "synced scripts/ and tests/ to $HOST:$DEST"
