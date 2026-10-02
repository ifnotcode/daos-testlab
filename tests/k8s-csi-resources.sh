#!/usr/bin/env bash
# Kubernetes: CPU and memory of dfuse in csi-daos mount pods (defaults, per-volume, rejections)
# needs: server
# Run by "lab test k8s-csi-resources <k8s vm>" after "lab csi <vm> <image>" with a csi-daos image
# that has the mount pod resource settings. Uses busybox from Docker Hub; I/O goes through dfuse.
# It patches the node plugin's arguments for the defaults check and rolls them back afterwards.
# KEEP=1 leaves the namespace for inspection.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
NS=csi-res-test
CSI_NS=daos-csi
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

sc() { # name key=value... -> StorageClass of csi.daos.io on $POOL with these parameters
	local name=$1 kv
	shift
	{
		echo "apiVersion: storage.k8s.io/v1"
		echo "kind: StorageClass"
		echo "metadata: {name: $name}"
		echo "provisioner: csi.daos.io"
		echo "reclaimPolicy: Delete"
		echo "parameters:"
		echo "  pool: \"$POOL\""
		for kv in "$@"; do echo "  ${kv%%=*}: \"${kv#*=}\""; done
	} | kubectl apply -f - >/dev/null
}
pvc_pod() { # name storageclass [command] -> PVC <name> and pod <name> using it at /data
	kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $1, namespace: $NS}
spec: {accessModes: [ReadWriteMany], storageClassName: $2, resources: {requests: {storage: 1Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $NS}
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: t
    image: docker.io/library/busybox:1.37
    command: [sh, -c, "${3:-sleep 3600}"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: $1}}]
EOF
}
running() { kubectl -n $NS wait --for=condition=Ready pod/"$1" --timeout="${2:-180s}" >/dev/null 2>&1; }
mount_pod() { # PVC -> the mount pod serving its volume on $NODE
	local pv
	pv=$(kubectl -n $NS get pvc "$1" -o jsonpath='{.spec.volumeName}')
	kubectl -n $CSI_NS get pods -o go-template='{{range .items}}{{.metadata.name}} {{with .metadata.annotations}}{{index . "daos-csi/volume"}}{{end}}{{"\n"}}{{end}}' |
		awk -v v="$POOL/$pv" '$2 == v {print $1}'
}
mp_res() { # PVC -> "cpu-request cpu-limit memory-request memory-limit" of its mount pod ("-" if unset)
	kubectl -n $CSI_NS get pod "$(mount_pod "$1")" -o go-template='{{with (index .spec.containers 0).resources}}{{or (and .requests .requests.cpu) "-"}} {{or (and .limits .limits.cpu) "-"}} {{or (and .requests .requests.memory) "-"}} {{or (and .limits .limits.memory) "-"}}{{else}}- - - -{{end}}'
}
mp_exec() { local p=$1; shift; kubectl -n $CSI_NS exec "$(mount_pod "$p")" -- "$@" 2>/dev/null; }
# The mount pod's own cgroup: mount pods have hostPID (so /proc/1 is the node's init), and the
# cgroup of a process started there by exec is the pod container's.
mp_cgroup() { # PVC file -> that cgroup file of its mount pod
	mp_exec "$1" sh -c "cat /sys/fs/cgroup\$(sed -n 's/^0:://p' /proc/self/cgroup)/$2"
}
mp_threads() { # PVC -> threads of the dfuse in its mount pod
	mp_exec "$1" sh -c 'cg=/sys/fs/cgroup$(sed -n "s/^0:://p" /proc/self/cgroup)
		for p in $(cat $cg/cgroup.procs); do
			[ "$(cat /proc/$p/comm 2>/dev/null)" = dfuse ] && sed -n "s/^Threads:\t*//p" /proc/$p/status
		done'
}
event() { # object-name text -> yes if an event about it contains the text (waits up to 2 minutes)
	for _ in $(seq 1 60); do
		kubectl -n "${3:-$NS}" get events --field-selector involvedObject.name="$1" \
			-o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -q -- "$2" && {
			echo yes
			return
		}
		sleep 2
	done
	echo no
}
millicores() { # Kubernetes CPU quantity -> millicores
	case $1 in *m) echo "${1%m}" ;; *) awk -v c="$1" 'BEGIN {printf "%d", c * 1000}' ;; esac
}
write_mbs() { # pod -> MB/s of a 256 MiB dd through dfuse
	kubectl -n $NS exec "$1" -- sh -c 'dd if=/dev/zero of=/data/f bs=1M count=256 conv=fsync 2>&1; rm -f /data/f' |
		sed -n 's/.*, \([0-9.]*\)\(MB\|M\)\/s.*/\1/p'
}

