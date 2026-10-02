#!/usr/bin/env bash
# Kubernetes over RDMA: which pods reach DAOS themselves, and dfuse volumes for userns pods
# Run by "lab -c profiles/rdma.conf test k8s-rdma <k8s vm> CLIENT_IMAGE=@<build>" on a lab whose
# DAOS_PROVIDER is verbs, after "lab csi". Every pod runs "daos pool query" with its own connection
# (libdaos, as libpil4dfs and libioil do) in a different setting: device access (privileged) and
# network (pod network or hostNetwork) separately. A user-namespaced pod cannot have hostNetwork,
# so it reaches DAOS over RDMA only through a dfuse volume, whose dfuse runs in the (privileged,
# hostNetwork) mount pod: that path is checked with data. KEEP=1 leaves the namespace.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
CLIENT_IMAGE=${CLIENT_IMAGE:?image with the DAOS client, e.g. CLIENT_IMAGE=@<build>}
[ "${CLIENT_IMAGE:0:1}" = @ ] && CLIENT_IMAGE=$REGISTRY/daos-client:${CLIENT_IMAGE:1}
MAPPED_USER=${AGENT_DEFAULT_USER%%:*}
NS=rdma-test

result() { # pod key -> text after "RESULT <key> " in its log, once there
	for _ in $(seq 1 150); do
		out=$(kubectl -n $NS logs "$1" 2>/dev/null | sed -n "s/^RESULT $2 //p" | tail -1)
		[ -n "$out" ] && { echo "$out"; return; }
		sleep 2
	done
	echo "no result: $(kubectl -n $NS get pod "$1" -o jsonpath='{.status.phase} {.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)"
}

# direct <name> <hostNetwork> <privileged>: a pod that connects to the pool itself
direct() {
	cat <<EOF
---
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $NS}
spec:
  restartPolicy: Never
  hostNetwork: $2
  containers:
  - name: t
    image: $CLIENT_IMAGE
    imagePullPolicy: IfNotPresent
    securityContext: {privileged: $3}
    command: ["bash", "-c"]
    args:
    - |
      echo "devices: \$(ls /dev/infiniband 2>/dev/null | tr '\\n' ' ')"
      if out=\$(timeout 60 daos pool query $POOL 2>&1); then echo "RESULT query ok"
      else echo "\$out" | tail -3; echo "RESULT query fails"; fi
      sleep 3600
    volumeMounts: [{name: agent, mountPath: /var/run/daos_agent}]
  volumes:
  - {name: agent, csi: {driver: csi.daos.io, volumeAttributes: {type: agent-socket}}}
EOF
}

kubectl delete ns $NS --ignore-not-found --wait=true >/dev/null
kubectl delete sc daos-rdma-idmap --ignore-not-found >/dev/null
{
	cat <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: $NS}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: daos-rdma-idmap}
provisioner: csi.daos.io
parameters:
  pool: $POOL
  dfuseArgs: "--allow-idmap"
  rootUid: "0"
  rootGid: "0"
  rootMode: "0777"
  acl: "A::$MAPPED_USER@:rwta"
reclaimPolicy: Delete
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data, namespace: $NS}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: daos-rdma-idmap
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: userns-dfuse, namespace: $NS}
spec:
  hostUsers: false
  restartPolicy: Never
  containers:
  - name: t
    image: docker.io/library/busybox:1.37
    command: ["sh", "-c"]
    args:
    - |
      head -c 67108864 /dev/urandom > /tmp/data && cp /tmp/data /data/data && sync &&
        cmp /tmp/data /data/data && echo "RESULT data ok" || echo "RESULT data bad"
      echo "RESULT owner \$(stat -c %u:%g /data/data)"
      sleep 3600
    volumeMounts: [{name: v, mountPath: /data}]
  volumes: [{name: v, persistentVolumeClaim: {claimName: data}}]
EOF
	direct podnet-plain false false
	direct podnet-privileged false true
	direct hostnet-plain true false
	direct hostnet-privileged true true
} | kubectl apply -f - >/dev/null

check "pod network, unprivileged: own connection" fails "$(result podnet-plain query)"
check "pod network, privileged (RDMA devices, pod IP): own connection" fails \
	"$(result podnet-privileged query)"
check "hostNetwork, unprivileged: own connection" fails "$(result hostnet-plain query)"
check "hostNetwork, privileged: own connection" ok "$(result hostnet-privileged query)"

# the API server refuses user namespaces together with host namespaces
out=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata: {name: userns-hostnet, namespace: $NS}
spec:
  hostUsers: false
  hostNetwork: true
  containers: [{name: t, image: docker.io/library/busybox:1.37, command: [sleep, "60"]}]
EOF
)
got=accepted
echo "$out" | grep -qi "hostUsers\|host namespaces\|forbidden\|invalid" && got=rejected
check "hostUsers: false + hostNetwork: pod ${got} (${out:0:70})" rejected "$got"

check "hostUsers: false, dfuse volume (--allow-idmap, verbs in the mount pod): 64 MiB data" ok \
	"$(result userns-dfuse data)"
check "hostUsers: false, dfuse volume: file owner as seen in the pod" 0:0 "$(result userns-dfuse owner)"

for p in podnet-plain podnet-privileged hostnet-plain; do
	echo "--- $p:"; kubectl -n $NS logs $p 2>/dev/null | grep -v "^RESULT" | tail -3
done
[ "${KEEP:-0}" = 1 ] || { kubectl delete ns $NS --wait=true >/dev/null; kubectl delete sc daos-rdma-idmap >/dev/null; }
report "k8s-rdma: provider $DAOS_PROVIDER, $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.nodeInfo.kernelVersion} {end}')"
