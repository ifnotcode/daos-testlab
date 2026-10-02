#!/usr/bin/env bash
# Installs DAOS client RPMs from ~<VM_USER>/testlab-rpms (copied by "lab deploy <vm> rpms <dir>")
# as a local repository that wins over all others (priority=1: its versions are used even when
# e.g. AppStream has a newer libfabric). With --release, removes it and goes back to the release
# packages. Restarts daos_agent if it was enabled (running dfuse mounts need a remount then).
source "$(dirname "$0")/../lib/remote.sh"

repo=/srv/testlab-rpms
home=$(getent passwd "$VM_USER" | cut -d: -f6)
# package scripts of the swap may stop and disable the agent: remember its state
agent=0
systemctl -q is-enabled daos_agent 2>/dev/null && agent=1

# test packages installed by deploy-tests.sh without some requirements: dnf would refuse to touch
# them, so they are taken out before and put back afterwards
tests=$(rpm -q --qf '%{name}\n' daos-client-tests daos-server-tests 2>/dev/null | grep -v 'not installed' || true)
# shellcheck disable=SC2086
[ -z "$tests" ] || rpm -e --nodeps $tests

# names of the packages of a repository
repo_names() { dnf -q repoquery --disablerepo='*' --enablerepo="$1" --qf '%{name}' 2>/dev/null | sort -u; }
installed() { local n; for n in "$@"; do rpm -q "$n" >/dev/null 2>&1 && echo "$n"; done; true; }

if [ "${1:-}" = --release ]; then
	[ -f /etc/yum.repos.d/testlab-local.repo ] || { log "no local DAOS build installed"; exit 0; }
	names=$(repo_names testlab-local)
	dnf clean all -q
	# back to the versions of the other repositories; --allowerasing: a build may split packages
	# differently (e.g. isa-l and libisa-l), and those have to go
	# shellcheck disable=SC2046
	dnf -y -q --disablerepo=testlab-local distro-sync --allowerasing $(installed $names) >/dev/null
	# packages of the build that no other repository has
	leftover=$(dnf -q --disablerepo=testlab-local list --extras 2>/dev/null |
		awk 'NR > 1 {sub(/\.[^.]*$/, "", $1); print $1}' | grep -Fx -f <(echo "$names") || true)
	# shellcheck disable=SC2086
	[ -z "$leftover" ] || dnf -y -q --disablerepo=testlab-local remove $leftover >/dev/null
	dnf -y -q --disablerepo=testlab-local install daos-client >/dev/null
	# only now: a failed run can be repeated
	rm -f /etc/yum.repos.d/testlab-local.repo
	rm -rf "$repo"
	dnf clean all -q
else
	dnf -y -q install createrepo_c >/dev/null
	rm -rf "$repo" && mkdir -p "$repo"
	cp "$home"/testlab-rpms/*.rpm "$repo"/
	createrepo_c -q "$repo"
	cat >/etc/yum.repos.d/testlab-local.repo <<EOF
[testlab-local]
name=DAOS build under test (daos-testlab)
baseurl=file://$repo
gpgcheck=0
priority=1
EOF
	dnf clean all -q
	names=$(repo_names testlab-local)
	# switch what is installed to the local versions, then make sure the client is there
	# shellcheck disable=SC2046
	[ -n "$(installed $names)" ] && dnf -y -q distro-sync $(installed $names) >/dev/null
	dnf -y -q install daos-client >/dev/null
fi
# shellcheck disable=SC2086
[ -z "$tests" ] || [ "${1:-}" = --release ] || bash "$(dirname "$0")/deploy-tests.sh" $tests
if [ "$agent" = 1 ]; then
	systemctl enable daos_agent >/dev/null 2>&1
	systemctl restart daos_agent
fi
log "$(hostname -s): $(rpm -q daos-client libfabric mercury 2>/dev/null | tr '\n' ' ')"
