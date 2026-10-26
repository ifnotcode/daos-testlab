#!/usr/bin/env bash
# dscan: build and unit tests of the per-container space scanner on a client VM
# needs: server
# Run by "scripts/lab-test.sh [UNIT_ONLY=1] [KEEP=1] [DSCAN_ARGS='--threads 1 --inflight 1']
# [DSCAN_SRC=/home/admin/dscan-src]" (lab-push.sh copies the sources first). DSCAN_ARGS is added to
# every dscan call. Source of truth: lab/tests/dscan.sh in the dscan repository.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
DSCAN_SRC=${DSCAN_SRC:-/home/admin/dscan-src}
UNIT_ONLY=${UNIT_ONLY:-0}
DSCAN_ARGS=${DSCAN_ARGS:-}

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
		# root may lack the right to destroy a container made by $CONT_OWNER (dscan-noacl)
		"$DAOS_BIN/daos" cont destroy "$POOL" "$l" --force >/dev/null 2>&1 ||
			sudo -u "$CONT_OWNER" "$DAOS_BIN/daos" cont destroy "$POOL" "$l" --force >/dev/null 2>&1
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

# ---- dscan mode W: dscan-a and an empty container ----
DSCAN=$DSCAN_SRC/dscan
# A run with --cont is ad hoc: it writes only <out-dir>/<pool>/scan-<ts>-cont.jsonl (no latest link,
# no textfile). adhoc_file <out-dir> prints that file (a path that does not exist if there is none).
adhoc_file() {
	local f
	f=$(ls "$1/$POOL"/scan-*-cont.jsonl 2>/dev/null | tail -1)
	echo "${f:-$1/$POOL/no-scan-file}"
}
"$DAOS_BIN/daos" cont create "$POOL" dscan-empty --type POSIX >"$work/empty.out" 2>&1
check "dscan-empty created" yes "$(yes_no "$DAOS_BIN/daos" cont get-prop "$POOL" dscan-empty)"
out=$work/out
t0=$(date +%s.%N)
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --cont dscan-a --cont dscan-empty --out-dir "$out" \
	--dump-entries "$work/w.list" $DSCAN_ARGS >"$work/dscan.out" 2>"$work/dscan.err"
rc=$?
t1=$(date +%s.%N)
cat "$work/dscan.out" "$work/dscan.err" >&2
echo "dscan W (DSCAN_ARGS='$DSCAN_ARGS'): exit $rc, wall $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }') s" >&2
check "dscan W: exit code 0" 0 "$rc"
latest=$(adhoc_file "$out")
line_a=$(jq -c 'select(.cont_label == "dscan-a")' "$latest" 2>/dev/null)
line_e=$(jq -c 'select(.cont_label == "dscan-empty")' "$latest" 2>/dev/null)
echo "dscan-a: $line_a" >&2
echo "dscan-empty: $line_e" >&2
jqa() { [ -n "$line_a" ] && jq -r ".$1" <<<"$line_a" 2>/dev/null || echo none; }
jqe() { [ -n "$line_e" ] && jq -r ".$1" <<<"$line_e" 2>/dev/null || echo none; }
check "dscan-a: files equal generator" "$gen_files" "$(jqa files)"
check "dscan-a: dirs equal generator" "$gen_dirs" "$(jqa dirs)"
check "dscan-a: symlinks equal generator" "$gen_links" "$(jqa symlinks)"
check "dscan-a: logical_bytes equal generator" "$gen_bytes" "$(jqa logical_bytes)"
check "dscan-a: status ok" ok "$(jqa status)"
check "dscan-a: errors 0" 0 "$(jqa errors)"
check "dscan-empty: files 0" 0 "$(jqe files)"
check "dscan-empty: dirs 1" 1 "$(jqe dirs)"
check "dscan-empty: logical_bytes 0" 0 "$(jqe logical_bytes)"
check "dscan-empty: status ok" ok "$(jqe status)"
check "dscan W: summary line, 2 containers, 2 ok" "2 2" \
	"$(jq -r 'select(.summary) | "\(.containers) \(.ok)"' "$latest" 2>/dev/null)"
check "dscan W: --dump-entries equals dfs-list (sorted)" yes \
	"$([ -s "$work/w.list" ] && cmp -s <(sort "$work/w.list") <(sort "$work/a.list") && echo yes || echo no)"
check "dscan-a: JSONL largest_file_bytes equals the largest size in dfs-list" \
	"$(awk '$3 > m { m = $3 } END { printf "%.0f", m }' "$work/a.list")" "$(jqa largest_file_bytes)"
check "dscan-empty: JSONL max_depth 0, largest_dir_entries 0, largest_file_bytes 0" "0 0 0" \
	"$(jqe max_depth) $(jqe largest_dir_entries) $(jqe largest_file_bytes)"

# ---- human output on stdout (like daos fs scan) ----
# hval <stdout file> <container label> <what>: the number of the line "dscan: <pool>/<label>: <n> <what>"
hval() { sed -n "s|^dscan: $POOL/$2: \([0-9]*\) $3\$|\1|p" "$1" | head -1; }
# the values of a container block, in JSONL order: files symlinks dirs bytes physical largest-file
# depth largest-dir
hblock() {
	echo "$(hval "$1" "$2" files) $(hval "$1" "$2" symlinks) $(hval "$1" "$2" directories)" \
		"$(hval "$1" "$2" 'bytes of total data') $(hval "$1" "$2" 'bytes estimated physical (oclass redundancy)')" \
		"$(hval "$1" "$2" 'bytes is largest file size') $(hval "$1" "$2" 'max tree depth')" \
		"$(hval "$1" "$2" 'entries in the largest directory')"
}
check "stdout W: dscan-a block equals its JSONL line (files symlinks dirs bytes physical largest-file depth largest-dir)" \
	"$(jqa files) $(jqa symlinks) $(jqa dirs) $(jqa logical_bytes) $(jqa physical_est_bytes) $(jqa largest_file_bytes) $(jqa max_depth) $(jqa largest_dir_entries)" \
	"$(hblock "$work/dscan.out" dscan-a)"
check "stdout W: dscan-a Done! line with status ok, average bytes per file" \
	"1 $(awk -v b="$(jqa logical_bytes)" -v f="$(jqa files)" 'BEGIN { if (f > 0) printf "%d", int(b / f); else print "none" }')" \
	"$(grep -cE "^dscan: $POOL/dscan-a: Done! \(runtime: [0-9]+ sec, avg [0-9]+ entries/sec, status ok\)$" "$work/dscan.out") $(hval "$work/dscan.out" dscan-a 'bytes per file on average')"
check "stdout W: the dscan-a block is 10 consecutive lines" "10 10" \
	"$(awk -v p="dscan: $POOL/dscan-a: " 'index($0, p) == 1 { n++; if (!f) f = NR; l = NR } END { print n + 0, l - f + 1 }' "$work/dscan.out")"
check "stdout W: start line, summary Done!, 2 ok 0 partial 0 failed 0 vanished" "1 1 1" \
	"$(grep -cE "^dscan: Start \([0-9TZ:-]+\) pool $POOL, shard 0/1, mode walk, 2 containers$" "$work/dscan.out") $(grep -cE '^dscan: Done! \(runtime: [0-9]+ sec, avg [0-9]+ entries/sec\)$' "$work/dscan.out") $(grep -cx 'dscan: 2 ok, 0 partial, 0 failed, 0 vanished containers' "$work/dscan.out")"
check "stdout W: run totals files/dirs/bytes equal dscan-a + dscan-empty" \
	"$(awk -v a="$(jqa files) $(jqa dirs) $(jqa logical_bytes)" -v e="$(jqe files) $(jqe dirs) $(jqe logical_bytes)" 'BEGIN { split(a, x); split(e, y); printf "%.0f %.0f %.0f", x[1] + y[1], x[2] + y[2], x[3] + y[3] }')" \
	"$(sed -n 's/^dscan: \([0-9]*\) files$/\1/p' "$work/dscan.out") $(sed -n 's/^dscan: \([0-9]*\) directories$/\1/p' "$work/dscan.out") $(sed -n 's/^dscan: \([0-9]*\) bytes of total data$/\1/p' "$work/dscan.out")"
