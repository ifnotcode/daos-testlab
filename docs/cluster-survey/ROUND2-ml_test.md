# Second pass on ml_test (after REPORT of 2026-10-18)

Follow `AGENT.md` again, with these changes. The first pass had only the ServiceAccount
`daos-client:storage-team`, so almost everything stayed `unknown`. This pass needs the four things
below. Ask the operator about each of them first.

## 1. Ask the operator

1. **The symptom**, verbatim, from the person who "cannot run the patch": the stage (section 4,
   step 1 of `AGENT.md`), the failing pod and namespace, the exact error text and when it
   happened. If nothing fails to start, say so.
2. **What exactly was deployed**:
   - which CSI driver serves `daos-static`;
   - what runs in the namespaces `daos-csi-driver` and `daos-mount-supervisor`;
   - which images (tags or digests) contain dfuse;
   - whether `--allow-idmap` was configured anywhere (StorageClass, PV `volumeAttributes`
     `mountOptions`, or the supervisor's config);
   - whether the images `ai-platform/daos-client:commit-15cb5127` (the test pod) and
     `:commit-a113b47f` (the agent) are built from the patch bundle `csi-daos-2.8.0-allow-idmap`.
3. **Permission to use `kubectl exec`** in namespace `daos-client`, for the read-only `probe.sh`
   in two pods:
   - `test-daos-client`;
   - the `daos-client` agent DaemonSet pod on `worker-a`. It is privileged with `hostPID`, so from
     it the dfuse processes of `worker-a` are visible.
4. **If possible, read access** (a kubeconfig or role) to:
   - the namespaces `daos-csi-driver` and `daos-mount-supervisor`;
   - cluster-wide `storageclasses`, `persistentvolumes`, `csidrivers`, `runtimeclasses`, `nodes`
     and `events`.

   With that, also run `survey.sh k8s` and `survey.sh pod` again.

## 2. Run

```bash
kubectl auth can-i create pods/exec -n daos-client
kubectl -n daos-client get pods -o wide                    # find the agent pod on worker-a
kubectl -n daos-client exec -i test-daos-client -- sh -s < probe.sh > probe-test-daos-client.txt 2>&1
kubectl -n daos-client exec -i <agent-pod-on-worker-a> -- sh -s < probe.sh > probe-agent-worker-a.txt 2>&1
```

If the operator allows it, also run `WRITE_TEST=1` in `test-daos-client`:

```bash
kubectl -n daos-client exec -i test-daos-client -- env WRITE_TEST=1 sh -s < probe.sh > probe-test-write.txt 2>&1
```

## 3. Questions this pass must answer

| Question | Where it shows |
|---|---|
| Kernel of `worker-a` | `probe-test-daos-client.txt`, `node kernel` |
| Is `/mnt/daos` in the test pod really dfuse, and is it idmapped? | Same file, mounts: `fuse.daos` and `idmapped` |
| Is the dfuse that serves it patched (PR 1+2)? Which binary and version? | `probe-agent-worker-a.txt`, dfuse processes: patch messages, version (`Using fuse 1.1.0`) |
| Is `--allow-idmap` passed? Who starts dfuse (cgroup and pod)? | Same: `cmdline`, `cgroup` |
| What does dfuse log about idmap, and what are its last errors? | Same: log lines |
| Is the DAOS client in the test pod patched, and what are its versions? | `probe-test-daos-client.txt`, DAOS client section |
| Node interfaces and fabric | `probe-agent-worker-a.txt`, node network |

Update `REPORT.md`: replace `unknown` with what was found, keep the evidence, and add the probe
outputs to the archive.
