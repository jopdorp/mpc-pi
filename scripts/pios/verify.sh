#!/bin/bash
# Measure the appliance. Numbers, not claims.
#
# Every check prints what it found and whether that passes, so a bad
# result is visible rather than buried. Checks that need hardware which
# is not attached SKIP loudly instead of failing quietly - an untested
# thing must never look like a passing thing.
#
#   sudo ./verify.sh [--quick]
set -uo pipefail
QUICK="${1:-}"
pass=0; fail=0; skip=0
ok()   { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  SKIP  %s\n' "$*"; skip=$((skip+1)); }
hdr()  { printf '\n== %s\n' "$*"; }

hdr "boot time"
if command -v systemd-analyze >/dev/null 2>&1; then
	t=$(systemd-analyze time 2>&1 | head -1)
	echo "  $t"
	# "Bootup is not yet finished" is a PASS-looking non-answer: it means
	# a job is still queued, which is how userconfig.service hid for
	# weeks while multi-user.target waited on a console nobody would ever
	# answer. Treat it as the failure it is, and name the culprit.
	case "$t" in
	*"not yet finished"*)
		bad "boot never completes - jobs still queued:"
		systemctl list-jobs 2>/dev/null | head -4 | sed 's/^/    /'
		;;
	*)
		secs=$(systemd-analyze time 2>/dev/null | grep -oE '=[0-9.]+s' |
			tail -1 | tr -d '=s')
		# Two budgets, because this board netboots and the shipped one
		# will not. Roughly 3s of the kernel phase is a single line -
		# "macb eth0: Link is Up" - waiting for ethernet negotiation so
		# the NFS root can mount. That cost does not exist on SD.
		if [ -n "$secs" ]; then
			awk -v s="$secs" 'BEGIN{exit !(s<15)}' &&
				ok "boot $secs s (netboot budget 15s)" ||
				bad "boot $secs s - run: systemd-analyze critical-chain"
		fi
		k=$(systemd-analyze time 2>/dev/null |
			grep -oE '[0-9.]+s \(kernel\)' | tr -d 's (kernel)')
		link=$(dmesg 2>/dev/null | grep -oE '^\[ *[0-9.]+\] macb.*Link is Up' |
			head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
		if [ -n "$k" ] && [ -n "$link" ]; then
			awk -v k="$k" -v l="$link" 'BEGIN{
				printf "  kernel %.2fs, of which %.2fs is the netboot link wait -> ~%.2fs on SD\n", k, l, k - l }'
		fi
		;;
	esac
	echo "  slowest units:"
	systemd-analyze blame 2>/dev/null | head -5 | sed 's/^/    /'
else
	note "systemd-analyze unavailable"
fi

hdr "kernel"
# uname -v, not /sys/kernel/realtime: that file does not exist on 6.12
# even on a PREEMPT_RT build, so testing for it reports a stock kernel
# on an RT one. The version string carries the preemption model.
# This is a FAILURE, not a note. Running the stock kernel is not a
# lesser configuration of this appliance - it is a different machine,
# and every latency number taken on it is void. It was a note once, and
# that is exactly how the board ran 6.18.34+rpt stock for an unknown
# stretch: apt installed linux-image-6.18.34+rpt-rpi-2712, which writes
# kernel_2712.img - the filename build-rt-kernel.sh used - and nothing
# ever said so out loud.
if uname -v | grep -q PREEMPT_RT; then
	ok "PREEMPT_RT kernel ($(uname -r))"
else
	bad "NOT PREEMPT_RT - running $(uname -r), $(uname -v)"
	echo "    Every latency measurement on this kernel is void."
	echo "    Serve the RT kernel:  sudo mpcpi-netboot kernel rt"
	echo "    Or build one:         scripts/build-rt-kernel.sh"
fi

# Requested on the cmdline is not the same as in effect. The stock
# kernel accepted nohz_full=1-3 and silently ignored it - no
# CONFIG_NO_HZ_FULL - leaving this file empty while /proc/cmdline looked
# perfectly correct. Compare against what the tuning file asks for
# rather than a number pasted here, which is how the old "2-3" survived
# the widening to 1-3.
want_nohz=$(grep -oE 'nohz_full=[^ ]+' \
	"$(dirname "$0")/../../board/rpi5/cmdline-tuning" 2>/dev/null |
	cut -d= -f2)
[ -n "$want_nohz" ] || want_nohz=$(grep -oE 'nohz_full=[^ ]+' /proc/cmdline |
	cut -d= -f2)
have_nohz=$(cat /sys/devices/system/cpu/nohz_full 2>/dev/null)
if [ -n "$want_nohz" ] && [ "$have_nohz" = "$want_nohz" ]; then
	ok "nohz_full=$have_nohz in effect"
elif [ -z "$have_nohz" ]; then
	bad "nohz_full requested ($want_nohz) but EMPTY - kernel lacks CONFIG_NO_HZ_FULL"
else
	bad "nohz_full is '$have_nohz', tuning asks for '$want_nohz'"
