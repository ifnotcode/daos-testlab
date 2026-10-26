# Survey report: ml_test, 2026-10-18 (second pass, ROUND2)

**Scope and access.** This is the second pass. Access is still limited to the ServiceAccount
`system:serviceaccount:daos-client:storage-team` (namespace `daos-client` + namespace list), but
with the operator's explicit OK the read-only `probe.sh` was run through `kubectl exec` in two pods:
- `test-daos-client` (application pod, `hostUsers: false`, on `worker-a`);
- `daos-client-daos-agent-qrxvw` (DAOS agent DaemonSet pod, privileged + `hostPID`, on the same
  node `worker-a`; from it the node's processes and dfuse are visible).

Namespaces `daos-csi-driver` and `daos-mount-supervisor`, plus cluster-wide objects
(`storageclasses`, `persistentvolumes`, `csidrivers`, `runtimeclasses`, `nodes`, `events`), are
still **not readable**. Nothing was changed; `probe.sh` is read-only (no `WRITE_TEST` run).

**Anonymization** (names/IPs/registry replaced consistently):
`docker-hosted.artifactory.tcsbank.ru` → `registry-1`; `10.181.220.37` → `IP-1` (DAOS server
access point); `10.181.220.42` → `IP-2` (agent pod IP); `10.185.213.200` → `IP-3` (test pod IP);
`ix-m3-sm15-cz2d290ggy` → `worker-a`. Namespace names are kept as identifiers (not hostnames/IPs).
Raw survey tarballs contain real identifiers (raw evidence); redact before sharing outside.

## 1. Symptom
- Stage: **the operator asked to "try all variants" and determine it by probing.** Observed: the
  DAOS volume mount of `test-daos-client` exists and is an idmapped `fuse.daos` mount, but the
  dfuse daemon behind it is **not running**, so the mount is dead: any access to `/mnt/daos`
  returns `Transport endpoint is not connected` (ENOTCONN). This is closest to "dfuse does not
  start" / "I/O errors". There is **no** `MOUNT_ATTR_IDMAP`/`failed to set` error: the idmapped
  mount itself succeeded.
- What was deployed (visible): two pods in `daos-client`, both on `worker-a`:
  - agent DaemonSet `daos-client-daos-agent-qrxvw`, image `registry-1/ai-platform/daos-client:commit-a113b47f`;
  - test pod `test-daos-client`, image `registry-1/ai-platform/daos-client:commit-15cb5127`, digest
    `sha256:51a384f55293d50c0b5606abe54e23b9eea9d16899e96d3e756587f440519bd6`.
  The operator stated both images were built from the patch bundle `csi-daos-2.8.0-allow-idmap`.
  **This is only true for the agent image** (its dfuse is patched). The test pod image's dfuse is
  **not** patched (see 1.3 and check b).
- Exact error (verbatim, seen where and when):
  ```
  # inside test-daos-client, on /mnt/daos:
  ls: cannot access '/mnt/daos': Transport endpoint is not connected
  ```
  (observed on 2026-10-18 via `probe.sh`). The mount line for `/mnt/daos`:
  `... /mnt/daos rw,nosuid,nodev,noatime,idmapped - fuse.daos dfuse rw,user_id=0,group_id=0,default_permissions,allow_other`
- What works for comparison: the pod `test-daos-client` itself is `Running`/`Ready`, restart 0,
  no events; `hostUsers: false` and the idmapped mount were accepted. The **agent image** contains
  a correctly patched dfuse (fuse 1.1.0, both idmap markers, `--allow-idmap` known).

## 2. Findings per check (section 4, a–n)
| # | Finding | Evidence |
|---|---|---|
| a | Node kernel: **6.18.42-talos** — a **Talos** node; kernel ≥ 6.12, so idmapped FUSE is possible. | `probe-test-daos-client.txt` and `probe-agent-worker-a.txt`: `node kernel (uname -r): 6.18.42-talos` |
| b | dfuse actually running: **none on `worker-a` right now.** The patched dfuse exists in the agent image; the test pod image has an **unpatched** dfuse. Agent image `/opt/daos/bin/dfuse 2.9.100, libdaos 2.8.0`, `Using fuse 1.1.0`, markers `Idmapped mounts allowed` + `Kernel does not support idmapped mounts`, `--allow-idmap`=1 → PR1+PR2. Test pod image `/daos/install/bin/dfuse 2.8.0`, `Using fuse 1.0.0`, markers `none`, `--allow-idmap`=0 → **not patched**. | `probe-agent-worker-a.txt` (DAOS client section); `probe-test-daos-client.txt` (DAOS client section). `probe-agent-worker-a.txt`: dfuse processes visible = **none** |
| c | Is `--allow-idmap` passed to a running dfuse? **unknown** — no dfuse is running to inspect its cmdline, and its `volumeAttributes`/`mountOptions`/supervisor config are in unreadable namespaces. | `probe-agent-worker-a.txt` (no dfuse process found) |
| d | dfuse idmap logs: **unknown** — no running dfuse; its log (likely in the supervisor/CSI pod) is not readable. | — |
| e | FUSE mount: `/mnt/daos` in the test pod **is** `fuse.daos` and **is** idmapped (`idmapped`, `user_id=0,group_id=0,allow_other`) but **disconnected** (dfuse dead → ENOTCONN). | `probe-test-daos-client.txt` (mounts; `ls /mnt/daos` → `Transport endpoint is not connected`) |
| f | User namespaces: **enabled and working.** Cluster server v1.36.2; `test-daos-client` has `hostUsers: false` and its volume is mounted with the `idmapped` option; uid_map `0 3701211136 65536` (user-namespace offset). Kubelet feature-gate/`/etc/subuid` not readable (Talos). | `probe-test-daos-client.txt` (`uid_map`, mount `idmapped`); `cluster.txt` (server v1.36.2) |
| g | Runtime / OCI: **unknown** (no node access; RuntimeClasses Forbidden). Node is Talos (cgroup v2, root fs xfs). | `probe-agent-worker-a.txt` (root fs xfs, seclabel) |
| h | The pod: `test-daos-client`, `hostUsers:false`, `runAsUser:1234`/`runAsGroup:1234`, not privileged, `Running`/`Ready`, 0 restarts, no events; volume = PVC `daos-fast-pvc-ml-core-test-38` (Filesystem, RWX, `daos-static`) at `/mnt/daos` (dead mount); also mounts `hostPath /var/run/daos_agent` (ro); node `worker-a`. | `pod.txt` (pod survey); `probe-test-daos-client.txt` |
| i | CSI driver: **unknown** — `csidrivers`/StorageClasses/PV Forbidden; namespaces `daos-csi-driver` and `daos-mount-supervisor` exist but not readable. | `storage.txt` (Forbidden) |
| j | DAOS agent: DaemonSet in `daos-client`, image `registry-1/ai-platform/daos-client:commit-a113b47f`, privileged+hostNetwork+hostPID; version 2.9.100 (CLI), agent 2.9.100; config: `access_points: [IP-1]`, port 10001, `allow_insecure: true`, `exclude_fabric_ifaces: [cilium_host, dummy-bgp]`, `client_user_map.default: nobody`. Agent socket at `/var/run/daos_agent/daos_agent.sock` (host tmpfs). | agent DaemonSet yaml; ConfigMap; `probe-agent-worker-a.txt` |
| k | DAOS servers: outside K8s; version/provider/ACLs **unknown** (no server access). Access point IP-1, `allow_insecure`. | agent ConfigMap |
| l | Fabric: node is Talos with **InfiniBand** (`ib0`, `ib1`) and **RDMA devices `mlx5_0..mlx5_3`**; CNI **Cilium** (`cilium_host` present; agent excludes `cilium_host`,`dummy-bgp`). Provider version unknown. | `probe-agent-worker-a.txt` (node network, RDMA list); agent ConfigMap |
| m | Security layers: **unknown** — webhooks/SCC/Kyverno Forbidden; many namespaces labelled `protected=true` (meaning not verified). | `security.txt`; `kubectl get ns --show-labels` |
| n | Network: **Cilium**; node interfaces include `eth0..eth5`, `ib0/ib1`, `dummy-host`, `dummy-bgp`, `cilium_host`, many `lxc*` veths. kube-proxy mode / pod CIDRs unknown (nodes Forbidden). | `probe-agent-worker-a.txt`; `network.txt` |

## 3. Most likely cause(s)
Hypotheses only, ranked. No fixes were applied.
1. **The dfuse daemon that serves the pod's volume is not running on `worker-a`.** The mount at
   `/mnt/daos` is an idmapped `fuse.daos` mount but returns ENOTCONN, and a `hostPID` probe sees no
   dfuse process on the node. For the operator's goal ("the patch cannot be made to work"), the
   idmapped-mount mechanism itself works (kernel 6.18.42-talos, `hostUsers:false`, `idmapped` mount);
   the broken link is the **dfuse process** that should be serving it. Evidence: probe mounts +
   `Transport endpoint is not connected` + no dfuse process.
2. **Image mismatch / bundle not applied where it matters.** The agent image has a correctly
   patched dfuse (fuse 1.1.0, both markers, `--allow-idmap`). The **test pod image has an
   unpatched dfuse** (fuse 1.0.0, no markers, no `--allow-idmap`) even though the operator said all
   images came from the allow-idmap bundle. If dfuse is intended to run from a client image, the
   unpatched one cannot accept idmapped mounts. Evidence: `probe-test-daos-client.txt` vs
   `probe-agent-worker-a.txt` dfuse sections.
   *Against:* the dfuse serving the volume may live in the (unreadable) CSI/supervisor namespace,
   not in the test pod image; its patch state is unverified.
3. To confirm where dfuse runs and how it is started (cgroup/pod, `--allow-idmap`, logs), read
   access to `daos-csi-driver`/`daos-mount-supervisor` or node access on `worker-a` is required.

## 4. Unknowns and what is needed to resolve them
- **Which dfuse serves the volume, where it runs, its args and logs:** dfuse is not running now;
  its driver/supervisor is in unreadable namespaces. Need read access to
  `daos-csi-driver`/`daos-mount-supervisor` (and `events`), or node access on `worker-a`.
- **Why dfuse stopped / never started:** needs the dfuse/CSI/supervisor logs.
- **`--allow-idmap` configuration** (StorageClass `dfuseArgs` / PV `mountOptions` / supervisor
  config): needs StorageClass/PV/namespace read.
- **Container/OCI runtime versions, kubelet feature-gates:** need node access (Talos) or kubelet
  configz (Forbidden).
- **DAOS server version/provider/ACLs:** no server access.
- **Symbolic "which client image is the patched one" for the lab:** the agent image is patched;
  the test pod image is not. Confirm with the colleague which image should run dfuse.

## 5. Machine-readable summary for the lab
```yaml
cluster:
  alias: ml_test
  names_anonymized: yes
nodes:                      # no node access; data from hostPID probe on the failing node only
  - role: k8s-worker        # (failing pod's node)
    count: unknown
    os: Talos               # container OS of the image is Ubuntu 22.04.5; the node OS is Talos
    kernel: 6.18.42-talos
    arch: x86_64
    cpus_mem: unknown
    selinux: n/a            # seclabel present (cgroup v2)
    apparmor: unknown
    cgroup: v2
kubernetes:
  distribution: Talos
  version: v1.36.2          # server (client v1.33.9)
  kubelet_version: unknown
  user_namespaces: {feature_gate: default/on (works), kubelet_subids: unknown}
  container_runtime: unknown   # Talos default (containerd); version unknown
  oci_runtime: unknown
  runtime_classes: [unknown]
  failing_pod_runtime_class: none   # test pod has no runtimeClassName (observed)
  cni: cilium
  pod_cidr: unknown
  pod_security: unknown      # many namespaces labelled protected=true (meaning not verified)
daos:
  server_version: unknown
  server_hosts: outside       # access point IP-1 is a host IP, not in-cluster
  client_version: 2.8.0 (test pod) / 2.9.100 CLI + libdaos 2.8.0 (agent image)
  client_install: image:registry-1/ai-platform/daos-client (commit-a113b47f agent, commit-15cb5127 test)
  dfuse_binary_in_use: none running on worker-a
  dfuse_patch_markers:
    agent_image: "allowed"+"kernel" (fuse 1.1.0, --allow-idmap known)  # PR1+PR2
    test_pod_image: none (fuse 1.0.0, --allow-idmap unknown)            # not patched
  fuse_library: "Using fuse 1.1.0" (agent image) / "1.0.0" (test pod image)
  allow_idmap_passed: unknown   # no running dfuse to inspect; config in unreadable namespaces
  dfuse_runs_in: unknown        # daos-csi-driver / daos-mount-supervisor (not readable)
  provider: unknown             # agent fabric scan referenced tcp/eth0 earlier; IB present
  fabric_hw: mlx5 ConnectX (mlx5_0..mlx5_3), InfiniBand ib0/ib1 on the node
  rdma_device_plugin: unknown
  transport_security: insecure  # agent config allow_insecure: true
  agent: {runs_as: daemonset, client_user_map_default: "nobody:nobody",
          include_fabric_ifaces: null (exclude list), disable_auto_evict: unset}
  pool_container_acl: unknown
csi:
  driver: unknown               # namespaces daos-csi-driver & daos-mount-supervisor exist
  images: [unknown]
  privileged: unknown
  host_pid: unknown
  host_network: unknown
  storageclass_or_pv_params: {storageClassName: daos-static, accessModes: [ReadWriteMany],
                              volumeMode: Filesystem}   # from the PVC; PV itself not readable
failing_pod:
  host_users: false             # test-daos-client (Running/Ready)
  run_as_user: "1234"
  volume: csi (PVC daos-fast-pvc-ml-core-test-38) mounted as fuse.daos, idmapped, but disconnected
  uses_interception: unknown    # libpil4dfs/libioil exist in the agent image; pod LD_PRELOAD not set
  agent_socket_mounted: yes     # hostPath /var/run/daos_agent (ro)
not_reproducible_in_lab: [node OS is Talos, InfiniBand + mlx5 RDMA on the node,
                          CSI/supervisor internals, dfuse daemon state and logs]
```

*Evidence archives:* `survey-macbook-MWC7DCWHXL-k8s-20261017T210621Z.tar.gz`,
`survey-macbook-MWC7DCWHXL-pod-20261017T210551Z.tar.gz`,
`survey-macbook-MWC7DCWHXL-pod-20261017T210623Z.tar.gz`,
plus probe outputs `probe-test-daos-client.txt`, `probe-agent-worker-a.txt` (see below).