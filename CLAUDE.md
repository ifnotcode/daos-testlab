# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A reproducible DAOS test lab built on libvirt VMs. The lab is described by `lab.conf`, built by
`bin/lab`, and can be recreated from scratch with `bin/lab up`. It started as the lab for the DAOS
`dfuse --allow-idmap` patch (Kubernetes pods with `hostUsers: false` on dfuse volumes). Those tests
now serve as examples for new DAOS test tasks. The user-facing docs are in Russian: `README.md`,
`tests/README.md` and `docs/gotchas.md`. Read `docs/gotchas.md` before changing node setup or
writing tests.

## Where code runs

There are three execution contexts, and each file belongs to exactly one of them.

- **Workstation** (`bin/lab`, `lib/common.sh`, `lib/build.sh`, `lib/csi.sh`): runs locally,
  usually on macOS with **bash 3.2**. Do not use `mapfile`, associative arrays, `${x,,}`, or
  empty-array expansion under `set -u`. It only talks ssh to the host (`lab`) and the VMs (ProxyJump
  via the host).
- **libvirt host** (`host/*.sh`, and `talos/patches` rendered by `host/create-talos.sh`):
  `host_run` copies `lib host talos` plus `lab.env` to a directory of its own under
  `$HOST_WORK/run/` (several lab commands may run at once) and runs them as the host user.
  **There is no sudo on the host.** Claude must never type the host password. Use
  `virsh -c qemu:///system` (libvirt group), `virt-install` and rootless podman.
- **VMs** (`nodes/*.sh`, `tests/*.sh`): `vm_run` copies `lib nodes tests` plus `lab.env` to
  `/tmp/testlab` and runs them with sudo. VMs are AlmaLinux 9 with bash 5. The VM user is
  `VM_USER` (`admin`), with passwordless sudo.

Configuration flows one way. `lab.conf`, plus an optional `lab.conf.local` or a profile given with
`-c`, is sourced by `lib/common.sh:load_config`. `write_env_file` serializes the settings with
`declare -p` into `work/<lab>/lab.env`. Remote scripts source that file through `$LAB_ENV`
(`lib/remote.sh` for host and node scripts, directly for tests). **A new setting must also be added
to `write_env_file`** before remote scripts can see it. `work/<lab>/` also holds the generated
`ssh_config` and `known_hosts`. Use `ssh -F work/default/ssh_config <vm>` for ad-hoc access, or
`bin/lab ssh <vm>`.

## Conventions

- **Node scripts must be idempotent.** `lab provision` re-runs all of them. A script that needs a
  reboot exits with **100**. `step()` in `bin/lab` then reboots the VM and runs the script again,
  up to 3 times.
- **Roles.** `server`, `client`, `k8s`, `k8s-worker`, `talos` and `ftest` come from the `VMS`
  array (`name role ip mac vcpus ram_mb disk_gb image kernel`). `provision_vm` in `bin/lab` maps
  each role to its node scripts.
  - `k8s` is a kubeadm control plane. Without `k8s-worker` VMs it is a single node that also runs
    workloads. A `k8s-worker` joins the config's first `k8s` VM with a token that
    `join_worker` gets from it, and its `lab kubectl` runs on the control plane.
  - In a config without a server, `k8s` and `k8s-worker` get no DAOS (no repo, no client, no
    registry, no no-NAT rule). The Kubernetes course stands
    (`/Users/Dmitry/Documents/Claude/k8Learning/stands/`) are such labs.
  - `pod_routes` (server routes to pod networks) knows one pod CIDR per `k8s` VM, not the
    per-node subnets of workers. A lab with a server and workers needs per-node routes first. `kernel=ml` adds ELRepo kernel-ml (≥ 6.12, needed for FUSE idmapped
  mounts). The `alma9.7` image pins dnf to the 9.7 vault. `vm-power.sh config` (run by `start`)
  sets a domain's vCPUs and RAM to the config's, from its next cold start.
- **ftest** (`profiles/ftest.conf`): two VMs of role `ftest` (`nodes/ftest-node.sh`, a shared ssh
  key of VM_USER from `ftest_ssh`) for DAOS's avocado tests, run by `tests/ftest.sh` through
  `launch.py`. The harness sets up and starts its own server (8 vCPUs: an engine needs its
  targets plus 2 cores). `FORCE_IDMAP=1` patches `util/dfuse_utils.py` on the launch node.
- **Test packages** (`lab deploy <vm> tests [pkg...]`, `nodes/deploy-tests.sh`): the build's
  `daos-client-tests` etc. with their requirements from the repositories and `rpm --nodeps` for
  the rest (`ior`, which no configured repository has). `deploy-rpms.sh` takes them out before a
  dnf transaction and puts them back afterwards.
