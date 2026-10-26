#!/usr/bin/env bash
# container evict: without --all it closes only the caller's handles; --all needs the owner
# needs: server
# Run by "lab test evict-per-user <client vm> [DAOS_PREFIX=/opt/daos] [IO_TIMEOUT=20]" as root.
# Checks the assumption of the Storage API access model: writers and readers of a volume use two
# DAOS users (RW_U, RO_U, default csi_rw and csi_ro), and "daos container evict" run as RW_U
# disconnects the writers only. A test container gets the ACL OWNER@ all, RW_U rwt, RO_U rt and
# is mounted by two dfuse instances, one per user. Then evict is run as different users, and the
# suite checks which mounts keep working and how many handles the container has.
# The users are created without a password (locked, nologin) and get pool access through the
# pool's GROUP@ entry (group $CONT_OWNER); users created here are removed at the end.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
daos_paths
DFUSE=$DAOS_BIN/dfuse
DAOS=$DAOS_BIN/daos
OWNER=$CONT_OWNER
RW_U=${RW_U:-csi_rw}
RO_U=${RO_U:-csi_ro}
T=${IO_TIMEOUT:-20}
C=evict-test-$$
WORK=$(mktemp -d)
chmod 777 "$WORK" # dfuse of each user writes its log here
MNT_O=$WORK/owner
MNT_RW=$WORK/rw
MNT_RO=$WORK/ro
CREATED=""

as() { local u=$1; shift; sudo -u "$u" -- "$@"; }
mounted() { findmnt -n -t fuse.daos "$1" >/dev/null; }
# handles of the container besides the one of the query itself
others() {
	local n
	n=$(as "$OWNER" "$DAOS" cont query "$POOL" "$C" --json 2>/dev/null |
		grep -o '"num_handles": *[0-9]*' | grep -o '[0-9]*$')
	[ -n "$n" ] && echo $((n - 1)) || echo error
}
# io <user> <command...>: ok, error or timeout; the first error line is kept in $WORK/io.err
io() {
	local u=$1 rc
	shift
	timeout -k 5 "$T" sudo -u "$u" -- "$@" >/dev/null 2>"$WORK/io.err"
	rc=$?
	case $rc in 0) echo ok ;; 124 | 137) echo timeout ;; *) echo error ;; esac
}
why() { head -1 "$WORK/io.err" | cut -c1-80; }
evict() { # evict <user> [--all]: ok or failed
	local u=$1
	shift
	as "$u" "$DAOS" container evict "$@" "$POOL" "$C" >"$WORK/evict.out" 2>&1 && echo ok || echo failed
}
dfuse_of() { # dfuse_of <user> <mountpoint> [dfuse options]: daemon mode, returns once mounted
	local u=$1 m=$2
	shift 2
	mkdir -p "$m" && chown "$u" "$m"
	as "$u" env D_LOG_FILE="$WORK/dfuse-$u.log" "$DFUSE" "$@" "$m" "$POOL" "$C" >/dev/null 2>&1
}
cleanup() {
	local m u
	for m in "$MNT_O" "$MNT_RW" "$MNT_RO"; do umount -l "$m" 2>/dev/null; done
	pkill -f -- "$WORK/" 2>/dev/null # only the dfuse instances of this suite
	sleep 1
	as "$OWNER" "$DAOS" cont destroy "$POOL" "$C" --force >/dev/null 2>&1
	for u in $CREATED; do userdel "$u" 2>/dev/null; done
	rm -rf "$WORK"
}
trap cleanup EXIT

# --- users: no password, no shell, member of the pool's owner group ---------------------------
getent group "$OWNER" >/dev/null || { echo "no group $OWNER"; exit 2; }
for u in "$RW_U" "$RO_U"; do
	if ! id "$u" >/dev/null 2>&1; then
		useradd -r -M -s /sbin/nologin -G "$OWNER" "$u" && CREATED="$CREATED $u"
	fi
	check "$u: password locked, shell nologin" "LK /sbin/nologin" \
		"$(passwd -S "$u" 2>/dev/null | awk '{print $2}') $(getent passwd "$u" | cut -d: -f7)"
	check "$u: pool $POOL reachable (GROUP@ of the pool)" yes \
		"$(yes_no as "$u" "$DAOS" pool query "$POOL")"
