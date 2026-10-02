#!/usr/bin/env bash
# Kubernetes: csi-daos health checks of dfuse mounts: a hung dfuse, and the node losing DAOS
# needs: server
# Run by "lab test k8s-csi-health <k8s vm>" after "lab csi <vm> <image>" with a csi-daos image that
# has the health checks (-r6 or later). Runs on the node itself (kubectl, curl of the plugin's
# metrics, iptables). It sets short health check times on the node plugin and rolls them back.
#   1. dfuse is frozen (SIGSTOP): the volume turns unhealthy, dfuse is killed and restarted by its
#      mount pod, the pods' mounts are switched to the new dfuse, and a pod with a liveness probe
#      on the volume recovers by itself. A pod without one keeps the dead mount.
#   2. The node loses the DAOS servers (iptables DROP), as with a dead network port: the same,
#      once the network is back.
# KEEP=1 leaves the namespace for inspection.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
NS=csi-health-test
CSI_NS=daos-csi
METRICS=http://localhost:9810/metrics
RULE_OUT=(OUTPUT -d "$SERVER_IP" -m comment --comment csi-health-test -j DROP)
RULE_IN=(INPUT -s "$SERVER_IP" -m comment --comment csi-health-test -j DROP)

network() { # up|down: traffic between this node and the DAOS server
	if [ "$1" = down ]; then
		iptables -I "${RULE_OUT[@]}" && iptables -I "${RULE_IN[@]}"
	else
		while iptables -D "${RULE_OUT[@]}" 2>/dev/null; do :; done
		while iptables -D "${RULE_IN[@]}" 2>/dev/null; do :; done
	fi
}
cleanup() {
	network up
	kubectl delete ns $NS --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1
	kubectl delete sc health-test --ignore-not-found >/dev/null
}
restore_plugin() {
	kubectl -n $CSI_NS rollout undo ds/daos-csi-node >/dev/null
	kubectl -n $CSI_NS rollout status ds/daos-csi-node --timeout=180s >/dev/null
}
trap 'network up' EXIT