check "stdout W: every line starts with 'dscan: ', none on stderr" "0 0" \
	"$(grep -vc '^dscan: ' "$work/dscan.out") $(grep -cE 'Done!|max tree depth|Start \(' "$work/dscan.err")"

# daos fs scan output on 2.8 (stdout, among other lines):
#   DFS scanner: 40000 files
#   DFS scanner: 10 symlinks
#   DFS scanner: 51 directories            (the root is not counted; dscan's dirs include it)
#   DFS scanner: 2 max tree depth          (entries of the root are at depth 1)
#   DFS scanner: <n> bytes of total data
#   DFS scanner: <n> bytes is largest file size
#   DFS scanner: 20000 entries in the largest directory
# fsval <file> <what>: the number of "DFS scanner: <n> <what>"
fsval() { sed -n "s/^DFS scanner: \([0-9]*\) $2\$/\1/p" "$1" | head -1; }
# fsblock <file>: fs scan values in hblock order, directories + 1 for the root, physical left out
fsblock() {
	local d
	d=$(fsval "$1" directories)
	echo "$(fsval "$1" files) $(fsval "$1" symlinks) $([ -n "$d" ] && echo $((d + 1)))" \
		"$(fsval "$1" 'bytes of total data') $(fsval "$1" 'bytes is largest file size')" \
		"$(fsval "$1" 'max tree depth') $(fsval "$1" 'entries in the largest directory')"
}
# hblock without the physical estimate (fs scan has none)
hblock_fs() { hblock "$1" "$2" | awk '{ $5 = ""; print }' | tr -s ' '; }
"$DAOS_BIN/daos" fs scan "$POOL" dscan-a >"$work/fsscan.out" 2>&1
cat "$work/fsscan.out" >&2
check "daos fs scan: files equal dscan" "$(fsval "$work/fsscan.out" files)" "$(jqa files)"
check "daos fs scan: bytes of total data equal dscan logical_bytes" \
	"$(fsval "$work/fsscan.out" 'bytes of total data')" "$(jqa logical_bytes)"
check "daos fs scan = dscan stdout, dscan-a: files symlinks dirs(+root) bytes largest-file depth largest-dir" \
	"$(fsblock "$work/fsscan.out")" "$(hblock_fs "$work/dscan.out" dscan-a)"

# A deeper tree through dfuse, to compare depth and largest directory with fs scan: a chain of
# directories with a file at depth 5, a chain of empty directories down to depth 6, a symlink.
"$DAOS_BIN/daos" cont create "$POOL" dscan-deep --type POSIX >/dev/null 2>&1
fusermount3 -u "$MNT" 2>/dev/null
"$DAOS_BIN/dfuse" "$MNT" "$POOL" dscan-deep >"$work/dfuse-deep.out" 2>&1
mkdir -p "$MNT/a/b/c/d" "$MNT/x/y/z/w/v/u" "$MNT/many" &&
	echo data >"$MNT/a/b/c/d/f" && ln -s a "$MNT/l" && for i in $(seq 300); do : >"$MNT/many/e$i"; done
rc_deep=$?
fusermount3 -u "$MNT" 2>/dev/null
check "dscan-deep: tree created through dfuse" 0 "$rc_deep"
"$DAOS_BIN/daos" fs scan "$POOL" dscan-deep >"$work/fsscan-deep.out" 2>&1
cat "$work/fsscan-deep.out" >&2
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --cont dscan-deep --out-dir "$work/out-deep" $DSCAN_ARGS >"$work/dscan-deep.out" 2>"$work/dscan-deep.err"
rc=$?
cat "$work/dscan-deep.out" "$work/dscan-deep.err" >&2
check "dscan-deep: exit 0, max tree depth 6, 300 entries in the largest directory" "0 6 300" \
	"$rc $(hval "$work/dscan-deep.out" dscan-deep 'max tree depth') $(hval "$work/dscan-deep.out" dscan-deep 'entries in the largest directory')"
check "daos fs scan = dscan stdout, dscan-deep: files symlinks dirs(+root) bytes largest-file depth largest-dir" \
	"$(fsblock "$work/fsscan-deep.out")" "$(hblock_fs "$work/dscan-deep.out" dscan-deep)"

check "dscan W (--cont, ad hoc): one scan file scan-<ts>-<pid>-cont.jsonl, no latest link, no textfile" "1 0 0" \
	"$(ls "$out/$POOL" 2>/dev/null | grep -cE '^scan-[0-9]{8}T[0-9]{6}Z-[0-9]+-cont\.jsonl$') $(ls "$out/$POOL" 2>/dev/null | grep -c '^latest-') $(ls "$out" 2>/dev/null | grep -c '\.prom$')"
check "dscan W (--cont, ad hoc): run lock .lock-cont-$POOL" yes "$([ -e "$out/.lock-cont-$POOL" ] && echo yes || echo no)"

# ---- dscan mode O (OIT of a snapshot): dscan-a and dscan-b (chunked files) ----
# --max-size (not in the plan's command) gives the regular files non-zero sizes, so a wrong default
# chunk size would show up in logical_bytes too.
gen_b="--pool $POOL --cont dscan-b --seed 2 --dirs 10 --files 2000 --chunk-files 200 --chunk-size 65536 --max-size 4194304 --threads 4"
# shellcheck disable=SC2086
"$GEN" $gen_b >"$work/gen-b.json" 2>"$work/gen-b.err"
cat "$work/gen-b.err" >&2
echo "dscan-b generator: $(cat "$work/gen-b.json")" >&2
check "dscan-gen creates dscan-b (one JSON line)" 1 "$(jq -c . "$work/gen-b.json" 2>/dev/null | wc -l | tr -d ' ')"
jqb() { jq -r ".$1" "$work/gen-b.json" 2>/dev/null || echo none; }
"$LIST" --pool "$POOL" --cont dscan-b >"$work/b.list" 2>/dev/null
check "dscan-b: 200 files have chunk size 65536" 200 "$(awk '$2 == 65536' "$work/b.list" | wc -l | tr -d ' ')"

# DAOS 2.8 has no named snapshots (create with a name: DER_NOSYS, list returns no names). dscan
# records its snapshot in the container attribute dscan-snapshot-<ts>-<pid> = <epoch>. Here: a
# client snapshot that must survive, and a leftover of a killed mode-O pass that must be removed.
# Both helpers print "error" when the daos call fails, so a "nothing left" check cannot pass
# without proof.
snaps() {
	local j s
	j=$("$DAOS_BIN/daos" cont list-snaps "$POOL" "$1" --json 2>/dev/null) || { echo error; return; }
	s=$(jq -r '(.response // [])[].epoch' <<<"$j" | sort -n | tr '\n' ' ')
	echo "${s:-none}" | sed 's/ $//'
}
# number of dscan-snapshot-* attributes of container $1
dscan_attrs() {
	local j
	j=$("$DAOS_BIN/daos" cont list-attrs "$POOL" "$1" --json 2>/dev/null) || { echo error; return; }
	jq -r '(.response // [])[]' <<<"$j" | grep -c '^dscan-snapshot-'
}
"$DAOS_BIN/daos" cont create-snap "$POOL" dscan-b >/dev/null 2>&1
client_snap=$(snaps dscan-b)
"$DAOS_BIN/daos" cont create-snap "$POOL" dscan-b >/dev/null 2>&1
leftover=$("$DAOS_BIN/daos" cont list-snaps "$POOL" dscan-b --json 2>/dev/null | jq -r '[.response[].epoch] | max')
"$DAOS_BIN/daos" cont set-attr "$POOL" dscan-b "dscan-snapshot-1:$leftover" >/dev/null 2>&1
check "dscan-b: a client snapshot and a dscan leftover exist" 2 "$(snaps dscan-b | wc -w | tr -d ' ')"

