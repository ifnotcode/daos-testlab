#!/usr/bin/env bash
# Kubernetes: many pods, with and without user namespaces, on one volume of dfuse --allow-idmap
# needs: server
# Run by "lab test k8s-multi-pod <k8s or talos vm> CLIENT_IMAGE=@<build>" with a CSI image of a
# patched build ("lab csi") and a kernel >= 6.12. The pods of k8s/multi-pod.yaml sleep; this script
# does the steps in order with kubectl exec:
# - 8 user-namespaced pods (5 of them writers with uid 1000 and 2000, each pod its own uid range)
#   and 2 pods without user namespaces on the same volume: data, owners, permissions between them;
# - owners outside the range of a user namespace, subPath and readOnly mounts;
# - interception libraries in parallel in a pod with and one without a user namespace: dfuse must
#   tell every caller apart;
# - a pod replaced while the others do I/O, and a second dfuse (a static PV of the same container).
# KEEP=1 leaves the namespace for inspection.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
CLIENT_IMAGE=${CLIENT_IMAGE:?image with the DAOS client, e.g. CLIENT_IMAGE=@<build>}
[ "${CLIENT_IMAGE:0:1}" = @ ] && CLIENT_IMAGE=$REGISTRY/daos-client:${CLIENT_IMAGE:1}
NS=multi-pod-test
k() { kubectl -n $NS "$@"; }
kx() { local p=$1; shift; kubectl -n $NS exec "$p" -- sh -c "$*" 2>/dev/null; }
pods() { k get pod -l app="$1" -o jsonpath='{.items[*].metadata.name}'; }
cleanup() {
	kubectl delete ns $NS --ignore-not-found --wait=true >/dev/null 2>&1
	kubectl delete pv multi-pod-second --ignore-not-found >/dev/null 2>&1
	kubectl delete sc daos-multi-pod --ignore-not-found >/dev/null 2>&1
}

cleanup
sed -e "s#@CLIENT_IMAGE@#$CLIENT_IMAGE#" -e "s#@POOL@#$POOL#" \
	-e "s#@MAPPED_USER@#${AGENT_DEFAULT_USER%%:*}#" k8s/multi-pod.yaml | kubectl apply -f - >/dev/null
k wait --for=condition=Ready pod --all --timeout=300s >/dev/null 2>&1
running=$(k get pod --no-headers | awk '$3 == "Running"' | wc -l)
check "all 10 pods on the volume run (8 with user namespaces)" 10 "$running"
[ "$running" = 10 ] || { k get pod; report "k8s-multi-pod: pods did not start"; exit 1; }
A=($(pods writers-a)) B=($(pods writers-b))
USERNS=("${A[@]}" "${B[@]}" subpath readonly il-userns)

# every user-namespaced pod has a range of host uids of its own
maps=$(for p in "${USERNS[@]}"; do kx "$p" "awk 'NR == 1 {print \$2}' /proc/self/uid_map"; done)
check "user namespaces: ${#USERNS[@]} distinct host uid ranges" "${#USERNS[@]}" \
	"$(echo "$maps" | grep -v '^0$' | sort -u | wc -l)"

# 5 writers at the same time, then every pod checks every file
kx viewer "mkdir -p /data/w /data/p /data/sub && chmod 777 /data/w /data/p /data/sub"
for p in "${A[@]}" "${B[@]}"; do
	kx "$p" "head -c 4194304 /dev/urandom >/data/w/$p.dat && md5sum /data/w/$p.dat >/data/w/$p.md5" &
done
wait
# md5sum -c as both busybox and coreutils have it
verify='bad=0; n=0; for f in /data/w/*.md5; do n=$((n + 1)); md5sum -c "$f" >/dev/null 2>&1 || bad=$((bad + 1)); done; echo "$n $bad"'
for p in "${A[@]}" "${B[@]}" viewer il-host il-userns; do
	check "data: $p reads all 5 files intact (files, bad)" "5 0" "$(kx "$p" "$verify")"
done

