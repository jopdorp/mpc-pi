#!/bin/sh
# Put the cross-built emulator on the board and prove it starts there.
#
# Deploy and smoke test in one step, deliberately: the binary that
# preceded this script was copied over by hand, looked perfect to every
# check available on the build host - correct architecture, every NEEDED
# library resolved, no host paths in RPATH - and segfaulted before main()
# on the board, because the build host pages at 4K and the board pages at
# 16K. Nothing short of running it there could have caught that.
#
# So the deploy is not finished when the file has landed. It is finished
# when the board has run it.
#
#   deploy-mame.sh [host]
set -eu
HOST="${1:-${MPCPI_HOST:-192.168.7.110}}"
here=$(cd -- "$(dirname -- "$0")/../.." && pwd)
BIN="$here/board/rpi5/rootfs_overlay/usr/bin/mpc"
DEST=/usr/local/bin/mpc

[ -f "$BIN" ] || { echo "no emulator at $BIN - build it first" >&2; exit 1; }

SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=8"

# Stripped in flight. The unstripped binary carries debug_info and is
# 54MB rather than 76; on a board whose root is NFS-served by this same
# machine every megabyte crosses the link twice.
strip_bin=$(ls "$here"/.cache/br-rpi5/host/bin/aarch64-*-strip 2>/dev/null | head -1)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if [ -n "$strip_bin" ]; then
	"$strip_bin" -o "$tmp" "$BIN"
else
	cp "$BIN" "$tmp"
fi

$SSH "root@$HOST" "pkill -x mpc 2>/dev/null; true"
rsync -z -e "$SSH" "$tmp" "root@$HOST:$DEST.new"
$SSH "root@$HOST" "chmod 0755 $DEST.new && mv $DEST.new $DEST"

# The loader, not the program: --list resolves the interpreter and every
# library and reports what is wrong in one line, where running the
# program gives an exit code of 139 and nothing else. "not a dynamic
# executable" out of ldd means ldd could not run it, which is itself the
# answer.
echo "== loader"
$SSH "root@$HOST" "/lib/ld-linux-aarch64.so.1 --list $DEST 2>&1 | tail -3"

echo "== starts"
$SSH "root@$HOST" "$DEST -help >/tmp/mpc-help.txt 2>&1; \
	printf 'exit=%s  ' \$?; head -c 60 /tmp/mpc-help.txt; echo"
