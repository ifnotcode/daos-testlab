#!/usr/bin/env bash
# Checks the libvirt host for what the lab needs (no sudo; reports what an admin has to fix).
source "$(dirname "$0")/../lib/remote.sh"

ok=1
need() { command -v "$1" >/dev/null 2>&1 && echo "ok   $1" || { echo "MISS $1 ($2)"; ok=0; }; }
need virsh "libvirt-client"
need virt-install "virt-install"
need genisoimage "genisoimage"
need podman "podman (builds, images)"
need curl "curl"
need python3 "python3"
id -nG | tr ' ' '\n' | grep -qx libvirt && echo "ok   $(id -un) is in the libvirt group" ||
	{ echo "MISS $(id -un) is not in the libvirt group"; ok=0; }
VIRSH="virsh -c $LIBVIRT_URI"
if [ -n "${LIBVIRT_POOL_DIR:-}" ] && [ ! -d "$(dirname "$LIBVIRT_POOL_DIR")" ]; then
	echo "MISS $(dirname "$LIBVIRT_POOL_DIR") (external disk not mounted?)"
	ok=0
else
	ensure_pool
	echo "ok   storage pool $LIBVIRT_POOL ($($VIRSH pool-dumpxml "$LIBVIRT_POOL" | sed -n 's|.*<path>\(.*\)</path>.*|\1|p'))"
fi
$VIRSH net-info "$LIBVIRT_NET" >/dev/null 2>&1 && echo "ok   network $LIBVIRT_NET" ||
	{ echo "MISS network $LIBVIRT_NET"; ok=0; }
$VIRSH pool-refresh "$LIBVIRT_POOL" >/dev/null 2>&1 || true
free_gb=$($VIRSH pool-info --bytes "$LIBVIRT_POOL" 2>/dev/null | awk '/^Available/ {printf "%d", $2 / 2^30}')
echo "     pool $LIBVIRT_POOL: ${free_gb:-?} GiB free (VM disks are thin; a server + client need ~5 GiB)"
[ "${free_gb:-0}" -ge 8 ] || echo "WARN little space in the storage pool: VMs pause when it runs out"
mkdir -p "$HOST_WORK" "$HOST_BUILDS" "$HOST_CACHE"
avail() { df -h --output=avail "$1" | tail -1 | tr -d ' '; }
echo "     builds, cache: $(dirname "$HOST_BUILDS"), $(avail "$HOST_BUILDS") free"
echo "     podman storage: $(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null), $(avail ~) free (a DAOS build image takes 5-7 GB)"
echo "     memory: $(free -g | awk '/^Mem/ {print $2 " GB total, " $7 " GB available"}'), cpus: $(nproc)"
echo "     VMs: $($VIRSH list --all --name | grep -v '^$' | tr '\n' ' ')"
[ "$ok" = 1 ] || die "host is not ready"