# owners: as stored in DAOS (viewer, no user namespace) and as seen in a user namespace
owners() { kx "$1" "stat -c %u:%g /data/w/$2-*.dat | sort -u | tr '\n' ' '"; }
check "owners in DAOS of writers-a files" "1000:1000 " "$(owners viewer writers-a)"
check "owners in DAOS of writers-b files" "2000:2000 " "$(owners viewer writers-b)"
check "owners of writers-b files seen in writers-a" "2000:2000 " "$(owners "${A[0]}" writers-b)"
check "owners of writers-a files seen in writers-b" "1000:1000 " "$(owners "${B[0]}" writers-a)"

# permissions between pods: same uid in another user namespace, another uid, a 0600 file
kx "${A[0]}" "echo a >/data/p/a0 && chmod 644 /data/p/a0 && echo s >/data/p/secret && chmod 600 /data/p/secret"
try() { kx "$1" "$2" >/dev/null && echo allowed || echo denied; }
check "uid 1000 of another pod writes a 0644 file of uid 1000" allowed "$(try "${A[1]}" "echo x >>/data/p/a0")"
check "uid 2000 writes a 0644 file of uid 1000" denied "$(try "${B[0]}" "echo x >>/data/p/a0")"
check "uid 1000 of another pod reads a 0600 file of uid 1000" allowed "$(try "${A[2]}" "cat /data/p/secret")"
check "uid 2000 reads a 0600 file of uid 1000" denied "$(try "${B[1]}" "cat /data/p/secret")"
check "root of a user namespace writes a 0644 file of uid 1000" allowed \
	"$(try il-userns "echo r >>/data/p/a0")"

# an owner outside the uid range of the user namespaces
kx viewer "echo o >/data/p/outside && chown 70000:70000 /data/p/outside && chmod 666 /data/p/outside"
check "owner 70000 (not mapped) seen in a user namespace" "65534:65534" \
	"$(kx "${A[0]}" "stat -c %u:%g /data/p/outside")"
check "uid 1000 writes a 0666 file of an unmapped owner" denied \
	"$(try "${A[0]}" "echo x >>/data/p/outside")"
check "root of a user namespace gives a file to an unmapped uid" denied \
	"$(try il-userns "chown 70000 /data/p/a0")"

# subPath and readOnly mounts
kx subpath "echo s >/data/in-sub"
check "subPath: file in the subdirectory, owner in DAOS" "1000:1000" \
	"$(kx viewer "stat -c %u:%g /data/sub/in-sub")"
check "readOnly mount: write" denied "$(try readonly "touch /data/p/ro")"
check "readOnly mount: data" "5 0" "$(kx readonly "$verify")"

# interception libraries in parallel in two pods: 8 libpil4dfs and 4 libioil processes each
il='f=$(ls /data/w/*.dat | head -1); want=$(md5sum <"$f" | cut -d" " -f1)
	for i in 1 2 3 4 5 6 7 8; do
		(o=$(LD_PRELOAD=libpil4dfs.so D_IL_REPORT=1 D_IL_NO_BYPASS=1 md5sum "$f" 2>/tmp/p$i)
		 [ "${o%% *}" = "$want" ] && echo ok >/tmp/p$i.ok) &
	done
	for i in 1 2 3 4; do
		(LD_PRELOAD=libioil.so D_LOG_FILE=/tmp/i$i.log D_LOG_MASK=DEBUG DD_MASK=all \
			dd if="$f" of=/tmp/i$i.dat bs=64k 2>/dev/null
		 [ "$(md5sum </tmp/i$i.dat | cut -d" " -f1)" = "$want" ] && echo ok >/tmp/i$i.ok) &
	done
	wait
	pil=0; for i in 1 2 3 4 5 6 7 8; do
		n=$(sed -n "s/^\[op_sum *\] *\([0-9]*\).*/\1/p" /tmp/p$i | tail -1); [ "${n:-0}" -gt 0 ] && pil=$((pil + 1))
	done
	dfuse=0; for i in 1 2 3 4; do grep -q "ioil_fetch_cont_handles() ioctl returned" /tmp/i$i.log && dfuse=$((dfuse + 1)); done
	echo "correct $(ls /tmp/*.ok | wc -l) pil4dfs-intercepting $pil ioil-with-dfuse-handles $dfuse"'
