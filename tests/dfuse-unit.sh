#!/usr/bin/env bash
# DAOS's dfuse_test (cmocka) on dfuse without and with --allow-idmap: cache modes x interception
# needs: server
# Run by "lab test dfuse-unit <client vm> [DAOS_PREFIX=/opt/daos] [AS=<user>|root]
# [MODES='default allow'] [CACHES='writeback writethrough metadata otoc']
# [ILS='none ioil pil4dfs pil4dfs-env']"
# with a DAOS build whose tests package has dfuse_test. As ftest daos_test/dfuse.py does
# (DaosCoreTestDfuse, which upstream CI runs for dfuse changes): a container per cache mode with
# that mode's dfuse attributes, dfuse in multi-user mode, dfuse_test with the same test groups, as
# the user that runs dfuse (AS, default the container owner; root works too). With an
# interception library it also checks whose pool and container handles the library used: dfuse's,
# shared through the ioctl, since dfuse_test runs as the dfuse user.
#   pil4dfs      libpil4dfs finds the mount and takes dfuse's handles through the ioctl, the path
#                of dfuse --allow-idmap. Without the exec group: its child checks D_IL_MOUNT_POINT.
#   pil4dfs-env  as in ftest: D_IL_MOUNT_POINT, D_IL_POOL and D_IL_CONTAINER, with which
#                libpil4dfs connects to the pool itself and never asks dfuse
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
daos_paths
DFUSE=$DAOS_BIN/dfuse
DFUSE_TEST=$DAOS_BIN/dfuse_test
[ -x "$DFUSE_TEST" ] || { echo "no $DFUSE_TEST (daos-client-tests package)" >&2; exit 2; }
AS=${AS:-$CONT_OWNER}
MODES=${MODES:-default allow}
CACHES=${CACHES:-writeback writethrough metadata otoc}
ILS=${ILS:-none ioil pil4dfs pil4dfs-env}
WORK=$(mktemp -d)
chmod 777 "$WORK"
# some path tests create files next to the test directory: its parent must be writable for AS
MNT=$WORK/dfuse

as_user() { if [ "$AS" = root ]; then "$@"; else sudo -u "$AS" -- "$@"; fi; }

# dfuse attributes of the cache modes, as in ftest daos_test/dfuse.py
cache_attrs() {
	case $1 in
	writeback | writethrough | metadata)
		local data=on
		[ "$1" = metadata ] && data=otoc
		echo "dfuse-data-cache:$data,dfuse-attr-time:5m,dfuse-dentry-time:5m,dfuse-ndentry-time:5m"
		;;
	otoc) echo "dfuse-data-cache:otoc,dfuse-attr-time:0,dfuse-dentry-time:0,dfuse-ndentry-time:0" ;;
	esac
}

start_dfuse() { # mode cache cont
	local args=(--foreground --multi-user)
	[ "$1" = allow ] && args+=(--allow-idmap)
	[ "$2" != writeback ] && args+=(--disable-wb-cache)
	mkdir -p "$MNT"
	chown "$AS" "$MNT"
	as_user env D_LOG_FILE="$WORK/dfuse-$1-$2.log" D_LOG_MASK=INFO \
		"$DFUSE" "${args[@]}" "$MNT" "$POOL" "$3" >/dev/null 2>&1 &
	dfuse_pid=$!
	for _ in $(seq 1 60); do
		findmnt -n -t fuse.daos "$MNT" >/dev/null && return 0
		sleep 0.5
	done
	return 1
}

stop_dfuse() {
	fusermount3 -u "$MNT" 2>/dev/null || umount -l "$MNT"
	wait "$dfuse_pid" 2>/dev/null
}

