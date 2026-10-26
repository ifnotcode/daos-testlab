#!/usr/bin/env bash
# Kubernetes: the colleagues' ml_test stand (agent DaemonSet, their CSI driver, userns pod) and a driver restart
# needs: server
# Run by "lab -c profiles/ml_test.conf test k8s-ml-test <talos or k8s vm> VARIANT=orig|fixed IMAGE=@<image>".
# Only kubectl: works with Talos. Rebuilds what the survey of their cluster showed (2026-10-18,
# docs/cluster-survey/part2):
#   - namespace daos-client: daos_agent DaemonSet "daos-client-daos-agent" (privileged, hostPID,
#     hostNetwork), config as theirs: insecure, exclude_fabric_ifaces, client_user_map default
#     nobody:nobody (the lab adds flannel.1 and cni0 to the exclude list: theirs is Cilium);
#   - namespace daos-csi-driver: their driver mlcore.daos.csi (tests/k8s/mlcore/<variant>.yaml);
#   - static PV daos-fast-pv-ml-core-test-38 / PVC daos-fast-pvc-ml-core-test-38 (daos-static),
#     dfuse with --multi-user --allow-idmap (orig: PV mountOptions; fixed: dfuse.defaultArgs);
#   - pod test-daos-client: hostUsers: false, uid 1234, the volume at /mnt/daos, the agent socket
#     (hostPath, read-only).
# Checks what probe.sh showed there (idmapped fuse.daos mount, the dfuse process), then deletes the
# driver pod (rollout, OOM, liveness) and checks again, then recreates the test pod. orig is the
# driver as they run it, fixed has the fixes of DaosInmapPatch/bundles/.../mlcore-csi-fixed.
# IMAGE: driver image with the DAOS client ("@name:tag" = $REGISTRY/name:tag); the agent and the
# test pod use it too. KEEP=1 leaves everything for inspection.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
VARIANT=${VARIANT:?orig or fixed}
IMAGE=${IMAGE:?driver image, e.g. IMAGE=@mlcore-csi:orig-v2.8.0}
[ "${IMAGE:0:1}" = @ ] && IMAGE=$REGISTRY/${IMAGE:1}
APPNS=daos-client
DRVNS=daos-csi-driver
PV=daos-fast-pv-ml-core-test-38
PVC=daos-fast-pvc-ml-core-test-38
CONT=ml-core-test
ARGS="--multi-user --allow-idmap"
pv_opts=$ARGS
[ "$VARIANT" = fixed ] && pv_opts=""
# a new staging directory per run: a dead mount left by an earlier run must not decide this one
HANDLE=$PV-$VARIANT-$(date +%s)
K=kubectl

driver_yaml() {
	sed -e "s#MLCORE_REPO:MLCORE_TAG#$IMAGE#g" -e "s#namespace: dcd\$#namespace: $DRVNS#" \
		-e "s#K8sNamespace: dcd#K8sNamespace: $DRVNS#" \
		-e "s#defaultArgs: \"--multi-user\"#defaultArgs: \"$ARGS\"#" "k8s/mlcore/$VARIANT.yaml"
}
agent_pod() { $K -n $APPNS get pods -l app=daos-client-daos-agent -o jsonpath='{.items[0].metadata.name}'; }
aexec() { $K -n $APPNS exec "$(agent_pod)" -- "$@"; }
pexec() { timeout 30 $K -n $APPNS exec test-daos-client -- "$@"; }
# dfuse processes of the node that serve the test container, as the hostPID agent pod sees them
dfuse_cmdlines() {
	aexec sh -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = dfuse ] && { tr "\0" " " <$p/cmdline; echo; }; done' 2>/dev/null |
		grep -- "$CONT"
}

test_pod() {
	$K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: test-daos-client, namespace: $APPNS}
spec:
  hostUsers: false
  terminationGracePeriodSeconds: 1
  securityContext: {runAsUser: 1234, runAsGroup: 1234}
  containers:
  - name: shelly
    image: $IMAGE
    command: [sleep, "10000000000"]
    volumeMounts:
    - {name: data, mountPath: /mnt/daos}
    - {name: agent, mountPath: /var/run/daos_agent, readOnly: true}
  volumes:
  - {name: data, persistentVolumeClaim: {claimName: $PVC}}
  - {name: agent, hostPath: {path: /var/run/daos_agent, type: Directory}}
