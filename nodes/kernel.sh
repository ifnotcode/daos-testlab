#!/usr/bin/env bash
# Default boot kernel of an AlmaLinux VM: kernel.sh <stock|ml> (newest installed of that kind).
# Exits 100 when a reboot into it is still needed (bin/lab reboots and goes on). For "lab kernel":
# "lab provision" makes the kernel of lab.conf the default again.
source "$(dirname "$0")/../lib/remote.sh"

case ${1:?stock or ml} in
stock) want=$(ls -1 /boot/vmlinuz-* | grep -v -e elrepo -e rescue | sort -V | tail -1) ;;
ml) want=$(ls -1 /boot/vmlinuz-*elrepo* 2>/dev/null | sort -V | tail -1 || true) ;;
*) die "kernel: stock or ml" ;;
esac
[ -n "$want" ] || die "no $1 kernel installed (kernel ml needs \"ml\" in the VMS entry and provision)"
grubby --set-default "$want" >/dev/null 2>&1
if [ "$want" = "/boot/vmlinuz-$(uname -r)" ]; then
	log "running $(uname -r)"
else
	log "default kernel $want, reboot needed"
	exit 100
fi
