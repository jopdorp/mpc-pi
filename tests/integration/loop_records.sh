#!/bin/bash
# The loop recorder, end to end on real Ardour: a take must become a region
# that repeats, and the transport must survive the punch-out.
#
# Exit status is NOT the pass signal. luasession aborts on teardown ("FATAL:
# exception not rethrown") whatever the script did, so every run exits 134;
# the summary markers are the contract, exactly as phase3-run.sh reads them.
set -uo pipefail
cd "$(dirname "$0")/../.."
. scripts/daw/ardour-env.sh
ardour_env || { echo "SKIP: no Ardour found"; exit 0; }

base=$(mktemp -d /tmp/looptest-XXXXXX)
# The Dummy backend, not the appliance's graph: this test records silence to
# prove region lifecycle, and it must not need PipeWire or take over a sound
# card on whatever machine runs it.
out=$(LOOPTEST_DIR="$base/s" MPCPI_SRC="$PWD" ARDOUR_BACKEND=Dummy \
	timeout 300 "$LUASESSION" tests/integration/loop_records.lua 2>&1 |
	grep -E "^(PASS|FAIL|LOOPTEST)|^    ")
echo "$out"
rm -rf "$base"

echo "$out" | grep -q "LOOPTEST-SUMMARY-END failures=0" || {
	echo "FAIL: the loop recorder did not complete cleanly"
	exit 1
}
