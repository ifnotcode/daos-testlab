# "lab csi <vm> <image|@tag>": daos_agent DaemonSet, CSI driver and the no-NAT DaemonSet from
# $CSI_DIR/deploy on a k8s or talos VM, adapted to this lab (server address, pool, pod CIDR).
# "@<tag>" is $REGISTRY/daos-csi:<tag>, as pushed by "lab build csi <base> <tag>".
# shellcheck shell=bash

deploy_csi() {
	local vm=$1 image=$2 role cidr d out
	role=$(vm_field "$vm" role)
	[ "${image:0:1}" = @ ] && image=$(grep '^REGISTRY=' "$WORK/lab.env" | cut -d= -f2)/daos-csi:${image:1}
	case $role in
	k8s) cidr=$K8S_POD_CIDR ;;
	talos) cidr=$TALOS_POD_CIDR ;;
	*) die "$vm is not a Kubernetes node" ;;
	esac
	d=$CSI_DIR/deploy
	[ -f "$d/daos-csi.yaml" ] || die "no CSI manifests in $d (set CSI_DIR in lab.conf)"
	local srv_ip user group
	srv_ip=$(vm_field "$(server_vm)" ip)
	user=${AGENT_DEFAULT_USER%%:*}
	group=${AGENT_DEFAULT_USER##*:}
	out=$WORK/csi-$vm.yaml
	{
		# RDMA (a verbs provider): the controller's daos CLI and the agent's fabric scan need
		# /dev/infiniband, as dfuse in the (privileged) mount pods does. On tcp the driver's
		# unprivileged controller and agent are kept.
		rdma_ctl=0
		case $DAOS_PROVIDER in *verbs*) rdma_ctl=1 ;; esac
		sed -e "s#DAOS_CSI_IMAGE#$image#g" -e "s#^  pool: tank#  pool: $POOL#" "$d/daos-csi.yaml" |
			awk -v rdma=$rdma_ctl '{print}
				rdma && /args: \[-controller,/ {print "        securityContext: {privileged: true} # RDMA devices for the daos CLI"}'
		echo "---"
		sed -e "s#DAOS_CSI_IMAGE#$image#g" -e "s#access_points: \['[^']*'\]#access_points: ['$srv_ip']#" \
			-e "s#user: admin#user: ${user:-admin}#" -e "s#group: admin#group: ${group:-admin}#" \
			"$d/daos-agent.yaml" |
			awk -v rdma=$rdma_ctl '{print}
				rdma && /command: \[daos_agent,/ {print "        securityContext: {privileged: true} # RDMA devices for the fabric scan"}'
		echo "---"
		sed -e "s#value: \"10\.24[0-9]\.0\.0/16\"#value: \"$cidr\"#" \
			-e "s#value: \"192\.168\.122\.0/24\"#value: \"$LAB_NET_CIDR\"#" "$d/daos-pod-nonat.yaml"
	} >"$out"
	if [ "$role" = k8s ]; then
		# the DaemonSet agent serves the same socket path as the host service
		vm_ssh "$vm" 'sudo systemctl disable --now daos_agent 2>/dev/null; sudo touch /etc/daos/testlab-agent-daemonset'
	fi
	kubectl_for "$vm" apply -f - <"$out"
	kubectl_for "$vm" -n daos-csi rollout status ds/daos-agent --timeout=300s
	kubectl_for "$vm" -n daos-csi rollout status ds/daos-csi-node --timeout=300s
	kubectl_for "$vm" -n daos-csi rollout status deploy/daos-csi-controller --timeout=300s
	log "CSI driver $image deployed on $vm (manifests: $out)"
}
