#!/usr/bin/env bash
# dfuse --allow-idmap: idmapped mounts, owners, permissions, interception-library handles
# needs: server
# Run by "lab test dfuse-idmap <vm> [DAOS_PREFIX=/opt/daos]" as root on a client or k8s VM with a
# DAOS build that has the patch (patchsets/allow-idmap-*). Every check runs twice: dfuse started
# without and with --allow-idmap. Idmapped mounts need Linux >= 6.12 (kernel "ml" in lab.conf).
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
daos_paths
DFUSE=$DAOS_BIN/dfuse
IOIL=$DAOS_LIB/libioil.so
PIL=$DAOS_LIB/libpil4dfs.so
IDMAP_BIND=$(idmap_bind)
FD_MOUNT=$(tool fuse-fd-mount)
OTHER=$(id -u "$CONT_OWNER") # a user other than the one running dfuse
MNT=/mnt/idmap-test
IDMNT=/mnt/idmap-test-idmapped
WORK=$(mktemp -d)
chmod 755 "$WORK" && mkdir -m 1777 "$WORK"/il # logs of the interception libraries, any user

start_dfuse() { # [pidns|fdmount]
	mkdir -p "$MNT"
	local args=(--foreground --multi-user --disable-caching) mp=$MNT
	[ "$mode" = allow ] && args+=(--allow-idmap)
	local pre=()
	# Own pid namespace, but still the host's /proc (and mount namespace, to keep the mount
	# visible). The thread count is given because hwloc cannot get the CPU binding of dfuse from
	# the /proc of another pid namespace, and dfuse then fails to start (with or without idmap).
	[ "${1:-}" = pidns ] && pre=(unshare --pid --fork) && args+=(--thread-count=4)
	# Mounted by fuse-fd-mount, which gives dfuse the mounted /dev/fuse as /dev/fd/10
	[ "${1:-}" = fdmount ] && pre=("$FD_MOUNT" "$MNT") && mp=/dev/fd/10
	D_LOG_FILE=$WORK/dfuse-$mode-${1:-host}.log D_LOG_MASK=INFO D_LOG_FLUSH=INFO \
		"${pre[@]}" "$DFUSE" "${args[@]}" "$mp" "$POOL" "$CONT" >/dev/null 2>&1 &
	dfuse_pid=$!
	for _ in $(seq 1 60); do
		if findmnt -n -t fuse.daos "$MNT" >/dev/null; then
			# With /dev/fd/N the mount is there before dfuse has answered FUSE_INIT, and only
			# that answer allows idmapped mounts. A request waits for it: statfs returns once
			# dfuse is up (over slower fabrics, e.g. verbs on Soft-RoCE, idmap-bind came first).
			timeout 60 stat -f "$MNT" >/dev/null && return 0
			break
		fi
		sleep 0.5
	done
	echo "dfuse did not mount" >&2
	return 1
}

stop_dfuse() {
	umount "$IDMNT" 2>/dev/null
	fusermount3 -u "$MNT" 2>/dev/null || umount -l "$MNT"
	wait "$dfuse_pid" 2>/dev/null
}

as() { # uid command...: run as another uid (root: as is)
	local u=$1
	shift
	if [ "$u" = root ]; then "$@"; else setpriv --reuid="$u" --regid="$u" --clear-groups "$@"; fi
}

ioil_handles() { # user [wrapper...] -- command... -> dfuse, own or none
	# Whose pool and container handles libioil used for its reads: dfuse's (shared through the
	# ioctl), its own (it connects itself when dfuse refuses them with EPERM) or none (no reads).
	# The wrapper (unshare, nsenter) comes before LD_PRELOAD so that only the command is traced.
	local u=$1 wrap=() log n
	shift
	while [ "$1" != -- ]; do wrap+=("$1"); shift; done
	shift
	log=$(mktemp -p "$WORK"/il) && chmod 666 "$log"
	as "$u" "${wrap[@]}" env LD_PRELOAD="$IOIL" D_LOG_FILE="$log" D_LOG_MASK=DEBUG DD_MASK=all \
		"$@" >/dev/null 2>&1
	# the summary on stderr is written from a destructor and may be lost, NLT reads the log too
	n=$(sed -n 's/.*Performed \([0-9]*\) reads.*/\1/p' "$log" | tail -1)
	if [ "${n:-0}" -eq 0 ]; then echo none
	elif grep -q "ioil_fetch_cont_handles() failed, backing off" "$log"; then echo own
	elif grep -q "ioil_fetch_cont_handles() ioctl returned" "$log"; then echo dfuse
	else echo unknown; fi
}

