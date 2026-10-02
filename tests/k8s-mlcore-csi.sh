#!/usr/bin/env bash
# Kubernetes: the colleagues' CSI driver (mlcore.daos.csi), original or fixed, in the cases where it broke
# needs: server
# Run by "lab test k8s-mlcore-csi <k8s vm> VARIANT=orig|fixed IMAGE=<registry image:tag>".
# The manifests are their Helm chart rendered by helm (tests/k8s/mlcore/<variant>.yaml), with the
# image of a lab build of their driver (their Dockerfile, the lab's DAOS client). VARIANT orig is
# the driver as received; fixed has the fixes of DaosInmapPatch/colleagues-csi/fixed. The same
# checks run on both: orig is expected to fail some of them. Volumes are static PVs on a DAOS
# container of $POOL. dfuse gets --multi-user --allow-idmap: from the PVs' mountOptions in orig,
# from dfuse.defaultArgs in fixed. KEEP=1 leaves everything for inspection.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
VARIANT=${VARIANT:?orig or fixed}
IMAGE=${IMAGE:?image of the driver, e.g. IMAGE=$REGISTRY/mlcore-csi:fixed-v2.8.0}
NS=dcd
APP=mlcore-test
CONT=mlcore-test
ARGS="--multi-user --allow-idmap"
pv_opts=$ARGS
[ "$VARIANT" = fixed ] && pv_opts=""

driver_pod() { kubectl -n $NS get pods -l app=daos-csi-driver -o jsonpath='{.items[0].metadata.name}'; }
dexec() { kubectl -n $NS exec "$(driver_pod)" -c driver -- "$@"; }
pv() { # name -> static PV and PVC <name> on the test container
	kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolume
metadata: {name: $APP-$1}
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: daos-storage-class
  claimRef: {namespace: $APP, name: $1}
  csi:
    driver: mlcore.daos.csi
    volumeHandle: $APP-$1
    volumeAttributes: {poolID: "$POOL", containerID: $CONT, mountOptions: "$pv_opts"}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $1, namespace: $APP}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: daos-storage-class
  volumeName: $APP-$1
  resources: {requests: {storage: 1Gi}}
EOF
}
pod() { # name pvc hostUsers uid [agent] -> pod sleeping with the PVC at /data
	local agent_mount="" agent_vol=""
	if [ "${5:-}" = agent ]; then
		agent_mount="- {name: agent, mountPath: /var/run/daos_agent}"
		agent_vol="- {name: agent, hostPath: {path: /var/run/daos_agent, type: Directory}}"
	fi
	kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $APP}
spec:
  hostUsers: $3
  terminationGracePeriodSeconds: 1
  securityContext: {runAsUser: $4, runAsGroup: $4}
  containers:
  - name: t
    image: $IMAGE
    command: [sleep, infinity]
    volumeMounts:
    - {name: d, mountPath: /data}
    $agent_mount
  volumes:
  - {name: d, persistentVolumeClaim: {claimName: $2}}
  $agent_vol
EOF
}
ready() { kubectl -n $APP wait --for=condition=Ready pod/"$1" --timeout="${2:-180s}" >/dev/null 2>&1 && echo yes || echo no; }
reads() { timeout 20 kubectl -n $APP exec "$1" -- timeout 10 cat /data/hello 2>/dev/null | grep -q hello && echo ok || echo fail; }
replicas() { # name pvc count
	kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: $1, namespace: $APP}
spec:
  replicas: $3
  selector: {matchLabels: {run: $1}}
  template:
    metadata: {labels: {run: $1}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
      - {name: t, image: $IMAGE, command: [sleep, infinity], volumeMounts: [{name: d, mountPath: /data}]}
      volumes: [{name: d, persistentVolumeClaim: {claimName: $2}}]
EOF
}
cleanup() {
	kubectl delete ns $APP --wait=false >/dev/null 2>&1
	# pods whose unpublish was lost keep a mount on the node and never finish: free them
	for _ in $(seq 1 60); do
		kubectl get ns $APP >/dev/null 2>&1 || break
		for m in $(grep " /var/lib/kubelet/pods/.*mlcore-test" /proc/mounts | cut -d' ' -f2); do umount -l "$m"; done
		sleep 3
	done
	for p in $(kubectl get pv -o name | grep "/$APP-"); do kubectl patch "$p" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1; kubectl delete "$p" --wait=false >/dev/null 2>&1; done
	for va in $(kubectl get volumeattachment -o jsonpath='{range .items[?(@.spec.attacher=="mlcore.daos.csi")]}{.metadata.name} {end}'); do
		kubectl patch volumeattachment "$va" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
	done
	dexec daos cont destroy "$POOL" $CONT >/dev/null 2>&1
	sed -e "s#MLCORE_REPO:MLCORE_TAG#$IMAGE#g" k8s/mlcore/$VARIANT.yaml | kubectl delete -f - --wait=true >/dev/null 2>&1
	kubectl delete ns $NS --wait=true >/dev/null 2>&1
	for m in $(grep " /var/lib/kubelet/plugins/kubernetes.io/csi/mlcore.daos.csi" /proc/mounts | cut -d' ' -f2); do umount -l "$m"; done
}

cleanup
kubectl create ns $NS >/dev/null
kubectl label ns $NS pod-security.kubernetes.io/enforce=privileged >/dev/null
sed -e "s#MLCORE_REPO:MLCORE_TAG#$IMAGE#g" -e "s#defaultArgs: \"--multi-user\"#defaultArgs: \"$ARGS\"#" \
	k8s/mlcore/$VARIANT.yaml | kubectl apply -f - >/dev/null