EOF
}
pod_ready() { $K -n $APPNS wait --for=condition=Ready pod/"$1" --timeout="${2:-240s}" >/dev/null 2>&1 && echo yes || echo no; }
last_event() { $K -n $APPNS get events --field-selector involvedObject.name="$1" -o jsonpath='{.items[-1:].message}' 2>/dev/null | cut -c1-150; }
# "ok", or the error of ls (e.g. "Transport endpoint is not connected")
reads() {
	local out
	out=$(pexec sh -c 'ls /mnt/daos >/dev/null && cat /mnt/daos/u1234/f' 2>&1)
	case $out in *hello*) echo ok ;; *) echo "${out:-no output}" | grep -oE 'Transport endpoint is not connected|Permission denied|No such file[^,]*|not running|[A-Z][a-z]+ [a-z ]+' | head -1 ;; esac
}

cleanup() {
	$K -n $APPNS delete pod test-daos-client helper --grace-period=0 --force >/dev/null 2>&1
	$K -n $APPNS delete pvc $PVC --wait=false >/dev/null 2>&1
	for p in $($K get pv -o name | grep "/$PV"); do
		$K patch "$p" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
		$K delete "$p" --wait=false >/dev/null 2>&1
	done
	for va in $($K get volumeattachment -o jsonpath='{range .items[?(@.spec.attacher=="mlcore.daos.csi")]}{.metadata.name} {end}' 2>/dev/null); do
		$K patch volumeattachment "$va" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
	done
	driver_yaml | $K delete -f - --wait=true --timeout=120s >/dev/null 2>&1
	$K delete ns $DRVNS $APPNS --wait=true --timeout=180s >/dev/null 2>&1
}

cleanup
$K create ns $APPNS >/dev/null
$K create ns $DRVNS >/dev/null
$K label ns $APPNS $DRVNS pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null

# --- the agent, as theirs ---
$K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: daos-client-daos-agent-config, namespace: $APPNS}
data:
  daos-agent.yaml: |
    name: $DAOS_SYSTEM
    access_points: ['$SERVER_IP']
    port: 10001
    transport_config:
      allow_insecure: true
    exclude_fabric_ifaces: [cilium_host, dummy-bgp, flannel.1, cni0]
    credential_config:
      client_user_map:
        default:
          user: nobody
          group: nobody
---
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: daos-client-daos-agent, namespace: $APPNS}
spec:
  selector: {matchLabels: {app: daos-client-daos-agent}}
  template:
    metadata: {labels: {app: daos-client-daos-agent}}
    spec:
      hostNetwork: true
      hostPID: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: daos-agent
        image: $IMAGE
        command: [/opt/daos/bin/daos_agent, -o, /etc/daos-agent.yaml, -s, /var/run/daos_agent]
        securityContext: {privileged: true}
        volumeMounts:
        - {name: config, mountPath: /etc/daos-agent.yaml, subPath: daos-agent.yaml, readOnly: true}
        - {name: sock, mountPath: /var/run/daos_agent}
      volumes:
      - {name: config, configMap: {name: daos-client-daos-agent-config}}
      - {name: sock, hostPath: {path: /var/run/daos_agent, type: DirectoryOrCreate}}
EOF
$K -n $APPNS rollout status ds/daos-client-daos-agent --timeout=300s >/dev/null
check "agent DaemonSet runs (privileged, hostPID)" yes \
	"$($K -n $APPNS get ds daos-client-daos-agent -o jsonpath='{.status.numberReady}' | grep -q '^[1-9]' && echo yes || echo no)"
aexec /opt/daos/bin/daos cont create "$POOL" $CONT --type POSIX >/dev/null 2>&1
check "container $CONT on $POOL (created as root through the agent)" yes \
	"$(aexec /opt/daos/bin/daos cont query "$POOL" $CONT >/dev/null 2>&1 && echo yes || echo no)"

# --- their driver ---
driver_yaml | $K apply -f - >/dev/null
$K -n $DRVNS rollout status ds/daos-csi-driver --timeout=300s >/dev/null
node=$($K get nodes -o jsonpath='{.items[0].metadata.name}')
for _ in $(seq 1 30); do $K get csinode "$node" -o jsonpath='{.spec.drivers[*].name}' | grep -q mlcore && break; sleep 2; done
check "driver registered on $node" yes \
	"$($K get csinode "$node" -o jsonpath='{.spec.drivers[*].name}' | grep -q mlcore && echo yes || echo no)"

