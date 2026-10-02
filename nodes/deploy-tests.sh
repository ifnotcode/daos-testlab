#!/usr/bin/env bash
# DAOS test packages of the build installed by "lab deploy <vm> rpms": deploy-tests.sh [package...]
# (default daos-client-tests: dfuse_test and the ftest tree). Their requirements come from the
# local build, the distribution, CRB and EPEL. Those that no configured repository provides (ior)
# are left out and listed, and the package is installed without them (rpm --nodeps): tests that
# use them fail. Idempotent; deploy-rpms.sh runs it again after it installed another build.
source "$(dirname "$0")/../lib/remote.sh"

repo=/srv/testlab-rpms
[ -f /etc/yum.repos.d/testlab-local.repo ] || die "no local DAOS build (lab deploy <vm> rpms @<build>)"
dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
for p in ${*:-daos-client-tests}; do
	f=$(ls "$repo/$p"-[0-9]*.rpm 2>/dev/null | head -1)
	[ -n "$f" ] || die "the build has no $p"
	want="" missing=""
	# what the package provides itself (its libraries, config(...)) is not a requirement to install
	provides=$(rpm -qp --provides "$f" | awk '{print $1}')
	while read -r req; do
		case $req in rpmlib* | /*) continue ;; esac
		name=${req%% *} # "daos-client = 2.9.100-8" and "go >= 1.21": the name only
		echo "$provides" | grep -qxF "$name" && continue
		rpm -q --whatprovides "$name" >/dev/null 2>&1 && continue
		if dnf -q repoquery --whatprovides "$name" 2>/dev/null | grep -q .; then
			want="$want $name"
		else
			missing="$missing $name"
		fi
	done < <(rpm -qpR "$f" | sort -u)
	# shellcheck disable=SC2086
	[ -z "$want" ] || dnf -y -q install $want >/dev/null
	if [ "$(rpm -q "$p" 2>/dev/null)" != "$(rpm -qp "$f")" ]; then
		rpm -U --nodeps --replacepkgs "$f"
	fi
	log "$(rpm -q "$p")${missing:+, installed without:$missing}"
done
