#!/usr/bin/env bash
# dscan: build and unit tests of the per-container space scanner on a client VM
# needs: server
# Run by "scripts/lab-test.sh [UNIT_ONLY=1] [DSCAN_SRC=/home/admin/dscan-src]" (lab-push.sh copies
# the sources first). Source of truth: lab/tests/dscan.sh in the dscan repository.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
DSCAN_SRC=${DSCAN_SRC:-/home/admin/dscan-src}
UNIT_ONLY=${UNIT_ONLY:-0}

dnf -y -q install daos-devel libuuid-devel gcc make jq >&2
check "daos-devel installed" yes "$(yes_no rpm -q daos-devel)"
check "dscan builds" yes "$(yes_no make -C "$DSCAN_SRC")"
check "unit tests pass" yes "$(yes_no make -C "$DSCAN_SRC" test)"
if [ "$UNIT_ONLY" = 1 ]; then
	report "dscan (unit only) on $(hostname -s)"
	exit
fi

daos_paths
GEN=$DSCAN_SRC/dscan-gen
LIST=$DSCAN_SRC/dfs-list
MNT=/mnt/testlab-dscan
work=$(mktemp -d)
chmod 755 "$work"

# Test containers are all named dscan-*. Stale ones (an earlier KEEP=1 run) are removed first, the
# trap removes ours at exit unless KEEP=1.
purge_containers() {
	local l
	for l in $("$DAOS_BIN/daos" cont list "$POOL" --json 2>/dev/null |
		jq -r '.response[]? | .label // empty | select(startswith("dscan-"))'); do
		"$DAOS_BIN/daos" cont destroy "$POOL" "$l" --force >/dev/null 2>&1
	done
}
cleanup() {
	fusermount3 -u "$MNT" 2>/dev/null
	[ "${KEEP:-0}" = 1 ] || purge_containers
	rm -rf "$work"
}
trap cleanup EXIT
fusermount3 -u "$MNT" 2>/dev/null
purge_containers

# ---- dscan-gen test tree (container dscan-a) vs dfuse and dfs-list ----
gen_a="--pool $POOL --cont dscan-a --seed 1 --dirs 50 --files 20000 --max-size 8388608 --symlinks 10 --big-dir 20000 --oclass mix"
# shellcheck disable=SC2086
"$GEN" $gen_a >"$work/gen-a.json" 2>"$work/gen-a.err"
check "dscan-gen creates dscan-a (one JSON line)" 1 "$(jq -c . "$work/gen-a.json" 2>/dev/null | wc -l | tr -d ' ')"
cat "$work/gen-a.err" >&2
jqn() { jq -r ".$1" "$work/gen-a.json" 2>/dev/null || echo none; }
gen_files=$(jqn files)
gen_dirs=$(jqn dirs)
gen_links=$(jqn symlinks)
gen_bytes=$(jqn logical_bytes)
echo "dscan-a generator: $(cat "$work/gen-a.json")" >&2

mkdir -p "$MNT"
fusermount3 -u "$MNT" 2>/dev/null
"$DAOS_BIN/dfuse" "$MNT" "$POOL" dscan-a >"$work/dfuse.out" 2>&1
check "dfuse mounts dscan-a" yes "$(yes_no findmnt -n -t fuse.daos "$MNT")"
check "dfuse: find -type f count equals files" "$gen_files" "$(find "$MNT" -type f | wc -l | tr -d ' ')"
check "dfuse: sum of file sizes equals logical_bytes" "$gen_bytes" \
	"$(find "$MNT" -type f -printf '%s\n' | awk '{ s += $1 } END { printf "%.0f", s }')"
check "dfuse: find -type d count equals dirs" "$gen_dirs" "$(find "$MNT" -type d | wc -l | tr -d ' ')"
check "dfuse: find -type l count equals symlinks" "$gen_links" "$(find "$MNT" -type l | wc -l | tr -d ' ')"
# 40000 file indexes: every 1000th gets a 255-byte name, every 1000th shifted by 500 a UTF-8 name
check "dfuse: 40 files with a 255-byte name" 40 \
	"$(find "$MNT" -type f -name 'f*xxxxxxxxxx*' | awk -F/ '{ if (length($NF) == 255) n++ } END { print n + 0 }')"
