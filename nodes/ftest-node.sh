#!/usr/bin/env bash
# Node of DAOS's functional tests (ftest, avocado; role "ftest", profiles/ftest.conf): the system
# settings of src/tests/ftest/scripts/setup_nodes.sh and the tools the tests call. DAOS itself comes
# from "lab deploy <vm> rpms @<build>" and "lab deploy <vm> tests ...", the ftest virtualenv from
# tests/ftest.sh. Idempotent. Exits 100 when a reboot is needed (transparent hugepages off, as for
# the lab server: daos_engine needs that).
source "$(dirname "$0")/../lib/remote.sh"

dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
rpm -q epel-release >/dev/null 2>&1 || dnf -y -q install epel-release >/dev/null
dnf -y -q install python3.11 python3.11-pip python3.11-devel clustershell fio git gcc \
	libaio pciutils sshpass libuuid-devel boost-devel vim-common dos2unix bzip2 binutils valgrind \
	curl diffutils gcc-c++ >/dev/null

cat >/etc/sysctl.d/10-dmesg-for-all.conf <<EOF
kernel.dmesg_restrict=0
EOF
cat >/etc/sysctl.d/10-daos-verbs.conf <<EOF
net.ipv4.conf.all.accept_local=1
net.ipv4.conf.all.arp_ignore=2
net.ipv4.conf.all.arp_announce=2
net.ipv4.conf.all.rp_filter=2
EOF
# ftest/scripts/main.sh checks this; the daos-server package sets it on servers
cat >/etc/sysctl.d/10-ftest-map-count.conf <<EOF
vm.max_map_count=1000000
EOF
cat >/etc/security/limits.d/80_daos_limits.conf <<EOF
*  soft  core  unlimited
*  soft  memlock  unlimited
*  hard  memlock  unlimited
*  soft  nofile 1048576
*  hard  nofile 1048576
EOF
echo 'kernel.core_pattern=/var/tmp/core.%e.%t.%p' >/etc/sysctl.d/10-ftest-core.conf
sysctl -q --system

if ! grep -q 'transparent_hugepage=never' /proc/cmdline; then
	grubby --update-kernel=ALL --args=transparent_hugepage=never
	log "transparent_hugepage=never set, reboot needed"
	exit 100
fi
log "ftest node $(hostname -s) ready: $(uname -r), $(python3.11 --version)"