cleanup() {
	kubectl delete ns $NS --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1
	kubectl delete sc res-cap res-free res-bad res-huge res-evict res-default res-override \
		--ignore-not-found >/dev/null
}
cleanup
kubectl create ns $NS >/dev/null

# 1. Per-volume limits: applied to the mount pod and its cgroup, and they throttle dfuse
sc res-cap dfuseCpuRequest=100m dfuseCpuLimit=200m dfuseMemoryRequest=128Mi dfuseMemoryLimit=1Gi \
	dfuseArgs=--thread-count=2
sc res-free
pvc_pod cap res-cap
pvc_pod free res-free
running cap && running free
check "per-volume settings in the mount pod spec" "100m 200m 128Mi 1Gi" "$(mp_res cap)"
check "no settings: no resources" "- - - -" "$(mp_res free)"
check "cgroup cpu.max of the limited dfuse" "20000 100000" "$(mp_cgroup cap cpu.max)"
check "cgroup memory.max of the limited dfuse" 1073741824 "$(mp_cgroup cap memory.max)"
n_cap=$(mp_threads cap) n_free=$(mp_threads free)
check "dfuse threads: fewer with --thread-count=2 ($n_cap) than by default ($n_free)" yes \
	"$([ "${n_cap:-99}" -lt "${n_free:-0}" ] && echo yes || echo no)"
before=$(mp_cgroup cap cpu.stat | sed -n 's/nr_throttled //p')
cap_mbs=$(write_mbs cap)
free_mbs=$(write_mbs free)
after=$(mp_cgroup cap cpu.stat | sed -n 's/nr_throttled //p')
check "200m dfuse is throttled under load ($cap_mbs MB/s, unlimited $free_mbs MB/s)" yes \
	"$([ "${after:-0}" -gt "${before:-0}" ] && echo yes || echo "no: $before -> $after")"

# 2. A bad setting fails at provisioning, with the parameter named
sc res-bad dfuseCpuRequest=2 dfuseCpuLimit=1
pvc_pod bad res-bad
check "request above limit: provisioning fails, naming the parameter" yes "$(event bad dfuseCpuRequest)"

# 3. Requests that cannot fit the node: kubelet rejects the mount pod, the driver says why. For a
#    system-node-critical pod kubelet first looks for pods to evict, and finds none to free enough.
sc res-huge dfuseCpuRequest=64
pvc_pod huge res-huge
check "request above the node's CPUs: the pod's mount fails, saying why" yes \
	"$(event huge 'Pod was rejected.*preempt\|OutOfcpu')"
check "the rejected mount pod is not left behind" yes \
	"$([ "$(kubectl -n $CSI_NS get pods --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)" -le 1 ] && echo yes || echo no)"
kubectl -n $NS delete pod huge pvc/huge --wait=false >/dev/null 2>&1
kubectl -n $NS delete pod huge --wait=false >/dev/null 2>&1
kubectl -n $NS delete pvc huge --wait=false >/dev/null 2>&1

# 4. Requests that fit only without a lower-priority pod: kubelet evicts that pod for the
#    (system-node-critical) mount pod
alloc=$(millicores "$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.cpu}')")
used=$(kubectl describe node "$NODE" | awk '/Allocated resources/ {f=1} f && $1 == "cpu" {print $2; exit}')
free=$((alloc - $(millicores "$used")))
filler_out=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata: {name: filler, namespace: $NS}
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - {name: t, image: docker.io/library/busybox:1.37, command: [sleep, "3600"],
     resources: {requests: {cpu: "$((free - 100))m"}}}
EOF
)
running filler || echo "filler (${free}m free of ${alloc}m): $filler_out $(kubectl -n $NS get pod filler -o jsonpath='{.status.phase}' 2>&1)"
sc res-evict dfuseCpuRequest=500m
pvc_pod evict res-evict
running evict 240s
check "mount pod that does not fit next to a filler pod: the app pod runs" yes \
	"$(kubectl -n $NS get pod evict -o jsonpath='{.status.phase}' | grep -q Running && echo yes || echo no)"