check "dfuse: 40 files with a UTF-8 name" 40 "$(find "$MNT" -type f -name 'файл-*' | wc -l | tr -d ' ')"
check "dfuse: at least 800 zero-size files (i % 50 == 0)" yes \
	"$([ "$(find "$MNT" -type f -size 0 | wc -l)" -ge 800 ] && echo yes || echo no)"
check "dfuse: symlinks point at d0000" d0000 "$(readlink "$MNT/s0")"
fusermount3 -u "$MNT" 2>/dev/null

# the object class lives in the high bits of oid.hi: --oclass mix gives two distinct values
oclasses() {
	awk '{ h = $1; sub(/\..*/, "", h); while (length(h) < 16) h = "0" h; print substr(h, 1, 8) }' "$1" |
		sort -u | wc -l | tr -d ' '
}

"$LIST" --pool "$POOL" --cont dscan-a >"$work/a.list" 2>"$work/a.list.err"
cat "$work/a.list.err" >&2
check "dfs-list: line count equals files" "$gen_files" "$(wc -l <"$work/a.list" | tr -d ' ')"
check "dfs-list: sum of size column equals logical_bytes" "$gen_bytes" \
	"$(awk '{ s += $3 } END { printf "%.0f", s }' "$work/a.list")"
check "dfs-list: every line is <hex>.<hex> <chunk> <size>" 0 \
	"$(grep -vcE '^[0-9a-f]+\.[0-9a-f]+ [0-9]+ [0-9]+$' "$work/a.list")"
check "dfs-list: --oclass mix gives two object classes" 2 "$(oclasses "$work/a.list")"
check "dfs-list: object ids are unique" "$gen_files" "$(cut -d' ' -f1 "$work/a.list" | sort -u | wc -l | tr -d ' ')"

# ---- chunked files: per-file chunk size and oit_logical_bytes ----
gen_c="--pool $POOL --cont dscan-gc --seed 5 --dirs 4 --files 100 --max-size 100000 --big-dir 30 --chunk-files 30 --chunk-size 65536 --oclass S1 --threads 3"
# shellcheck disable=SC2086
"$GEN" $gen_c >"$work/gen-c.json" 2>"$work/gen-c.err"
cat "$work/gen-c.err" >&2
echo "dscan-gc generator: $(cat "$work/gen-c.json")" >&2
"$LIST" --pool "$POOL" --cont dscan-gc >"$work/c.list" 2>/dev/null
check "dscan-gc: dfs-list count equals files" "$(jq -r .files "$work/gen-c.json" 2>/dev/null || echo none)" \
	"$(wc -l <"$work/c.list" | tr -d ' ')"
check "dscan-gc: dfs-list sum equals logical_bytes" "$(jq -r .logical_bytes "$work/gen-c.json" 2>/dev/null || echo none)" \
	"$(awk '{ s += $3 } END { printf "%.0f", s }' "$work/c.list")"
check "dscan-gc: --oclass S1 gives one object class" 1 "$(oclasses "$work/c.list")"
check "dscan-gc: 30 files have chunk size 65536" 30 "$(awk '$2 == 65536' "$work/c.list" | wc -l | tr -d ' ')"
# a mode-O scan assumes a 1 MiB chunk: D*floor((s-1)/C) + (s-1)%C + 1 for files with another chunk size
check "dscan-gc: oit_logical_bytes equals the 1 MiB chunk model of dfs-list" \
	"$(jq -r .oit_logical_bytes "$work/gen-c.json" 2>/dev/null || echo none)" \
	"$(awk -v D=1048576 '{ s = $3; c = $2; if (s > 0 && c != D) s = D * int((s - 1) / c) + (s - 1) % c + 1; t += s } END { printf "%.0f", t }' "$work/c.list")"

report "dscan on $(hostname -s)"