done

# --- container: open root, a file, then the ACL of the model ----------------------------------
as "$OWNER" "$DAOS" cont create "$POOL" "$C" --type=POSIX >/dev/null 2>&1
check "container $C created by $OWNER" yes "$(yes_no as "$OWNER" "$DAOS" cont query "$POOL" "$C")"
dfuse_of "$OWNER" "$MNT_O"
as "$OWNER" sh -c "chmod 777 '$MNT_O' && echo hello >'$MNT_O/f' && chmod 666 '$MNT_O/f'"
as "$OWNER" fusermount3 -u "$MNT_O"
for _ in $(seq 1 20); do [ "$(others)" = 0 ] && break; sleep 0.5; done
printf 'A::OWNER@:rwdtTaAo\nA::%s@:rwt\nA::%s@:rt\n' "$RW_U" "$RO_U" >"$WORK/acl"
chmod 644 "$WORK/acl"
check "ACL set: OWNER@ all, $RW_U@ rwt, $RO_U@ rt" yes \
	"$(yes_no as "$OWNER" "$DAOS" cont overwrite-acl "$POOL" "$C" --acl-file="$WORK/acl")"
check "no handles left after setup" 0 "$(others)"

# --- two mounts: writer as RW_U, reader as RO_U -----------------------------------------------
dfuse_of "$RW_U" "$MNT_RW" --disable-caching
dfuse_of "$RO_U" "$MNT_RO" --disable-caching --read-only
check "dfuse of $RW_U mounted" yes "$(yes_no mounted "$MNT_RW")"
check "dfuse of $RO_U mounted (--read-only)" yes "$(yes_no mounted "$MNT_RO")"
mounted "$MNT_RW" && mounted "$MNT_RO" || { report "evict-per-user: mounts failed"; exit 1; }

state() { # state <label> <rw expected> <ro expected> <handles expected>
	local r
	if [ "$2" != - ]; then
		r=$(io "$RW_U" sh -c "echo x >>'$MNT_RW/f'")
		check "$1: writer ($RW_U) writes${r:+ ($r$([ "$r" != ok ] && echo ": $(why)"))}" "$2" \
			"$([ "$r" = ok ] && echo ok || echo broken)"
	fi
	r=$(io "$RO_U" cat "$MNT_RO/f")
	check "$1: reader ($RO_U) reads${r:+ ($r$([ "$r" != ok ] && echo ": $(why)"))}" "$3" \
		"$([ "$r" = ok ] && echo ok || echo broken)"
	check "$1: open handles besides the query" "$4" "$(others)"
}

state "before evict" ok ok 2

# 1. owner without --all: the owner has no handles of its own, nothing else is touched
check "evict as $OWNER (owner), without --all: command" ok "$(evict "$OWNER")"
state "after evict as owner" ok ok 2

# 2. writer's user without --all: only its handles
check "evict as $RW_U, without --all: command" ok "$(evict "$RW_U")"
state "after evict as $RW_U" broken ok 1

# 3. a user that is not the owner cannot evict everyone
check "evict --all as $RO_U (not the owner, in the owner group): refused" failed "$(evict "$RO_U" --all)"
echo "evict --all as $RO_U said: $(head -1 "$WORK/evict.out")"
state "after refused --all" - ok 1

# 4. the owner with --all: everyone's handles
check "evict --all as $OWNER (owner): command" ok "$(evict "$OWNER" --all)"
state "after evict --all as owner" - broken 0

report "evict-per-user on $(hostname -s), $(uname -r), $("$DFUSE" --version 2>&1 | head -1)"