out_o=$work/out-o
t0=$(date +%s.%N)
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --mode oit --cont dscan-a --cont dscan-b --cont dscan-empty --out-dir "$out_o" $DSCAN_ARGS \
	>"$work/dscan-o.out" 2>"$work/dscan-o.err"
rc=$?
t1=$(date +%s.%N)
cat "$work/dscan-o.out" "$work/dscan-o.err" >&2
echo "dscan O (DSCAN_ARGS='$DSCAN_ARGS'): exit $rc, wall $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }') s" >&2
check "dscan O: exit code 0" 0 "$rc"
latest_o=$(adhoc_file "$out_o")
line_oa=$(jq -c 'select(.cont_label == "dscan-a")' "$latest_o" 2>/dev/null)
line_ob=$(jq -c 'select(.cont_label == "dscan-b")' "$latest_o" 2>/dev/null)
echo "dscan-a (oit): $line_oa" >&2
echo "dscan-b (oit): $line_ob" >&2
jqoa() { [ -n "$line_oa" ] && jq -r ".$1" <<<"$line_oa" 2>/dev/null || echo none; }
jqob() { [ -n "$line_ob" ] && jq -r ".$1" <<<"$line_ob" 2>/dev/null || echo none; }
check "dscan O dscan-a: mode oit, status ok" "oit ok" "$(jqoa mode) $(jqoa status)"
# An empty file that was never written has no object, so the OIT does not list it: mode O counts
# files minus those (the generator writes nothing to its size-0 files). Their size is 0, so
# logical_bytes is the same.
empty_a=$(awk '$3 == 0' "$work/a.list" | wc -l | tr -d ' ')
empty_b=$(awk '$3 == 0' "$work/b.list" | wc -l | tr -d ' ')
check "dscan O dscan-a: files equal generator minus never-written empty files ($empty_a)" \
	"$((gen_files - empty_a))" "$(jqoa files)"
check "dscan O dscan-a: dirs equal generator" "$gen_dirs" "$(jqoa dirs)"
check "dscan O dscan-a: logical_bytes equal generator" "$gen_bytes" "$(jqoa logical_bytes)"
check "dscan O dscan-a: symlinks null" null "$(jqoa symlinks)"
check "dscan O dscan-a: max_depth null, largest_dir_entries null, largest_file_bytes as mode W" \
	"null null $(jqa largest_file_bytes)" "$(jqoa max_depth) $(jqoa largest_dir_entries) $(jqoa largest_file_bytes)"
check "stdout O: dscan-a block has no symlinks, depth or largest-directory line" 0 \
	"$(grep -cE "^dscan: $POOL/dscan-a: [0-9]+ (symlinks|max tree depth|entries in the largest directory)$" "$work/dscan-o.out")"
check "stdout O: dscan-a block equals its JSONL line (files dirs bytes physical largest-file)" \
	"$(jqoa files) $(jqoa dirs) $(jqoa logical_bytes) $(jqoa physical_est_bytes) $(jqoa largest_file_bytes)" \
	"$(hval "$work/dscan-o.out" dscan-a files) $(hval "$work/dscan-o.out" dscan-a directories) $(hval "$work/dscan-o.out" dscan-a 'bytes of total data') $(hval "$work/dscan-o.out" dscan-a 'bytes estimated physical (oclass redundancy)') $(hval "$work/dscan-o.out" dscan-a 'bytes is largest file size')"
check "stdout O: start line mode oit with 3 containers, summary without a symlinks line" "1 1 0" \
	"$(grep -cE "^dscan: Start \(.*\) pool $POOL, shard 0/1, mode oit, 3 containers$" "$work/dscan-o.out") $(grep -cx 'dscan: 3 ok, 0 partial, 0 failed, 0 vanished containers' "$work/dscan-o.out") $(grep -cE '^dscan: [0-9]+ symlinks$' "$work/dscan-o.out")"
check "dscan O dscan-a: errors 0, other_objects 0" "0 0" "$(jqoa errors) $(jqoa other_objects)"
check "dscan O dscan-b: mode oit, status ok" "oit ok" "$(jqob mode) $(jqob status)"
check "dscan O dscan-b: files equal generator minus never-written empty files ($empty_b)" \
	"$(($(jqb files) - empty_b))" "$(jqob files)"
check "dscan O dscan-b: dirs equal generator" "$(jqb dirs)" "$(jqob dirs)"
check "dscan O dscan-b: logical_bytes equal oit_logical_bytes (default chunk for every file)" \
	"$(jqb oit_logical_bytes)" "$(jqob logical_bytes)"
line_oe=$(jq -c 'select(.cont_label == "dscan-empty")' "$latest_o" 2>/dev/null)
echo "dscan-empty (oit): $line_oe" >&2
# the root of an empty container has no object yet: counted anyway, as in mode W
check "dscan O dscan-empty: status ok, files 0, dirs 1" "ok 0 1" \
	"$([ -n "$line_oe" ] && jq -r '"\(.status) \(.files) \(.dirs)"' <<<"$line_oe" || echo none)"
check "dscan O: summary mode oit, 3 containers, 3 ok" "oit 3 3" \
	"$(jq -r 'select(.summary) | "\(.mode) \(.containers) \(.ok)"' "$latest_o" 2>/dev/null)"
# (no textfile from a --cont run: "no symlinks metric in mode O" is covered by tests/unit/test_report.c)
check "dscan O: dscan-a and dscan-empty have no snapshot left" "none none" "$(snaps dscan-a) $(snaps dscan-empty)"
check "dscan O: dscan-b keeps only the client snapshot" "$client_snap" "$(snaps dscan-b)"
check "dscan O: no dscan-snapshot-* attribute left" "0 0 0" \
	"$(dscan_attrs dscan-a) $(dscan_attrs dscan-b) $(dscan_attrs dscan-empty)"

# ---- no OIT object left behind ----
# Each mode-O pass makes the engine write the OIT as an object of the container (about 340 bytes
# per object, ~13 MB for dscan-a); destroying the snapshot does not remove it, dscan punches it and
# aggregation returns the space within ~1.5 min. Signal: pool SCM used around one more pass on
# dscan-a, after the pool settled (container purges and earlier writes are reclaimed in background).
scm_used() { "$DAOS_BIN/daos" pool query "$POOL" --json 2>/dev/null | jq -r '.response.tier_stats[0] | .total - .free'; }
scm_prev=$(scm_used)
for _ in $(seq 30); do   # settled: two samples 10 s apart are equal (at most 5 min)
	sleep 10
	scm_before=$(scm_used)
	[ "$scm_before" = "$scm_prev" ] && break
	scm_prev=$scm_before
done
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --mode oit --cont dscan-a --out-dir "$work/out-o2" $DSCAN_ARGS >/dev/null 2>&1
rc_o2=$?
scm_peak=$(scm_used)
# without this the space check could pass because the pass failed before creating its snapshot
check "dscan O (space check pass): exit 0, dscan-a status ok" "0 ok" \
	"$rc_o2 $(jq -r 'select(.cont_label == "dscan-a") | .status' "$(adhoc_file "$work/out-o2")" 2>/dev/null || echo none)"
scm_after=$scm_peak
for _ in $(seq 36); do   # at most 3 min for aggregation
	[ -n "$scm_after" ] && [ -n "$scm_before" ] && [ "$scm_after" -le $((scm_before + 4194304)) ] && break
	sleep 5
	scm_after=$(scm_used)
done
echo "SCM used: settled $scm_before, after an O pass on dscan-a $scm_peak, after aggregation $scm_after" >&2
check "dscan O: SCM used back within 4 MB of before after aggregation (OIT object punched)" yes \
	"$([ -n "$scm_after" ] && [ -n "$scm_before" ] && [ "$scm_after" -le $((scm_before + 4194304)) ] && echo yes || echo no)"

