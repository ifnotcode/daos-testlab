#!/usr/bin/env bash
# Kubernetes (kubeadm) that supports pods with hostUsers: false: containerd 2.x and runc from
# upstream releases, flannel, gVisor (RuntimeClass gvisor), pulls from the lab registry.
#   role k8s:        control plane (kubeadm init); a single node also runs workloads
#   role k8s-worker: k8s.sh join <endpoint> <token> <ca cert hash>, given by bin/lab from
#                    the lab's control plane (the first VM of role k8s)
# Idempotent: kubeadm init and join only run when the node is not part of a cluster yet.
source "$(dirname "$0")/../lib/remote.sh"
# sudo's secure_path omits /usr/local, where containerd, runc and runsc are installed
export PATH=/usr/local/bin:/usr/local/sbin:$PATH

me=$(hostname -s)
node_ip=$(vm_field "$me" ip)
role=$(vm_field "$me" role)
if [ "$role" = k8s-worker ]; then
	[ "${1:-}" = join ] && [ $# -eq 4 ] || die "usage: k8s.sh join <endpoint> <token> <ca cert hash>"
fi

# DAOS servers reply to the address a client advertises (the pod IP), so pod -> storage traffic
# must not be masqueraded; the server VM routes the pod CIDR back to this node
nonat_service() {
	cat >/etc/systemd/system/daos-pod-nonat.service <<EOF
[Unit]
Description=Do not NAT pod traffic to the DAOS storage network
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'R="-s ${K8S_POD_CIDR} -d ${LAB_NET_CIDR} -m comment --comment DAOS-no-NAT -j RETURN"; iptables -t nat -C POSTROUTING \$R 2>/dev/null || iptables -t nat -I POSTROUTING 1 \$R'

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now daos-pod-nonat.service
}

# --- host prerequisites ---
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab
systemctl disable --now firewalld 2>/dev/null || true
printf 'overlay\nbr_netfilter\n' >/etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter
cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null
# shadow-utils-subid provides getsubids, which kubelet needs for user namespaces
dnf -y -q install tar bzip2 iptables-nft conntrack-tools socat fuse3 shadow-utils-subid >/dev/null

# --- containerd, runc, CNI plugins, gVisor ---
tmp=$(mktemp -d)
if [ "$(containerd --version 2>/dev/null | awk '{print $3}')" != "v$CONTAINERD_VER" ]; then
	curl -fsSL "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VER}/containerd-${CONTAINERD_VER}-linux-amd64.tar.gz" |
		tar -C /usr/local -xz
	curl -fsSL -o /usr/local/lib/systemd/system/containerd.service --create-dirs \
		"https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VER}/containerd.service"
fi
if ! runc --version 2>/dev/null | grep -q "version $RUNC_VER"; then
	curl -fsSL -o "$tmp/runc" "https://github.com/opencontainers/runc/releases/download/v${RUNC_VER}/runc.amd64"
	install -m 755 "$tmp/runc" /usr/local/sbin/runc
fi
if [ ! -x /opt/cni/bin/bridge ]; then
	mkdir -p /opt/cni/bin
	curl -fsSL "https://github.com/containernetworking/plugins/releases/download/v${CNI_VER}/cni-plugins-linux-amd64-v${CNI_VER}.tgz" |
		tar -C /opt/cni/bin -xz
fi
if [ ! -x /usr/local/bin/runsc ] || [ ! -d /usr/local/bin/gvisor-bin ]; then
	# releases since 2026-09 ship one tarball: runsc, the containerd shim, and gvisor-bin/ with
	# sidecars (gvisor_sentry, ...) that runsc requires next to itself
	url="https://storage.googleapis.com/gvisor/releases/release/${GVISOR_RELEASE}/$(uname -m)"
	(cd "$tmp" && curl -fsSLO "$url/gvisor.tar.bz2" && curl -fsSLO "$url/gvisor.tar.bz2.sha512" &&
		sha512sum -c gvisor.tar.bz2.sha512 >/dev/null && tar -xjf gvisor.tar.bz2 &&
		install -m 755 runsc containerd-shim-runsc-v1 /usr/local/bin/ &&
		rm -rf /usr/local/bin/gvisor-bin && cp -r gvisor-bin /usr/local/bin/)
fi
rm -rf "$tmp"

mkdir -p /etc/containerd
if [ ! -f /etc/containerd/config.toml ] || ! grep -q daos-testlab /etc/containerd/config.toml; then
	containerd config default >/etc/containerd/config.toml
	sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
	# registry hosts from /etc/containerd/certs.d (the lab registry is plain HTTP)
	sed -i "/io.containerd.cri.v1.images'.registry\]/,/config_path/ s#config_path = ''#config_path = '/etc/containerd/certs.d'#" \
		/etc/containerd/config.toml
	cat >>/etc/containerd/config.toml <<'EOF'

# daos-testlab: gVisor. host-uds=open lets sandboxes connect to host unix sockets
# (daos_agent.sock of the CSI agent-socket volume)
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]
  runtime_type = 'io.containerd.runsc.v1'
  [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc.options]
    TypeUrl = 'io.containerd.runsc.v1.options'
    ConfigPath = '/etc/containerd/runsc.toml'