- **Builds are shared by all labs on the host.** `lab build` writes to
  `$HOST_BUILDS/<name>/{ctx,out}` (`$LAB_HOST_STORE/builds`), and other commands refer to a build
  as `@<name>`.
  - An EL9 build produces `out/rpms`, `out/opt-daos.tar.gz`, `out/daos-src.tar.gz`, and the image
    `localhost/daos-client:<name>` in the host's podman.
  - An Ubuntu build produces `out/daos-<ver>-<name>-ubuntu<ver>-x86_64.tar.gz`.
- **Patch sets.** `patchsets/<name>/*.patch` are applied in order with `git apply` to a fresh
  shallow clone of `daos-stack/daos` at `--ref`. Changes to DAOS deps, such as a fused bump, are
  carried as `deps/patches/<comp>/*.patch` inside a DAOS patch, the way upstream does it.
  `--patches` can be repeated; the sets are applied in the given order.
- **RDMA** (`profiles/rdma.conf`, `DAOS_PROVIDER="ofi+verbs;ofi_rxm"`): software RDMA on eth0
  from `nodes/rdma.sh`, because the host has no RDMA hardware.
  - DAOS needs `patchsets/soft-rdma`, a lab-only change to sysfs device discovery. It lives on
    branch `lab-soft-rdma` in the patch project's DAOS clone and is not part of the PRs.
  - The profile's `DAOS_BUILD=@<build>` makes provisioning install that build everywhere.
  - `daos-server.sh` sets `FI_UNIVERSE_SIZE=64` for the engine and, via `client_env_vars`, for
    the clients.
  - With verbs, `lib/csi.sh` makes the CSI agent and controller privileged.
  - See `docs/gotchas.md`.
- **Long podman builds** must keep an ssh session open, and `host_podman_build` does this. Rootless
  containers are killed when the host user's last session ends.
- **Host podman commands go through `host_podman`.** It sets `TMPDIR` under `$HOST_BUILDS`,
  because `/var/tmp` sits on the host's nearly full root filesystem.
- **`bin/lab` dispatches from `main()`,** so it can be edited while a long command runs. Keep new
  top-level code inside functions.
- **Node scripts compare generated configs before restarting services** (`daos_server.yml`,
  `daos_agent.yml`). A needless `daos_server` restart drops every client's handles, and on a
  server reboot the tmpfs SCM, and with it the pool, is gone. `lab provision <server>` recreates
  it.
- **VMs run only while they are needed.** All of them together barely fit the host's 31 GB, so
  they have no autostart, and `lab start|stop|suspend` (`host/vm-power.sh`) manage them.
  - `suspend` saves the RAM with `virsh save` to `$HOST_SAVED` (`$LAB_HOST_STORE/saved/<lab>`).
    libvirt's managed save would write to the host's small root filesystem. libvirt does not
    track these images, so `vm-power.sh` stamps the disks' mtime and size at save time and only
    restores an image whose disks still match. After a restore it sets the guest clock with
    `virsh domtime --sync` (qemu-guest-agent). Talos has no agent and is stopped instead.
  - `start` waits for each VM's job: a cold-booted server has no pool, so it reruns
    `nodes/daos-server.sh` and restarts the agents of running clients; clients must reach the
    pool; Kubernetes nodes must be Ready.
  - Commands that need a VM call `require_running`, and `provision` starts a stopped VM.
  - Every VM has a virtio-balloon with free page reporting, so memory the guest frees goes back
    to the host. A restore brings back the domain XML saved in the image: domain config changes
    need a cold `stop` and `start`.
  - VM arguments of `start|stop|suspend|use` and `needs:` are resolved by `resolve_vms`: VM names,
    groups of `VM_GROUPS` (by role, so profiles keep them; not named `GROUPS`, which is a bash
    builtin variable), roles, or `all`.
  - `lab use <group>` suspends the other VMs and starts the group. `lab kernel <vm> stock|ml`
    switches the default kernel until the next provision (`nodes/kernel.sh`).
  - Memory: `make_room` suspends VMs a command does not need, biggest first and the server last,
    until the VMs it starts fit into the host's available memory minus `HOST_MEM_RESERVE_GB`. It
    counts a saved image for a suspended VM and the full RAM for a stopped one.

## Tests

`bin/lab test <suite> <vm> [VAR=value...]` copies `tests/` and runs `tests/<suite>.sh` as root on
the VM. For a talos VM it runs on the host with the Talos kubeconfig. For a k8s VM,
`KUBECONFIG=/etc/kubernetes/admin.conf` is set.
- Suites source `tests/lib/check.sh`, record results with
  `check "<name>" <expected> <actual>`, and end with `report`, which exits 1 on any FAIL.
- Line 2 of a suite is its description in `lab test list`. Line 3, `# needs: <roles, groups, VMs
  | none>` (default `server`), is what it needs besides the VM it runs on.
- `lab test` starts what the suite needs (`make_room` first; `--exclusive` suspends every VM it
  does not need) and suspends again what it started, unless `--keep`. It keeps the suite's exit
  code.
