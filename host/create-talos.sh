#!/usr/bin/env bash
# Creates a single-node Talos cluster VM: create-talos.sh <name>
# Runs on the libvirt host (no sudo). Downloads talosctl/kubectl into $HOST_WORK/bin, gets the
# Image Factory schematic for $TALOS_EXTENSIONS, generates the machine config from the patches in
# talos/patches (cluster secrets are generated once and kept in $HOST_WORK/talos/<name>), creates
# the VM, bootstraps it and writes the kubeconfig. Idempotent.
source "$(dirname "$0")/../lib/remote.sh"

name=${1:?VM name}
VIRSH="virsh -c $LIBVIRT_URI"
ip=$(vm_field "$name" ip) || die "$name is not in the config"
mac=$(vm_field "$name" mac) cpus=$(vm_field "$name" cpus) ram=$(vm_field "$name" ram)
disk=$(vm_field "$name" disk)
bin=$HOST_WORK/bin
dir=$HOST_WORK/talos/$name
mkdir -p "$bin" "$dir"
chmod 700 "$dir" # cluster secrets
talosctl=$bin/talosctl-$TALOS_VERSION
kubectl=$bin/kubectl

# --- tools (downloads kept in $HOST_CACHE) ---
if [ ! -x "$talosctl" ]; then
	install -m 755 "$(cached "https://github.com/siderolabs/talos/releases/download/$TALOS_VERSION/talosctl-linux-amd64" \
		"bin/talosctl-$TALOS_VERSION")" "$talosctl"
fi
if [ ! -x "$kubectl" ]; then
	v=$(curl -fsSL "https://dl.k8s.io/release/stable-${K8S_MINOR#v}.txt")
	install -m 755 "$(cached "https://dl.k8s.io/release/$v/bin/linux/amd64/kubectl" "bin/kubectl-$v")" \
		"$kubectl"
fi
ensure_pool

