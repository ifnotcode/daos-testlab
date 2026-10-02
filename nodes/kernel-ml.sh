#!/usr/bin/env bash
# ELRepo kernel-ml (>= 6.12: idmapped FUSE mounts) as the default boot kernel. Idempotent.
# Exits 100 when a reboot into it is still needed (bin/lab reboots and goes on).
source "$(dirname "$0")/../lib/remote.sh"

if ! rpm -q kernel-ml >/dev/null 2>&1; then
	rpm --import https://www.elrepo.org/RPM-GPG-KEY-v2-elrepo.org
	dnf -y -q install https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm >/dev/null
	# the ELRepo mirrors are slow and sometimes time out
	for i in 1 2 3 4; do
		dnf -y -q --enablerepo=elrepo-kernel install kernel-ml kernel-ml-modules-extra >/dev/null &&
			break
		log "kernel-ml download failed (attempt $i), retrying"
		[ "$i" = 4 ] && die "could not install kernel-ml"
	done
fi
latest=$(ls -1 /boot/vmlinuz-*elrepo* | sort -V | tail -1)
grubby --set-default "$latest" >/dev/null
case "$(uname -r)" in
*elrepo*) log "running $(uname -r)" ;;
*) log "kernel-ml installed ($latest), reboot needed"; exit 100 ;;
esac
