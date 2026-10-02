#!/usr/bin/env bash
# DAOS functional tests (ftest, avocado) through launch.py, as upstream CI runs them on VMs
# needs: ftest-pair
# Run by "lab -c profiles/ftest.conf test ftest <launch node> [TAGS='<tags or test files>']
# [FORCE_IDMAP=1] [LAUNCH_ARGS=...]" after deploying a build (see profiles/ftest.conf). The launch
# node is one of FTEST_CLIENTS; launch.py runs there as VM_USER, with a virtualenv of ftest's
# requirements (without torch, which only the pytorch tests use) and pydaos, as
# ftest/scripts/setup_nodes.sh makes it. TAGS: avocado tags ("a,b" both, "-c" not c) or test
# files. The default is the tests upstream CI runs on VMs for dfuse changes (tags dfuse and vm),
# without dfuse/daos_build_vm.py (builds DAOS on dfuse for hours) and dfuse/ioctl_pool_handles.py
# (2 servers, ior); tags alone would also pick datamover and pytorch tests, which use dfuse.
# FORCE_IDMAP=1 starts every dfuse of the harness with --allow-idmap (a test-only change of
# util/dfuse_utils.py; a run without it restores the file). Each avocado test is one check; the
# tests of known-failures.txt are expected to fail (see there).
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
FTEST=/usr/lib/daos/TESTING/ftest
[ -f $FTEST/launch.py ] || { echo "no $FTEST (lab deploy <vm> tests daos-client-tests)" >&2; exit 2; }
TAGS=${TAGS:-dfuse/bash.py dfuse/bash_dcache.py dfuse/bash_fd.py dfuse/container_attrs.py
dfuse/container_type.py dfuse/enospace.py dfuse/il_whitelist.py dfuse/mu_mount.py dfuse/mu_perms.py
dfuse/pil4dfs_many_mounts.py dfuse/read.py daos_test/dfuse.py}
U=$VM_USER
H=$(getent passwd "$U" | cut -d: -f6)
VENV=$H/daos_ftest_venv

# virtualenv, rebuilt when the requirements or the tests package change
req=$(grep -v -e '^torch' -e '^#' -e '^$' $FTEST/requirements-ftest.txt)
stamp="$req $(rpm -q daos-client-tests daos-devel)"
if [ "$(cat "$VENV/.lab-stamp" 2>/dev/null)" != "$stamp" ]; then
	echo "setting up $VENV"
	echo "$req" >/tmp/ftest-requirements.txt
	rm -rf /tmp/ftest-pydaos && cp -a /usr/lib/daos/python /tmp/ftest-pydaos && chown -R "$U" /tmp/ftest-pydaos
	sudo -u "$U" -H bash -ec "rm -rf $VENV; python3.11 -m venv $VENV
		$VENV/bin/pip -q install --upgrade pip
		$VENV/bin/pip -q install -r /tmp/ftest-requirements.txt
		cd /tmp && $VENV/bin/pip -q install /tmp/ftest-pydaos" ||
		{ echo "virtualenv setup failed" >&2; exit 2; }
	echo "$stamp" >"$VENV/.lab-stamp"
fi

# FORCE_IDMAP: --allow-idmap for every dfuse the harness starts
du=$FTEST/util/dfuse_utils.py
[ -f $du.lab-orig ] || cp -p $du $du.lab-orig
if [ "${FORCE_IDMAP:-0}" = 1 ]; then
	python3 - $du.lab-orig $du <<'EOF'
import sys
s = open(sys.argv[1]).read()
old = '        self.multi_user = FormattedParameter("--multi-user", False)\n'
assert s.count(old) == 1, 'dfuse_utils.py changed: no multi_user parameter'
s = s.replace(old, old + '        # daos-testlab FORCE_IDMAP=1\n'
              '        self.allow_idmap = FormattedParameter("--allow-idmap", True)\n')
open(sys.argv[2], 'w').write(s)
EOF
else
	cp -p $du.lab-orig $du
fi

# launch.py as the ftest user; each test is an avocado job with its own results.json
mark=$(mktemp)
log=$H/ftest-launch.log
servers=${FTEST_SERVERS// /,} clients=${FTEST_CLIENTS// /,}
echo "launch.py: servers $servers, clients $clients, tags $TAGS${FORCE_IDMAP:+, FORCE_IDMAP=$FORCE_IDMAP}"
# shellcheck disable=SC2086
sudo -u "$U" -H bash -c "cd $FTEST && source $VENV/bin/activate &&
	DAOS_TEST_SHARED_DIR=$H/ftest-shared python launch.py --mode normal --insecure_mode \
		--user_create --provider ofi+tcp --test_servers $servers --test_clients $clients \
		${LAUNCH_ARGS:-} $(echo $TAGS)" >"$log" 2>&1
rc=$?
echo "launch.py rc=$rc, log $log"
grep -E '^(Running|Test|  )' "$log" | tail -40 || true

results=$(find "$H/avocado/job-results" -name results.json -newer "$mark" 2>/dev/null)
rm -f "$mark"
[ -n "$results" ] || { check "launch.py ran tests" yes no; report "ftest: no results"; exit 1; }
known() { # test -> "status reason" of known-failures.txt
	awk -v t="$1" '$1 == "ftest" && $2 == t {s = $3; $1 = $2 = $3 = ""; sub(/^ +/, ""); print s, $0; exit}' \
		known-failures.txt
}
# shellcheck disable=SC2086
while read -r status name; do
	k=$(known "${name%% *}")
	if [ -n "$k" ]; then
		check "$name (known: ${k#* })" "${k%% *}" "$status"
	else
		check "$name" PASS "$status"
	fi
done < <(python3 - $results <<'EOF'
import json, sys
for f in sys.argv[1:]:
    for t in json.load(open(f)).get('tests', []):
        name = t.get('name') or t.get('id', '?')
        name = name.split(':', 1)[-1].split(';')[0]   # file.py:Class.test_x;variant -> Class.test_x
        variant = (t.get('id') or '').split(';')[-1] if ';' in (t.get('id') or '') else ''
        print(t.get('status', '?'), name + (f' [{variant}]' if variant else ''))
EOF
)
[ "${FORCE_IDMAP:-0}" = 1 ] && cp -p $du.lab-orig $du
report "ftest on $servers + $clients$([ "${FORCE_IDMAP:-0}" = 1 ] && echo ', every dfuse with --allow-idmap'), $(rpm -q daos-client), $(uname -r)"