# mode W on dscan-b counts each file with its own chunk size: exactly logical_bytes. Rate-limited
# (about 4 500 operations at 200/s: over 20 s) for the default 15 s progress line.
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --cont dscan-b --rate 200 --out-dir "$work/out-wb" $DSCAN_ARGS >"$work/dscan-wb.out" 2>"$work/dscan-wb.err"
rc=$?
cat "$work/dscan-wb.out" "$work/dscan-wb.err" >&2
line_wb=$(jq -c 'select(.cont_label == "dscan-b")' "$(adhoc_file "$work/out-wb")" 2>/dev/null)
echo "dscan-b (walk): $line_wb" >&2
check "dscan W dscan-b: exit 0, logical_bytes equal generator" "0 $(jqb logical_bytes)" \
	"$rc $([ -n "$line_wb" ] && jq -r .logical_bytes <<<"$line_wb" || echo none)"
# progress lines: "dscan: Scanned <E> files/directories in <done>/<total> containers (runtime: <S> sec,
# avg <A> entries/sec, last <I>s <L> entries/sec)"; prog_lines <file> prints "E S A I L" per line
prog_re='^dscan: Scanned [0-9]+ files/directories in [0-9]+/[0-9]+ containers \(runtime: [0-9]+ sec, avg [0-9]+ entries/sec, last [0-9]+s [0-9]+ entries/sec\)$'
prog_lines() { grep -E "$prog_re" "$1" | sed -E 's/^dscan: Scanned ([0-9]+) .*runtime: ([0-9]+) sec, avg ([0-9]+) .*last ([0-9]+)s ([0-9]+) .*/\1 \2 \3 \4 \5/'; }
prog_lines "$work/dscan-wb.out" >"$work/prog-wb.txt"
check "progress (default 15 s, run over 20 s): at least 1 line, every line well-formed" yes \
	"$([ -s "$work/prog-wb.txt" ] && [ "$(grep -c '^dscan: Scanned' "$work/dscan-wb.out")" = "$(wc -l <"$work/prog-wb.txt" | tr -d ' ')" ] && echo yes || echo no)"
check "progress (default 15 s): first line at 15 s, interval 15 s, avg > 0" "15 15 yes" \
	"$(awk 'NR == 1 { print $2, $4, ($3 > 0 ? "yes" : "no") }' "$work/prog-wb.txt")"
check "progress: avg is entries / runtime (within 1/s)" yes \
	"$(awk 'NR == 1 { a = $1 / $2; print (a - $3 < 1.01 && $3 - a < 1.01) ? "yes" : "no" }' "$work/prog-wb.txt")"

# --progress-interval 2 on a run of about 10 s (dscan-gc: about 330 operations at 30/s)
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --cont dscan-gc --rate 30 --progress-interval 2 --out-dir "$work/out-pi" $DSCAN_ARGS \
	>"$work/dscan-pi.out" 2>"$work/dscan-pi.err"
rc=$?
cat "$work/dscan-pi.out" "$work/dscan-pi.err" >&2
prog_lines "$work/dscan-pi.out" >"$work/prog-pi.txt"
check "--progress-interval 2: exit 0, at least 3 progress lines" "0 yes" \
	"$rc $([ "$(wc -l <"$work/prog-pi.txt")" -ge 3 ] && echo yes || echo no)"
check "--progress-interval 2: runtimes 2, 4, 6 ..., intervals 2 s, entries never decrease" yes \
	"$(awk '{ if ($2 != 2 * NR || $4 != 2 || $1 < p) bad = 1; p = $1 } END { print (NR > 0 && !bad) ? "yes" : "no" }' "$work/prog-pi.txt")"
check "--progress-interval 2: progress lines come before the container block and the summary" yes \
	"$(awk '/^dscan: Scanned/ { l = NR } /^dscan: Done! / { d = NR } END { print (l > 0 && d > l) ? "yes" : "no" }' "$work/dscan-pi.out")"

# --quiet: nothing on stdout, even with progress due every second; the scan itself is unchanged
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --cont dscan-gc --rate 60 --progress-interval 1 --quiet --out-dir "$work/out-q" $DSCAN_ARGS \
	>"$work/dscan-q.out" 2>"$work/dscan-q.err"
rc=$?
cat "$work/dscan-q.err" >&2
check "--quiet: exit 0, empty stdout, dscan-gc ok in the JSONL" "0 0 ok" \
	"$rc $(wc -c <"$work/dscan-q.out" | tr -d ' ') $(jq -r 'select(.cont_label == "dscan-gc") | .status' "$(adhoc_file "$work/out-q")" 2>/dev/null || echo none)"

# ---- shards: 0/2 and 1/2 together cover every container of the pool exactly once ----
# The pool may hold containers the suite did not create (the lab's "posix"): compare with the full
# "daos cont list". A container dscan cannot open is reported failed; only the uuids matter here.
for i in 1 2 3 4 5 6; do
	"$DAOS_BIN/daos" cont create "$POOL" "dscan-sh$i" --type POSIX >/dev/null 2>&1
done
for k in 0 1; do
	# shellcheck disable=SC2086
	"$DSCAN" --pool "$POOL" --shard "$k/2" --out-dir "$work/out-sh$k" $DSCAN_ARGS >/dev/null 2>"$work/dscan-sh$k.err"
	echo "dscan --shard $k/2: exit $?" >&2
done
"$DAOS_BIN/daos" cont list "$POOL" --json 2>/dev/null | jq -r '.response[].uuid' | sort >"$work/all.uuids"
sh_uuids() { jq -r 'select(.summary | not) | .cont_uuid' "$work/out-sh$1/$POOL/latest-shard$1of2.jsonl" 2>/dev/null | sort; }
sh_uuids 0 >"$work/sh0.uuids"
sh_uuids 1 >"$work/sh1.uuids"
echo "shards: pool $(wc -l <"$work/all.uuids") containers, shard 0/2 $(wc -l <"$work/sh0.uuids"), shard 1/2 $(wc -l <"$work/sh1.uuids")" >&2
check "shards: the pool has the 6 dscan-sh containers and more" yes \
	"$([ "$(wc -l <"$work/all.uuids")" -ge 6 ] && echo yes || echo no)"
check "shards: union of 0/2 and 1/2 equals daos cont list" yes \
	"$(cmp -s <(sort -u "$work/sh0.uuids" "$work/sh1.uuids") "$work/all.uuids" && echo yes || echo no)"
check "shards: 0/2 and 1/2 have no container in common" 0 \
	"$(comm -12 "$work/sh0.uuids" "$work/sh1.uuids" | wc -l | tr -d ' ')"
check "shards: both shards got containers" yes \
	"$([ -s "$work/sh0.uuids" ] && [ -s "$work/sh1.uuids" ] && echo yes || echo no)"
# the outputs of a shard pass
for k in 0 1; do
	o=$work/out-sh$k
	f=$(cd "$o/$POOL" 2>/dev/null && ls scan-*-shard${k}of2.jsonl 2>/dev/null)
	check "shard $k/2: one scan file scan-<ts>-shard${k}of2.jsonl, latest link to it, .lock-shard${k}of2" "1 yes yes" \
		"$(echo "$f" | grep -cE "^scan-[0-9]{8}T[0-9]{6}Z-shard${k}of2\.jsonl$") $([ -n "$f" ] && [ "$(readlink "$o/$POOL/latest-shard${k}of2.jsonl")" = "$f" ] && echo yes || echo no) $([ -e "$o/.lock-shard${k}of2" ] && echo yes || echo no)"
done
check "shards: .prom logical_bytes of dscan-a (in whichever shard has it)" "$gen_bytes" \
	"$(cat "$work/out-sh0/dscan-shard0of2.prom" "$work/out-sh1/dscan-shard1of2.prom" 2>/dev/null |
		sed -n 's/^dscan_container_logical_bytes{.*cont_label="dscan-a".*} \([0-9]*\)$/\1/p')"