check "kubelet evicted the lower-priority filler pod (${free}m free) for it" yes \
	"$(kubectl -n $NS get pod filler -o jsonpath='{.status.reason}' 2>/dev/null | grep -qi 'preempt\|evict' && echo yes ||
		echo "no: $(kubectl -n $NS get pod filler -o jsonpath='{.status.phase}/{.status.reason}' 2>/dev/null)")"
kubectl -n $NS delete pod filler evict --wait=true >/dev/null 2>&1

# 5. Defaults from the node plugin's flags, and a volume overriding one of them
kubectl -n $CSI_NS patch ds daos-csi-node --type=json -p '[
 {"op": "add", "path": "/spec/template/spec/containers/1/args/-", "value": "-mount-pod-cpu-limit=1500m"},
 {"op": "add", "path": "/spec/template/spec/containers/1/args/-", "value": "-mount-pod-memory-limit=3Gi"}]' >/dev/null
kubectl -n $CSI_NS rollout status ds/daos-csi-node --timeout=180s >/dev/null
sc res-default
sc res-override dfuseCpuLimit=700m
pvc_pod default res-default
pvc_pod override res-override
running default && running override
# a limit alone reserves nothing: request 0, not Kubernetes' default of request = limit
check "defaults from the plugin's flags (limits only: requests 0)" "0 1500m 0 3Gi" "$(mp_res default)"
check "a volume overrides one default" "0 700m 0 3Gi" "$(mp_res override)"
# dfuse does not size its threads by a CPU limit: the driver adds --thread-count = CPUs + 1 queue
mp_cmd() { kubectl -n $CSI_NS get pod "$(mount_pod "$1")" -o jsonpath='{.spec.containers[0].command}'; }
check "CPU limit 1500m: dfuse gets --thread-count=3" yes \
	"$(mp_cmd default | grep -q -- '--thread-count=3' && echo yes || echo "no: $(mp_cmd default)")"
check "--thread-count in dfuseArgs is kept as is (and not added)" "--thread-count=2" \
	"$(mp_cmd cap | grep -o -- '--thread-count=[0-9]*' | paste -sd' ')"
check "earlier mount pods keep their resources across the plugin restart" "100m 200m 128Mi 1Gi" "$(mp_res cap)"
check "and their volumes still work" ok \
	"$(kubectl -n $NS exec cap -- sh -c 'echo x > /data/y && cat /data/y >/dev/null && echo ok' 2>&1)"
kubectl -n $CSI_NS rollout undo ds/daos-csi-node >/dev/null
kubectl -n $CSI_NS rollout status ds/daos-csi-node --timeout=180s >/dev/null

# 6. maxVolumesPerNode: the scheduler places no more DAOS volumes on the node than allowed. The
#    limit is the volumes in use now plus one.
inuse=$(kubectl -n $CSI_NS get pods -l app=daos-csi-mount --no-headers 2>/dev/null | wc -l)
kubectl -n $CSI_NS patch ds daos-csi-node --type=json -p '[
 {"op": "add", "path": "/spec/template/spec/containers/1/args/-", "value": "-max-volumes-per-node='$((inuse + 1))'"}]' >/dev/null
kubectl -n $CSI_NS rollout status ds/daos-csi-node --timeout=180s >/dev/null
for _ in $(seq 1 30); do
	[ "$(kubectl get csinode "$NODE" -o jsonpath='{.spec.drivers[?(@.name=="csi.daos.io")].allocatable.count}' 2>/dev/null)" = $((inuse + 1)) ] && break
	sleep 2
done
check "CSINode allows $((inuse + 1)) volumes ($inuse in use)" $((inuse + 1)) \
	"$(kubectl get csinode "$NODE" -o jsonpath='{.spec.drivers[?(@.name=="csi.daos.io")].allocatable.count}')"
pvc_pod lim1 res-free
running lim1
check "one more volume: the pod runs" Running "$(kubectl -n $NS get pod lim1 -o jsonpath='{.status.phase}')"
pvc_pod lim2 res-free
check "a volume over the limit: the pod is not scheduled" yes "$(event lim2 'max volume count')"
kubectl -n $NS delete pod lim1 lim2 --wait=true >/dev/null 2>&1
kubectl -n $CSI_NS rollout undo ds/daos-csi-node >/dev/null
kubectl -n $CSI_NS rollout status ds/daos-csi-node --timeout=180s >/dev/null

[ "${KEEP:-0}" = 1 ] || cleanup
report "k8s-csi-resources: $NODE, $(nproc) CPUs"
