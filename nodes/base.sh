#!/usr/bin/env bash
# Every AlmaLinux VM: static /etc/hosts for all lab VMs and a few basic tools. Idempotent.
source "$(dirname "$0")/../lib/remote.sh"

hosts_file >/etc/hosts
# cloud-init must not rewrite it (it maps the hostname to 127.0.0.1, which makes daos_server
# and kubeadm bind to loopback)
mkdir -p /etc/cloud/cloud.cfg.d
echo 'manage_etc_hosts: false' >/etc/cloud/cloud.cfg.d/99-static-hosts.cfg

dnf -y -q install tar rsync gcc make >/dev/null
# the disk is a thin qcow2 with discard: return freed blocks to the host pool regularly
systemctl enable --now fstrim.timer >/dev/null 2>&1 || true
log "base setup done on $(hostname), $(cat /etc/almalinux-release), kernel $(uname -r)"
