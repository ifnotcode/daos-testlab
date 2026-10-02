# Result table for test suites: check "<description>" <expected> <actual>; report at the end.
# shellcheck shell=bash

TEST_RESULTS=()

# check <description> <expected> <actual>
check() {
	if [ "$2" = "$3" ]; then
		TEST_RESULTS+=("$(printf 'PASS  %-10s %s' "$2" "$1")")
	else
		TEST_RESULTS+=("$(printf 'FAIL  %-10s %s (got %s)' "$2" "$1" "$3")")
	fi
}

# yes_no <command...>: "yes" if the command succeeds
yes_no() { "$@" >/dev/null 2>&1 && echo yes || echo no; }

# report [title]: prints the table; returns 1 if a check failed
report() {
	echo
	[ -n "${1:-}" ] && echo "$1"
	printf 'RESULT EXPECT     CHECK\n'
	printf '%s\n' "${TEST_RESULTS[@]}"
	! printf '%s\n' "${TEST_RESULTS[@]}" | grep -q '^FAIL'
}

# DAOS install to test: DAOS_PREFIX=/usr (RPMs, default) or e.g. /opt/daos (lab deploy tree)
daos_paths() {
	DAOS_PREFIX=${DAOS_PREFIX:-/usr}
	DAOS_BIN=$DAOS_PREFIX/bin
	DAOS_LIB=$DAOS_PREFIX/lib64
	[ -x "$DAOS_BIN/dfuse" ] || { echo "no dfuse in $DAOS_BIN (set DAOS_PREFIX)" >&2; exit 2; }
}

# tool <name>: path of a tool from tools/<name>.c, compiled on first use
tool() {
	local bin=/usr/local/bin/$1 src
	src=$(cd "$(dirname "${BASH_SOURCE[0]}")/../tools" && pwd)/$1.c
	if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
		gcc -O2 -Wall -o "$bin" "$src" >&2 || { echo "cannot build $1" >&2; exit 2; }
	fi
	echo "$bin"
}

# idmap_bind: path of the idmap-bind tool (tools/idmap-bind.c)
idmap_bind() { tool idmap-bind; }

# kernel_ge <version>: the running kernel is at least <version>
kernel_ge() { [ "$(printf '%s\n%s\n' "$1" "$(uname -r | cut -d- -f1)" | sort -V | head -1)" = "$1" ]; }
