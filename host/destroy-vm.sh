#!/usr/bin/env bash
# Removes a lab VM with its disk, seed image and DHCP lease: destroy-vm.sh <name>
# Base images stay in the pool for the next create. Runs on the libvirt host.
source "$(dirname "$0")/../lib/remote.sh"

name=${1:?VM name}
VIRSH="virsh -c $LIBVIRT_URI"
mac=$(vm_field "$name" mac) || die "$name is not in the config"
if $VIRSH dominfo "$name" >/dev/null 2>&1; then
	$VIRSH destroy "$name" >/dev/null 2>&1 || true
	# the VM's own disks (overlay, seed), in whatever pool they are; backing images stay
	$VIRSH undefine "$name" --nvram --remove-all-storage >/dev/null 2>&1 ||
		$VIRSH undefine "$name" --remove-all-storage >/dev/null
fi
for v in "$name.qcow2" "seed-$name.iso"; do
	$VIRSH vol-delete --pool "$LIBVIRT_POOL" "$v" >/dev/null 2>&1 || true
done
$VIRSH net-update "$LIBVIRT_NET" delete ip-dhcp-host "<host mac='$mac'/>" --live --config \
	>/dev/null 2>&1 || true
rm -rf "$HOST_WORK/talos/$name"
rm -f "$HOST_SAVED/$name.save" "$HOST_SAVED/$name.disks" # RAM image of a suspended VM
log "$name removed"