pil_ops() { # user command... -> pil4dfs op_sum (it has no fallback: 0 if dfuse refuses the handles)
	local u=$1
	shift
	# D_IL_NO_BYPASS: do not skip commands such as cat that pil4dfs leaves alone by default
	as "$u" env LD_PRELOAD="$PIL" D_IL_REPORT=1 D_IL_NO_BYPASS=1 "$@" 2>&1 >/dev/null |
		sed -n 's/^\[op_sum *\] *\([0-9]*\).*/\1/p' | tail -1
}

make_userns() { # prints the pid of a process whose user namespace maps 0-65535 to 100000-165535
	# no inherited stdout: this runs inside $(...), which would otherwise wait for it to exit
	unshare --user sleep 600 >/dev/null 2>&1 &
	local p=$!
	sleep 0.3
	echo deny >/proc/$p/setgroups
	echo "0 100000 65536" >/proc/$p/uid_map
	echo "0 100000 65536" >/proc/$p/gid_map
	echo $p
}

t() { check "[$mode] $1" "$2" "$3"; }

run_mode() {
	start_dfuse || { t "dfuse starts" yes no; return; }

	# Test data, created through the plain mount by root
	rm -rf "${MNT:?}"/idm && mkdir -p "$MNT"/idm/root-dir "$MNT"/idm/u1000
	chmod 755 "$MNT"/idm "$MNT"/idm/root-dir "$MNT"/idm/u1000
	chown 1000:1000 "$MNT"/idm/u1000
	head -c 1048576 /dev/urandom >"$MNT"/idm/file && chmod 644 "$MNT"/idm/file

	local expect_idmap=no got holder n exp dpid
	[ "$mode" = allow ] && kernel_ge 6.12 && expect_idmap=yes

	# Kernel negotiation reported in the log
	if [ "$mode" = allow ]; then
		if grep -q "Idmapped mounts allowed" "$WORK"/dfuse-allow-host.log; then got=yes
		elif grep -q "Kernel does not support idmapped mounts" "$WORK"/dfuse-allow-host.log; then got=no
		else got=unknown; fi
		t "dfuse log: idmapped mounts allowed by the kernel ($(uname -r))" "$expect_idmap" "$got"
	fi

	# An idmapped bind mount of the dfuse mount can be created
	holder=$(make_userns)
	mkdir -p "$IDMNT"
	got=$(yes_no "$IDMAP_BIND" "$holder" "$MNT" "$IDMNT")
	t "idmapped mount can be created" "$expect_idmap" "$got"

	if [ "$got" = yes ]; then
		t "on-disk uid 0 appears as 100000 through the idmapped mount" 100000 \
			"$(stat -c %u "$IDMNT"/idm/file)"
		as 101000 touch "$IDMNT"/idm/u1000/new
		t "create through idmapped mount by uid 101000 -> on-disk owner" 1000:1000 \
			"$(stat -c %u:%g "$MNT"/idm/u1000/new 2>/dev/null)"
		t "uid 101000 cannot create in on-disk 0:0 0755 directory" no \
			"$(yes_no as 101000 touch "$IDMNT"/idm/root-dir/x)"
		chown 100500:100500 "$IDMNT"/idm/u1000/new
		t "chown 100500 through idmapped mount -> on-disk owner" 500:500 \
			"$(stat -c %u:%g "$MNT"/idm/u1000/new)"
		as 101000 sh -c "mkdir $IDMNT/idm/u1000/d && mv $IDMNT/idm/u1000/d $IDMNT/idm/u1000/d2"
		t "mkdir + rename through idmapped mount by uid 101000 -> on-disk owner" 1000:1000 \
			"$(stat -c %u:%g "$MNT"/idm/u1000/d2 2>/dev/null)"
		umount "$IDMNT"
	fi
	kill "$holder" 2>/dev/null

	# Interception libraries of the dfuse user (root) still get dfuse's handles
	t "libioil as the dfuse user uses dfuse's handles" dfuse \
		"$(ioil_handles root -- dd if="$MNT"/idm/file of=/dev/null bs=64k)"
	n=$(pil_ops root cat "$MNT"/idm/file)
	t "libpil4dfs as the dfuse user intercepts ($n ops)" yes "$([ "${n:-0}" -gt 0 ] && echo yes || echo no)"
	# ... also from a nested pid namespace (the pid is visible to dfuse)
	t "libioil as the dfuse user in a nested pid namespace uses dfuse's handles" dfuse \
		"$(ioil_handles root unshare --pid --fork --mount-proc -- dd if="$MNT"/idm/file of=/dev/null bs=64k)"

	# Another user never gets dfuse's handles: libioil connects with its own credentials,
	# libpil4dfs leaves the file to the kernel
	t "libioil as another user ($OTHER) is refused dfuse's handles" own \
		"$(ioil_handles "$OTHER" -- dd if="$MNT"/idm/file of=/dev/null bs=64k)"
	n=$(pil_ops "$OTHER" cat "$MNT"/idm/file)
	t "libpil4dfs as another user ($OTHER) does not intercept ($n ops)" no \
		"$([ "${n:-0}" -gt 0 ] && echo yes || echo no)"
	stop_dfuse

	# dfuse in its own pid namespace but with the host's /proc. With idmap the kernel gives
	# dfuse only pids relative to its namespace: a caller outside it has pid 0, and one inside it
	# cannot be looked up in a /proc of another namespace, so neither gets the handles. Without
	# idmap the kernel-provided uid/gid are used, as before.
	start_dfuse pidns || { t "dfuse starts in a pid namespace" yes no; return; }
	exp=dfuse
	[ "$expect_idmap" = yes ] && exp=own
	t "libioil (dfuse user) outside dfuse's pid namespace" "$exp" \
		"$(ioil_handles root -- dd if="$MNT"/idm/file of=/dev/null bs=64k)"
	dpid=$(pgrep -P "$dfuse_pid" | head -1)
	t "libioil (dfuse user) inside dfuse's pid namespace, /proc of the host" "$exp" \
		"$(ioil_handles root nsenter --target "$dpid" --pid -- dd if="$MNT"/idm/file of=/dev/null bs=64k)"
	stop_dfuse

	# dfuse given the mounted /dev/fuse as /dev/fd/N by the process that mounted it. With idmap
	# the kernel gives dfuse pids relative to the pid namespace of that process, which dfuse cannot
	# check, so it refuses the handles even to the dfuse user in its own namespace. Idmapped
	# mounts work as with a mount of dfuse itself. Without idmap the kernel-provided uid/gid are
	# used, as before.
	start_dfuse fdmount || { t "dfuse starts on /dev/fd/N" yes no; return; }
	holder=$(make_userns)
	t "idmapped mount can be created, dfuse on /dev/fd/N" "$expect_idmap" \
		"$(yes_no "$IDMAP_BIND" "$holder" "$MNT" "$IDMNT")"
	umount "$IDMNT" 2>/dev/null
	kill "$holder" 2>/dev/null
	t "libioil (dfuse user), dfuse on /dev/fd/N" "$exp" \
		"$(ioil_handles root -- dd if="$MNT"/idm/file of=/dev/null bs=64k)"
	n=$(pil_ops root cat "$MNT"/idm/file)
	t "libpil4dfs (dfuse user) intercepts, dfuse on /dev/fd/N ($n ops)" \
		"$([ "$exp" = dfuse ] && echo yes || echo no)" "$([ "${n:-0}" -gt 0 ] && echo yes || echo no)"
	stop_dfuse
}

for mode in default allow; do
	run_mode
done
rm -rf "$WORK"
report "dfuse-idmap on $(hostname -s), kernel $(uname -r), $("$DFUSE" --version | head -1)"
