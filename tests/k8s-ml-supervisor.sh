#!/usr/bin/env bash
# Kubernetes: the colleagues' daos-mount-supervisor (dfuse in Volcano mount jobs) with --allow-idmap
# needs: server
# Run by "lab -c profiles/ml_test.conf test k8s-ml-supervisor <talos or k8s vm> SUP=orig|fixed
# SUP_TAG=<tag> IMAGE=@<driver image>". Only kubectl: works with Talos. The ml_test stand of
# k8s-ml-test.sh (agent DaemonSet as theirs, static PV, hostUsers: false pod with uid 1234), but
# dfuse runs where the colleagues plan to run it (MLP-15629): their CSI driver in
# dfuse.mountMode supervisor (our fixed driver plus a supervisor client,
# k8s/mlcore/supervisor-driver.yaml) calls daos-mount-supervisor over its unix socket, and the
# supervisor runs one Volcano job per staging path with dfuse in it.
#   SUP=orig  their supervisor as received, SUP=fixed with our fixes
#             (DaosInmapPatch/colleagues-csi/mount-supervisor: patches/, src/);
#             k8s/mlcore/supervisor-<SUP>.yaml is their chart rendered with lab/values.lab.yaml;
#   SUP_TAG   mount-supervisor image in the lab registry (lab/build.sh), also the mount image;
#   IMAGE     driver image (lab/build.sh driver), with the DAOS client: the agent and the
#             test pods use it too.
# Volcano (v1.15.3, images in the lab registry: see profiles/ml_test.conf) is installed once and
# left in place. The checks: the mount job and its pod, dfuse with --allow-idmap in it, the
# idmapped volume of the userns pod, restarts of the driver and of the supervisor, an invalid dfuse
# option, a dfuse that dies (kill -9) and the recovery by recreating the pod, the unmount.
# KEEP=1 leaves everything for inspection.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
SUP=${SUP:?orig or fixed}
SUP_TAG=${SUP_TAG:?mount-supervisor image tag, e.g. fixed-r4}
IMAGE=${IMAGE:?driver image, e.g. IMAGE=@mlcore-csi:fixed-v2.8.0-sup-r1}
[ "${IMAGE:0:1}" = @ ] && IMAGE=$REGISTRY/${IMAGE:1}
VOLCANO=v1.15.3
VOLCANO_YAML=${VOLCANO_YAML:-/mnt/keenetic/daos-testlab/cache/volcano/volcano-$VOLCANO.yaml}
APPNS=daos-client
DRVNS=daos-csi-driver
SUPNS=daos-mount-supervisor
PV=daos-fast-pv-ml-core-test-38
PVC=daos-fast-pvc-ml-core-test-38
CONT=ml-core-test
ARGS="--multi-user --allow-idmap"
# a new staging directory per run: a dead mount left by an earlier run must not decide this one
HANDLE=$PV-sup-$SUP-$(date +%s)
K=kubectl