# An ad-hoc run (--cont) in the shard's --out-dir leaves the shard's outputs alone.
o=$work/out-sh0
latest_sh0=$(readlink "$o/$POOL/latest-shard0of2.jsonl")
cp "$o/dscan-shard0of2.prom" "$work/sh0.prom.saved" 2>/dev/null
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --cont dscan-empty --out-dir "$o" $DSCAN_ARGS >/dev/null 2>"$work/dscan-adhoc.err"
rc=$?
cat "$work/dscan-adhoc.err" >&2
check "ad hoc beside a shard: exit 0, dscan-empty ok in scan-<ts>-cont.jsonl" "0 ok" \
	"$rc $(jq -r 'select(.cont_label == "dscan-empty") | .status' "$(adhoc_file "$o")" 2>/dev/null || echo none)"
check "ad hoc beside a shard: latest-shard0of2.jsonl unchanged" "$latest_sh0" "$(readlink "$o/$POOL/latest-shard0of2.jsonl")"
check "ad hoc beside a shard: dscan-shard0of2.prom unchanged, no other .prom" "yes 1" \
	"$(cmp -s "$o/dscan-shard0of2.prom" "$work/sh0.prom.saved" && echo yes || echo no) $(ls "$o" | grep -c '\.prom$')"

# A result that cannot be written (here the textfile: its temporary name is a directory) keeps the
# previous textfile and latest link and exits 1. A textfile of another sharding draws a warning.
mkdir "$o/dscan-shard0of2.prom.tmp"
: >"$o/dscan-shard3of4.prom"
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --shard 0/2 --out-dir "$o" $DSCAN_ARGS >/dev/null 2>"$work/dscan-werr.err"
rc=$?
cat "$work/dscan-werr.err" >&2
check "write error: exit 1, says the textfile was not written" "1 1" \
	"$rc $(grep -c 'cannot write .*dscan-shard0of2.prom' "$work/dscan-werr.err")"
check "write error: latest-shard0of2.jsonl still points at the previous pass, a new scan file exists" "$latest_sh0 2" \
	"$(readlink "$o/$POOL/latest-shard0of2.jsonl") $(ls "$o/$POOL" | grep -c '^scan-.*-shard0of2\.jsonl$')"
check "write error: dscan-shard0of2.prom unchanged" yes \
	"$(cmp -s "$o/dscan-shard0of2.prom" "$work/sh0.prom.saved" && echo yes || echo no)"
check "foreign sharding: warning names dscan-shard3of4.prom" 1 "$(grep -c 'warning: .*dscan-shard3of4.prom' "$work/dscan-werr.err")"
rmdir "$o/dscan-shard0of2.prom.tmp"
rm -f "$o/dscan-shard3of4.prom"

# wait_exit <pid> <seconds>: $rc = the exit code of a background job, or "timeout" (the job is then
# killed). Not in $(...): a subshell cannot wait for the parent's job.
wait_exit() {
	local i
	for ((i = 0; i < $2 * 10; i++)); do
		kill -0 "$1" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$1" 2>/dev/null; then
		kill -9 "$1" 2>/dev/null
		wait "$1" 2>/dev/null
		rc=timeout
		return
	fi
	wait "$1"
	rc=$?
}

# ---- run locks: .lock-shard<k>of<N> for a shard pass, .lock-cont-<pool> for ad-hoc runs ----
# A second pass on the same shard and --out-dir exits 4, so does a second ad-hoc run; an ad-hoc run
# and a shard pass do not block each other.
out_l=$work/out-lock
# wait_file <glob> <pid>: until a file matching <glob> exists (at most 30 s) or <pid> ends
wait_file() {
	for _ in $(seq 300); do
		compgen -G "$1" >/dev/null && return 0
		kill -0 "$2" 2>/dev/null || return 1
		sleep 0.1
	done
	return 1
}
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --rate 200 --out-dir "$out_l" $DSCAN_ARGS >"$work/dscan-l1.out" 2>"$work/dscan-l1.err" &
pid=$!
wait_file "$out_l/$POOL/scan-*-shard0of1.jsonl" "$pid"
check "lock: first shard pass runs" yes "$(kill -0 "$pid" 2>/dev/null && echo yes || echo no)"
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --out-dir "$out_l" $DSCAN_ARGS >/dev/null 2>"$work/dscan-l2.err"
rc=$?
cat "$work/dscan-l2.err" >&2
check "lock: second pass on the same shard exits 4" 4 "$rc"
check "lock: second pass says why on stderr (.lock-shard0of1)" 1 "$(grep -c 'lock-shard0of1' "$work/dscan-l2.err")"
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --cont dscan-a --rate 200 --out-dir "$out_l" $DSCAN_ARGS >"$work/dscan-l3.out" 2>"$work/dscan-l3.err" &
pid_a=$!
wait_file "$out_l/$POOL/scan-*-cont.jsonl" "$pid_a"
check "lock: an ad-hoc run starts while the shard pass runs" yes "$(kill -0 "$pid_a" 2>/dev/null && echo yes || echo no)"
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --cont dscan-empty --out-dir "$out_l" $DSCAN_ARGS >/dev/null 2>"$work/dscan-l4.err"
rc=$?
cat "$work/dscan-l4.err" >&2
check "lock: a second ad-hoc run exits 4 (.lock-cont-<pool>)" "4 1" "$rc $(grep -c "lock-cont-$POOL" "$work/dscan-l4.err")"
check "lock: first shard pass still runs" yes "$(kill -0 "$pid" 2>/dev/null && echo yes || echo no)"
kill -TERM "$pid" "$pid_a" 2>/dev/null
wait_exit "$pid" 60
rc_l1=$rc
wait_exit "$pid_a" 60
cat "$work/dscan-l1.err" "$work/dscan-l3.err" >&2
check "lock: both passes stopped by SIGTERM exit 3" "3 3" "$rc_l1 $rc"
check "SIGTERM (W): no summary line, no dscan-a line in the shard's scan file" "0 0" \
	"$(jq -c 'select(.summary)' "$out_l/$POOL"/scan-*-shard0of1.jsonl 2>/dev/null | wc -l | tr -d ' ') $(jq -c 'select(.cont_label == "dscan-a")' "$out_l/$POOL"/scan-*-shard0of1.jsonl 2>/dev/null | wc -l | tr -d ' ')"
check "SIGTERM (W): no textfile written, latest link not created" "no no" \
	"$([ -e "$out_l/dscan-shard0of1.prom" ] && echo yes || echo no) $([ -e "$out_l/$POOL/latest-shard0of1.jsonl" ] && echo yes || echo no)"
check "SIGTERM (W, ad hoc): no summary line, no dscan-a line" "0 0" \
	"$(jq -c 'select(.summary)' "$(adhoc_file "$out_l")" 2>/dev/null | wc -l | tr -d ' ') $(jq -c 'select(.cont_label == "dscan-a")' "$(adhoc_file "$out_l")" 2>/dev/null | wc -l | tr -d ' ')"
cat "$work/dscan-l1.out" "$work/dscan-l3.out" >&2
check "SIGTERM (W, both runs): stdout ends with 'dscan: Interrupted (runtime: S sec)', no Done! summary" "1 1 0 0" \
	"$(tail -1 "$work/dscan-l1.out" | grep -cE '^dscan: Interrupted \(runtime: [0-9]+ sec\)$') $(tail -1 "$work/dscan-l3.out" | grep -cE '^dscan: Interrupted \(runtime: [0-9]+ sec\)$') $(grep -c '^dscan: Done! ' "$work/dscan-l1.out") $(grep -c '^dscan: Done! ' "$work/dscan-l3.out")"

