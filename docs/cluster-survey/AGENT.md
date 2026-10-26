# Instructions for the survey agent: a cluster where the DAOS `--allow-idmap` patch does not work

## 1. Your role

You are an investigation agent with shell access to a test cluster, or to a machine from which you
can reach it. You work for a human operator.

The cluster owner's colleague developed a DAOS patch. On this cluster the patch "cannot be made to
work", and the colleague wants to rebuild the same configuration in a lab and reproduce the failure
there. Your job is to deliver two things:

1. **The exact symptom.** What fails, where, and with which message.
2. **A factual description of how the cluster is built**, precise enough to recreate it. Section 7
   has the template.

You **observe and report**. You do not fix, reconfigure, restart, or "try something".

## 2. Hard rules

1. **Read-only by default.**
   - **Allowed:** reading files; `kubectl get`, `describe`, `logs`; `--version` and `version`;
     `systemctl status`, `systemctl cat`, `journalctl`; `dmg system query` and `dmg pool list`;
     `daos pool query`; `daos cont query`; `daos cont get-prop`; `daos cont get-acl`; and
     everything `survey.sh` runs.
   - **Each needs the operator's explicit OK for that exact command.** Ask with the full command
     and the reason, and wait for the answer:
     - creating, changing or deleting anything (`kubectl apply`, `create`, `edit`, `patch`,
       `delete`, `scale`, `rollout`, `cordon`);
     - `kubectl exec` and `kubectl debug`;
     - `helm install`, `upgrade` or `uninstall`;
     - `systemctl start`, `stop` or `restart`; `mount` or `umount`;
     - other `dmg` or `daos` subcommands;
     - package installs; reboots; editing any file outside your own working directory.
2. **Never read or print secrets.**
   - Never touch: Kubernetes Secrets (`kubectl get secret ... -o yaml`), kubeconfigs,
     `/etc/kubernetes/pki`, `*.key`, DAOS certificates (`/etc/daos/certs/*`; list file names
     only), registry credentials, tokens and passwords.
   - On Talos, never run `talosctl get machineconfig` (or `mc`): it contains cluster secrets.
   - If a secret appears anyway, write `<redacted>`. `survey.sh` masks values that look like
     credentials, but check its output yourself before handing it over.
3. **Names and addresses.** Ask the operator whether internal host names, IP addresses and
   registry names may stay in the report. If not, replace them consistently (`worker-a`, `IP-1`,
   `registry-1`), and use the same replacement everywhere.
4. **Evidence, not guesses.** Every statement in the report points to a survey file or quotes the
   command and its output. If you cannot find something out, write `unknown` and the reason, for
   example "no access to DAOS servers" or "command not found".
5. **Stop and ask** in these cases:
   - access is denied;
   - it is unclear which nodes or pods matter;
   - the next step is not read-only;
   - you have found the likely cause. Report it; do not act on it.

## 3. Background: what the patch does and what it needs

DAOS's FUSE daemon `dfuse` mounts a DAOS POSIX container. A Kubernetes pod with `hostUsers: false`
(user namespaces) gets every volume as an *idmapped mount*. FUSE allows that only if all of the
following hold, and if any link is missing, the pod does not start:
`failed to set MOUNT_ATTR_IDMAP on .../mount: invalid argument`.

1. **The node kernel is Linux ≥ 6.12.** This is the kernel of the node, not of the container
   image.
2. **dfuse tells the kernel that it allows idmapped mounts.** That is what the patch adds:
   - **PR 1** adds the dfuse option `--allow-idmap`. It also changes the ioctl check through
     which libpil4dfs and libioil get dfuse's handles: with idmap enabled, the kernel no longer
     sends the caller's uid and gid.
   - **PR 2** updates DAOS's libfuse fork `fused` to v1.1.0 and adds the libfuse
     `FUSE_CAP_ALLOW_IDMAP` backport.
   - **Without PR 2** the option does nothing and logs `Fuse library does not support idmapped
     mounts`.
   - The patch exists for DAOS master and as a port to DAOS 2.8.0. The colleague handed over a
     bundle `csi-daos-2.8.0-allow-idmap`: CSI driver images
     `daos-csi:0.1.0-v2.8.0-allow-idmap` (`localhost/daos-csi:v2.8.0-allow-idmap-u22-r2` or
     `-u24-r2` after `docker load`) and DAOS client tarballs `daos-client-2.8.0-allow-idmap-*`.