- `tests/known-failures.txt` lists failures that are not the tested code's fault
  (`<suite> <test> <status> <reason>`). `tests/ftest.sh` reports them as expected, and a known
  failure that passes again as FAIL. The evidence is in
  `/Users/Dmitry/Documents/Claude/DaosInmapPatch/KNOWN-ISSUES.md`. Check both before investigating
  a failure.
- Kubernetes after a cold boot: the node turns Ready before the control plane has settled, so
  `node_ready` also waits until the kube-system and daos-csi pods stay Ready.
- `DAOS_PREFIX` selects the DAOS under test: `/usr` for RPMs, `/opt/daos` for a deployed tree.
- See `tests/README.md` for each suite's prerequisites.

Common flows:

```bash
bin/lab check && bin/lab up && bin/lab test smoke client-1
bin/lab status                              # VM state and memory, host memory available
bin/lab use plain                           # only daos-1 and client-1 run, the rest is suspended
bin/lab test --exclusive nlt k8s-1          # starts k8s-1 alone, suspends it again afterwards
bin/lab build el9 --ref v2.8.0 --patches patchsets/allow-idmap-v2.8.0     # ~1 h on the host
bin/lab deploy client-1 rpms @el9-v2.8.0-allow-idmap-v2.8.0
bin/lab test dfuse-idmap client-1
bin/lab -c profiles/verify.conf up          # a second, independent lab on the same host
bin/lab test k8s-smoke k8s-1                # base for Kubernetes suites (kubeadm or Talos)
```

## Lab host facts

- Host `192.168.1.83`, user `user`, key `~/.ssh/keys/almaserver1`.
- Big files live on an external USB SSD, `LAB_HOST_STORE=/mnt/keenetic/daos-testlab`, which is
  ext4 with ~1.3 TB free. It holds the libvirt pool `testlab` (`pool/`), `builds/`, `cache/`
  (downloads through `cached()` in `lib/remote.sh`) and `saved/` (RAM of suspended VMs).
- Keep VM disks off the host's root filesystem, which holds libvirt's default `images` pool.
  It is small: it had ~6 GB free while the old VMs lived there and ~45 GB after they were removed.
  VM disks use `discard=unmap`, and provisioning ends with `fstrim`.
- Podman storage stays in `/home`.
- On 2026-09-27 the main lab (`lab.conf`) was destroyed and recreated from scratch by these
  scripts, and its current contents are listed in README ("Что проверено").
  - client-1 and k8s-1 run the build `@el9-master-0dbc4dd-allow-idmap-r2` (PR 1 with the
    `/dev/fd/N` refusal). The previous build `@el9-master-0dbc4dd-allow-idmap` is kept on the host.
  - k8s-1 also has the `/opt/daos` tree and `~/daos-src` for NLT.
  - CSI on k8s-1: `daos-csi:master-0dbc4dd-idmap-r8` (02.10.2026: metrics and health on ports
    9810/9811, log options, mount pod resources, thread count, volumes per node, health checks).
    talos-1 still has `-r2`. The registry is on daos-1.
  - `patchsets/allow-idmap-v2.8.0` is the port of the current PRs (PR 1 `f7c505b` with its NLT test
    in `utils/node_local_test.py`, PR 2 as before). Builds from it:
    `@ubuntu-{22.04,24.04}-v2.8.0-allow-idmap-r3-client`, base images
    `localhost/daos-client-ubuntu:{22.04,24.04}-v2.8.0-allow-idmap` and CSI images
    `daos-csi:v2.8.0-allow-idmap-u{22,24}-r2`.
  - The colleagues' driver (`tests/k8s-mlcore-csi.sh`): images `mlcore-csi:orig-v2.8.0` and
    `mlcore-csi:fixed-v2.8.0-r2`.
  - client-1 also has `daos-client-tests` (`lab deploy client-1 tests`) and podman.
  - `profiles/ftest.conf` exists too: ft-server (8 vCPUs, stock kernel) and ft-client (6 vCPUs,
    kernel-ml), with `@el9-master-0dbc4dd-allow-idmap-r2` and its test packages.
  - `@el9-master-0dbc4dd-baseline` is master 0dbc4dd without patches, for A/B checks.
  - The old scripts in `/Users/Dmitry/Music/Claude/Daos/Agent/testenv` are superseded.
- Kubernetes on the k8s VMs uses the CSI driver from `CSI_DIR`, a separate repo
  (`/Users/Dmitry/Music/Claude/Daos/Agent/csi-daos`).
- The DAOS work this lab was built for (the upstream `--allow-idmap` patch, Jira and PR texts)
  lives in `/Users/Dmitry/Documents/Claude/DaosInmapPatch` (the `upstream/` directory).

## Commits

- The author is `Dmitry Polonsky <ifnotelse@gmail.com>`.
- Do not add Claude co-author lines or `Signed-off-by` on the user's behalf.
- Commit only when the user asks. The repository has no commits yet.
