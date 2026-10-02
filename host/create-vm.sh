#!/usr/bin/env bash
# Creates an AlmaLinux VM from the lab config: create-vm.sh <name> <public key file>
# Runs on the libvirt host as a member of the libvirt group (no sudo). Idempotent: an existing VM is
# left alone. Base images are downloaded once into the storage pool.
source "$(dirname "$0")/../lib/remote.sh"

name=${1:?VM name}
pubkey=$(cat "${2:?public key file}")
VIRSH="virsh -c $LIBVIRT_URI"
image=$(vm_field "$name" image) || die "$name is not in the config"
ip=$(vm_field "$name" ip) mac=$(vm_field "$name" mac) cpus=$(vm_field "$name" cpus)
ram=$(vm_field "$name" ram) disk=$(vm_field "$name" disk)

if $VIRSH dominfo "$name" >/dev/null 2>&1; then
	log "$name already exists, left as is"
	exit 0
fi

case $image in
alma9) url=$IMG_alma9 ;;
alma9.7) url=$IMG_alma9_7 ;;
*) die "unsupported image $image for create-vm.sh" ;;
esac
base_vol="base-$(basename "$url")"
work=$HOST_WORK/vm
mkdir -p "$work"
cd "$work"
ensure_pool

if ! $VIRSH vol-info --pool "$LIBVIRT_POOL" "$base_vol" >/dev/null 2>&1; then
	img=$(cached "$url" "images/$(basename "$url")")
	$VIRSH vol-create-as "$LIBVIRT_POOL" "$base_vol" "$(stat -c %s "$img")" --format qcow2
	$VIRSH vol-upload --pool "$LIBVIRT_POOL" "$base_vol" "$img"
	# a fresh upload can show a stale allocation until the pool is refreshed
	$VIRSH pool-refresh "$LIBVIRT_POOL" >/dev/null
fi

$VIRSH net-update "$LIBVIRT_NET" delete ip-dhcp-host "<host mac='$mac'/>" --live --config \
	>/dev/null 2>&1 || true
$VIRSH net-update "$LIBVIRT_NET" add ip-dhcp-host "<host mac='$mac' name='$name' ip='$ip'/>" \
	--live --config

$VIRSH vol-delete --pool "$LIBVIRT_POOL" "$name.qcow2" >/dev/null 2>&1 || true
$VIRSH vol-create-as "$LIBVIRT_POOL" "$name.qcow2" "${disk}G" --format qcow2 \
	--backing-vol "$base_vol" --backing-vol-format qcow2

# cloud-init: admin user with the lab key, static /etc/hosts (cloud-init would map the hostname
# to 127.0.0.1, and then daos_server and kubeadm bind to loopback)
pin=""
if [ "$image" = alma9.7 ]; then
	# stay on 9.7: point the AlmaLinux repos at the vault instead of the mirror list
	pin="  - sed -i -e 's|^mirrorlist=|#mirrorlist=|' -e 's|^# *baseurl=https://repo.almalinux.org/almalinux/\$releasever|baseurl=$ALMA_VAULT/9.7|' /etc/yum.repos.d/almalinux-*.repo"
fi
seed=seed-$name
rm -rf "$seed" && mkdir -p "$seed"
printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" >"$seed/meta-data"
{
	cat <<EOF
#cloud-config
hostname: $name
fqdn: $name
manage_etc_hosts: false
users:
  - name: $VM_USER
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $pubkey
growpart: {mode: auto, devices: ['/']}
write_files:
  - path: /etc/hosts
    content: |
EOF
	hosts_file | sed 's/^/      /'
	echo "runcmd:"
	echo "  - echo lab-vm-created > /etc/daos-testlab-vm"
	[ -n "$pin" ] && echo "$pin"
	true
} >"$seed/user-data"
genisoimage -quiet -output "$seed.iso" -volid cidata -joliet -rock "$seed/user-data" "$seed/meta-data"
$VIRSH vol-delete --pool "$LIBVIRT_POOL" "$seed.iso" >/dev/null 2>&1 || true
$VIRSH vol-create-as "$LIBVIRT_POOL" "$seed.iso" "$(stat -c %s "$seed.iso")" --format raw
$VIRSH vol-upload --pool "$LIBVIRT_POOL" "$seed.iso" "$seed.iso"

# No autostart: VMs run only while they are needed (lab start, stop, suspend). Free page
# reporting gives the memory the guest frees back to the host.
virt-install --connect "$LIBVIRT_URI" \
	--name "$name" --memory "$ram" --vcpus "$cpus" --cpu host-passthrough --osinfo almalinux9 \
	--disk vol="$LIBVIRT_POOL/$name.qcow2",bus=virtio,discard=unmap \
	--disk vol="$LIBVIRT_POOL/$seed.iso",device=cdrom \
	--network network="$LIBVIRT_NET",mac="$mac",model=virtio \
	--memballoon model=virtio,freePageReporting=on \
	--graphics none --noautoconsole --import
log "$name created ($ip)"