# ---- mode O interrupted: kill -9 leaves the snapshot for the next pass, SIGTERM cleans up ----
# A client snapshot on dscan-a must survive all of this. dscan's own snapshot is recognised by its
# container attribute dscan-snapshot-<ts>-<pid> (DAOS 2.8 has no snapshot names).
"$DAOS_BIN/daos" cont create-snap "$POOL" dscan-a >/dev/null 2>&1
snaps_pre=$(snaps dscan-a)
check "dscan-a: one client snapshot before the interrupt checks" 1 "$(grep -cE '^[0-9]+$' <<<"$snaps_pre")"
# values of the dscan-snapshot-* attributes of container $1, one per line ("epoch=<E|pending>
# host=... pid=..."); list-attrs prints them base64-encoded
dscan_attr_values() {
	"$DAOS_BIN/daos" cont list-attrs "$POOL" "$1" --verbose --json 2>/dev/null |
		jq -r '(.response // {}) | if type == "object" then to_entries[] else empty end |
			select(.key | startswith("dscan-snapshot-")) | .value | @base64d' 2>/dev/null
}
# number of dscan-snapshot-* attributes whose value holds an epoch (not "pending")
dscan_epoch_attrs() { dscan_attr_values "$1" | grep -cE '^epoch=[0-9]+ '; }
# start_o <out-dir> [rate]: a slow mode-O pass on dscan-a in the background (pid in $pid, rate
# default 200 ops/s); waits (at most 30 s) until its snapshot exists and is recorded: a
# dscan-snapshot-* attribute holding an epoch and one snapshot more than before
start_o() {
	# shellcheck disable=SC2086
	"$DSCAN" --pool "$POOL" --mode oit --cont dscan-a --rate "${2:-200}" --out-dir "$1" $DSCAN_ARGS >/dev/null 2>"$1.err" &
	pid=$!
	for _ in $(seq 60); do
		[ "$(dscan_epoch_attrs dscan-a)" -ge 1 ] && [ "$(snaps dscan-a | wc -w)" -gt "$(wc -w <<<"$snaps_pre")" ] && return 0
		kill -0 "$pid" 2>/dev/null || return 1
		sleep 0.5
	done
	return 1
}
start_o "$work/out-k9"
check "kill -9 (O): the pass created its snapshot (attribute + snapshot)" 0 $?
kill -9 "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
check "kill -9 (O): its snapshot and attribute are left behind" "1 yes" \
	"$(dscan_attrs dscan-a) $([ "$(snaps dscan-a | wc -w)" -gt "$(wc -w <<<"$snaps_pre")" ] && echo yes || echo no)"
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --mode oit --cont dscan-a --out-dir "$work/out-k9b" $DSCAN_ARGS >/dev/null 2>"$work/dscan-k9b.err"
rc=$?
cat "$work/dscan-k9b.err" >&2
check "kill -9 (O): next pass exits 0" 0 "$rc"
check "kill -9 (O): next pass removed the leftover, client snapshot kept" "$snaps_pre 0" \
	"$(snaps dscan-a) $(dscan_attrs dscan-a)"

start_o "$work/out-term"
check "SIGTERM (O): the pass created its snapshot (attribute + snapshot)" 0 $?
kill -TERM "$pid" 2>/dev/null
wait_exit "$pid" 60
cat "$work/out-term.err" >&2
check "SIGTERM (O): exit 3" 3 "$rc"
check "SIGTERM (O): no dscan snapshot or attribute left, client snapshot kept" "$snaps_pre 0" \
	"$(snaps dscan-a) $(dscan_attrs dscan-a)"
check "SIGTERM (O): no summary line, no dscan-a line" "0 0" \
	"$(jq -c 'select(.summary)' "$work/out-term/$POOL"/scan-*.jsonl 2>/dev/null | wc -l | tr -d ' ') $(jq -c 'select(.cont_label == "dscan-a")' "$work/out-term/$POOL"/scan-*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
check "SIGTERM (O): no textfile written" no "$([ -e "$work/out-term/dscan-shard0of1.prom" ] && echo yes || echo no)"

# ---- overlapping mode-O passes on one container (as from two hosts, or a manual run) ----
# The attribute of the running pass names its owner (host, pid, start time): the second pass sees
# a live owner on this host and leaves that snapshot alone, so both count dscan-a fully.
ov_line() {
	jq -r 'select(.cont_label == "dscan-a") | "\(.status) \(.files) \(.dirs) \(.logical_bytes)"' \
		"$(adhoc_file "$1")" 2>/dev/null || echo none
}
ov_want="ok $((gen_files - empty_a)) $gen_dirs $gen_bytes"
start_o "$work/out-ov1" 1000
check "overlap (O): the first pass created its snapshot (attribute + snapshot)" 0 $?
pid_ov=$pid
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --mode oit --cont dscan-a --out-dir "$work/out-ov2" $DSCAN_ARGS >/dev/null 2>"$work/out-ov2.err"
rc_ov2=$?
cat "$work/out-ov2.err" >&2
echo "overlap (O): first pass still running when the second ended: $(kill -0 "$pid_ov" 2>/dev/null && echo yes || echo no)" >&2
wait_exit "$pid_ov" 300
cat "$work/out-ov1.err" >&2
check "overlap (O): the second pass left the running pass's snapshot alone (stderr note)" 1 \
	"$(grep -c 'another mode-O pass appears to be running on dscan-a' "$work/out-ov2.err")"
check "overlap (O): second pass exit 0, dscan-a ok with full counts" "0 $ov_want" "$rc_ov2 $(ov_line "$work/out-ov2")"
check "overlap (O): first pass exit 0, dscan-a ok with full counts" "0 $ov_want" "$rc $(ov_line "$work/out-ov1")"
check "overlap (O): no dscan snapshot or attribute left, client snapshot kept" "$snaps_pre 0" \
	"$(snaps dscan-a) $(dscan_attrs dscan-a)"

# ---- a pass that loses its snapshot while it runs is partial (snapshot_lost) ----
# Another pass that took it for a leftover would punch its OIT and destroy it; the listing then just
# ends. Simulated here by destroying the pass's snapshot from outside while it lists.
start_o "$work/out-lost" 1000
check "snapshot lost (O): the pass created its snapshot (attribute + snapshot)" 0 $?
lost_epoch=$(dscan_attr_values dscan-a | sed -n 's/^epoch=\([0-9]*\) .*/\1/p' | head -1)
"$DAOS_BIN/daos" cont destroy-snap "$POOL" dscan-a --epc "${lost_epoch:-0}" >/dev/null 2>&1
rc_ds=$?
check "snapshot lost (O): its snapshot destroyed from outside while the pass runs" "0 yes" \
	"$rc_ds $(kill -0 "$pid" 2>/dev/null && echo yes || echo no)"
wait_exit "$pid" 300
cat "$work/out-lost.err" >&2
check "snapshot lost (O): exit 1, dscan-a partial, reason snapshot_lost" "1 partial snapshot_lost" \
	"$rc $(jq -r 'select(.cont_label == "dscan-a") | "\(.status) \(.reason)"' "$(adhoc_file "$work/out-lost")" 2>/dev/null || echo none)"
check "snapshot lost (O): stderr says so" 1 "$(grep -c 'was lost while it ran' "$work/out-lost.err")"
check "snapshot lost (O): no dscan snapshot or attribute left, client snapshot kept" "$snaps_pre 0" \
	"$(snaps dscan-a) $(dscan_attrs dscan-a)"

# ---- empty shard: --cont that matches nothing ----
out_e=$work/out-none
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --cont no-such-label --out-dir "$out_e" $DSCAN_ARGS >/dev/null 2>"$work/dscan-none.err"
rc=$?
cat "$work/dscan-none.err" >&2
check "no match: exit 0" 0 "$rc"
check "no match: warning on stderr" 1 "$(grep -c 'no-such-label' "$work/dscan-none.err")"
check "no match: JSONL is one summary line with containers 0" "1 true 0" \
	"$(wc -l <"$(adhoc_file "$out_e")" 2>/dev/null | tr -d ' ') $(jq -r '"\(.summary) \(.containers)"' "$(adhoc_file "$out_e")" 2>/dev/null)"
# (an empty shard's textfile with dscan_run_success 1: tests/unit/test_report.c)
check "no match: ad hoc, no textfile" 0 "$(ls "$out_e" 2>/dev/null | grep -c '\.prom$')"

