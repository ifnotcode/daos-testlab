#!/usr/bin/env bash
# DAOS node local tests (utils/node_local_test.py, as ci/unit/test_nlt_node.sh runs them)
# needs: none
# Run by "lab test nlt <vm> [NLT_ARGS='--test il_allow_idmap'] [FORCE_IDMAP=1]" on a VM with
# an install tree in DAOS_PREFIX (default /opt/daos, "lab deploy <vm> tree @<build>") and the source
# tree of the same commit in ~$VM_USER/daos-src ("lab deploy <vm> src @<build>"). The suite runs as
# $VM_USER; setup steps that need root run first.
#   NLT_ARGS      options for node_local_test.py (default: the whole suite)
#   FORCE_IDMAP=1 start every dfuse of the suite with --allow-idmap (test-only harness change)
# NLT starts its own DAOS server on the VM: needs ~12 GB of RAM and 6 vCPUs to finish in time.
set -euo pipefail
cd "$(dirname "$0")"
source "${LAB_ENV:?}"
PREFIX=${DAOS_PREFIX:-/opt/daos}
user=$VM_USER
home=$(getent passwd "$user" | cut -d: -f6)
SRC=${SRC:-$home/daos-src}
[ -x "$PREFIX/bin/dfuse" ] || { echo "no DAOS tree in $PREFIX (lab deploy <vm> tree @<build>)"; exit 2; }
[ -f "$SRC/utils/node_local_test.py" ] || { echo "no DAOS source in $SRC (lab deploy <vm> src @<build>)"; exit 2; }

# numactl: the special test run_dfuse starts dfuse through it
dnf -y -q install python3.11 python3.11-devel gcc fuse3 patchelf numactl >/dev/null
[ -d "$home/nlt-venv" ] || setpriv --reuid="$user" --regid="$user" --init-groups python3.11 -m venv "$home/nlt-venv"
# requirements-utest.txt without torch (only for the pydaos.torch tests)
setpriv --reuid="$user" --regid="$user" --init-groups env HOME="$home" \
	"$home/nlt-venv/bin/pip" -q install tabulate junit_xml pyxattr PyYAML

echo "{\"PREFIX\": \"$PREFIX\"}" >"$SRC/.build_vars.json"
grep -q '^user_allow_other' /etc/fuse.conf || echo user_allow_other >>/etc/fuse.conf
# as ci/unit/test_nlt_node.sh: mmap()'ed ULT stacks
[ "$(sysctl -n vm.max_map_count)" -ge 1000000 ] || sysctl -q vm.max_map_count=1000000

# daos_server_helper, as utils/setup_daos_server_helper.sh does, but with only the absolute
# entries of its rpath: the VM may also have DAOS packages in /usr/lib64, where $ORIGIN/../lib64
# of /usr/bin/daos_server_helper would point to.
if [ -x "$PREFIX/bin/daos_server_helper" ]; then
	rpath=$(patchelf --print-rpath "$PREFIX/bin/daos_server_helper" | tr : '\n' | grep '^/' | paste -sd:)
	cp "$PREFIX/bin/daos_server_helper" /usr/bin/daos_server_helper
	patchelf --set-rpath "$rpath" /usr/bin/daos_server_helper
	chmod 4755 /usr/bin/daos_server_helper
	chmod -x "$PREFIX/bin/daos_server_helper"
fi

# SCM of the NLT server (engine 0): an empty tmpfs owned by the user, which is what --no-root expects
if ! findmnt -n /mnt/daos_0 >/dev/null; then
	mkdir -p /mnt/daos_0
	mount -t tmpfs -o size=4g tmpfs /mnt/daos_0
fi
chown "$user:$user" /mnt/daos_0
find /mnt/daos_0 -mindepth 1 -delete

if [ "${FORCE_IDMAP:-0}" = 1 ]; then
	sed -i "s/        self.allow_idmap = allow_idmap/        self.allow_idmap = True/" \
		"$SRC/src/tests/nlt/dfuse.py"
	grep -q "self.allow_idmap = True" "$SRC/src/tests/nlt/dfuse.py" ||
		{ echo "FORCE_IDMAP: the harness of this tree has no allow_idmap"; exit 2; }
fi

logs=$home/nlt_logs
setpriv --reuid="$user" --regid="$user" --init-groups mkdir -p "$logs"
ulimit -Hn 262144
ulimit -Sn 1024
cd "$SRC"
# setpriv, not su/runuser: no PAM session, so the raised file limit is kept
rc=0
# shellcheck disable=SC2086
setpriv --reuid="$user" --regid="$user" --init-groups env HOME="$home" USER="$user" TMPDIR="$logs" \
	"$home/nlt-venv/bin/python" utils/node_local_test.py --no-root --memcheck no \
	--system-ram-reserved 1 --dfuse-dir /tmp ${NLT_ARGS:-} || rc=$?
# when NLT itself crashes, its server keeps running (and keeps the ssh session of "lab test" open)
pkill -u "$user" -f "^$PREFIX/bin/daos_(server|engine|agent) " 2>/dev/null || true
exit $rc