3. **dfuse is actually started with `--allow-idmap`.** How it is passed depends on what starts
   dfuse:
   - **csi-daos** (`csi.daos.io`): dfuse runs in "mount pods" in the driver's namespace, usually
     `daos-csi`. The option comes from the StorageClass parameter `dfuseArgs`.
   - **The colleagues' own driver** (`daos-csi-driver`, provisioner `mlcore.daos.csi`, Helm, a
     namespace like `dcd`): dfuse runs inside the `driver` container of its DaemonSet. The
     options come from `mountOptions` in the PV's `volumeAttributes`. Their client image was
     seen as `daos-client:release-v0.0.1`; its content is unknown.
   - **A systemd unit** on the host, with a `hostPath` volume in the pod.
4. **Kubernetes and the runtime support user namespaces with idmapped mounts:**
   - kubelet with user namespaces enabled (`UserNamespacesSupport`), and sub-ids for the user
     `kubelet` (`/etc/subuid`, `getsubids kubelet`);
   - containerd ≥ 2.0 with runc ≥ 1.2, or CRI-O with a recent crun or runc;
   - gVisor or Kata `RuntimeClass`es work differently, so record whether one is used.

These things can also fail even when the mount works:

- **DAOS agent.** Processes of a user-namespaced pod reach `daos_agent` with host uids that have
  no passwd entry. Without `credential_config.client_user_map.default` in `daos_agent.yml` they
  get `DER_NO_PERM` on their own connections.
- **Interception libraries in pods.** libpil4dfs and libioil use dfuse's pool and container
  handles only if the calling process has the same uid as dfuse and dfuse can see its pid (the
  mount pod needs `hostPID`).
  - Otherwise they connect to DAOS themselves. That needs the agent socket in the pod, a network
    path to the DAOS engines without NAT, and, with RDMA, access to RDMA devices.
  - If they cannot connect, I/O silently falls back to dfuse. That is not an error, only slower.
- **RDMA providers (verbs).** Every component that talks to DAOS needs RDMA devices: dfuse, the
  agent's fabric scan and the CSI controller. That means privileged pods or an RDMA device plugin.
- **DFS has no sticky bit.** `chmod 1777`, or a CSI `rootMode: 1777`, fails with `ENOTSUP`.
- **The `-o` mount syntax of dfuse is broken** (`mount -t fuse3 ... -o pool=...,container=...`):
  only the first option is honoured. Command-line arguments work.
- **SELinux enforcing** can block `fusermount3` in systemd units.

## 4. Procedure

### Step 1: the symptom

Ask the operator and record the answers verbatim:

- **What exactly does not work?** Pick the stage:
  - build;
  - installation;
  - dfuse does not start;
  - `--allow-idmap` is not recognized;
  - the volume does not mount;
  - a pod with `hostUsers: false` does not start;
  - I/O errors;
  - permission errors;
  - libpil4dfs or libioil do not intercept.
- **What was deployed?**
  - Which artifact: the bundle, an own build or another image. Exact image tags and digests.
  - How it was installed: Helm values, manifests or packages.
  - Where: which nodes and namespaces.
- **Which pods or nodes show the failure, and since when?** Get the exact error text and a
  timestamp.
- **What works on the same cluster?** For example, the same pod without `hostUsers: false`, or
  dfuse without the option.

### Step 2: inventory and access

- **List the nodes and their roles:**
  - control plane;
  - workers where applications and dfuse run;
  - DAOS servers, which are often outside Kubernetes;
  - DAOS client hosts.
- **For each node, find out how you can reach it.** The options are ssh with sudo, `talosctl`,
  or none. `kubectl debug node/...` creates a pod, so it needs the operator's OK.
- **Group the nodes** by role, OS, kernel and hardware. Survey one representative per group.
  Always survey the node where the failing pod ran (`kubectl get pod -o wide`).

### Step 3: run `survey.sh`

`survey.sh` comes with these instructions. Copy it to the machine where you run it.

```bash
./survey.sh k8s                       # once, where kubectl works
./survey.sh pod <namespace> <pod>     # each failing pod; also one working pod for comparison
sudo ./survey.sh node                 # on each representative node, first the failing pod's node
```

How to run it:

