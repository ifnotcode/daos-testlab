#!/usr/bin/env bash
# Plain client host: dfuse as a user's daemon and as a systemd service, daos CLI through dfuse
# needs: server
# Run by "lab test dfuse-client <client vm> [DAOS_PREFIX=/opt/daos]" as root. Everything twice:
# dfuse without and with --allow-idmap. Covers what the other suites leave out:
# - dfuse started by a user (fusermount3) in daemon mode, unmounted by that user; the
#   interception libraries of that user get dfuse's handles;
# - dfuse --multi-user as a systemd service (SELinux enforcing on the lab clients), stopped with
#   ExecStop=umount;
# - daos filesystem query/evict and daos container query --path, which talk to dfuse through
#   its ioctl, as root and as another user;
# - an interception library called from a thread that is not the main one, so dfuse sees a
#   thread id and not the process id (--allow-idmap reads /proc/<pid>/task/<tid>).
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
daos_paths
DFUSE=$DAOS_BIN/dfuse
DAOS=$DAOS_BIN/daos
U=$CONT_OWNER
WORK=$(mktemp -d)
chmod 777 "$WORK"
MNT_U=$WORK/user-mnt
MNT_S=/mnt/dfuse-client-svc
UNIT=dfuse-client-test

as_u() { sudo -u "$U" -- "$@"; }
mounted() { findmnt -n -t fuse.daos "$1" >/dev/null; }
wait_mount() { for _ in $(seq 1 60); do mounted "$1" && return 0; sleep 0.5; done; return 1; }

ioil_handles() { # user file -> dfuse, own or none: whose handles libioil used for its reads
	local log
	log=$(mktemp -p "$WORK") && chmod 666 "$log"
	sudo -u "$1" env LD_PRELOAD="$DAOS_LIB/libioil.so" D_LOG_FILE="$log" D_LOG_MASK=DEBUG \
		DD_MASK=all dd if="$2" of=/dev/null bs=64k >/dev/null 2>&1
	if grep -q "ioil_fetch_cont_handles() failed, backing off" "$log"; then echo own
	elif grep -q "ioil_fetch_cont_handles() ioctl returned" "$log"; then echo dfuse
	else echo none; fi
}

pil_ops() { # user command... -> operations libpil4dfs intercepted
	local u=$1
	shift
	sudo -u "$u" env LD_PRELOAD="$DAOS_LIB/libpil4dfs.so" D_IL_REPORT=1 D_IL_NO_BYPASS=1 "$@" \
		2>&1 >/dev/null | sed -n 's/^\[op_sum *\] *\([0-9]*\).*/\1/p' | tail -1
}

# thread_read <user> <lib> <file>: reads the file in a thread other than the main one
cat >"$WORK/thread_read.py" <<'EOF'
import sys, threading
data = {}
def reader():
    with open(sys.argv[1], 'rb', buffering=0) as f:
        data['n'] = len(f.read())
t = threading.Thread(target=reader)
t.start()
t.join()
print(data.get('n', -1))
EOF
thread_ioil() { # user file -> whose handles libioil used, reading in a second thread
	local log
	log=$(mktemp -p "$WORK") && chmod 666 "$log"
	sudo -u "$1" env LD_PRELOAD="$DAOS_LIB/libioil.so" D_LOG_FILE="$log" D_LOG_MASK=DEBUG \
		DD_MASK=all python3 "$WORK/thread_read.py" "$2" >/dev/null 2>&1
	if grep -q "ioil_fetch_cont_handles() failed, backing off" "$log"; then echo own
	elif grep -q "ioil_fetch_cont_handles() ioctl returned" "$log"; then echo dfuse
	else echo none; fi
}

t() { check "[$mode] $1" "$2" "$3"; }

