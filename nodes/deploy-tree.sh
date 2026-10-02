#!/usr/bin/env bash
# Unpacks a /opt/daos install tree (copied by "lab deploy <vm> tree" to ~<VM_USER>/testlab.tar.gz)
# and installs the system libraries it links to. A tree comes without the dependencies of its RPMs:
# e.g. daos_engine, which NLT starts from the tree, needs libunwind.
source "$(dirname "$0")/../lib/remote.sh"

home=$(getent passwd "$VM_USER" | cut -d: -f6)
tarball=$home/testlab.tar.gz
[ -f "$tarball" ] || die "no $tarball"
rm -rf /opt/daos
tar -xzf "$tarball" -C /
rm -f "$tarball"

missing() {
	for f in /opt/daos/bin/* /opt/daos/lib64/*.so*; do ldd "$f" 2>/dev/null; done |
		awk '/not found/ {print $1}' | sort -u
}
for lib in $(missing); do
	# RPMs provide their sonames as "<soname>()(64bit)"
	dnf -y -q install "$lib()(64bit)" >/dev/null 2>&1 || true
done
left=$(missing | tr '\n' ' ')
[ -z "$left" ] || log "no package found for: $left"
log "$(hostname -s): $(/opt/daos/bin/dfuse --version | head -1)"