# --- the static volume, a root helper that makes uid 1234 a directory, the test pod ---
$K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolume
metadata: {name: $PV}
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: daos-static
  claimRef: {namespace: $APPNS, name: $PVC}
  csi:
    driver: mlcore.daos.csi
    volumeHandle: $HANDLE
    volumeAttributes: {poolID: "$POOL", containerID: $CONT, mountOptions: "$pv_opts"}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $PVC, namespace: $APPNS}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: daos-static
  volumeName: $PV
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: helper, namespace: $APPNS}
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: h
    image: $IMAGE
    command: [sh, -c, "mkdir -p /mnt/daos/u1234 && chown 1234:1234 /mnt/daos/u1234 && echo done && sleep 600"]
    volumeMounts: [{name: data, mountPath: /mnt/daos}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: $PVC}}]
EOF
check "root helper prepares a directory for uid 1234" yes \
	"$([ "$(pod_ready helper)" = yes ] && $K -n $APPNS logs helper | grep -q done && echo yes || echo "no: $(last_event helper)")"
$K -n $APPNS delete pod helper --grace-period=0 --force >/dev/null 2>&1
test_pod
check "test-daos-client (hostUsers: false, uid 1234) runs" yes \
	"$(r=$(pod_ready test-daos-client); [ "$r" = yes ] && echo yes || echo "no: $(last_event test-daos-client)")"

# --- what probe.sh showed on their stand ---
check "kernel of the node is >= 6.12 ($(pexec uname -r 2>/dev/null))" yes \
	"$(pexec uname -r 2>/dev/null | awk -F. '{print ($1 > 6 || ($1 == 6 && $2 >= 12)) ? "yes" : "no"}')"
check "/mnt/daos in the pod is fuse.daos, mounted idmapped" yes \
	"$(pexec grep ' /mnt/daos ' /proc/self/mountinfo 2>/dev/null | grep -q 'idmapped.*fuse.daos' && echo yes || echo no)"
pexec sh -c 'echo hello > /mnt/daos/u1234/f' >/dev/null 2>&1
check "uid 1234 writes and reads in its directory" ok "$(reads)"
check "file owner as the pod sees it" 1234:1234 "$(pexec stat -c %u:%g /mnt/daos/u1234/f 2>/dev/null)"
cmd=$(dfuse_cmdlines | head -1)
check "a dfuse serving $CONT runs on the node" yes "$([ -n "$cmd" ] && echo yes || echo no)"
check "that dfuse has --allow-idmap" yes "$(echo "$cmd" | grep -q -- --allow-idmap && echo yes || echo no)"
out=$(pexec sh -c "/opt/daos/bin/daos pool query $POOL >/tmp/q 2>&1; echo rc=\$?; grep -oE 'DER_[A-Z_]+' /tmp/q | head -1" 2>&1 | tr '\n' ' ')
check "daos pool query from the pod, own connection: fails (uid -> nobody at the agent; in the lab also no route from the pod network) ($out)" fails \
	"$(case $out in *rc=0*) echo works ;; *) echo fails ;; esac)"

# the driver must stay up on its own (its liveness probe: a driver image without the health server
# is restarted every ~40 s, and every restart kills its dfuse processes)
sleep 45
check "driver container not restarted by itself (liveness)" 0 \
	"$($K -n $DRVNS get pods -l app=daos-csi-driver -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="driver")].restartCount}')"

# --- the driver pod restarts, as on their stand ---
$K -n $DRVNS delete pod -l app=daos-csi-driver --wait=true >/dev/null
$K -n $DRVNS rollout status ds/daos-csi-driver --timeout=300s >/dev/null
sleep 10
check "driver restarted: a dfuse serving $CONT still runs" yes "$([ -n "$(dfuse_cmdlines)" ] && echo yes || echo no)"
check "driver restarted: test-daos-client still reads its volume" ok "$(reads)"

# --- the pod is recreated: does a new mount work? ---
$K -n $APPNS delete pod test-daos-client --grace-period=0 --force >/dev/null 2>&1
for _ in $(seq 1 30); do $K -n $APPNS get pod test-daos-client >/dev/null 2>&1 || break; sleep 2; done
test_pod
check "recreated test-daos-client runs" yes \
	"$(r=$(pod_ready test-daos-client); [ "$r" = yes ] && echo yes || echo "no: $(last_event test-daos-client)")"
check "recreated test-daos-client reads its volume" ok "$(reads)"

if [ "${KEEP:-0}" = 1 ]; then
	echo "kept: namespaces $APPNS and $DRVNS, PV $PV"
else
	aexec /opt/daos/bin/daos cont destroy "$POOL" $CONT >/dev/null 2>&1
	cleanup
fi
report "k8s-ml-test: $VARIANT, $IMAGE, node $node, $($K version 2>/dev/null | grep -i server)"