# run_dfuse_test mode cache il: prints "passed", or the failed tests; for an interception library
# also whose handles it used
run_dfuse_test() {
	local mode=$1 cache=$2 il=$3 log=$WORK/test-$1-$2-$3 env=() groups rc
	groups=(--io --stream --mmap --exec --directory --cache --path --lowfd --flock)
	# ftest leaves out metadata with writeback caching
	[ "$cache" != writeback ] && groups+=(--metadata)
	case $il in
	ioil) env=(LD_PRELOAD="$DAOS_LIB/libioil.so") ;;
	pil4dfs*)
		env=(LD_PRELOAD="$DAOS_LIB/libpil4dfs.so" D_IL_NO_BYPASS=1 D_IL_MAX_EQ=2 D_IL_REPORT=1)
		if [ "$il" = pil4dfs-env ]; then
			env+=(D_IL_MOUNT_POINT="$MNT" D_IL_POOL="$POOL" D_IL_CONTAINER="$cont")
		else
			groups=("${groups[@]/--exec/}")
		fi
		;;
	esac
	[ "$il" != none ] && env+=(D_LOG_FILE="$log.il.log" D_LOG_MASK=INFO,IL=DEBUG DD_MASK=all
		DD_SUBSYS=all)
	# the tests create their files in the test directory, which the dfuse user owns
	# shellcheck disable=SC2068
	as_user env "${env[@]}" "$DFUSE_TEST" --test-dir "$MNT" ${groups[@]} >"$log.out" 2>&1
	rc=$?
	if [ $rc = 0 ] && grep -q 'OK - NO TEST FAILURES' "$log.out"; then
		echo passed
	else
		echo "rc $rc: $(grep '\[  FAILED  \] [a-z]' "$log.out" | awk '{print $NF}' | sort -u | tr '\n' ' ')"
		cp "$log.out" "/tmp/dfuse-unit-$mode-$cache-$il.out"
	fi
}

ioil_handles() { # libioil log -> whose pool and container handles it used (as in dfuse-idmap)
	if grep -q "ioil_fetch_cont_handles() failed, backing off" "$1" 2>/dev/null; then echo own
	elif grep -q "ioil_fetch_cont_handles() ioctl returned" "$1" 2>/dev/null; then echo dfuse
	else echo none; fi
}

pil_ops() { # dfuse_test output -> most operations one process intercepted with libpil4dfs
	sed -n 's/^\[op_sum *\] *\([0-9]*\).*/\1/p' "$1" | sort -n | tail -1
}

t() { check "[$mode] $1" "$2" "$3"; }

for mode in $MODES; do
	for cache in $CACHES; do
		cont=dfuse-unit-$cache-$$
		as_user "$DAOS_BIN/daos" cont create "$POOL" "$cont" --type POSIX \
			--properties cksum:off,srv_cksum:off --attrs "$(cache_attrs "$cache")" >/dev/null ||
			{ t "$cache: container" created failed; continue; }
		if ! start_dfuse "$mode" "$cache" "$cont"; then
			t "$cache: dfuse mounts" yes no
			as_user "$DAOS_BIN/daos" cont destroy "$POOL" "$cont" >/dev/null 2>&1
			continue
		fi
		for il in $ILS; do
			# ftest: "File metadata is incorrect after write with writeback caching and IL"
			[ "$cache" = writeback ] && [ "$il" != none ] && continue
			t "$cache, $il: dfuse_test" passed "$(run_dfuse_test "$mode" "$cache" "$il")"
			log=$WORK/test-$mode-$cache-$il
			[ "$il" = ioil ] &&
				t "$cache, ioil: uses dfuse's handles" dfuse "$(ioil_handles "$log.il.log")"
			if [ "${il:0:7}" = pil4dfs ]; then
				n=$(pil_ops "$log.out")
				what="intercepts with dfuse's handles"
				[ "$il" = pil4dfs-env ] && what="intercepts with its own connection"
				t "$cache, $il: $what (${n:-0} ops)" yes \
					"$([ "${n:-0}" -gt 0 ] && echo yes || echo no)"
			fi
		done
		stop_dfuse
		as_user "$DAOS_BIN/daos" cont destroy "$POOL" "$cont" >/dev/null 2>&1
	done
	if [ "$mode" = allow ]; then
		got=unknown
		grep -q "Idmapped mounts allowed" "$WORK"/dfuse-allow-*.log 2>/dev/null && got=allowed
		grep -q "Kernel does not support idmapped mounts" "$WORK"/dfuse-allow-*.log 2>/dev/null &&
			got=unsupported
		exp=unsupported
		kernel_ge 6.12 && exp=allowed
		t "dfuse log: idmapped mounts ($(uname -r))" "$exp" "$got"
	fi
done
rm -rf "$WORK"
report "dfuse-unit on $(hostname -s), $(uname -r), dfuse as $AS, $("$DFUSE" --version | head -1)"