for mode in default allow; do
	opt=()
	[ "$mode" = allow ] && opt=(--allow-idmap)

	# dfuse of a user, daemon mode (it forks and the parent returns once mounted)
	mkdir -p "$MNT_U" && chown "$U" "$MNT_U"
	as_u "$DFUSE" "${opt[@]}" "$MNT_U" "$POOL" "$CONT" >/dev/null 2>&1
	t "user dfuse, daemon mode: mounted when the command returns" yes "$(yes_no mounted "$MNT_U")"
	f=$MNT_U/dfuse-client-$$
	as_u sh -c "head -c 1048576 /dev/urandom >$f"
	t "user dfuse: its user writes and reads" yes "$(yes_no as_u cmp -n 1048576 "$f" "$f")"
	t "user dfuse: libioil of its user uses dfuse's handles" dfuse "$(ioil_handles "$U" "$f")"
	n=$(pil_ops "$U" cat "$f")
	t "user dfuse: libpil4dfs of its user intercepts (${n:-0} ops)" yes \
		"$([ "${n:-0}" -gt 0 ] && echo yes || echo no)"
	t "user dfuse: libioil in a second thread uses dfuse's handles" dfuse "$(thread_ioil "$U" "$f")"
	as_u rm -f "$f"
	as_u fusermount3 -u "$MNT_U"
	sleep 1
	t "user dfuse: unmounted by its user, daemon gone" "no no" \
		"$(yes_no mounted "$MNT_U") $(pgrep -u "$U" -f "dfuse.*$MNT_U" >/dev/null && echo yes || echo no)"

	# dfuse --multi-user as a systemd service
	mkdir -p "$MNT_S"
	cat >/run/systemd/system/$UNIT.service <<EOF
[Unit]
Description=dfuse of the lab test dfuse-client
After=daos_agent.service
[Service]
Type=simple
Environment=D_LOG_FILE=$WORK/dfuse-svc-$mode.log D_LOG_MASK=INFO
ExecStart=$DFUSE --foreground --multi-user ${opt[*]} $MNT_S $POOL $CONT
ExecStop=/usr/bin/umount $MNT_S
EOF
	systemctl daemon-reload
	systemctl start $UNIT
	wait_mount "$MNT_S"
	t "service dfuse ($(getenforce)): active and mounted" "active yes" \
		"$(systemctl is-active $UNIT) $(yes_no mounted "$MNT_S")"
	d=$MNT_S/dfuse-client-$$
	mkdir -p "$d" && chmod 777 "$d"
	head -c 1048576 /dev/urandom >"$d/root-file" && chmod 644 "$d/root-file"
	t "service dfuse: another user reads root's file" yes "$(yes_no as_u cmp "$d/root-file" "$d/root-file")"
	t "service dfuse: another user cannot write it" no "$(yes_no as_u sh -c "echo x >>$d/root-file")"

	# daos CLI through the dfuse ioctl
	for who in root "$U"; do
		run=()
		[ "$who" = root ] || run=(sudo -u "$U" --)
		t "daos filesystem query, as $who" yes "$(yes_no "${run[@]}" "$DAOS" filesystem query "$MNT_S")"
		t "daos container query --path, as $who: the container" "$CONT" \
			"$("${run[@]}" "$DAOS" container query --path "$MNT_S" 2>/dev/null |
				sed -n 's/^ *Container Label *: *//p' | awk '{print $1}')"
		t "daos filesystem get-attr --path, as $who" yes \
			"$(yes_no "${run[@]}" "$DAOS" filesystem get-attr --path "$d/root-file")"
	done
	t "daos filesystem evict of a file, as root" yes "$(yes_no "$DAOS" filesystem evict "$d/root-file")"

	# the interception libraries of root (dfuse's user) and of another user, from a second thread
	t "service dfuse: libioil of root in a second thread uses dfuse's handles" dfuse \
		"$(thread_ioil root "$d/root-file")"
	t "service dfuse: libioil of $U in a second thread opens its own" own \
		"$(thread_ioil "$U" "$d/root-file")"

	rm -rf "$d"
	systemctl stop $UNIT
	sleep 1
	t "service dfuse: stopped, unmounted" "no" "$(yes_no mounted "$MNT_S")"
	if [ "$mode" = allow ]; then
		got=unknown
		grep -q "Idmapped mounts allowed" "$WORK/dfuse-svc-allow.log" && got=allowed
		grep -q "Kernel does not support idmapped mounts" "$WORK/dfuse-svc-allow.log" && got=unsupported
		exp=unsupported
		kernel_ge 6.12 && exp=allowed
		t "dfuse log: idmapped mounts ($(uname -r))" "$exp" "$got"
	fi
done
rm -f /run/systemd/system/$UNIT.service
systemctl daemon-reload
rm -rf "$WORK"
report "dfuse-client on $(hostname -s), $(uname -r), SELinux $(getenforce), $("$DFUSE" --version | head -1)"