metric() { # name{labels} -> value from the node plugin
	curl -s $METRICS | awk -v m="$1" 'index($0, m " ") == 1 {print $2}'
}
wait_metric() { # name{labels} value seconds -> yes once the metric has the value
	for _ in $(seq 1 "$3"); do
		[ "$(metric "$1")" = "$2" ] && { echo yes; return; }
		sleep 1
	done
	echo "no: $(metric "$1")"
}
volume_of() { # PVC -> volume id
	echo "$POOL/$(kubectl -n $NS get pvc "$1" -o jsonpath='{.spec.volumeName}')"
}
staging_of() { # volume id -> its staging path, from the stage records
	grep -l "\"volumeID\":\"$1\"" /var/lib/kubelet/plugins/kubernetes.io/csi/csi.daos.io/*/daos-csi.json |
		xargs -r dirname | sed 's#$#/globalmount#'
}
dfuse_pid() { pgrep -f "dfuse --foreground .* $1\$" | head -1; }
reads() { # pod -> ok if it reads the test file within 10 s
	timeout 15 kubectl -n $NS exec "$1" -- timeout 10 cat /data/hello 2>/dev/null | grep -q hello && echo ok || echo fail
}
wait_reads() { # pod seconds -> ok once the pod reads the file
	for _ in $(seq 1 $(($2 / 5))); do
		[ "$(reads "$1")" = ok ] && { echo ok; return; }
		sleep 5
	done
	echo fail
}

cleanup
network up
kubectl create ns $NS >/dev/null
# short times for the test: probe every 3 s, unhealthy after 5 s, kill after 15 s more
kubectl -n $CSI_NS patch ds daos-csi-node --type=json -p '[
 {"op": "add", "path": "/spec/template/spec/containers/1/args/-", "value": "-health-interval=3s"},
 {"op": "add", "path": "/spec/template/spec/containers/1/args/-", "value": "-health-timeout=5s"},
 {"op": "add", "path": "/spec/template/spec/containers/1/args/-", "value": "-health-kill-after=15s"}]' >/dev/null
kubectl -n $CSI_NS rollout status ds/daos-csi-node --timeout=180s >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: health-test}
provisioner: csi.daos.io
reclaimPolicy: Delete
parameters: {pool: "$POOL"}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data, namespace: $NS}
spec: {accessModes: [ReadWriteMany], storageClassName: health-test, resources: {requests: {storage: 1Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: plain, namespace: $NS}
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - {name: t, image: docker.io/library/busybox:1.37, command: [sh, -c, "echo hello > /data/hello; sleep 3600"],
     volumeMounts: [{name: d, mountPath: /data}]}
  volumes: [{name: d, persistentVolumeClaim: {claimName: data}}]
---
apiVersion: v1
kind: Pod
metadata: {name: live, namespace: $NS}
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: t
    image: docker.io/library/busybox:1.37
    command: [sleep, "3600"]
    volumeMounts: [{name: d, mountPath: /data}]
    # the application's own check of its volume: a dead or hung mount restarts the container
    livenessProbe:
      exec: {command: [stat, -f, /data]}
      periodSeconds: 5
      timeoutSeconds: 3
      failureThreshold: 2
  volumes: [{name: d, persistentVolumeClaim: {claimName: data}}]
EOF
kubectl -n $NS wait --for=condition=Ready pod/plain pod/live --timeout=180s >/dev/null
VOL=$(volume_of data)
STAGING=$(staging_of "$VOL")
check "volume reported healthy" yes "$(wait_metric "daos_csi_volume_healthy{volume=\"$VOL\"}" 1 30)"
check "both pods read the volume" "ok ok" "$(reads plain) $(reads live)"
# kubelet picks up a new pod's volumes within a minute and asks for their stats once a minute
stats=no
for _ in $(seq 1 50); do
	# not "kubectl | grep -q": under pipefail, grep's early exit fails kubectl with SIGPIPE
	m=$(kubectl get --raw "/api/v1/nodes/$(hostname -s)/proxy/metrics" 2>/dev/null)
	grep -q "kubelet_volume_stats_capacity_bytes{namespace=\"$NS\",persistentvolumeclaim=\"data\"}" <<<"$m" &&
		{ stats=yes; break; }
	sleep 5
done
check "kubelet gets the volume's space (NodeGetVolumeStats)" yes $stats

kills0=$(metric daos_csi_dfuse_kills_total) kills0=${kills0:-0}
rebound0=$(metric daos_csi_targets_rebound_total) rebound0=${rebound0:-0}
restarts0=$(kubectl -n $NS get pod live -o jsonpath='{.status.containerStatuses[0].restartCount}')

# 1. a frozen dfuse
pid=$(dfuse_pid "$STAGING")
check "dfuse of the volume found" yes "$([ -n "$pid" ] && echo yes || echo no)"
kill -STOP "$pid"
check "frozen dfuse: volume unhealthy" yes "$(wait_metric "daos_csi_volume_healthy{volume=\"$VOL\"}" 0 30)"
check "frozen dfuse: killed" yes "$(wait_metric daos_csi_dfuse_kills_total $((kills0 + 1)) 60)"
check "a new dfuse serves the volume" yes "$(wait_metric "daos_csi_volume_healthy{volume=\"$VOL\"}" 1 120)"
check "both pods' mounts switched to it" yes "$(wait_metric daos_csi_targets_rebound_total $((rebound0 + 2)) 30)"
check "pod with a liveness probe on the volume reads again" ok "$(wait_reads live 180)"
check "its container was restarted (liveness)" yes \
	"$([ "$(kubectl -n $NS get pod live -o jsonpath='{.status.containerStatuses[0].restartCount}')" -gt "$restarts0" ] && echo yes || echo no)"
check "pod without one keeps the dead mount" fail "$(reads plain)"
kubectl -n $NS delete pod plain --wait=true >/dev/null 2>&1

# 2. the node loses the DAOS servers
kills1=$(metric daos_csi_dfuse_kills_total)
rebound1=$(metric daos_csi_targets_rebound_total)
network down
check "network down: volume unhealthy" yes "$(wait_metric "daos_csi_volume_healthy{volume=\"$VOL\"}" 0 60)"
check "network down: dfuse killed" yes "$(wait_metric daos_csi_dfuse_kills_total $((kills1 + 1)) 90)"
sleep 20
network up
check "network back: a new dfuse serves the volume" yes \
	"$(wait_metric "daos_csi_volume_healthy{volume=\"$VOL\"}" 1 300)"
check "the pod's mount switched to it" yes "$(wait_metric daos_csi_targets_rebound_total $((rebound1 + 1)) 60)"
check "pod with a liveness probe reads again" ok "$(wait_reads live 300)"

restore_plugin
trap - EXIT
network up
[ "${KEEP:-0}" = 1 ] || cleanup
report "k8s-csi-health: $(hostname -s), volume $VOL"
