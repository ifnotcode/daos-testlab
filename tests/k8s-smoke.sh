#!/usr/bin/env bash
# Kubernetes node check: node Ready, plain pod, gVisor pod (RuntimeClass gvisor), userns pod
# needs: none
# Run by "lab test k8s-smoke <k8s or talos vm>". Uses busybox from Docker Hub; no DAOS involved.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
NS=testlab-k8s-smoke

pod_log() { # pod -> its log once it has finished, or why it has not (e.g. ImagePullBackOff)
	# 5 minutes: the first busybox pull from Docker Hub on a new node can be slow
	for _ in $(seq 1 150); do
		case $(kubectl -n $NS get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null) in
		Succeeded | Failed) kubectl -n $NS logs "$1"; return ;;
		esac
		sleep 2
	done
	echo "not finished: $(kubectl -n $NS get pod "$1" \
		-o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)"
}

kubectl delete ns $NS --ignore-not-found --wait=true >/dev/null
kubectl create ns $NS >/dev/null
check "all nodes Ready" yes "$(yes_no kubectl wait --for=condition=Ready node --all --timeout=60s)"
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: plain, namespace: $NS}
spec:
  restartPolicy: Never
  containers: [{name: t, image: docker.io/library/busybox:1.37, command: [sh, -c, "echo ok"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: gvisor, namespace: $NS}
spec:
  runtimeClassName: gvisor
  restartPolicy: Never
  containers: [{name: t, image: docker.io/library/busybox:1.37, command: [sh, -c, "dmesg | head -1"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: userns, namespace: $NS}
spec:
  hostUsers: false
  restartPolicy: Never
  containers: [{name: t, image: docker.io/library/busybox:1.37, command: [sh, -c, "cat /proc/self/uid_map"]}]
EOF
check "plain pod runs" ok "$(pod_log plain)"
out=$(pod_log gvisor)
check "gVisor pod runs in the gVisor kernel" yes \
	"$(echo "$out" | grep -q gVisor && echo yes || echo "no: ${out:0:60}")"
# uid_map "0 <host uid> 65536": root of the pod is an unprivileged uid of the node
out=$(pod_log userns)
check "hostUsers: false pod gets a user namespace" yes \
	"$(echo "$out" | awk '{print ($1 == 0 && $2 > 0) ? "yes" : "no: " $0; exit}')"
kubectl delete ns $NS --wait=false >/dev/null
report "k8s-smoke: $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.nodeInfo.kubeletVersion} {.status.nodeInfo.kernelVersion} {end}')"