# --- Image Factory schematic and nocloud image ---
{
	echo "customization:"
	echo "  systemExtensions:"
	echo "    officialExtensions:"
	for e in $TALOS_EXTENSIONS; do echo "      - $e"; done
} >"$dir/schematic.yaml"
id=$(curl -fsSL -X POST --data-binary @"$dir/schematic.yaml" https://factory.talos.dev/schematics |
	python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')
base_vol="talos-$TALOS_VERSION-${id:0:12}.qcow2"
if ! $VIRSH vol-info --pool "$LIBVIRT_POOL" "$base_vol" >/dev/null 2>&1; then
	img=$(cached "https://factory.talos.dev/image/$id/$TALOS_VERSION/nocloud-amd64.qcow2" \
		"images/talos-$TALOS_VERSION-$id-nocloud-amd64.qcow2")
	$VIRSH vol-create-as "$LIBVIRT_POOL" "$base_vol" "$(stat -c %s "$img")" --format qcow2
	$VIRSH vol-upload --pool "$LIBVIRT_POOL" "$base_vol" "$img"
	$VIRSH pool-refresh "$LIBVIRT_POOL" >/dev/null
fi

# --- machine config ---
[ -f "$dir/secrets.yaml" ] || "$talosctl" gen secrets -o "$dir/secrets.yaml"
patches=()
for p in "$(dirname "$0")"/../talos/patches/*.yaml.in; do
	out=$dir/$(basename "$p" .in)
	sed -e "s|@REGISTRY@|$REGISTRY|g" -e "s|@TALOS_POD_CIDR@|$TALOS_POD_CIDR|g" "$p" >"$out"
	patches+=(--config-patch "@$out")
done
k8s_version=()
[ -n "${TALOS_K8S_VERSION:-}" ] && k8s_version=(--kubernetes-version "$TALOS_K8S_VERSION")
"$talosctl" gen config "$TALOS_CLUSTER" "https://$ip:6443" --with-secrets "$dir/secrets.yaml" \
	"${k8s_version[@]}" --install-image "factory.talos.dev/nocloud-installer/$id:$TALOS_VERSION" "${patches[@]}" \
	--output-types controlplane,talosconfig -o "$dir" --force >/dev/null
"$talosctl" validate --config "$dir/controlplane.yaml" --mode cloud >/dev/null
export TALOSCONFIG=$dir/talosconfig
"$talosctl" config endpoint "$ip"
"$talosctl" config node "$ip"

# --- VM ---
if ! $VIRSH dominfo "$name" >/dev/null 2>&1; then
	$VIRSH net-update "$LIBVIRT_NET" delete ip-dhcp-host "<host mac='$mac'/>" --live --config \
		>/dev/null 2>&1 || true
	$VIRSH net-update "$LIBVIRT_NET" add ip-dhcp-host "<host mac='$mac' name='$name' ip='$ip'/>" \
		--live --config
	$VIRSH vol-delete --pool "$LIBVIRT_POOL" "$name.qcow2" >/dev/null 2>&1 || true
	$VIRSH vol-create-as "$LIBVIRT_POOL" "$name.qcow2" "${disk}G" --format qcow2 \
		--backing-vol "$base_vol" --backing-vol-format qcow2
	# NoCloud seed: Talos reads its machine config from user-data
	mkdir -p "$dir/seed"
	cp "$dir/controlplane.yaml" "$dir/seed/user-data"
	printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" >"$dir/seed/meta-data"
	genisoimage -quiet -output "$dir/seed.iso" -volid cidata -joliet -rock \
		"$dir/seed/user-data" "$dir/seed/meta-data"
	$VIRSH vol-delete --pool "$LIBVIRT_POOL" "seed-$name.iso" >/dev/null 2>&1 || true
	$VIRSH vol-create-as "$LIBVIRT_POOL" "seed-$name.iso" "$(stat -c %s "$dir/seed.iso")" --format raw
	$VIRSH vol-upload --pool "$LIBVIRT_POOL" "seed-$name.iso" "$dir/seed.iso"
	# No autostart: VMs run only while they are needed (lab start, stop, suspend). Free page
	# reporting gives the memory the guest frees back to the host.
	virt-install --connect "$LIBVIRT_URI" \
		--name "$name" --memory "$ram" --vcpus "$cpus" --cpu host-passthrough --osinfo linux2022 \
		--boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
		--disk vol="$LIBVIRT_POOL/$name.qcow2",bus=virtio,discard=unmap \
		--disk vol="$LIBVIRT_POOL/seed-$name.iso",device=cdrom \
		--network network="$LIBVIRT_NET",mac="$mac",model=virtio \
		--memballoon model=virtio,freePageReporting=on \
		--graphics none --noautoconsole --import
	log "$name created, waiting for the Talos API"
else
	log "$name already exists; applying the current config"
	"$talosctl" apply-config --file "$dir/controlplane.yaml" >/dev/null 2>&1 || true
fi

for i in $(seq 1 120); do
	"$talosctl" version >/dev/null 2>&1 && break
	sleep 5
	[ "$i" = 120 ] && die "Talos API on $ip did not come up"
done
# etcd bootstrap happens once; a second call fails with AlreadyExists
"$talosctl" bootstrap 2>&1 | grep -v -i 'already' || true
for i in $(seq 1 120); do
	# the API answers before the node has registered: wait for the node object as well
	"$talosctl" kubeconfig "$dir/kubeconfig" --force >/dev/null 2>&1 &&
		[ -n "$(KUBECONFIG=$dir/kubeconfig "$kubectl" get nodes -o name 2>/dev/null)" ] && break
	sleep 5
	[ "$i" = 120 ] && die "Kubernetes API on $ip did not come up"
done
KUBECONFIG=$dir/kubeconfig "$kubectl" wait --for=condition=Ready node --all --timeout=600s >/dev/null
# the gvisor extension only adds the runsc handler to containerd; pods select it by RuntimeClass
printf 'apiVersion: node.k8s.io/v1\nkind: RuntimeClass\nmetadata:\n  name: gvisor\nhandler: runsc\n' |
	KUBECONFIG=$dir/kubeconfig "$kubectl" apply -f - >/dev/null
log "Talos $TALOS_VERSION ready on $name: $(KUBECONFIG=$dir/kubeconfig "$kubectl" get nodes --no-headers | awk '{print $1, $2, $5}')"
log "kubeconfig: $dir/kubeconfig, talosconfig: $dir/talosconfig"