fi

# isolcpus the same way: what the scheduler actually honoured.
want_iso=$(grep -oE 'isolcpus=[^ ]+' \
	"$(dirname "$0")/../../board/rpi5/cmdline-tuning" 2>/dev/null | cut -d= -f2)
have_iso=$(cat /sys/devices/system/cpu/isolated 2>/dev/null)
if [ -n "$want_iso" ] && [ "$have_iso" = "$want_iso" ]; then
	ok "isolcpus=$have_iso in effect"
else
	bad "isolated cores are '$have_iso', tuning asks for '$want_iso'"
	echo "    A netbooting Pi reads cmdline.txt over TFTP, not from its"
	echo "    root - so tune-realtime.sh cannot fix this. Re-run:"
	echo "      sudo mpcpi-netboot start"
fi

hdr "cpu"
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "?")
[ "$gov" = "performance" ] && ok "governor performance" || bad "governor is $gov"
grep -qw isolcpus /proc/cmdline && ok "isolcpus present" || bad "isolcpus missing"
grep -qw nohz_full /proc/cmdline && ok "nohz_full present" || bad "nohz_full missing"
[ "$(swapon --show 2>/dev/null | wc -l)" -eq 0 ] && ok "swap off" || bad "swap is on"

hdr "scheduling latency"
if command -v cyclictest >/dev/null 2>&1; then
	if [ "$QUICK" = "--quick" ]; then dur=10; else dur=60; fi
	echo "  running cyclictest for ${dur}s on an isolated core..."
	out=$(cyclictest -m -p 90 -a 3 -t 1 -i 500 -D "${dur}" -q 2>/dev/null | tail -3)
	echo "$out" | sed 's/^/    /'
	max=$(echo "$out" | grep -oE 'Max:[ ]*[0-9]+' | grep -oE '[0-9]+' | tail -1)
	if [ -n "$max" ]; then
		# At quantum 32 a period is 667us, so a worst case above ~200us
		# is eating a third of the budget and will eventually xrun.
		[ "$max" -lt 200 ] && ok "worst-case latency ${max}us" \
			|| bad "worst-case ${max}us is too high for quantum 32"
	fi
else
	note "cyclictest not installed (apt install rt-tests)"
fi

hdr "audio devices"
if aplay -l 2>/dev/null | grep -qi "mpc\|pcm5102\|i2s"; then
	ok "I2S card present"
	aplay -l 2>/dev/null | grep -i "card" | sed 's/^/    /'
else
	note "no I2S card - DAC/ADC not connected (expected on the bench)"
fi
if [ -d /sys/class/udc ] && [ -n "$(ls /sys/class/udc 2>/dev/null)" ]; then
	ok "USB gadget controller present ($(ls /sys/class/udc | head -1))"
else
	note "no UDC - dwc2 overlay inactive or no USB-C host attached"
fi

hdr "audio engine"
if command -v ardour9 >/dev/null 2>&1 || command -v ardour >/dev/null 2>&1; then
	ok "Ardour installed"
else
	bad "Ardour missing"
fi
if command -v lv2ls >/dev/null 2>&1; then
	# Enumerate ONCE into a variable. Piping lv2ls into `grep -q` makes
	# grep exit at the first match, which SIGPIPEs lv2ls, and with
	# pipefail the whole pipeline then reports failure - so installed
	# plugins were being reported absent. Found by this script
	# contradicting a plugin load that had already been proven.
	all=$(lv2ls 2>/dev/null)
	n=$(printf '%s\n' "$all" | grep -c . )
	[ "$n" -gt 100 ] && ok "$n LV2 plugins" || bad "only $n LV2 plugins"
	for want in lsp-plug guitarix dragonfly neural-amp x42 ardour; do
		case "$all" in
			*"$want"*) ok "  $want present" ;;
			*) note "  $want absent" ;;
		esac
	done
else
	note "lv2ls unavailable (apt install lilv-utils)"
fi

hdr "appliance payload"
for f in /opt/mpc-pi/daw/daw-ctl /opt/mpc-pi/maschine/daw_ui.py \
         /usr/local/bin/mpc; do
	[ -e "$f" ] && ok "$(basename "$f")" || bad "missing $f"
done
if [ -e /opt/mpc-pi/maschine/daw_ui.py ]; then
	python3 - <<'PY' && ok "panel renders on target" || bad "panel render failed"
import sys
sys.path.insert(0, "/opt/mpc-pi/maschine")
import daw_ui
f = daw_ui.render(daw_ui.sample_state("LOOP"))
assert len(f.px) == 255 * 64
PY
fi

hdr "services"
for s in mpcpi-daw-ui mpcpi-irq-affinity; do
	if systemctl is-enabled "$s" >/dev/null 2>&1; then
		state=$(systemctl is-active "$s" 2>/dev/null)
		[ "$state" = "active" ] || [ "$state" = "inactive" ] &&
			ok "$s ($state)" || bad "$s is $state"
	else
		note "$s not enabled"
	fi
done

printf '\n== %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