kubectl -n $NS exec il-host -- bash -c "$il" >/tmp/il-host.out 2>/dev/null &
kubectl -n $NS exec il-userns -- bash -c "$il" >/tmp/il-userns.out 2>/dev/null &
wait
check "IL in parallel, no user namespace: correct, pil4dfs with dfuse's handles, ioil with them" \
	"correct 12 pil4dfs-intercepting 8 ioil-with-dfuse-handles 4" "$(cat /tmp/il-host.out)"
check "IL in parallel, user namespace: correct, no pil4dfs interception, ioil own connection" \
	"correct 12 pil4dfs-intercepting 0 ioil-with-dfuse-handles 0" "$(cat /tmp/il-userns.out)"

# a pod replaced (its idmapped mount goes, a new one comes) while another pod reads all the time
kx "${A[1]}" 'end=$(($(date +%s) + 40)); bad=0; while [ $(date +%s) -lt $end ]; do
	for f in /data/w/*.md5; do md5sum -c "$f" >/dev/null 2>&1 || bad=$((bad + 1)); done; done
	echo $bad >/tmp/churn' &
reader=$!
k delete pod "${A[0]}" --wait=false >/dev/null
new=""
for _ in $(seq 1 60); do
	new=$(k get pod -l app=writers-a -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' |
		grep -vx -e "${A[0]}" -e "${A[1]}" -e "${A[2]}" | head -1)
	[ -n "$new" ] && k wait --for=condition=Ready "pod/$new" --timeout=5s >/dev/null 2>&1 && break
	sleep 2
done
wait $reader
check "replaced pod: the new one reads all 5 files" "5 0" "$(kx "$new" "$verify")"
check "replaced pod: reads in another pod meanwhile, failures" 0 "$(kx "${A[1]}" "cat /tmp/churn")"

# a second dfuse for the same container: static PV with the volume handle of the shared volume
handle=$(kubectl get pv "$(k get pvc shared -o jsonpath='{.spec.volumeName}')" -o jsonpath='{.spec.csi.volumeHandle}')
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolume
metadata: {name: multi-pod-second}
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  csi: {driver: csi.daos.io, volumeHandle: "$handle", volumeAttributes: {dfuseArgs: "--allow-idmap"}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: second, namespace: $NS}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: multi-pod-second
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: second-dfuse, namespace: $NS}
spec:
  hostUsers: false
  securityContext: {runAsUser: 1000, runAsGroup: 1000}
  terminationGracePeriodSeconds: 1
  containers:
  - {name: t, image: docker.io/library/busybox:1.37, command: [sleep, "36000"],
     volumeMounts: [{name: v, mountPath: /data}]}
  volumes: [{name: v, persistentVolumeClaim: {claimName: second}}]
EOF
k wait --for=condition=Ready pod/second-dfuse --timeout=180s >/dev/null 2>&1
check "second dfuse ($handle): pod runs" Running "$(k get pod second-dfuse -o jsonpath='{.status.phase}')"
check "second dfuse: reads all 5 files" "5 0" "$(kx second-dfuse "$verify")"
kx second-dfuse "echo from-second >/data/p/second"
got=missing
for _ in $(seq 1 30); do
	[ "$(kx "${A[1]}" "cat /data/p/second 2>/dev/null")" = from-second ] && { got=seen; break; }
	sleep 1
done
check "second dfuse: its new file seen through the first dfuse" seen "$got"
check "second dfuse: owner of that file in DAOS" "1000:1000" "$(kx viewer "stat -c %u:%g /data/p/second")"

[ "${KEEP:-0}" = 1 ] || cleanup
report "k8s-multi-pod: $(kubectl version 2>/dev/null | grep -i server), $(kubectl get nodes \
	-o jsonpath='{range .items[*]}{.metadata.name} {.status.nodeInfo.kernelVersion} {end}')"