- **Order matters.** Run `pod` and `node` while the failing pod and its dfuse still exist.
- **Output.** Each run writes `survey-<host>-<mode>-<time>/` and a `.tar.gz` of it.
- **Without sudo**, run `node` anyway. The file `00-NOT-ROOT` marks it.
- **Talos nodes have no shell.** Use read-only `talosctl` instead:
  - `talosctl version`
  - `talosctl get extensions`
  - `talosctl read /proc/version`
  - `talosctl get mounts`
  - `talosctl get kernelparamstatus`
  - `talosctl logs kubelet --tail 300`
  - `talosctl logs containerd --tail 300`
- **If you cannot copy the script**, run its commands by hand. Each output file starts with the
  command that produced it.

### Step 4: checks

Answer each item with evidence. The file names refer to `survey.sh` output.

| # | Question | Where to look | How to read it |
|---|---|---|---|
| a | Kernel of the node where the pod runs | `node`: `system.txt` (`uname -a`); `k8s`: `cluster.txt` (KERNEL column) | Must be ≥ 6.12, or idmapped FUSE mounts are impossible |
| b | Which dfuse binary actually runs, and is it patched? | `node`: `dfuse-processes.txt` (binary of the running process, inside its container); `daos-binaries.txt` for binaries on disk | Patch messages in the binary: both `Idmapped mounts allowed` and `Kernel does not support idmapped mounts` mean PR 1 and PR 2. `Fuse library does not support idmapped mounts` means PR 1 without PR 2, so the option is a no-op. No message means no patch, or a different idmap patch: the colleagues' own variant `idmap-v2` turns idmap on always, has no option and none of these messages. Tell them apart with `--allow-idmap` in `--help` and with the outcome. `dfuse --version` prints `Using fuse 1.1.0` with PR 2 and `1.0.0` without |
| c | Is `--allow-idmap` really passed to that dfuse? | `dfuse-processes.txt` (`cmdline:`), then where it comes from: StorageClass `dfuseArgs` (`storage.txt`), PV `volumeAttributes`/`mountOptions` (`volumes.txt`), the systemd unit (`daos-services.txt`) | A missing option is the most common cause |
| d | What did dfuse log about idmap? | `dfuse-processes.txt` (log lines), the driver or mount-pod logs (`node-pods-logs.txt`, `daos-ns-*-logs.txt`) | The lines `Idmapped mounts allowed`, `Kernel does not support ...` and `Fuse library does not support ...` are INFO: you see them only if dfuse runs with `D_LOG_MASK` INFO or more. Without them, rely on b, c and the outcome. Do not change the log level of a running dfuse |
| e | FUSE mount of the volume | `dfuse-processes.txt` (mounts), `fuse.txt` | `fuse.daos` with `default_permissions,allow_other` is expected. Note `user_id` and `group_id` |
| f | Are user namespaces enabled in Kubernetes? | `kubelet-configz.txt` (`featureGates`, `userNamespaces`), `control-plane.txt`, `system.txt` (`/etc/subuid`, `getsubids kubelet`), `cluster.txt` (`kubectl version`) | Does any `hostUsers: false` pod run on that node? Check existing pods. A test pod needs the operator's OK |
| g | Container runtime and OCI runtime | `k8s-node.txt` (containerd or CRI-O version and config, `runc` and `crun` versions, `crictl info`), `storage.txt` (`RuntimeClass`) | Record exact versions. Note the failing pod's `runtimeClassName` |
| h | The failing pod | `pod.txt` (spec, events), `pod-logs.txt`, `volumes.txt` | Quote the exact event. Record `hostUsers`, `securityContext` (`runAsUser`, `fsGroup`, `privileged`), volume type (CSI, `hostPath` on a dfuse mount, `subPath`), node |
| i | CSI driver | `storage.txt` (`csidrivers`, StorageClasses), `daos-workloads.txt`, `daos-ns-*.txt`, `helm.txt` | Which driver: `csi.daos.io`, `mlcore.daos.csi` or another. Record its images, where dfuse runs, and `privileged`, `hostPID`, `hostNetwork`, mount propagation, resources |
| j | DAOS agent | `daos-config.txt` (`daos_agent.yml`), `daos-services.txt`, `daos-ns-*.txt` (agent DaemonSet or ConfigMap) | Record where the agent runs, its version, `access_points`, `include_fabric_ifaces`, `credential_config.client_user_map` and `disable_auto_evict` |
| k | DAOS servers | server `node` survey: `daos-config.txt`, `daos-system.txt`, `daos-binaries.txt` | Record the version, `provider`, transport security (`allow_insecure`), and pool and container ACLs if you can query them read-only |
| l | Fabric | `fabric.txt`, `daos-fabric.txt`, `network.txt` | Record the provider (`ofi+tcp`, `ofi+verbs;ofi_rxm`, `ucx+...`, `ofi+cxi`), the NIC model, and whether it is RoCE or InfiniBand. With RDMA, record whether pods that run dfuse, the agent or the CSI controller have `/dev/infiniband` (privileged, or an RDMA device plugin) |
| m | Security layers | `system.txt` (SELinux, AppArmor), `security.txt` (namespace Pod Security labels, OpenShift SCC, Kyverno or Gatekeeper, webhooks) | Look for anything that mutates or denies `hostUsers`, privileged pods, `hostPID` or `hostPath` |
| n | Network between pods and DAOS | `network.txt` (CNI, pod CIDRs, kube-proxy mode) | NAT between pods and DAOS servers matters only for interception libraries connecting from pods |

