#!/bin/sh
# probe.sh - read-only checks from INSIDE a pod, for when there is no node access. Run it through
# kubectl exec (which needs the operator's OK), output goes to the terminal:
#
#   kubectl -n <ns> exec -i <pod> [-c <container>] -- sh -s < probe.sh > probe-<pod>.txt 2>&1
#
# In an application pod: the node's kernel (uname in a container shows the node's), the user
# namespace mapping, what is really mounted at the DAOS volume, the dfuse/DAOS client in the image.
# In a privileged pod with hostPID (e.g. the daos_agent DaemonSet): additionally every dfuse
# process of the node, whoever started it: its arguments, the patch markers of its binary, its
# FUSE mounts and idmap log lines, plus the node's network interfaces.
# Optional, only with the operator's OK: WRITE_TEST=1 (write and read back a 1 MiB file on the
# volume), VOLUME=<mount path> (default: every fuse/DAOS-looking mount found).
#   kubectl -n <ns> exec -i <pod> -- env WRITE_TEST=1 sh -s < probe.sh
# POSIX sh; works with busybox. Masks nothing because it reads no configuration files.

MARKERS='Idmapped mounts allowed|Kernel does not support idmapped mounts|Fuse library does not support idmapped mounts'
say() { printf '\n## %s\n' "$*"; }

markers() { # binary -> the patch messages it contains, or "none"
	m=$(grep -aoE "$MARKERS" "$1" 2>/dev/null | sort -u)
	echo "  patch messages: ${m:-none}" | sed '2,$s/^/                  /'
	printf '  knows --allow-idmap: '; grep -aoE -- '--allow-idmap' "$1" 2>/dev/null | sort -u | grep -c . || echo 0
}

say "context"
echo "hostname: $(hostname)"
echo "node kernel (uname -r): $(uname -r)"
echo "id: $(id)"
printf 'uid_map: '; tr -s ' ' <"/proc/self/uid_map"
printf 'gid_map: '; tr -s ' ' <"/proc/self/gid_map"
printf 'container OS: '; (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
hostpid=no
[ -r /proc/1/comm ] && case $(cat /proc/1/comm) in systemd | init) hostpid=yes ;; esac
echo "sees the node's processes (hostPID): $hostpid"

say "mounts that look like DAOS / FUSE"
grep -E 'fuse|daos|dfuse' /proc/self/mountinfo || echo "none"
for v in ${VOLUME:-$(awk '$0 ~ /fuse|daos/ {print $5}' /proc/self/mountinfo | sort -u)}; do
	echo "--- $v"
	stat -f -c 'fs type: %T' "$v" 2>/dev/null || df -T "$v" 2>/dev/null | tail -1
	ls -lnd "$v"; ls -ln "$v" 2>&1 | head -8
	if [ "${WRITE_TEST:-0}" = 1 ]; then
		f=$v/.probe-$$; head -c 1048576 /dev/urandom >/tmp/probe-$$
		if cp /tmp/probe-$$ "$f" 2>/tmp/probe-err && cmp -s /tmp/probe-$$ "$f"; then
			echo "write+read 1 MiB: ok, file owner as seen here: $(stat -c %u:%g "$f")"
		else
			echo "write+read 1 MiB: FAILED: $(cat /tmp/probe-err)"
		fi
		rm -f "$f" /tmp/probe-$$ /tmp/probe-err
	fi
done
echo "--- \"idmapped\" in the mount options: the volume is an idmapped mount (user namespace)."
echo "--- a volume that is not fuse.daos here (e.g. ext4/xfs/overlay) is not served by dfuse"

say "DAOS client in this image"
seen=" "
for b in $(command -v dfuse) /opt/daos/bin/dfuse /usr/bin/dfuse; do
	[ -x "$b" ] || continue
	case $seen in *" $b "*) continue ;; esac
	seen="$seen$b "
	echo "$b: $("$b" --version 2>&1 | tr '\n' ' ')"
	markers "$b"
done
for b in daos daos_agent; do command -v $b >/dev/null && echo "$b: $($b version 2>&1 | head -1)"; done
ls /usr/lib64/libpil4dfs.so /usr/lib64/libioil.so /opt/daos/lib64/libpil4dfs.so /opt/daos/lib64/libioil.so 2>/dev/null
ls -l /var/run/daos_agent/ 2>&1 | head -3
env | grep -E '^(D_|DD_|FI_|CRT_|OFI_|DAOS|LD_PRELOAD)' | sed 's/=.*TOKEN.*/=<redacted>/'

say "dfuse processes visible from here"
found=0
for p in /proc/[0-9]*; do
	[ "$(cat "$p/comm" 2>/dev/null)" = dfuse ] || continue
	found=1; pid=${p#/proc/}
	echo "--- pid $pid"
	printf '  cmdline: '; tr '\0' ' ' <"$p/cmdline"; echo
	grep -E '^(Uid|Gid):' "$p/status" | tr -s '\t' ' ' | sed 's/^/  /'
	printf '  cgroup: '; head -1 "$p/cgroup" 2>/dev/null
	echo "  binary: $(readlink "$p/exe" 2>/dev/null)"
	markers "$p/exe"
	echo "  version: $(chroot "$p/root" "$(readlink "$p/exe")" --version 2>/dev/null | tr '\n' ' ')"
	# its own mount point: after --mountpoint/-m, else the last absolute path argument; then every
	# mount of the same FUSE device (the staging mount and the bind mounts into pods)
	mp=$(tr '\0' '\n' <"$p/cmdline" | awk '
		prev == "--mountpoint" || prev == "-m" { m = $0 } { prev = $0 }
		/^--mountpoint=/ { m = substr($0, 14) }
		/^\// && m == "" { last = $0 }
		END { print (m != "" ? m : last) }')
	dev=$(awk -v t="$mp" '$5 == t {print $3; exit}' "$p/mountinfo" 2>/dev/null)
	echo "  mount point: $mp (device ${dev:-not found})"
	echo "  mounts of this dfuse (target, mount options, FUSE options):"
	[ -n "$dev" ] && awk -v d="$dev" '$3 == d {print "    " $5, $6, $(NF)}' "$p/mountinfo" | sort -u
	log=$(tr '\0' '\n' <"$p/environ" 2>/dev/null | sed -n 's/^D_LOG_FILE=//p')
	tr '\0' '\n' <"$p/environ" 2>/dev/null | grep -E '^(D_LOG_MASK|D_LOG_FILE|FI_PROVIDER|D_PROVIDER|D_INTERFACE)=' | sed 's/^/  env: /'
	if [ -n "$log" ] && [ -r "$p/root$log" ]; then
		echo "  log $log, idmap lines and last errors:"
		grep -E 'Idmapped|idmap|Fuse library|Kernel does not support' "$p/root$log" | tail -5 | sed 's/^/    /'
		grep -E ' ERR | CRIT | EMRG ' "$p/root$log" | tail -5 | sed 's/^/    /'
	fi
done
[ $found = 1 ] || echo "none (without hostPID only this pod's own processes are visible)"

if [ $hostpid = yes ]; then
	say "node network (hostNetwork pods see the node's interfaces)"
	ip -br addr 2>/dev/null || cat /proc/net/dev
	ls /sys/class/infiniband 2>/dev/null && echo "(RDMA devices above)"
fi
echo
echo "probe done"
