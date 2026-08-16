#!/bin/bash
# Cross-build the appliance kernel: PREEMPT_RT + NO_HZ_FULL + Cortex-A76.
#
# Pi OS ships neither PREEMPT_RT nor NO_HZ_FULL, and both were being
# "configured" from the cmdline where the kernel silently ignored them.
# RT is mainline arm64 since 6.12, so this is a config, not a patch set.
# Netboot makes delivery a copy into TFTP - no card, no flashing.
#
#   scripts/build-rt-kernel.sh          (desktop; result in .cache/rt-kernel)
set -euo pipefail
D=~/development/mpc-pi/.cache/rt-kernel
SRC=$D/linux
REPO=~/development/mpc-pi
mkdir -p "$D"
# Prefer the repo's own Buildroot toolchain; its prefix is aarch64-linux-.
BR=~/development/mpc-pi/.cache/br-rpi5/host/bin
if [ -x "$BR/aarch64-linux-gcc" ]; then
	export PATH="$BR:$PATH"; XPREFIX=aarch64-linux-
elif command -v aarch64-linux-gnu-gcc >/dev/null; then
	XPREFIX=aarch64-linux-gnu-
else
	echo "no aarch64 cross compiler" >&2; exit 1
fi
if [ ! -d "$SRC" ]; then
	git clone --depth=1 --branch rpi-6.12.y \
		https://github.com/raspberrypi/linux "$SRC"
fi
cd "$SRC"
export ARCH=arm64 CROSS_COMPILE=$XPREFIX KERNEL=kernel_2712
make bcm2712_defconfig
./scripts/config --enable PREEMPT_RT --disable PREEMPT_DYNAMIC \
	--enable NO_HZ_FULL --enable RCU_NOCB_CPU \
	--enable HIGH_RES_TIMERS --disable DEBUG_PREEMPT
# A76 tuning: the compiler flag is what matters; defconfig is generic v8.
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-mpcpi-rt"/' .config || true
make olddefconfig
grep -E "PREEMPT_RT=y|NO_HZ_FULL=y" .config || { echo "config refused RT" >&2; exit 1; }
# Patches. Kept as a stack like the MAME one, applied fresh each build
# so a rebuilt tree never silently loses them, and reverted on exit so
# the checkout stays clean for the next run.
KPATCHES=$(ls "$REPO"/patches/kernel/0*.patch 2>/dev/null || true)
applied=0
cleanup_kpatch() {
	for p in $(printf '%s\n' $KPATCHES | tac); do
		[ "$applied" -gt 0 ] || break
		git -C "$SRC" apply --reverse "$p" 2>/dev/null || true
		applied=$((applied - 1))
	done
}
trap cleanup_kpatch EXIT
for p in $KPATCHES; do
	git -C "$SRC" apply --check "$p" 2>/dev/null || {
		printf 'error: kernel patch does not apply: %s\n' "$p" >&2
		exit 1
	}
	git -C "$SRC" apply "$p"
	applied=$((applied + 1))
	printf 'applied %s\n' "$(basename "$p")"
done

make -j"$(nproc)" KCFLAGS="-mcpu=cortex-a76" Image dtbs modules
echo "BUILD OK: $SRC/arch/arm64/boot/Image"