### Step 5: the report

1. Write `REPORT.md` from the template in section 7. Fill in every field: a value, `unknown`
   with a reason, or `n/a`.
2. Put the survey `.tar.gz` files next to it.
3. Search everything you hand over for secrets:

   ```bash
   grep -rIiE 'token|passw|secret|BEGIN .*KEY|client-key|bearer' <files>
   ```

   Anything found must be `<redacted>`, or the file must be left out.
4. Hand the report and the archives to the operator.

## 5. What the lab can reproduce

The lab can reproduce the following. Be precise about these items, because each maps to one lab
setting:

- **Nodes:** AlmaLinux 9.x VMs on the EL9 stock kernel (5.14) or ELRepo kernel-ml (currently
  7.2); Talos nodes.
- **Kubernetes:** kubeadm of any 1.3x version, or Talos.
- **Container runtime:** containerd and runc of chosen versions, gVisor.
- **DAOS:** the 2.8.0 release or any build (git ref + patches), as RPMs or an `/opt/daos`
  tarball.
- **Images:** Ubuntu 22.04 and 24.04 client images.
- **Fabric:** `ofi+tcp`, and `ofi+verbs;ofi_rxm` over software RoCE.
- **CSI drivers:** csi-daos, and the colleagues' driver.

The lab cannot reproduce the following, so record any detail that may matter:

- Ubuntu or other non-EL distributions as the node OS;
- CRI-O, OpenShift, managed clouds (EKS, AKS, GKE);
- real RDMA NICs, InfiniBand, CXI;
- several DAOS servers;
- GPUs.

## 6. Do not

- Do not fix the cluster, even when the fix looks obvious. Report it as a hypothesis.
- Do not create test pods, PVCs or StorageClasses without the operator's OK.
- Do not restart dfuse, agents, drivers or kubelet, and do not unmount anything. Other workloads
  may depend on them.
- Do not run `dmg` commands that change state: pool or container create, destroy and set-prop,
  `system stop`, `system start`.
- Do not copy Secrets, kubeconfigs, keys or certificates anywhere.

## 6a. If you can read only one namespace

With no node access and no cluster-wide read, most of section 4 can still be answered from
**inside pods of the namespace you can read**, using `probe.sh` through `kubectl exec`. That is
the "exec" exception of rule 1, so ask the operator's OK first. The probe only reads, except for
`WRITE_TEST=1`.

1. Check that `exec` is allowed:

   ```bash
   kubectl auth can-i create pods/exec -n <ns>
   ```

2. **Application pod**, preferably one with `hostUsers: false` and a DAOS volume. In a container,
   `uname -r` shows the node's kernel, so this gives check a. It also gives the user-namespace
   mapping and what is really mounted at the volume: `fuse.daos` with `idmapped` in its options
   means an idmapped dfuse mount. Anything else means that dfuse does not serve the volume. It
   also shows the DAOS client and the dfuse patch markers in the image.

   ```bash
   kubectl -n <ns> exec -i <app-pod> -- sh -s < probe.sh > probe-<app-pod>.txt 2>&1
   ```

