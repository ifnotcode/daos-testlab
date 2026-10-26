#!/usr/bin/env bash
# survey.sh - read-only survey of a DAOS + Kubernetes environment, so that it can be reproduced in
# a lab. It changes nothing: it reads files and runs query commands only. It never reads Secrets,
# kubeconfigs, certificates or keys, and it masks values that look like credentials.
#
#   sudo ./survey.sh node                  on a node (k8s worker / DAOS client, DAOS server,
#                                          control plane): OS, kernel, FUSE, DAOS, fabric, runtime
#   ./survey.sh k8s                        where kubectl reaches the cluster: versions, nodes,
#                                          runtimes, storage, CSI drivers, DAOS workloads, policies
#   ./survey.sh pod <namespace> <pod>      a failing pod: spec, events, logs, its volumes, the
#                                          DAOS/CSI pods on its node
#
# Output: ./survey-<host>-<mode>-<UTC time>/ (one file per topic) and the same as .tar.gz.
# Every file starts with the command that produced it. Missing tools are skipped, not errors.
set -u
umask 077

MODE=${1:-}
case $MODE in node | k8s | pod) ;; *) sed -n '2,14p' "$0"; exit 2 ;; esac
HOST=$(hostname -s 2>/dev/null || hostname)
OUT=${SURVEY_OUT:-./survey-$HOST-$MODE-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$OUT" || exit 1
TO=""
command -v timeout >/dev/null && TO="timeout 60"
KC=${KUBECTL:-kubectl}

# Mask anything that looks like a credential: private keys, certificates, long base64 blobs,
# "token/password/secret/...: value" and the value of env entries with such names.
redact() {
	awk '
	BEGIN { for (i = 0; i < 80; i++) blob = blob "[A-Za-z0-9+/=]"; blob = blob "*" }
	/-----BEGIN [A-Z ]*PRIVATE KEY-----/ { print "<private key omitted>"; skip = 1; next }
	skip && /-----END [A-Z ]*PRIVATE KEY-----/ { skip = 0; next }
	/-----BEGIN CERTIFICATE-----/ { print "<certificate omitted>"; skip = 1; next }
	skip && /-----END CERTIFICATE-----/ { skip = 0; next }
	skip { next }
	{
		l = tolower($0)
		if (pending && l ~ /^[ \t-]*value:/) {
			sub(/value:.*/, "value: <redacted>"); print; pending = 0; next
		}
		pending = 0
		if (l ~ /name:[ \t]*"?[a-z0-9_.-]*(token|passw|secret|apikey|api_key|credential|private|auth)/)
			pending = 1
		if (l ~ /(token|passw|secret|apikey|api_key|private_key|client-key|-data|bearer|authorization|password)[a-z0-9_"-]*[ \t]*[:=]/ &&
		    l !~ /(allow_insecure|secret_dir|token_file|authkey_file|_dir"?[ \t]*[:=])/) {
			i = match($0, /[:=]/)
			v = substr($0, i + 1); gsub(/[ \t"]/, "", v)
			# a section header ("authorization:", "credential_config:") or a nested block
			if (v == "" || v == "{" || v == "[" || v == "|" || v == ">" || v == "{}" || v == "[]") { print; next }
			print substr($0, 1, i) " <redacted>"; next
		}
		# long base64-like runs: masked, unless they are hex (hashes, ids) or paths
		line = $0; out = ""
		while (match(line, blob)) {
			run = substr(line, RSTART, RLENGTH); keep = (run ~ /^[0-9a-fA-F]+$/)
			if (!keep && run ~ /\//) {
				keep = 1; n = split(run, seg, "/")
				for (k = 1; k <= n; k++)
					if (length(seg[k]) >= 64 && seg[k] !~ /^[0-9a-fA-F]+$/) keep = 0
			}
			out = out substr(line, 1, RSTART - 1) (keep ? run : "<redacted-blob>")
			line = substr(line, RSTART + RLENGTH)
		}
		print out line
	}'
}

# run <file> <command...>: append the command and its output (stdout and stderr) to <file>
run() {
	local f=$OUT/$1
	shift
	{
		printf '\n$ %s\n' "$*"
		# shellcheck disable=SC2086
		$TO "$@" 2>&1 | redact
	} >>"$f"
}

# sh_run <file> <shell snippet>: same, for pipelines
sh_run() {
	local f=$OUT/$1
	{
		printf '\n$ %s\n' "$2"
		$TO bash -c "$2" 2>&1 | redact
	} >>"$f"
}

# copy <file> <path...>: append readable files (redacted)
copy() {
	local f=$OUT/$1 p
	shift
	for p in "$@"; do
		[ -r "$p" ] && [ -f "$p" ] || continue
		{ printf '\n=== %s\n' "$p"; redact <"$p"; } >>"$f"
	done
}

have() { command -v "$1" >/dev/null 2>&1; }

node_survey() {
	[ "$(id -u)" = 0 ] || echo "not root: some files and /proc entries will be missing" >"$OUT/00-NOT-ROOT"

	# --- system ---
	copy system.txt /etc/os-release
	run system.txt uname -a
	copy system.txt /proc/cmdline
	sh_run system.txt 'stat -fc %T /sys/fs/cgroup'
	have getenforce && run system.txt getenforce
	have sestatus && run system.txt sestatus
	have aa-status && sh_run system.txt 'aa-status 2>&1 | head -20'
	run system.txt nproc
	run system.txt free -g
	sh_run system.txt 'sysctl user.max_user_namespaces kernel.unprivileged_userns_clone vm.max_map_count 2>&1'
	sh_run system.txt 'ulimit -l; ulimit -n'
	copy system.txt /etc/subuid /etc/subgid
	have getsubids && sh_run system.txt 'getsubids kubelet; getsubids -g kubelet'
	if [ -r /proc/config.gz ]; then
		sh_run kernel-config.txt 'zcat /proc/config.gz | grep -E "^CONFIG_(FUSE_FS|CUSE|USER_NS|IDMAP|INFINIBAND|RDMA_RXE|RDMA_SIW|MLX5_INFINIBAND|SECURITY_SELINUX|SECURITY_APPARMOR)"'
	elif [ -r "/boot/config-$(uname -r)" ]; then
		sh_run kernel-config.txt "grep -E '^CONFIG_(FUSE_FS|CUSE|USER_NS|IDMAP|INFINIBAND|RDMA_RXE|RDMA_SIW|MLX5_INFINIBAND|SECURITY_SELINUX|SECURITY_APPARMOR)' /boot/config-$(uname -r)"
	fi
	sh_run kernel-config.txt 'lsmod | grep -E "^(fuse|rdma|ib_|mlx|rxe|siw|cxi|irdma|bnxt_re)" || true'

	# --- FUSE ---
	sh_run fuse.txt 'ls -l /dev/fuse'
	copy fuse.txt /etc/fuse.conf
	have fusermount3 && run fuse.txt fusermount3 --version
	sh_run fuse.txt 'findmnt -rn -t fuse,fuse3,fuse.daos,fuseblk -o TARGET,SOURCE,FSTYPE,OPTIONS || true'

	# --- DAOS packages and binaries ---
	have rpm && sh_run daos-packages.txt 'rpm -qa | grep -iE "daos|mercury|libfabric|fused|^fuse|argobots|isa-l|pmdk|spdk|ucx|rdma-core|libibverbs|hwloc" | sort'
	have dpkg && sh_run daos-packages.txt 'dpkg -l | grep -iE "daos|mercury|libfabric|fuse|argobots|isa-l|pmdk|spdk|ucx|rdma-core|ibverbs|hwloc"'
	sh_run daos-packages.txt 'ls -la /opt/daos /opt/daos/bin 2>&1 | head -60'
	local b
	for b in $(command -v dfuse) /opt/daos/bin/dfuse /usr/bin/dfuse; do
		[ -x "$b" ] || continue
		{
			printf '\n### %s\n' "$b"
			$TO "$b" --version 2>&1 | head -5
			printf -- '--allow-idmap in --help: '; $TO "$b" --help 2>&1 | grep -c -- '--allow-idmap'
			echo 'patch messages in binary (PR 1+2: "allowed" and "Kernel ..."; PR 1 alone: "Fuse library ..."; none: no patch):'
			grep -aoE 'Idmapped mounts allowed|Kernel does not support idmapped mounts|Fuse library does not support idmapped mounts' "$b" | sort -u | sed 's/^/  /'
			ldd "$b" 2>&1 | grep -iE 'fuse|daos|fabric|mercury'
		} >>"$OUT/daos-binaries.txt" 2>&1
	done
	for b in daos daos_agent daos_server dmg; do
		have "$b" && sh_run daos-binaries.txt "$b version 2>&1 | head -3"
	done

	# --- DAOS configuration and services (certificates: names only) ---
	copy daos-config.txt /etc/daos/daos_agent.yml /etc/daos/daos_control.yml /etc/daos/daos_server.yml
	sh_run daos-config.txt 'ls -la /etc/daos /etc/daos/certs 2>&1'
	sh_run daos-services.txt 'systemctl list-units --all --no-pager | grep -iE "daos|dfuse" || true'
	local u
	for u in daos_agent daos_server; do
		systemctl cat "$u" >/dev/null 2>&1 || continue
		run daos-services.txt systemctl status "$u" --no-pager -l
		run daos-services.txt systemctl cat "$u"
		sh_run daos-services.txt "journalctl -u $u --no-pager -n 150"
	done
	for u in $(systemctl list-units --all --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -i dfuse); do
		run daos-services.txt systemctl cat "$u"
		run daos-services.txt systemctl status "$u" --no-pager -l
	done
	local log
	for log in /tmp/daos_agent.log /var/log/daos/daos_agent.log /tmp/daos_server.log /var/log/daos_server.log; do
		[ -r "$log" ] && sh_run daos-logs.txt "tail -n 200 $log"
	done
	if [ -r /etc/daos/daos_control.yml ] && have dmg && [ "$(id -u)" = 0 ]; then
		sh_run daos-system.txt 'dmg -o /etc/daos/daos_control.yml system query -v'
		sh_run daos-system.txt 'dmg -o /etc/daos/daos_control.yml pool list -v'
	fi
	have daos_agent && sh_run daos-fabric.txt 'daos_agent net-scan 2>&1 | head -60'
	have daos_server && sh_run daos-fabric.txt 'daos_server network scan 2>&1 | head -60'

	# --- running dfuse processes, also inside containers (host PID view) ---
	local pid exe
	for pid in $(pgrep -x dfuse 2>/dev/null); do
		{
			printf '\n### dfuse pid %s\n' "$pid"
			printf 'cmdline: '; tr '\0' ' ' <"/proc/$pid/cmdline"; echo
			grep -E '^(Uid|Gid|NSpid|CapEff):' "/proc/$pid/status"
			printf 'user ns: '; readlink "/proc/$pid/ns/user"; printf 'pid ns: '; readlink "/proc/$pid/ns/pid"
			printf 'host user ns: '; readlink /proc/1/ns/user
			printf 'cgroup: '; head -1 "/proc/$pid/cgroup"
			echo 'environment (DAOS, fabric and log variables only):'
			tr '\0' '\n' <"/proc/$pid/environ" | grep -E '^(D_|DD_|FI_|CRT_|OFI_|HG_|DAOS|UCX_|LD_PRELOAD)' | redact
			echo 'fuse mounts in its mount namespace:'
			grep -E 'fuse' "/proc/$pid/mountinfo"
			exe=$(readlink "/proc/$pid/exe")
			printf 'binary (inside its root): %s\n' "$exe"
			echo 'patch messages in binary (PR 1+2: "allowed" and "Kernel ..."; PR 1 alone: "Fuse library ..."; none: no patch):'
			grep -aoE 'Idmapped mounts allowed|Kernel does not support idmapped mounts|Fuse library does not support idmapped mounts' "/proc/$pid/exe" | sort -u | sed 's/^/  /'
			printf -- '--allow-idmap known by binary: '; grep -ao -- '--allow-idmap' "/proc/$pid/exe" | sort -u | wc -l
			printf 'version (run in its mount namespace): '
			have nsenter && $TO nsenter -t "$pid" -m -- "$exe" --version 2>&1 | head -3
			local dlog
			dlog=$(tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^D_LOG_FILE=//p')
			if [ -n "$dlog" ] && [ -r "/proc/$pid/root$dlog" ]; then
				echo "log $dlog: idmap lines and last errors"
				grep -E 'Idmapped|idmap|Fuse library|Kernel does not support' "/proc/$pid/root$dlog" | tail -20
				grep -E ' ERR | CRIT | EMRG ' "/proc/$pid/root$dlog" | tail -20
			fi
		} 2>&1 | redact >>"$OUT/dfuse-processes.txt"
	done
	[ -s "$OUT/dfuse-processes.txt" ] || echo "no dfuse process on this node" >"$OUT/dfuse-processes.txt"

	# --- fabric ---
	sh_run fabric.txt 'ip -br link; ip -br addr'
	sh_run fabric.txt 'ip route'
	have lspci && sh_run fabric.txt 'lspci | grep -iE "mellanox|infiniband|ethernet|network|cxi|slingshot|intel corporation .*(e810|columbiaville)"'
	have rdma && sh_run fabric.txt 'rdma link show; rdma system show'
	have ibv_devinfo && sh_run fabric.txt 'ibv_devinfo | grep -E "hca_id|transport|fw_ver|vendor_part_id|state|link_layer|active_mtu|max_cqe"'
	sh_run fabric.txt 'ls -l /dev/infiniband 2>&1'
	have fi_info && sh_run fabric.txt 'fi_info -l 2>&1 | head -40'
	[ -x /opt/daos/prereq/release/ofi/bin/fi_info ] && sh_run fabric.txt '/opt/daos/prereq/release/ofi/bin/fi_info -l 2>&1 | head -40'
	have ucx_info && sh_run fabric.txt 'ucx_info -v; ucx_info -d | grep -E "Transport|Device" | head -40'

	# --- Kubernetes node: kubelet, container runtime, OCI runtimes (kubeconfigs are not read) ---
	have kubelet && run k8s-node.txt kubelet --version
	sh_run k8s-node.txt 'ps -eo args | grep -E "^/[^ ]*kubelet " | head -2'
	have systemctl && systemctl cat kubelet >/dev/null 2>&1 && run k8s-node.txt systemctl cat kubelet
	copy k8s-node.txt /var/lib/kubelet/config.yaml /etc/kubernetes/kubelet-config.yaml \
		/etc/rancher/rke2/config.yaml /etc/rancher/k3s/config.yaml
	have containerd && run k8s-node.txt containerd --version
	copy k8s-node.txt /etc/containerd/config.toml /var/lib/rancher/rke2/agent/etc/containerd/config.toml \
		/var/lib/rancher/k3s/agent/etc/containerd/config.toml
	sh_run k8s-node.txt 'ls -la /etc/containerd/conf.d /etc/containerd/certs.d 2>&1 | head -30'
	have crio && run k8s-node.txt crio --version
	sh_run k8s-node.txt 'cat /etc/crio/crio.conf /etc/crio/crio.conf.d/* 2>/dev/null | grep -vE "^\s*#|^\s*$"'
	local r
	for r in runc crun runsc kata-runtime; do have "$r" && sh_run k8s-node.txt "$r --version 2>&1 | head -3"; done
	sh_run k8s-node.txt 'ls -la /usr/local/sbin/runc /usr/local/bin/runc /usr/bin/runc /usr/bin/crun /usr/local/bin/runsc 2>/dev/null'
	have crictl && sh_run k8s-node.txt 'crictl version; crictl info 2>/dev/null | grep -iE "runtimeType|runtimes|userns|idmap|enableSelinux|cgroup|runtimeHandler|features" | head -60'
}

k8s_survey() {
	have "$KC" || { echo "no $KC" >"$OUT/ERROR"; return; }
	run cluster.txt "$KC" version -o yaml
	run cluster.txt "$KC" get nodes -o wide --show-labels
	run cluster.txt "$KC" get nodes -o "custom-columns=NAME:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion,OS:.status.nodeInfo.osImage,RUNTIME:.status.nodeInfo.containerRuntimeVersion,KUBELET:.status.nodeInfo.kubeletVersion,ARCH:.status.nodeInfo.architecture"
	sh_run cluster.txt "$KC get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"\\n  allocatable: \"}{.status.allocatable}{\"\\n  taints: \"}{.spec.taints}{\"\\n  runtimeHandlers: \"}{.status.runtimeHandlers}{\"\\n  features: \"}{.status.features}{\"\\n\"}{end}'"
	local n
	# kubelet configuration as the kubelet reads it (feature gates, userNamespaces); pretty-printed,
	# so that masking works line by line
	for n in $($KC get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
		sh_run kubelet-configz.txt "$KC get --raw /api/v1/nodes/$n/proxy/configz | { python3 -m json.tool 2>/dev/null || tr ',' '\\n'; }"
	done
	sh_run cluster.txt "$KC get pods -A -o wide"
	sh_run control-plane.txt "$KC -n kube-system get pods -l component=kube-apiserver -o jsonpath='{range .items[*].spec.containers[*]}{.command}{\"\\n\"}{end}' | tr ',' '\\n' | grep -iE 'feature|admission|version|runtime' || true"
	run storage.txt "$KC" get csidrivers -o yaml
	run storage.txt "$KC" get csinodes -o yaml
	run storage.txt "$KC" get storageclass -o yaml
	run storage.txt "$KC" get runtimeclass -o yaml
	sh_run storage.txt "$KC get pv -o wide; $KC get pvc -A -o wide"
	sh_run storage.txt "$KC get pv -o yaml | grep -iE -B3 -A25 'driver: .*(daos|dcd|mlcore)' | head -400"
	run security.txt "$KC" get ns --show-labels
	sh_run security.txt "$KC get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name"
	sh_run security.txt "$KC get scc 2>/dev/null || echo 'no SecurityContextConstraints (not OpenShift)'"
	sh_run security.txt "$KC get clusterpolicies.kyverno.io,constraints 2>/dev/null | head -50 || true"
	sh_run network.txt "$KC get ds,deploy -A -o wide | grep -iE 'calico|cilium|flannel|ovn|antrea|weave|multus|sriov|rdma|network-operator|whereabouts|kube-proxy|NAMESPACE'"
	sh_run network.txt "$KC get network-attachment-definitions -A 2>/dev/null || true"
	sh_run network.txt "$KC -n kube-system get cm kube-proxy -o yaml 2>/dev/null | grep -E 'mode:|clusterCIDR' ; $KC get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.podCIDR}{\"\\n\"}{end}'"
	# DAOS-related workloads: anything whose name or image mentions daos, dfuse, dcd or mlcore
	local ns
	sh_run daos-workloads.txt "$KC get ds,deploy,sts,pods -A -o wide | grep -iE 'daos|dfuse|dcd|mlcore|NAMESPACE'"
	for ns in $($KC get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.spec.containers[*].image}{"\n"}{end}' 2>/dev/null |
		grep -iE 'daos|dfuse|dcd|mlcore' | awk '{print $1}' | sort -u); do
		sh_run "daos-ns-$ns.txt" "$KC -n $ns get ds,deploy,sts -o yaml"
		sh_run "daos-ns-$ns.txt" "$KC -n $ns get cm -o yaml"
		sh_run "daos-ns-$ns.txt" "$KC -n $ns get pods -o wide"
		local p
		for p in $($KC -n "$ns" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
			sh_run "daos-ns-$ns-logs.txt" "$KC -n $ns logs $p --all-containers --tail=200 --prefix"
		done
	done
	have helm && sh_run helm.txt 'helm list -A'
	if have helm; then
		local rel
		helm list -A 2>/dev/null | awk 'NR>1 {print $1, $2}' | grep -iE 'daos|dcd|mlcore|csi' | while read -r rel ns; do
			sh_run helm.txt "helm -n $ns get values $rel"
			sh_run helm.txt "helm -n $ns status $rel | head -20"
		done
	fi
	sh_run events.txt "$KC get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -200"
}

pod_survey() {
	local ns=${2:?namespace} pod=${3:?pod} node c pvc
	run pod.txt "$KC" -n "$ns" get pod "$pod" -o yaml
	run pod.txt "$KC" -n "$ns" describe pod "$pod"
	sh_run pod-logs.txt "$KC -n $ns logs $pod --all-containers --prefix --tail=500"
	sh_run pod-logs.txt "$KC -n $ns logs $pod --all-containers --prefix --previous --tail=200"
	sh_run pod.txt "$KC -n $ns get events --field-selector involvedObject.name=$pod --sort-by=.lastTimestamp"
	for pvc in $($KC -n "$ns" get pod "$pod" -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null); do
		sh_run volumes.txt "$KC -n $ns get pvc $pvc -o yaml"
		sh_run volumes.txt "$KC get pv \$($KC -n $ns get pvc $pvc -o jsonpath='{.spec.volumeName}') -o yaml"
	done
	sh_run volumes.txt "$KC -n $ns get pod $pod -o jsonpath='{range .spec.volumes[*]}{@}{\"\\n\"}{end}'"
	node=$($KC -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
	echo "node: $node" >"$OUT/node.txt"
	[ -n "$node" ] || return
	# the DAOS / CSI pods on the same node, and their recent logs
	$KC get pods -A -o wide --field-selector "spec.nodeName=$node" 2>/dev/null | grep -iE 'daos|dfuse|dcd|mlcore|csi|NAMESPACE' >>"$OUT/node.txt"
	$KC get pods -A --field-selector "spec.nodeName=$node" -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null |
		grep -iE 'daos|dfuse|dcd|mlcore|csi' | while read -r ns2 p2; do
			sh_run node-pods-logs.txt "$KC -n $ns2 logs $p2 --all-containers --prefix --tail=300 --since=24h"
		done
}

case $MODE in
node) node_survey ;;
k8s) k8s_survey ;;
pod) pod_survey "$@" ;;
esac

tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" && echo "survey written to $OUT and $OUT.tar.gz"
echo "Review the files before sharing: values that look like credentials are masked, names and IPs are not."
