#!/usr/bin/env bash
# podman: several containers in user namespaces of their own on one dfuse mount (":idmap" volumes)
# needs: server
# Run by "lab test podman-idmap <client vm> [DAOS_PREFIX=/opt/daos]" as root, kernel >= 6.12.
# Outside Kubernetes, rootful podman with --userns=auto gives each container its own range of host
# uids and, with the volume option "idmap", an idmapped bind mount of the dfuse mount. The checks:
# the containers start only with dfuse --allow-idmap; files keep the owners they have in the
# containers; containers see each other's files with those owners; permissions hold between them.
# podman is installed on first use. The containers have no network: podman's default bridge needs
# the iptables nat table, which ELRepo kernel-ml does not have.
set -uo pipefail
cd "$(dirname "$0")"
source lib/check.sh
source "${LAB_ENV:?}"
daos_paths
MNT=/mnt/podman-idmap
IMAGE=docker.io/library/busybox:1.37
rpm -q podman >/dev/null 2>&1 || dnf -y -q install podman >/dev/null || { echo "no podman" >&2; exit 2; }
# --userns=auto takes host uid ranges from the "containers" entries
grep -q '^containers:' /etc/subuid || echo 'containers:2147483647:2147483648' >>/etc/subuid
grep -q '^containers:' /etc/subgid || echo 'containers:2147483647:2147483648' >>/etc/subgid
podman image exists $IMAGE || podman pull -q $IMAGE >/dev/null

start_dfuse() { # [--allow-idmap]
	mkdir -p "$MNT"
	"$DFUSE" --multi-user "$@" "$MNT" "$POOL" "$CONT" >/dev/null 2>&1
	findmnt -n -t fuse.daos "$MNT" >/dev/null
}
stop_dfuse() { podman rm -af -t 0 >/dev/null 2>&1; fusermount3 -u "$MNT" 2>/dev/null || umount -l "$MNT"; }
DFUSE=$DAOS_BIN/dfuse
run() { # name user command: a detached container with the test directory as an idmapped volume
	podman run --network none -d --name "$1" --userns=auto --user "$2" -v "$DIR:/data:idmap" $IMAGE sh -c "$3" \
		>/dev/null 2>/tmp/podman-$1.err
}
logs() { podman logs "$1" 2>/dev/null | tail -1; }
waitc() { podman wait "$@" >/dev/null 2>&1; }

# control: without --allow-idmap the kernel refuses the idmapped mount
start_dfuse || { check "dfuse mounts" yes no; report "podman-idmap"; exit 1; }
DIR=$MNT/podman-idmap-$$
mkdir -p "$DIR" && chmod 777 "$DIR"
run ctl 0 true
got=started
grep -qi 'idmap\|mount_setattr' /tmp/podman-ctl.err && got=idmap-error
check "without --allow-idmap: container with an :idmap volume" idmap-error "$got"
rm -rf "$DIR"
stop_dfuse

start_dfuse --allow-idmap || { check "dfuse --allow-idmap mounts" yes no; report "podman-idmap"; exit 1; }
DIR=$MNT/podman-idmap-$$
mkdir -p "$DIR" && chmod 777 "$DIR"
# four containers at once: root and uid 1000 twice each, every one in a user namespace of its own
for c in r1:0:0 r2:0:0 u1:1000:1000 u2:1000:1000; do
	n=${c%%:*} u=${c#*:}
	run "$n" "$u" "awk 'NR == 1 {print \"map\", \$2}' /proc/self/uid_map
		echo $n >/data/$n && chmod 644 /data/$n && echo \"wrote \$(stat -c %u:%g /data/$n)\"
		while [ \$(ls /data | wc -l) -lt 4 ]; do sleep 0.2; done
		echo \"sees \$(for f in r1 r2 u1 u2; do stat -c %u:%g /data/\$f; done | tr '\n' ' ')\"
		sleep 30"
done
sleep 5
check "4 containers with :idmap volumes run" 4 "$(podman ps -q | wc -l)"
maps=$(for n in r1 r2 u1 u2; do podman logs $n 2>/dev/null | sed -n 's/^map //p'; done | sort -u | wc -l)
check "4 distinct host uid ranges" 4 "$maps"
check "owners in DAOS: root and uid 1000 of the containers" "0:0 0:0 1000:1000 1000:1000" \
	"$(stat -c %u:%g "$DIR"/r1 "$DIR"/r2 "$DIR"/u1 "$DIR"/u2 | tr '\n' ' ' | sed 's/ $//')"
check "each container sees the owners of all files" 4 \
	"$(for n in r1 r2 u1 u2; do podman logs $n 2>/dev/null | tail -1; done |
		grep -c '^sees 0:0 0:0 1000:1000 1000:1000 $')"

# permissions between containers
try() { # user command
	podman run --network none --rm --userns=auto --user "$1" -v "$DIR:/data:idmap" $IMAGE sh -c "$2" \
		>/dev/null 2>&1 && echo allowed || echo denied
}
check "uid 1000 of another container writes a 0644 file of uid 1000" allowed \
	"$(try 1000:1000 'echo x >>/data/u1')"
check "uid 2000 writes a 0644 file of uid 1000" denied "$(try 2000:2000 'echo x >>/data/u1')"
check "uid 1000 writes a 0644 file of root" denied "$(try 1000:1000 'echo x >>/data/r1')"
check "root of another container writes a 0644 file of root" allowed "$(try 0:0 'echo x >>/data/r1')"

# without idmap the files of a user-namespaced container get its host uids
podman run --network none --rm --userns=auto --user 0:0 -v "$DIR:/data" $IMAGE sh -c 'echo p >/data/plain' >/dev/null 2>&1
check "plain volume (no idmap): the container's root gets a high host uid" yes \
	"$([ "$(stat -c %u "$DIR"/plain 2>/dev/null || echo 0)" -ge 65536 ] && echo yes || echo no)"

rm -rf "$DIR"
stop_dfuse
report "podman-idmap on $(hostname -s), $(uname -r), $(podman --version), $("$DFUSE" --version | head -1)"
