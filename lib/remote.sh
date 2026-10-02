# Helpers for scripts that run on the libvirt host or on the VMs (sourced after lab.env).
# shellcheck shell=bash
set -euo pipefail

# shellcheck disable=SC1090
source "${LAB_ENV:?LAB_ENV is not set}"

log() { printf '== %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

vm_field() {
	local name=$1 field=$2 e n role ip mac cpus ram disk image kernel
	for e in "${VMS[@]}"; do
		read -r n role ip mac cpus ram disk image kernel <<<"$e"
		[ "$n" = "$name" ] || continue
		case $field in
		role) echo "$role" ;; ip) echo "$ip" ;; mac) echo "$mac" ;; cpus) echo "$cpus" ;;
		ram) echo "$ram" ;; disk) echo "$disk" ;; image) echo "$image" ;; kernel) echo "$kernel" ;;
		esac
		return 0
	done
	return 1
}
vm_names() { local e n; for e in "${VMS[@]}"; do read -r n _ <<<"$e"; echo "$n"; done; }
vms_with_role() { local n; for n in $(vm_names); do [ "$(vm_field "$n" role)" = "$1" ] && echo "$n"; done; true; }

# libvirt host: the storage pool, created in $LIBVIRT_POOL_DIR if it does not exist yet
ensure_pool() {
	local virsh="virsh -c $LIBVIRT_URI"
	$virsh pool-info "$LIBVIRT_POOL" >/dev/null 2>&1 && return 0
	[ -n "${LIBVIRT_POOL_DIR:-}" ] || die "storage pool $LIBVIRT_POOL does not exist"
	mkdir -p "$LIBVIRT_POOL_DIR"
	$virsh pool-define-as "$LIBVIRT_POOL" dir --target "$LIBVIRT_POOL_DIR" >/dev/null
	$virsh pool-start "$LIBVIRT_POOL" >/dev/null
	$virsh pool-autostart "$LIBVIRT_POOL" >/dev/null
	log "storage pool $LIBVIRT_POOL created in $LIBVIRT_POOL_DIR"
}

# libvirt host: cached download, cached <url> <file in $HOST_CACHE>; prints the local path.
# Kept across labs and re-creations: delete the file to get a newer version of a "latest" URL.
cached() {
	local url=$1 f=$HOST_CACHE/$2
	if [ ! -s "$f" ]; then
		mkdir -p "$(dirname "$f")"
		log "downloading $url"
		curl -fsSL --retry 3 -o "$f.part" "$url" && mv "$f.part" "$f"
	fi
	echo "$f"
}

hosts_file() {
	local n
	printf '127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4\n'
	printf '::1         localhost localhost.localdomain localhost6 localhost6.localdomain6\n'
	for n in $(vm_names); do printf '%s %s\n' "$(vm_field "$n" ip)" "$n"; done
}

# Pod networks behind Kubernetes nodes, as "cidr via-ip" lines (DAOS servers reply to pod IPs)
pod_routes() {
	local n
	for n in $(vms_with_role k8s); do echo "$K8S_POD_CIDR $(vm_field "$n" ip)"; done
	for n in $(vms_with_role talos); do echo "$TALOS_POD_CIDR $(vm_field "$n" ip)"; done
}
