#!/usr/bin/env bash
# Basic client check: agent, pool/container, dfuse mount, data integrity, IL interception
# needs: server
# Run by "lab test smoke <vm> [DAOS_PREFIX=/opt/daos] [SIZE_MB=64]" as root on a client VM.
# A starting point for new test tasks: copy it and add checks.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
daos_paths
SIZE_MB=${SIZE_MB:-64}
MNT=/mnt/testlab-smoke
user=$CONT_OWNER
work=$(mktemp -d)
chmod 755 "$work"

check "daos_agent socket present" yes "$(yes_no test -S /var/run/daos_agent/daos_agent.sock)"
check "pool $POOL reachable ($user)" yes "$(yes_no sudo -u "$user" "$DAOS_BIN/daos" pool query "$POOL")"
check "container $CONT reachable ($user)" yes \
	"$(yes_no sudo -u "$user" "$DAOS_BIN/daos" cont query "$POOL" "$CONT")"

mkdir -p "$MNT"
fusermount3 -u "$MNT" 2>/dev/null
"$DAOS_BIN/dfuse" --multi-user "$MNT" "$POOL" "$CONT" >"$work/dfuse.out" 2>&1
check "dfuse mounts $POOL/$CONT" yes "$(yes_no findmnt -n -t fuse.daos "$MNT")"
findmnt -n -t fuse.daos "$MNT" >/dev/null || { cat "$work/dfuse.out"; report "smoke: no dfuse mount"; exit 1; }

dir=$MNT/testlab-smoke-$$
mkdir -p "$dir" && chmod 777 "$dir" # DFS has no sticky bit
head -c $((SIZE_MB * 1048576)) /dev/urandom >"$work/data"
cp "$work/data" "$dir/data"
sync
# read back through dfuse (--disable-caching is not used: this also checks the cache path)
check "data read back through dfuse is identical (${SIZE_MB} MiB)" yes \
	"$(yes_no cmp "$work/data" "$dir/data")"
check "another user ($user) reads it (multi-user)" yes "$(yes_no sudo -u "$user" cmp "$work/data" "$dir/data")"

log=$work/ioil.log
LD_PRELOAD=$DAOS_LIB/libioil.so D_LOG_FILE=$log D_LOG_MASK=DEBUG DD_MASK=all dd if="$dir/data" of=/dev/null bs=1M \
	>/dev/null 2>&1
n=$(sed -n 's/.*Performed \([0-9]*\) reads.*/\1/p' "$log" 2>/dev/null | tail -1)
check "libioil intercepts reads ($n)" yes "$([ "${n:-0}" -gt 0 ] && echo yes || echo no)"
n=$(LD_PRELOAD=$DAOS_LIB/libpil4dfs.so D_IL_REPORT=1 D_IL_NO_BYPASS=1 cat "$dir/data" 2>&1 >/dev/null |
	sed -n 's/^\[op_sum *\] *\([0-9]*\).*/\1/p' | tail -1)
check "libpil4dfs intercepts ($n ops)" yes "$([ "${n:-0}" -gt 0 ] && echo yes || echo no)"

rm -rf "$dir"
fusermount3 -u "$MNT"
check "dfuse unmounts" yes "$(findmnt -n "$MNT" >/dev/null && echo no || echo yes)"
# the agent logs the fabric it hands out for every client process: "... dom:rxe0 prov:<provider>"
alog=/var/log/daos/daos_agent.log
if [ -f "$alog" ]; then
	check "clients get fabric provider $DAOS_PROVIDER" "$DAOS_PROVIDER" \
		"$(grep -o 'prov:[^ ]*' "$alog" | tail -1 | cut -d: -f2)"
fi
rm -rf "$work"
report "smoke on $(hostname -s), $(uname -r), $("$DAOS_BIN/dfuse" --version | head -1), $DAOS_PROVIDER"
