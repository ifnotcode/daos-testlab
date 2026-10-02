#!/usr/bin/env bash
# Software RDMA for a DAOS provider over verbs (DAOS_PROVIDER="ofi+verbs;ofi_rxm"): the VMs have no
# RDMA hardware, so Soft-RoCE (rdma_rxe, SOFT_RDMA=rxe) or soft-iWARP (siw, SOFT_RDMA=siw) runs on
# top of eth0 as device ${SOFT_RDMA}0. Both are modules of the EL9 stock kernel and of kernel-ml.
# Idempotent; the link comes back at boot through testlab-soft-rdma.service.
source "$(dirname "$0")/../lib/remote.sh"

kind=${SOFT_RDMA:-rxe}
case $kind in
rxe) module=rdma_rxe ;;
siw) module=siw ;;
*) die "SOFT_RDMA must be rxe or siw" ;;
esac
dnf -y -q install rdma-core libibverbs-utils librdmacm-utils iproute >/dev/null

cat >/etc/systemd/system/testlab-soft-rdma.service <<EOF
[Unit]
Description=Software RDMA device ${kind}0 on eth0 (daos-testlab)
After=network-online.target
Wants=network-online.target
Before=daos_server.service daos_agent.service containerd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/modprobe $module
ExecStart=/bin/sh -c 'test -e /sys/class/infiniband/${kind}0 || rdma link add ${kind}0 type $kind netdev eth0'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now testlab-soft-rdma.service >/dev/null 2>&1
systemctl restart testlab-soft-rdma.service

# memory registration counts against RLIMIT_MEMLOCK: unlimited for users (libioil, tests) and for
# containerd, whose limit every container inherits (the CSI mount pods run dfuse over verbs)
cat >/etc/security/limits.d/80-testlab-rdma.conf <<EOF
*  soft  memlock  unlimited
*  hard  memlock  unlimited
EOF
mkdir -p /etc/systemd/system/containerd.service.d
cat >/etc/systemd/system/containerd.service.d/10-testlab-memlock.conf <<EOF
[Service]
LimitMEMLOCK=infinity
EOF
systemctl daemon-reload
systemctl is-active -q containerd 2>/dev/null && systemctl restart containerd

rdma link show "${kind}0/1" | grep -q ACTIVE || die "${kind}0 is not active: $(rdma link show)"
log "$(hostname -s): $(rdma link show "${kind}0/1" | awk '{print $2, $4}'), $(ibv_devinfo -d "${kind}0" | awk '/active_mtu/ {print "mtu", $2}')"