3. **A privileged pod with `hostPID`** on the same node, for example the `daos_agent` DaemonSet
   pod. It sees every process of the node, so it shows every dfuse, whichever driver started it:
   its arguments (is `--allow-idmap` there?), the patch markers of the binary that actually runs,
   its FUSE mounts, its log lines about idmap, and the node's network interfaces. This answers
   checks b, c, d, e and l without node access.

   ```bash
   kubectl -n <ns> exec -i <agent-pod-on-that-node> -- sh -s < probe.sh > probe-<agent-pod>.txt 2>&1
   ```

4. Optionally, with the operator's OK, `WRITE_TEST=1` writes and reads back 1 MiB on the volume
   and shows the file owner as the pod sees it.

## 7. Report template (`REPORT.md`)

````markdown
# Survey report: <cluster name or alias>, <date>

## 1. Symptom
- Stage: <build | install | dfuse start | option unknown | mount | pod start | I/O | permissions | interception>
- What was deployed: <artifact, image tags/digests, how installed>
- Exact error (verbatim, with where it was seen and when):
  ```
  <message>
  ```
- What works for comparison: <...>

## 2. Findings per check (section 4, a–n)
| # | Finding | Evidence (file or command + output) |
|---|---|---|
| a | | |
| ... | | |

## 3. Most likely cause(s)
Hypotheses only, ranked, each with the evidence for and against. No fixes were applied.

## 4. Unknowns and what is needed to resolve them
- <item>: <why unknown, who could provide it>

## 5. Machine-readable summary for the lab
```yaml
cluster:
  alias: <name>
  names_anonymized: <yes|no>
nodes:                      # one entry per distinct group
  - role: <k8s-control-plane | k8s-worker | daos-server | daos-client>
    count: <n>
    os: <e.g. Ubuntu 22.04.4 LTS | RHEL 9.4 | Talos v1.x>
    kernel: <uname -r>
    arch: <x86_64 | aarch64>
    cpus_mem: <e.g. 64 cores, 512 GiB>
    selinux: <enforcing | permissive | disabled | n/a>
    apparmor: <enabled | disabled | n/a>
    cgroup: <v1 | v2>
kubernetes:
  distribution: <kubeadm | OpenShift x.y | RKE2 | k3s | Talos | EKS | other>
  version: <server version>
  kubelet_version: <...>
  user_namespaces: {feature_gate: <on | off | default>, kubelet_subids: <yes | no | unknown>}
  container_runtime: <containerd x.y.z | cri-o x.y.z>
  oci_runtime: <runc x.y.z | crun x.y>
  runtime_classes: [<gvisor | kata | ...>]
  failing_pod_runtime_class: <none | name>
  cni: <calico | cilium | flannel | ovn | ...>
  pod_cidr: <...>
  pod_security: <namespace labels, SCC, policies relevant to the failing pod>
daos:
  server_version: <...>
  server_hosts: <in-cluster | outside>
  client_version: <...>
  client_install: <rpm | deb | opt-tarball | image:<tag>>
  dfuse_binary_in_use: <path inside its container + image>
  dfuse_patch_markers: <"allowed"+"kernel" | "fuse library" | none>
  fuse_library: <"Using fuse 1.1.0" | "1.0.0">
  allow_idmap_passed: <yes | no> (from <StorageClass dfuseArgs | PV mountOptions | unit>)
  dfuse_runs_in: <csi-daos mount pod | colleagues driver container | systemd | other>
  provider: <ofi+tcp | ofi+verbs;ofi_rxm | ucx+... | ofi+cxi>
  fabric_hw: <none | mlx5 ConnectX-N RoCE | mlx5 IB | cxi | ...>
  rdma_device_plugin: <none | name>
  transport_security: <insecure | certificates>
  agent: {runs_as: <systemd | daemonset>, client_user_map_default: <user:group | none>,
          include_fabric_ifaces: <...>, disable_auto_evict: <true | false | unset>}
  pool_container_acl: <owner and entries, if known>
csi:
  driver: <csi.daos.io | mlcore.daos.csi | other>
  images: [<...>]
  privileged: <yes | no>
  host_pid: <yes | no>
  host_network: <yes | no>
  storageclass_or_pv_params: {<key>: <value>}
failing_pod:
  host_users: <true | false | unset>
  run_as_user: <...>
  volume: <csi | hostPath to dfuse mount | ...>
  uses_interception: <libpil4dfs | libioil | none>
  agent_socket_mounted: <yes | no>
not_reproducible_in_lab: [<items from section 5 that matter here>]
````
