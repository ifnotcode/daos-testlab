#!/usr/bin/env bash
# EPEL, CRB and the DAOS release repository (DAOS_REPO) on an EL9 VM. Idempotent.
source "$(dirname "$0")/../lib/remote.sh"

dnf -y -q install epel-release dnf-plugins-core >/dev/null
dnf config-manager --set-enabled crb
cat >/etc/yum.repos.d/daos-packages.repo <<EOF
[daos-packages]
name=DAOS v${DAOS_VERSION} Packages
baseurl=${DAOS_REPO}
enabled=1
gpgcheck=1
protect=1
gpgkey=${DAOS_REPO_KEY}
EOF
rpm --import "$DAOS_REPO_KEY"
log "DAOS $DAOS_VERSION repository configured"
