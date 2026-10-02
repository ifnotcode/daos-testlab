#!/usr/bin/env bash
# Kubernetes: user-namespaced pods (hostUsers: false) on csi-daos volumes of dfuse --allow-idmap
# needs: server
# Run by "lab test k8s-allow-idmap <k8s or talos vm> CLIENT_IMAGE=@<build>" after
# "lab csi <vm> <image>" with a CSI image of a patched DAOS build (dfuse with --allow-idmap) and a
# kernel >= 6.12 on the node. CLIENT_IMAGE: image with the DAOS client of the same build,
# "@<build>" meaning $REGISTRY/daos-client:<build> ("lab images push localhost/daos-client:<build>").
# The scenarios are in k8s/allow-idmap.yaml. KEEP=1 leaves the namespace for inspection.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
CLIENT_IMAGE=${CLIENT_IMAGE:?image with the DAOS client, e.g. CLIENT_IMAGE=@<build>}
[ "${CLIENT_IMAGE:0:1}" = @ ] && CLIENT_IMAGE=$REGISTRY/daos-client:${CLIENT_IMAGE:1}
MAPPED_USER=${AGENT_DEFAULT_USER%%:*}
# Over RDMA (a verbs provider) a pod on the pod network cannot connect to DAOS itself (no RDMA
# devices, no RoCE address: see k8s-rdma.sh): libpil4dfs and libioil then fall back to plain I/O
# through dfuse, with the same data. Over tcp they connect and intercept.
direct=yes own=own
case $DAOS_PROVIDER in *verbs*) direct=no own=none ;; esac
NS=idmap-test

result() { # pod key -> text after "RESULT <key> " in its log
	kubectl -n $NS logs "$1" 2>/dev/null | sed -n "s/^RESULT $2 //p" | tail -1
}
wait_result() { # pod key
	for _ in $(seq 1 90); do
		[ -n "$(result "$1" "$2")" ] && return 0
		sleep 2
	done
	return 1
}
positive() { [ "${1:-0}" -gt 0 ] 2>/dev/null && echo yes || echo no; }

kubectl delete ns $NS --ignore-not-found --wait=true >/dev/null
kubectl delete sc daos-allow-idmap daos-no-idmap --ignore-not-found >/dev/null
sed -e "s#@CLIENT_IMAGE@#$CLIENT_IMAGE#" -e "s#@POOL@#$POOL#" -e "s#@MAPPED_USER@#$MAPPED_USER#" \
	k8s/allow-idmap.yaml | kubectl apply -f - >/dev/null

# volume of dfuse --allow-idmap
wait_result userns-root seen
check "userns root: create file and dir, chown dir to 1000" ok "$(result userns-root create-chown)"
check "userns root: its file and dir as seen in the pod" "0:0 1000:1000" "$(result userns-root seen)"
wait_result userns-1000 seen
check "userns uid 1000: write in its dir" ok "$(result userns-1000 write-own-dir)"
check "userns uid 1000: write to root's 0644 file" denied "$(result userns-1000 write-root-file)"
check "userns uid 1000: its file as seen in the pod" "1000:1000" "$(result userns-1000 seen)"
wait_result hostusers-view stored
check "owners stored in DAOS, seen by a pod without userns" "0:0 1000:1000 1000:1000" \
	"$(result hostusers-view stored)"
wait_result pil-hostusers data
check "libpil4dfs, root without userns: data" hello "$(result pil-hostusers data | cut -d' ' -f1)"
n=$(result pil-hostusers data | sed -n 's/.*op_sum \([0-9]*\).*/\1/p')
check "libpil4dfs, root without userns: intercepts with dfuse's handles ($n ops)" $direct "$(positive "$n")"
wait_result pil-userns data
check "libpil4dfs, userns root: data" hello "$(result pil-userns data | cut -d' ' -f1)"
n=$(result pil-userns data | sed -n 's/.*op_sum \([0-9]*\).*/\1/p')
check "libpil4dfs, userns root: no handles of dfuse, I/O through dfuse ($n ops)" no "$(positive "$n")"
wait_result ioil-userns handles
check "libioil, userns root: refused dfuse's handles, own connection" $own \
	"$(result ioil-userns handles | cut -d' ' -f1)"
n=$(result ioil-userns handles | sed -n 's/.*reads \([0-9]*\).*/\1/p')
check "libioil, userns root: intercepts reads ($n)" $direct "$(positive "$n")"

# control volume: dfuse without --allow-idmap
wait_result plain-pil-hostusers data
check "control: libpil4dfs, root without userns: data" hello \
	"$(result plain-pil-hostusers data | cut -d' ' -f1)"
n=$(result plain-pil-hostusers data | sed -n 's/.*op_sum \([0-9]*\).*/\1/p')
check "control: libpil4dfs, root without userns: intercepts ($n ops)" $direct "$(positive "$n")"
got=none
for _ in $(seq 1 30); do
	msg=$(kubectl -n $NS get pod plain-userns \
		-o jsonpath='{.status.containerStatuses[0].state.*.message}' 2>/dev/null)
	if echo "$msg" | grep -q MOUNT_ATTR_IDMAP; then got=idmap-error; break; fi
	kubectl -n $NS logs plain-userns 2>/dev/null | grep -q "RESULT started" && got=started && break
	sleep 2
done
check "control: userns pod fails to start (MOUNT_ATTR_IDMAP)" idmap-error "$got"

[ "${KEEP:-0}" = 1 ] || { kubectl delete ns $NS --wait=true >/dev/null;
	kubectl delete sc daos-allow-idmap daos-no-idmap >/dev/null; }
report "k8s-allow-idmap: $(kubectl version 2>/dev/null | grep -i server), $(kubectl get nodes \
	-o jsonpath='{range .items[*]}{.metadata.name} {.status.nodeInfo.kernelVersion} {end}')"