driver_yaml() {
	sed -e "s#MLCORE_REPO:MLCORE_TAG#$IMAGE#g" -e "s#namespace: dcd\$#namespace: $DRVNS#" \
		-e "s#K8sNamespace: dcd#K8sNamespace: $DRVNS#" \
		-e "s#defaultArgs: \"--multi-user\"#defaultArgs: \"$ARGS\"#" k8s/mlcore/supervisor-driver.yaml
}
supervisor_yaml() { sed -e "s#SUP_REGISTRY#$REGISTRY#g" -e "s#SUP_TAG#$SUP_TAG#g" "k8s/mlcore/supervisor-$SUP.yaml"; }
agent_pod() { $K -n $APPNS get pods -l app=daos-client-daos-agent -o jsonpath='{.items[0].metadata.name}'; }
aexec() { $K -n $APPNS exec "$(agent_pod)" -- "$@"; }
pexec() { timeout 30 $K -n $APPNS exec test-daos-client -- "$@"; }
# pid and command line of the node's dfuse processes serving the test container (hostPID agent pod)
dfuse_procs() {
	aexec sh -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = dfuse ] && { echo "${p#/proc/} $(tr "\0" " " <$p/cmdline)"; }; done' 2>/dev/null |
		grep -- "$CONT"
}
# the mount jobs of the supervisor, "name phase target" per line
jobs_() {
	$K -n $SUPNS get vcjob -o jsonpath='{range .items[*]}{.metadata.name} {.status.state.phase} {.metadata.annotations.mlcore\.t-tech\.team/fuse-target-path}{"\n"}{end}' 2>/dev/null
}
job_pod() { $K -n $SUPNS get pods -l "mlcore.t-tech.team/fuse-job-name=$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
# the UIDs of a job and of its pod (names are the same for every job of a target)
uids() {
	echo "$($K -n $SUPNS get vcjob "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null)/$($K -n $SUPNS get pods \
		-l "mlcore.t-tech.team/fuse-job-name=$1" -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null)"
}
# is the staging path mounted on the node, and as what ("fuse.daos", "none")
host_mount() {
	local t
	t=$(aexec awk -v p="$1" '$5 == p { for (i = 7; $i != "-"; i++); print $(i + 1) }' /proc/1/mountinfo 2>/dev/null | head -1)
	echo "${t:-none}"
}
sup_pod() { $K -n $SUPNS get pods -l app=daos-mount-supervisor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
# the supervisor's gRPC API directly, with the lab's client in its image (lab/supctl): first word
# of the answer, the state or the gRPC code
supctl() { $K -n $SUPNS exec "$(sup_pod)" -- /app/supctl "$@" 2>&1 | head -1 | awk '{print $1}' | tr -d :; }

test_pod() {
	$K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: ${2:-test-daos-client}, namespace: $APPNS}
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
  - {name: data, persistentVolumeClaim: {claimName: ${1:-$PVC}}}
  - {name: agent, hostPath: {path: /var/run/daos_agent, type: Directory}}
EOF
}
pod_ready() { $K -n $APPNS wait --for=condition=Ready pod/"$1" --timeout="${2:-240s}" >/dev/null 2>&1 && echo yes || echo no; }
last_event() { all_events "$1" | tail -1 | cut -c1-200; }
all_events() { $K -n $APPNS get events --field-selector involvedObject.name="$1" -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null; }
# "ok", or the error of ls (e.g. "Transport endpoint is not connected")
reads() {
	local out
	out=$(pexec sh -c 'ls /mnt/daos >/dev/null && cat /mnt/daos/u1234/f' 2>&1)
	case $out in *hello*) echo ok ;; *) echo "${out:-no output}" | grep -oE 'Transport endpoint is not connected|Permission denied|No such file[^,]*|not running|[A-Z][a-z]+ [a-z ]+' | head -1 ;; esac
}
delete_pod() {
	$K -n $APPNS delete pod "$1" --wait=false >/dev/null 2>&1
	for _ in $(seq 1 90); do $K -n $APPNS get pod "$1" >/dev/null 2>&1 || return 0; sleep 2; done
	$K -n $APPNS delete pod "$1" --grace-period=0 --force >/dev/null 2>&1
}
pv() { # pv <name> <pvc> <handle> <mountOptions>
	$K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolume
metadata: {name: $1}
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: daos-static
  claimRef: {namespace: $APPNS, name: $2}
  csi:
    driver: mlcore.daos.csi
    volumeHandle: $3
    volumeAttributes: {poolID: "$POOL", containerID: $CONT, mountOptions: "$4"}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $2, namespace: $APPNS}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: daos-static
  volumeName: $1
  resources: {requests: {storage: 1Gi}}
EOF
}

cleanup() {
	for p in test-daos-client bad-options helper; do $K -n $APPNS delete pod $p --wait=false >/dev/null 2>&1; done
	sleep 5
	for p in test-daos-client bad-options helper; do $K -n $APPNS delete pod $p --grace-period=0 --force >/dev/null 2>&1; done
	$K -n $APPNS delete pvc $PVC $PVC-bad --wait=false >/dev/null 2>&1
	for p in $($K get pv -o name | grep -E "/$PV(-bad)?\$"); do
		$K patch "$p" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
		$K delete "$p" --wait=false >/dev/null 2>&1
	done
	# the driver unstages through the supervisor: give it the time before both go
	for _ in $(seq 1 30); do [ -z "$(jobs_)" ] && break; sleep 2; done
	$K -n $SUPNS delete vcjob --all --wait=true --timeout=120s >/dev/null 2>&1
	driver_yaml | $K delete -f - --wait=true --timeout=120s >/dev/null 2>&1
	supervisor_yaml | $K delete -f - --wait=true --timeout=120s >/dev/null 2>&1
	$K delete ns $DRVNS $APPNS $SUPNS --wait=true --timeout=180s >/dev/null 2>&1
}

cleanup
for ns in $APPNS $DRVNS $SUPNS; do $K create ns $ns >/dev/null; done
$K label ns $APPNS $DRVNS $SUPNS pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null

# --- Volcano, once ---
if ! $K get crd jobs.batch.volcano.sh >/dev/null 2>&1; then
	[ -s "$VOLCANO_YAML" ] || { mkdir -p "$(dirname "$VOLCANO_YAML")" && curl -sfL -o "$VOLCANO_YAML" \
		"https://raw.githubusercontent.com/volcano-sh/volcano/$VOLCANO/installer/volcano-development.yaml"; }
	sed "s#docker.io/volcanosh/#$REGISTRY/#g" "$VOLCANO_YAML" | $K apply --server-side -f - >/dev/null
	$K label ns volcano-system pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