kubectl -n $NS rollout status ds/daos-csi-driver --timeout=300s >/dev/null
kubectl -n $NS rollout status sts/daos-csi-driver-attacher --timeout=300s >/dev/null
for _ in $(seq 1 30); do
	kubectl get csinode "$(hostname -s)" -o jsonpath='{.spec.drivers[*].name}' | grep -q mlcore && break
	sleep 2
done
check "driver registered" yes "$(kubectl get csinode "$(hostname -s)" -o jsonpath='{.spec.drivers[*].name}' | grep -q mlcore && echo yes || echo no)"
dexec daos cont create "$POOL" $CONT --type POSIX >/dev/null 2>&1
kubectl create ns $APP >/dev/null

# 1. pods on one volume: root with the agent socket (IL), uid 1000, a user namespace
pv data
pod root data true 0 agent
pod user data true 1000
pod userns data false 0
check "root pod runs" yes "$(ready root)"
kubectl -n $APP exec root -- sh -c 'echo hello > /data/hello; mkdir -p /data/u1000; chown 1000:1000 /data/u1000; chmod 644 /data/hello'
check "uid 1000 pod writes its directory" ok \
	"$( [ "$(ready user)" = yes ] && kubectl -n $APP exec user -- sh -c 'echo x > /data/u1000/f && echo ok' 2>&1)"
check "hostUsers: false pod runs and reads (dfuse --allow-idmap)" ok \
	"$( [ "$(ready userns)" = yes ] && reads userns || echo "not running")"
n=$(kubectl -n $APP exec root -- sh -c 'D_IL_REPORT=1 LD_PRELOAD=/opt/daos/lib64/libpil4dfs.so dd if=/dev/zero of=/data/il bs=1M count=4 2>&1' |
	sed -n 's/.*op_sum \]  *\([0-9]*\).*/\1/p')
check "libpil4dfs in the root pod intercepts with dfuse's handles ($n ops)" yes \
	"$([ "${n:-0}" -gt 0 ] && echo yes || echo no)"
check "pods start without a VolumeAttachment (no attach step, no single attacher in the way)" 0 \
	"$(kubectl get volumeattachment -o jsonpath='{range .items[?(@.spec.attacher=="mlcore.daos.csi")]}{.metadata.name}{"\n"}{end}' | grep -c .)"

# 2. many pods of one volume started and deleted at once
pv many
nomount=0 stuck=0
for round in 1 2; do
	replicas r many 8
	kubectl -n $APP rollout status deploy/r --timeout=240s >/dev/null 2>&1
	for p in $(kubectl -n $APP get pods -l run=r -o name); do
		kubectl -n $APP exec "$p" -- grep -q " /data fuse.daos" /proc/self/mounts 2>/dev/null || nomount=$((nomount + 1))
	done
	kubectl -n $APP delete deploy r --wait=false >/dev/null
	for _ in $(seq 1 40); do [ "$(kubectl -n $APP get pods -l run=r --no-headers 2>/dev/null | wc -l)" -eq 0 ] && break; sleep 3; done
	s=$(kubectl -n $APP get pods -l run=r --no-headers 2>/dev/null | wc -l)
	stuck=$((stuck + s))
	# free stuck pods for the next round
	for m in $(grep " /var/lib/kubelet/pods/.*/$APP-many/mount" /proc/mounts | cut -d' ' -f2); do umount -l "$m"; done
	for _ in $(seq 1 40); do [ "$(kubectl -n $APP get pods -l run=r --no-headers 2>/dev/null | wc -l)" -eq 0 ] && break; sleep 3; done
done
check "16 pods started at once: pods without the dfuse mount" 0 "$nomount"
check "16 pods deleted at once: pods stuck with a mount left behind" 0 "$stuck"

# 3. the driver pod restarts (upgrade, OOM, liveness): running pods keep their volume
kubectl -n $NS delete pod "$(driver_pod)" --wait=true >/dev/null
kubectl -n $NS rollout status ds/daos-csi-driver --timeout=300s >/dev/null
sleep 5
check "driver restarted: the running root pod still reads its volume" ok "$(reads root)"
check "driver restarted: a new pod on the volume starts and reads" ok \
	"$(pod late data true 0; [ "$(ready late)" = yes ] && reads late || echo "not running")"

# 4. dfuse of the volume dies: a new pod on the volume must still get it
pv crash
pod c1 crash true 0
ready c1 >/dev/null
kubectl -n $APP exec c1 -- sh -c 'echo hello > /data/hello'
# kubelet names the staging directory after the sha256 of the volume handle
staging=/var/lib/kubelet/plugins/kubernetes.io/csi/mlcore.daos.csi/$(printf %s "$APP-crash" | sha256sum | cut -d' ' -f1)/globalmount
pids=$(pgrep -f -- "dfuse.* --mountpoint $staging ")
check "dfuse of the volume found" yes "$([ -n "$pids" ] && echo yes || echo no)"
kill -KILL $pids 2>/dev/null
sleep 10
pod c2 crash true 0
check "dfuse died: a new pod on the volume starts and reads" ok \
	"$([ "$(ready c2 240s)" = yes ] && reads c2 || echo "not running: $(kubectl -n $APP get events --field-selector involvedObject.name=c2 -o jsonpath='{.items[-1:].message}' | cut -c1-120)")"

[ "${KEEP:-0}" = 1 ] || cleanup
report "k8s-mlcore-csi: $VARIANT, $IMAGE"