EOF
fi
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || die "SystemdCgroup not set in containerd config"
grep -q "config_path = '/etc/containerd/certs.d'" /etc/containerd/config.toml ||
	die "containerd registry config_path not set"
printf '[runsc_config]\n  host-uds = "open"\n' >/etc/containerd/runsc.toml
# the lab registry runs on the server VM; a lab without a server (plain Kubernetes) has none
if [ -n "$SERVER_VM" ]; then
	mkdir -p "/etc/containerd/certs.d/$REGISTRY"
	cat >"/etc/containerd/certs.d/$REGISTRY/hosts.toml" <<EOF
server = "http://$REGISTRY"
[host."http://$REGISTRY"]
  capabilities = ["pull", "resolve"]
EOF
fi
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd

# --- kubeadm, kubelet, kubectl ---
cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
dnf -y -q install kubelet kubeadm kubectl cri-tools --disableexcludes=kubernetes >/dev/null
systemctl enable kubelet
# sub-id range for pods with hostUsers: false (kubelet reads the "kubelet" user entry)
id kubelet >/dev/null 2>&1 || useradd -r -s /sbin/nologin kubelet
grep -q '^kubelet:' /etc/subuid || echo 'kubelet:65536:7208960' >>/etc/subuid
grep -q '^kubelet:' /etc/subgid || echo 'kubelet:65536:7208960' >>/etc/subgid

if [ "$role" = k8s-worker ]; then
	if [ ! -f /etc/kubernetes/kubelet.conf ]; then
		# the kubelet configuration comes from the cluster (kubeadm init wrote it to a ConfigMap)
		cat >/root/kubeadm-join.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: $2
    token: $3
    caCertHashes: ["$4"]
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: ${node_ip}
EOF
		kubeadm join --config /root/kubeadm-join.yaml
		rm -f /root/kubeadm-join.yaml
	fi
	[ -n "$SERVER_VM" ] && nonat_service
	# Ready once flannel's DaemonSet runs here; the node's own credentials may read Node objects
	export KUBECONFIG=/etc/kubernetes/kubelet.conf
	for i in $(seq 1 60); do
		kubectl get node "$me" --no-headers 2>/dev/null | grep -q ' Ready ' && break
		[ "$i" = 60 ] && die "$me: node not Ready after 5 minutes"
		sleep 5
	done
	log "Kubernetes worker ready: $(kubectl get node "$me" --no-headers | awk '{print $1, $2, $5}')"
	exit 0
fi

if [ ! -f /etc/kubernetes/admin.conf ]; then
	cat >/root/kubeadm.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${node_ip}
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: ${node_ip}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: ${K8S_POD_CIDR}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
# kubeadm writes 0s, which turns off the volume stats (kubelet_volume_stats_*, NodeGetVolumeStats)
volumeStatsAggPeriod: 1m
EOF
	kubeadm init --config /root/kubeadm.yaml
fi
# clusters created before that setting
if grep -q '^volumeStatsAggPeriod: 0s' /var/lib/kubelet/config.yaml 2>/dev/null; then
	sed -i 's/^volumeStatsAggPeriod: 0s/volumeStatsAggPeriod: 1m/' /var/lib/kubelet/config.yaml
	systemctl restart kubelet
fi
home=$(getent passwd "$VM_USER" | cut -d: -f6)
mkdir -p /root/.kube "$home/.kube"
cp /etc/kubernetes/admin.conf /root/.kube/config
cp /etc/kubernetes/admin.conf "$home/.kube/config"
chown -R "$VM_USER:" "$home/.kube"
export KUBECONFIG=/etc/kubernetes/admin.conf

[ -n "$SERVER_VM" ] && nonat_service

# a single node runs the workloads itself; with workers the control plane keeps its taint
if [ -z "$(vms_with_role k8s-worker)" ]; then
	kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
fi
# flannel's manifest has 10.244.0.0/16 built in
curl -fsSL https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml |
	sed "s#10.244.0.0/16#$K8S_POD_CIDR#" | kubectl apply -f - >/dev/null
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
EOF
# this node only: workers of a lab may be stopped while the control plane is provisioned again
kubectl wait --for=condition=Ready "node/$me" --timeout=300s >/dev/null
log "Kubernetes ready on $me: $(kubectl get nodes --no-headers | awk '{print $1, $2, $5}')"