fi
for d in volcano-admission volcano-controllers volcano-scheduler; do
	$K -n volcano-system rollout status deploy/$d --timeout=300s >/dev/null 2>&1
done
check "Volcano $VOLCANO runs (admission, controllers, scheduler)" 3 \
	"$($K -n volcano-system get deploy -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' | grep -c '^[1-9]')"

# --- the agent, as theirs (k8s-ml-test.sh) ---
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
aexec /opt/daos/bin/daos cont create "$POOL" $CONT --type POSIX >/dev/null 2>&1
check "agent runs, container $CONT on $POOL" yes \
	"$(aexec /opt/daos/bin/daos cont query "$POOL" $CONT >/dev/null 2>&1 && echo yes || echo no)"

# --- the supervisor and the driver ---
supervisor_yaml | $K apply -f - >/dev/null
$K -n $SUPNS rollout status ds/daos-mount-supervisor --timeout=300s >/dev/null 2>&1
check "supervisor ($SUP, $SUP_TAG) runs and is ready" yes \
	"$($K -n $SUPNS get ds daos-mount-supervisor -o jsonpath='{.status.numberReady}' | grep -q '^[1-9]' && echo yes || echo "no: $($K -n $SUPNS logs ds/daos-mount-supervisor --tail=3 2>&1 | tr '\n' ' ' | cut -c1-200)")"
driver_yaml | $K apply -f - >/dev/null
$K -n $DRVNS rollout status ds/daos-csi-driver --timeout=300s >/dev/null
node=$($K get nodes -o jsonpath='{.items[0].metadata.name}')
for _ in $(seq 1 30); do $K get csinode "$node" -o jsonpath='{.spec.drivers[*].name}' | grep -q mlcore && break; sleep 2; done
check "driver (mountMode supervisor) registered on $node" yes \
	"$($K get csinode "$node" -o jsonpath='{.spec.drivers[*].name}' | grep -q mlcore && echo yes || echo no)"

# --- the volume, a root helper that makes uid 1234 a directory, the test pod ---
pv $PV $PVC "$HANDLE" ""
$K apply -f - >/dev/null <<EOF
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
check "root helper mounts the volume, prepares a directory for uid 1234" yes \
	"$([ "$(pod_ready helper)" = yes ] && $K -n $APPNS logs helper | grep -q done && echo yes || echo "no: $(last_event helper)")"
delete_pod helper
test_pod
check "test-daos-client (hostUsers: false, uid 1234) runs" yes \
	"$(r=$(pod_ready test-daos-client); [ "$r" = yes ] && echo yes || echo "no: $(last_event test-daos-client)")"

# --- the mount job ---
read -r job phase target <<<"$(jobs_ | head -1)"
check "one mount job for the volume, Running" "1 Running" "$(jobs_ | grep -c .) ${phase:-none}"
jpod=$(job_pod "${job:-none}")
juids=$(uids "${job:-none}")
check "its pod: Ready, hostNetwork, priority system-node-critical" "True true system-node-critical" \
	"$($K -n $SUPNS get pod "${jpod:-none}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.spec.hostNetwork} {.spec.priorityClassName}' 2>/dev/null)"
check "the target is the staging path, mounted on the node as fuse.daos" fuse.daos \
	"$(case $target in /var/lib/kubelet/plugins/*/globalmount) host_mount "$target" ;; *) echo "target ${target:-none}" ;; esac)"
read -r dpid cmd <<<"$(dfuse_procs | head -1)"
check "dfuse serving $CONT runs with --foreground and --allow-idmap" yes \
	"$(echo "$cmd" | grep -q -- --foreground && echo "$cmd" | grep -q -- --allow-idmap && echo yes || echo "no: ${cmd:-no dfuse}")"
check "Volcano queue of the mount jobs is not reclaimable" false \
	"$($K get queue daos-fuse-mount-jobs -o jsonpath='{.spec.reclaimable}' 2>/dev/null)"

# --- the userns pod and its volume ---
check "/mnt/daos in the pod is fuse.daos, mounted idmapped" yes \
	"$(pexec grep ' /mnt/daos ' /proc/self/mountinfo 2>/dev/null | grep -q 'idmapped.*fuse.daos' && echo yes || echo no)"
pexec sh -c 'echo hello > /mnt/daos/u1234/f' >/dev/null 2>&1
check "uid 1234 writes and reads in its directory" ok "$(reads)"
check "file owner as the pod sees it" 1234:1234 "$(pexec stat -c %u:%g /mnt/daos/u1234/f 2>/dev/null)"

