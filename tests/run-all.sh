#!/bin/bash
# Everything that can be checked without hardware, in one command.
#
# Three layers, in increasing cost:
#   unit         pure logic, milliseconds
#   module       each script's own --self-test
#   integration  real Ardour: plugins load, a session builds, the region
#                governor edits actual audio
#
# Integration SKIPS loudly when Ardour is absent rather than passing
# quietly, because a test that silently does nothing is worse than no
# test - it reports green for work it never did.
#
#   tests/run-all.sh [--no-integration]
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0; skip=0
run() {
	local name="$1"; shift
	if "$@" >/tmp/mpcpi-test.$$ 2>&1; then
		printf '  PASS  %s\n' "$name"; pass=$((pass+1))
	else
		printf '  FAIL  %s\n' "$name"; fail=$((fail+1))
		sed 's/^/          /' /tmp/mpcpi-test.$$ | tail -12
	fi
	rm -f /tmp/mpcpi-test.$$
}
noted() { printf '  SKIP  %s\n' "$*"; skip=$((skip+1)); }

echo "== unit"
run "panel rendering, layout, control map" python3 tests/test_panel.py
run "engine, transport, clock, osc, routing" python3 tests/test_engine.py
run "interaction: input -> state -> screen" python3 tests/test_interaction.py
run "MK1 wire protocol: buttons, encoders, pads, LEDs" python3 tests/test_mk1_protocol.py

echo
echo "== module self-tests"
for m in scripts/daw/osc.py scripts/daw/daw_ctl.py scripts/daw/daw_ctl_clock.py \
         scripts/daw/daw-ctl scripts/daw/chains.py \
         scripts/maschine/plugins.py scripts/maschine/ardour_bindings.py \
         scripts/maschine/maschine-hub.py; do
	run "$(basename "$m")" python3 "$m" --self-test
done

if [ "${1:-}" = "--no-integration" ]; then
	echo; echo "== integration (skipped by request)"
else
	echo
	echo "== integration"
	# shellcheck source=../scripts/daw/ardour-env.sh
	. scripts/daw/ardour-env.sh
	if ardour_env; then
		echo "  (Ardour $ARDOUR_VERSION at $ARDOUR_DLL_PATH)"
		# The governor's own arithmetic needs no session, but it is Lua, and
		# the only Lua on this appliance is Ardour's - so it runs here rather
		# than with the unit tests.
		# CAPTURE, THEN MATCH, AND RETRY ONE KNOWN ABORT.
		#
		# This was piped into `grep -q`, which threw the output away, so
		# an intermittent failure here reported nothing at all to look
		# at. Capturing it named the fault in one run: luasession aborts
		# during process teardown with
		#
		#     FATAL: exception not rethrown        (SIGABRT, rc 134)
		#
		# roughly two runs in eight, before the self-test has printed
		# anything. That is Ardour's own shutdown race - it happens with
		# an unchanged, passing script and has nothing to do with the
		# loop-ops logic under test - so retrying it is honest, where
		# retrying a real assertion failure would not be. The retry is
		# bounded and matches that ONE signature; anything else fails on
		# the spot, with its output.
		#
		# A flaky harness is worse than a missing one: it trains you to
		# re-run until green, which is how a real regression gets waved
		# through.
		run "loop-ops: wire format, take selection, fit, plan" \
			bash -c 'for attempt in 1 2 3; do
				out=$(LOOP_OPS_SELFTEST=1 "$LUASESSION" \
					scripts/daw/loop-ops.lua 2>&1)
				case "$out" in
					*"self-test PASS"*) exit 0;;
					*"exception not rethrown"*) continue;;
				esac
				printf "%s\n" "$out"; exit 1
			done
			echo "luasession aborted on all 3 attempts:"
			printf "%s\n" "$out"; exit 1'
		run "every plugin in the manifest instantiates" \
			bash tests/integration/plugins_load.sh
		run "the session template builds the whole desk" \
			bash tests/integration/session_builds.sh
		run "a take becomes a region that repeats" \
			bash tests/integration/loop_records.sh
	else
		noted "Ardour not installed - integration not run"
	fi
fi

printf '\n== %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
