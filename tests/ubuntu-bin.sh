#!/usr/bin/env bash
# Ubuntu /opt/daos tarball ("lab build ubuntu"): runtime deps, agent, dfuse-idmap in a container
# needs: server
# Run by "lab test ubuntu-bin <client vm> UBUNTU=24.04 [TARBALL=/path/on/vm]" after
# "lab copy <vm> @<build>" (a full or a client-only build). Starts a privileged Ubuntu container
# (host network) on the VM, installs only the runtime packages of README "Ubuntu binaries", unpacks
# the tarball, checks for missing libraries, prints the libfabric providers and whether server
# parts are in it, starts the tarball's daos_agent and runs dfuse-idmap.sh against the lab pool.
#   TARBALL  default: the newest ~$VM_USER/daos-*-ubuntu$UBUNTU-x86_64.tar.gz
set -euo pipefail
cd "$(dirname "$0")"
source "${LAB_ENV:?}"
UBUNTU=${UBUNTU:?Ubuntu version: 22.04 or 24.04}
home=$(getent passwd "$VM_USER" | cut -d: -f6)
TARBALL=${TARBALL:-$(ls -t "$home"/daos-*-ubuntu"$UBUNTU"-x86_64.tar.gz 2>/dev/null | head -1)}
[ -f "$TARBALL" ] || { echo "no tarball for Ubuntu $UBUNTU (lab copy <vm> @<build>)"; exit 2; }
case $UBUNTU in
22.04) pkgs="libcapstone4 libhwloc15 libibverbs1 ibverbs-providers librdmacm1 libnl-route-3-200 liblz4-1 libnuma1 libprotobuf-c1 libpsm2-2" ;;
24.04) pkgs="libcapstone4 libhwloc15 libibverbs1 ibverbs-providers librdmacm1t64 libnl-3-200 libnl-route-3-200 liblz4-1 libnuma1 libprotobuf-c1 libpsm2-2" ;;
*) echo "UBUNTU must be 22.04 or 24.04"; exit 2 ;;
esac
command -v podman >/dev/null || dnf -y -q install podman
uid=$(id -u "$CONT_OWNER")
echo "tarball: $TARBALL"

podman run --rm --privileged --network=host \
	-v "$TARBALL":/tmp/daos.tar.gz:ro,z -v "$PWD":/tmp/testlab:ro,z -v "$LAB_ENV":/tmp/lab.env:ro,z \
	docker.io/library/ubuntu:"$UBUNTU" bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends $pkgs fuse3 procps gcc libc6-dev >/dev/null
tar -xzf /tmp/daos.tar.gz -C /
export PATH=/opt/daos/bin:\$PATH
missing=\$(for f in /opt/daos/bin/daos /opt/daos/bin/dfuse /opt/daos/bin/daos_agent /opt/daos/lib64/libioil.so \
	/opt/daos/lib64/libpil4dfs.so; do ldd \$f | grep 'not found' || true; done)
[ -z \"\$missing\" ] || { echo \"missing libraries: \$missing\"; exit 1; }
echo 'no missing libraries'
# what a hardware setup cares about: the fabric providers, and no server parts in a client tarball
echo \"libfabric providers: \$(/opt/daos/prereq/release/ofi/bin/fi_info -l 2>/dev/null |
	sed -n 's/^\\([a-z0-9_;]*\\):\$/\\1/p' | tr '\\n' ' ')\"
srv=\$(ls -d /opt/daos/bin/daos_server /opt/daos/bin/daos_engine /opt/daos/prereq/release/spdk \\
	/opt/daos/prereq/release/pmdk 2>/dev/null | tr '\\n' ' ' || true)
echo \"server parts: \${srv:-none}\"
# the container owner has the same uid as on the lab VMs
getent passwd $uid >/dev/null && userdel -r \$(getent passwd $uid | cut -d: -f1) 2>/dev/null || true
groupadd -g $uid $CONT_OWNER 2>/dev/null || true; useradd -u $uid -g $uid -M $CONT_OWNER
mkdir -p /etc/daos /var/run/daos_agent
cat > /etc/daos/daos_agent.yml <<EOF
name: $DAOS_SYSTEM
access_points: ['$SERVER_IP']
port: 10001
transport_config:
  allow_insecure: true
log_file: /tmp/daos_agent.log
include_fabric_ifaces: [eth0]
EOF
daos_agent -o /etc/daos/daos_agent.yml >/dev/null 2>&1 &
sleep 3
echo \"\$(grep PRETTY /etc/os-release | cut -d= -f2), \$(dfuse --version | head -1)\"
cp -r /tmp/testlab /tmp/t
DAOS_PREFIX=/opt/daos LAB_ENV=/tmp/lab.env bash /tmp/t/dfuse-idmap.sh
"