# --- restarts: the driver, then the supervisor ---
$K -n $DRVNS delete pod -l app=daos-csi-driver --wait=true >/dev/null
$K -n $DRVNS rollout status ds/daos-csi-driver --timeout=300s >/dev/null
sleep 5
check "driver restarted: the same dfuse still runs" "${dpid:-none}" "$(dfuse_procs | awk '{print $1}' | head -1)"
check "driver restarted: test-daos-client still reads its volume" ok "$(reads)"
$K -n $SUPNS delete pod "$(sup_pod)" --wait=true >/dev/null 2>&1
$K -n $SUPNS rollout status ds/daos-mount-supervisor --timeout=300s >/dev/null 2>&1
sleep 5
check "supervisor restarted: the same dfuse and mount job" "${dpid:-none} ${job:-none} Running" \
	"$(dfuse_procs | awk '{print $1}' | head -1) $(jobs_ | awk '{print $1, $2}' | head -1)"
check "supervisor restarted: test-daos-client still reads its volume" ok "$(reads)"

# --- a dfuse option the supervisor does not take ("rw" is a mount option, not dfuse's) ---
pv $PV-bad $PVC-bad "$HANDLE-bad" "rw"
test_pod $PVC-bad bad-options
sleep 20
check "a volume with mountOptions \"rw\" is refused: no mount job, the reason in the pod's events" "1 yes" \
	"$(jobs_ | grep -c .) $(all_events bad-options | grep -q 'not allowed' && echo yes || echo "no: $(last_event bad-options)")"
delete_pod bad-options

# --- the supervisor's API directly: what the driver never asks for ---
check "API: GetMount of the staging path" MOUNTED "$(supctl get "$target")"
check "API: Mount at /etc is refused" InvalidArgument "$(supctl mount "$POOL" $CONT /etc)"
check "API: Mount with --mountpoint=/etc is refused" InvalidArgument \
	"$(supctl mount "$POOL" $CONT /var/lib/kubelet/plugins/x --mountpoint=/etc)"

# --- dfuse dies (OOM kill, crash) ---
[ -n "${dpid:-}" ] && aexec kill -9 "$dpid" >/dev/null 2>&1
sleep 10
check "dfuse killed: the pod's volume is gone (FUSE cannot reconnect)" "Transport endpoint is not connected" "$(reads)"
check "dfuse killed: its mount job Failed, GetMount says FAILED" "Failed FAILED" \
	"$(jobs_ | awk -v j="$job" '$1 == j {print $2}') $(supctl get "$target")"
# the supervisor alone clears it (no kubelet call: the pod still runs): Unmount deletes the job,
# repeated Unmount removes the dead mount in the node's mount namespace
for _ in $(seq 1 20); do
	[ "$(supctl unmount "$target")" = OK ] && [ "$(supctl get "$target")" = NotFound ] && break
	sleep 3
done
check "Unmount through the API: job gone, the dead mount removed from the node" "NotFound 0 none" \
	"$(supctl get "$target") $(jobs_ | grep -c .) $(host_mount "$target")"
delete_pod test-daos-client
test_pod
check "recreated test-daos-client runs (stage makes a new mount job)" yes \
	"$(r=$(pod_ready test-daos-client); [ "$r" = yes ] && echo yes || echo "no: $(last_event test-daos-client)")"
check "recreated test-daos-client reads its volume" ok "$(reads)"
read -r job2 phase2 _ <<<"$(jobs_ | head -1)"
uids2=$(uids "${job2:-none}")
check "a new mount job (and pod) serves it" "1 Running new new" \
	"$(jobs_ | grep -c .) ${phase2:-none} $([ "${uids2%/*}" = "${juids%/*}" ] && echo old || echo new) $([ "${uids2#*/}" = "${juids#*/}" ] && echo old || echo new)"

# --- the unmount ---
delete_pod test-daos-client
for _ in $(seq 1 60); do [ -z "$(jobs_)" ] && break; sleep 2; done
check "pod deleted: the mount job is gone" 0 "$(jobs_ | grep -c .)"
check "pod deleted: nothing mounted at the staging path" none "$(host_mount "$target")"
check "supervisor container not restarted by itself" 0 \
	"$($K -n $SUPNS get pods -l app=daos-mount-supervisor -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')"

if [ "${KEEP:-0}" = 1 ]; then
	echo "kept: namespaces $APPNS, $DRVNS, $SUPNS, PV $PV"
else
	aexec /opt/daos/bin/daos cont destroy "$POOL" $CONT >/dev/null 2>&1
	cleanup
fi
report "k8s-ml-supervisor: supervisor $SUP ($SUP_TAG), driver $IMAGE, node $node, $($K version 2>/dev/null | grep -i server)"