# ---- no access: a container without an ACL entry for root is failed/no_permission, the run goes on ----
# A container created by $CONT_OWNER has only OWNER@ and GROUP@ in its ACL (the lab's CONT_ACL_EXTRA
# applies to "posix" only); root has pool rw, so it lists the container but cannot open it.
sudo -u "$CONT_OWNER" "$DAOS_BIN/daos" cont create "$POOL" dscan-noacl --type POSIX >"$work/noacl.out" 2>&1
check "dscan-noacl created by $CONT_OWNER" yes "$(yes_no sudo -u "$CONT_OWNER" "$DAOS_BIN/daos" cont get-prop "$POOL" dscan-noacl)"
check "dscan-noacl: root has no access (cont get-prop fails)" no "$(yes_no "$DAOS_BIN/daos" cont get-prop "$POOL" dscan-noacl)"
out_n=$work/out-noacl
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --cont dscan-noacl --cont dscan-empty --out-dir "$out_n" $DSCAN_ARGS >"$work/dscan-n.out" 2>"$work/dscan-n.err"
rc=$?
cat "$work/dscan-n.out" "$work/dscan-n.err" >&2
latest_n=$(adhoc_file "$out_n")
line_nn=$(jq -c 'select(.cont_label == "dscan-noacl")' "$latest_n" 2>/dev/null)
line_ne=$(jq -c 'select(.cont_label == "dscan-empty")' "$latest_n" 2>/dev/null)
echo "dscan-noacl: $line_nn" >&2
echo "dscan-empty (after noacl): $line_ne" >&2
check "no access: exit code 1" 1 "$rc"
check "no access: dscan-noacl status failed, reason no_permission" "failed no_permission" \
	"$([ -n "$line_nn" ] && jq -r '"\(.status) \(.reason)"' <<<"$line_nn" || echo none)"
check "no access: dscan-empty is still scanned (status ok, dirs 1)" "ok 1" \
	"$([ -n "$line_ne" ] && jq -r '"\(.status) \(.dirs)"' <<<"$line_ne" || echo none)"
check "no access: summary has 2 containers, 1 ok, 1 failed" "2 1 1" \
	"$(jq -r 'select(.summary) | "\(.containers) \(.ok) \(.failed)"' "$latest_n" 2>/dev/null)"
check "no access: stderr names dscan-noacl" 1 "$(grep -c 'dscan-noacl' "$work/dscan-n.err")"
# The textfile of a failed container (a shard pass over the whole pool): status, errors and last scan
# time only, no zero-valued byte or count series. Plus the README's coverage check: one
# dscan_container_status series per container of "daos cont list".
out_p=$work/out-pool
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --out-dir "$out_p" $DSCAN_ARGS >/dev/null 2>"$work/dscan-pool.err"
rc=$?
cat "$work/dscan-pool.err" >&2
prom_p=$out_p/dscan-shard0of1.prom
check "pool pass: exit 1 (dscan-noacl failed)" 1 "$rc"
pst() { sed -n "s/^dscan_container_status{.*cont_label=\"$1\".*} \([0-9]*\)$/\1/p" "$prom_p" 2>/dev/null; }
check "pool pass: .prom dscan_container_status of dscan-noacl 2, of dscan-empty 0" "2 0" "$(pst dscan-noacl) $(pst dscan-empty)"
check "pool pass: dscan-noacl has only status, errors and last_scan series" "3 0" \
	"$(grep -c '^dscan_container_.*cont_label="dscan-noacl"' "$prom_p" 2>/dev/null) $(grep -cE '^dscan_container_(logical_bytes|physical_estimated_bytes|files|dirs|symlinks|scan_duration_seconds)\{.*cont_label="dscan-noacl"' "$prom_p" 2>/dev/null)"
check "pool pass: one dscan_container_status series per container of daos cont list" \
	"$("$DAOS_BIN/daos" cont list "$POOL" --json 2>/dev/null | jq -r '.response | length')" \
	"$(grep -c '^dscan_container_status{' "$prom_p" 2>/dev/null)"
check "pool pass: dscan_run_vanished_containers 0" 1 "$(grep -cE '^dscan_run_vanished_containers\{.*\} 0$' "$prom_p" 2>/dev/null)"

# ---- minimal container ACE of a non-owner principal (the README's ACL section) ----
# dscan-acl is created and filled by $CONT_OWNER; root is neither its owner nor in its ACL, so each
# entry for root below is what a scanner user would get. Documented minimum: walk = "rt", oit =
# "rwt" (daos_cont_query for the layout type needs "t"; snapshots and the attribute need "w").
# Without them the container is failed/no_permission. Pool access of root is the lab's pool "rw".
acl_gen=$(sudo -u "$CONT_OWNER" "$GEN" --pool "$POOL" --cont dscan-acl --seed 3 --dirs 5 --files 200 \
	--max-size 100000 --symlinks 2 2>>"$work/gen-acl.err")
echo "dscan-acl generator: $acl_gen" >&2
cat "$work/gen-acl.err" >&2
acl_files=$(jq -r .files <<<"$acl_gen" 2>/dev/null || echo none)
acl_bytes=$(jq -r .logical_bytes <<<"$acl_gen" 2>/dev/null || echo none)
acl_obytes=$(jq -r .oit_logical_bytes <<<"$acl_gen" 2>/dev/null || echo none)
# every 50th file is never written, so the OIT does not list it
acl_ofiles=$(jq -r '.files - ((.files + 49) / 50 | floor)' <<<"$acl_gen" 2>/dev/null || echo none)
check "dscan-acl created by $CONT_OWNER, root not in its ACL (cont get-prop fails)" "yes no" \
	"$(yes_no sudo -u "$CONT_OWNER" "$DAOS_BIN/daos" cont get-prop "$POOL" dscan-acl) $(yes_no "$DAOS_BIN/daos" cont get-prop "$POOL" dscan-acl)"
# acl_try <ace> <mode> <name>: run dscan on dscan-acl with root's entry set to <ace>; sets $acl_rc and
# $acl_line (the container's JSON line)
acl_try() {
	local ace=$1 mode=$2 o=$work/out-acl-$3
	sudo -u "$CONT_OWNER" "$DAOS_BIN/daos" cont update-acl "$POOL" dscan-acl --entry "$ace" >/dev/null 2>&1
	# shellcheck disable=SC2086
	"$DSCAN" --pool "$POOL" --cont dscan-acl --mode "$mode" --out-dir "$o" $DSCAN_ARGS \
		>"$work/dscan-acl-$3.out" 2>"$work/dscan-acl-$3.err"
	acl_rc=$?
	cat "$work/dscan-acl-$3.err" >&2
	acl_line=$(jq -c 'select(.cont_label == "dscan-acl")' "$(adhoc_file "$o")" 2>/dev/null)
	echo "dscan-acl $mode with $ace: exit $acl_rc $acl_line" >&2
}
acl_st() { [ -n "$acl_line" ] && jq -r '"\(.status) \(.reason)"' <<<"$acl_line" || echo none; }
acl_try "A::root@:rt" walk w-rt
check "ACL walk with \"rt\": exit 0, status ok" "0 ok null" "$acl_rc $(acl_st)"
check "ACL walk with \"rt\": files, symlinks, logical_bytes equal generator" "$acl_files 2 $acl_bytes" \
	"$([ -n "$acl_line" ] && jq -r '"\(.files) \(.symlinks) \(.logical_bytes)"' <<<"$acl_line" || echo none)"
acl_try "A::root@:r" walk w-r
check "ACL walk with \"r\" only: failed, no_permission, exit 1" "1 failed no_permission" "$acl_rc $(acl_st)"
acl_try "A::root@:rwt" oit o-rwt
check "ACL oit with \"rwt\": exit 0, status ok" "0 ok null" "$acl_rc $(acl_st)"
check "ACL oit with \"rwt\": files (minus never-written), logical_bytes equal generator" "$acl_ofiles $acl_obytes" \
	"$([ -n "$acl_line" ] && jq -r '"\(.files) \(.logical_bytes)"' <<<"$acl_line" || echo none)"
acl_try "A::root@:rt" oit o-rt
check "ACL oit with \"rt\" (no w): failed, no_permission, exit 1" "1 failed no_permission" "$acl_rc $(acl_st)"
acl_try "A::root@:rw" oit o-rw
check "ACL oit with \"rw\" (no t): failed, no_permission, exit 1" "1 failed no_permission" "$acl_rc $(acl_st)"
check "ACL: no dscan-snapshot-* attribute left on dscan-acl" 0 \
	"$(sudo -u "$CONT_OWNER" "$DAOS_BIN/daos" cont list-attr "$POOL" dscan-acl 2>/dev/null | grep -c '^ *dscan-snapshot-')"

# ---- files deleted during the walk: counted as vanished, the container stays ok ----
# One directory of 5000 empty files. As soon as the scan has started (its scan file exists), dfuse
# deletes the directory. rm and the scan walk the names in the same (dkey) order; rm through dfuse
# deletes about 170 files a second, and the scan is rate-limited to 200 operations a second, i.e.
# about 100 files (an entry fetch and a size query each), so rm stays ahead and by the time the scan
# fetches a listed entry it is gone (-DER_NONEXIST) or its directory is. (At --rate 500 a scan with
# --inflight 1, which fetches strictly in listing order, overtook rm and saw nothing vanish.) A race
# by nature: if "vanished" stays 0, lower --rate (not the scanner).
gen_v="--pool $POOL --cont dscan-v --seed 3 --dirs 1 --files 5000 --max-size 0"
# shellcheck disable=SC2086
"$GEN" $gen_v >"$work/gen-v.json" 2>"$work/gen-v.err"
cat "$work/gen-v.err" >&2
echo "dscan-v generator: $(cat "$work/gen-v.json")" >&2
check "dscan-gen creates dscan-v (one JSON line)" 1 "$(jq -c . "$work/gen-v.json" 2>/dev/null | wc -l | tr -d ' ')"
fusermount3 -u "$MNT" 2>/dev/null
"$DAOS_BIN/dfuse" "$MNT" "$POOL" dscan-v >"$work/dfuse-v.out" 2>&1
check "dfuse mounts dscan-v" yes "$(yes_no findmnt -n -t fuse.daos "$MNT")"
check "dscan-v: d0000 holds the generated files" "$(jq -r .files "$work/gen-v.json" 2>/dev/null || echo none)" \
	"$(find "$MNT/d0000" -type f 2>/dev/null | wc -l | tr -d ' ')"
out_v=$work/out-v
# shellcheck disable=SC2086
"$DSCAN" --pool "$POOL" --cont dscan-v --rate 200 --out-dir "$out_v" $DSCAN_ARGS >"$work/dscan-v.out" 2>"$work/dscan-v.err" &
pid=$!
for _ in $(seq 300); do   # the scan file is created once the pass runs (at most 30 s)
	ls "$out_v/$POOL"/scan-*.jsonl >/dev/null 2>&1 && break
	kill -0 "$pid" 2>/dev/null || break
	sleep 0.1
done
t0=$(date +%s.%N)
rm -rf "$MNT/d0000"
rc_rm=$?
t1=$(date +%s.%N)
wait_exit "$pid" 300
t2=$(date +%s.%N)
cat "$work/dscan-v.out" "$work/dscan-v.err" >&2
echo "dscan-v: rm -rf took $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }') s, the scan ended $(awk -v a="$t0" -v b="$t2" 'BEGIN { printf "%.2f", b - a }') s after the rm started" >&2
line_v=$(jq -c 'select(.cont_label == "dscan-v")' "$(adhoc_file "$out_v")" 2>/dev/null)
echo "dscan-v: $line_v" >&2
jqv() { [ -n "$line_v" ] && jq -r ".$1" <<<"$line_v" 2>/dev/null || echo none; }
check "vanished: rm -rf of d0000 succeeded and it is gone" "0 no" "$rc_rm $([ -e "$MNT/d0000" ] && echo yes || echo no)"
check "vanished: exit code 0" 0 "$rc"
check "vanished: dscan-v status ok" ok "$(jqv status)"
check "vanished: dscan-v vanished > 0" yes "$([ "$(jqv vanished)" -gt 0 ] 2>/dev/null && echo yes || echo no)"
check "vanished: dscan-v errors 0" 0 "$(jqv errors)"
fusermount3 -u "$MNT" 2>/dev/null

# ---- a container destroyed after the container list was read: not reported, not failed ----
# One thread opens one container at a time. A slow mode-O pass over a fresh "blocker" container and
# a fresh empty one: once the blocker got the pass's snapshot attribute (it is being scanned) and the
# other has no line yet (it is still queued), the other is destroyed. Which one comes first depends
# on the order of the pool's container list (on the lab's 2.8 pool the newest container came first
# every time), so the tries alternate which of the two is created last, each with fresh containers.
gone_done=no
for i in 1 2 3 4; do
	g=dscan-gone$i
	b=dscan-blk$i
	o=$work/out-gone$i
	mk_gone() { "$DAOS_BIN/daos" cont create "$POOL" "$g" --type POSIX >/dev/null 2>&1; }
	# about 2 000 written files: a mode-O pass at 200 ops/s takes about 10 s
	mk_blk() { "$GEN" --pool "$POOL" --cont "$b" --seed 4 --dirs 2 --files 2000 --max-size 1000 --threads 4 >/dev/null 2>>"$o.gen.err"; }
	if [ $((i % 2)) = 1 ]; then mk_gone; mk_blk; else mk_blk; mk_gone; fi
	# shellcheck disable=SC2086
	"$DSCAN" --pool "$POOL" --mode oit --cont "$b" --cont "$g" --rate 200 --out-dir "$o" $DSCAN_ARGS --threads 1 \
		>/dev/null 2>"$o.err" &
	pid=$!
	queued=no
	for _ in $(seq 150); do   # at most 30 s
		if [ "$(dscan_attrs "$b")" = 1 ]; then
			[ "$(jq -c "select(.cont_label == \"$g\")" "$(adhoc_file "$o")" 2>/dev/null | wc -l)" -eq 0 ] && queued=yes
			break
		fi
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.2
	done
	if [ "$queued" = yes ]; then
		"$DAOS_BIN/daos" cont destroy "$POOL" "$g" --force >/dev/null 2>&1
		rc_d=$?
		wait_exit "$pid" 300
		cat "$o.err" >&2
		echo "vanished container (try $i): $(cat "$(adhoc_file "$o")" 2>/dev/null)" >&2
		check "vanished container: $g destroyed while queued" 0 "$rc_d"
		check "vanished container: exit 0, $b ok, no line for $g" "0 ok 0" \
			"$rc $(jq -r "select(.cont_label == \"$b\") | .status" "$(adhoc_file "$o")" 2>/dev/null || echo none) $(jq -c "select(.cont_label == \"$g\")" "$(adhoc_file "$o")" 2>/dev/null | wc -l | tr -d ' ')"
		check "vanished container: summary containers 1, failed 0, vanished_containers 1" "1 0 1" \
			"$(jq -r 'select(.summary) | "\(.containers) \(.failed) \(.vanished_containers)"' "$(adhoc_file "$o")" 2>/dev/null)"
		check "vanished container: stderr names $g" yes "$(grep -q "container $g .*destroyed after the container list was read" "$o.err" && echo yes || echo no)"
		gone_done=yes
		"$DAOS_BIN/daos" cont destroy "$POOL" "$b" --force >/dev/null 2>&1
		break
	fi
	wait_exit "$pid" 300   # $g was scanned first: try again
	echo "vanished container (try $i): $g came first, retrying" >&2
	"$DAOS_BIN/daos" cont destroy "$POOL" "$g" --force >/dev/null 2>&1
	"$DAOS_BIN/daos" cont destroy "$POOL" "$b" --force >/dev/null 2>&1
done
check "vanished container: a try with the blocker opened first" yes "$gone_done"

report "dscan on $(hostname -s)"
