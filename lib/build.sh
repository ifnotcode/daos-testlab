# "lab build": DAOS from source with a patch set, on the libvirt host with rootless podman.
# Results stay on the host in $HOST_BUILDS/<name>/out; "lab deploy <vm> rpms|tree @<name>"
# takes them from there.
# shellcheck shell=bash

# prepare_source <name> <ref> [patch dir...]: DAOS tree in $HOST_BUILDS/<name>/ctx/daos. The patch
# sets are applied in the given order: their files get the prefix 1-, 2-, ... on the host.
prepare_source() {
	local name=$1 ref=$2 ctx=$HOST_BUILDS/$1/ctx dir f i=0 n=0
	shift 2
	host_ssh "rm -rf $ctx/patches && mkdir -p $ctx/patches"
	for dir in "$@"; do
		i=$((i + 1))
		[ -d "$dir" ] || die "no patch directory $dir"
		ls "$dir"/*.patch >/dev/null 2>&1 || die "no *.patch in $dir"
		for f in "$dir"/*.patch; do
			vm_scp "$f" "lab:$ctx/patches/$i-$(basename "$f")"
			n=$((n + 1))
		done
	done
	log "source: daos-stack/daos $ref + $n patches"
	host_ssh "set -e; cd $ctx; rm -rf daos
		if echo '$ref' | grep -qE '^[0-9a-f]{40}\$'; then
			# a commit (full SHA): fetch only that commit
			git init -q daos
			git -C daos fetch -q --depth 1 https://github.com/daos-stack/daos.git '$ref'
			git -C daos checkout -q FETCH_HEAD
		else
			git clone -q --depth 1 --branch '$ref' https://github.com/daos-stack/daos.git daos
		fi
		echo \"source: \$(git -C daos log -1 --format='%h %cd %s' --date=short)\"
		git -C daos submodule -q update --init
		for p in \$(ls patches/*.patch 2>/dev/null | sort); do
			git -C daos apply \"\$PWD/\$p\" || { echo \"patch \$p does not apply to $ref\"; exit 1; }
			echo \"applied \$(basename \$p)\"
		done
		git -C daos status --short | head -20"
}

# source_info <name>: what a build was made from, in <out>/source and in its tarballs
# (opt/daos/share/daos/source): SOURCE (base commit and patches), the patches as applied, and
# daos.diff, the whole change of the build tree against the base commit (new files included).
# The tarballs are packed again with root as the owner, as they were in the container.
source_info() {
	local ctx=$HOST_BUILDS/$1/ctx out=$HOST_BUILDS/$1/out
	host_ssh "set -e; cd $ctx/daos
		git add -A -N # files the patches add (e.g. deps/patches) show up in the diff
		rm -rf $out/source && mkdir -p $out/source
		git diff HEAD >$out/source/daos.diff
		{ echo 'repository: https://github.com/daos-stack/daos'
		  echo \"base: \$(git log -1 --format='%H %cd %s' --date=short HEAD)\"
		  echo 'patches, applied in this order with git apply:'
		  for p in \$(ls ../patches/*.patch 2>/dev/null | sort); do echo \"  \$(basename \$p)\"; done
		  echo 'daos.diff: all of them together, against the base commit'
		} >$out/source/SOURCE
		cp ../patches/*.patch $out/source/ 2>/dev/null || true
		mkdir -p $HOST_BUILDS/.tmp
		for t in $out/daos-*.tar.gz; do
			[ -e \"\$t\" ] || continue
			tmp=\$(mktemp -d -p $HOST_BUILDS/.tmp)
			tar -xpzf \"\$t\" -C \$tmp
			mkdir -p \$tmp/opt/daos/share/daos/source
			cp $out/source/* \$tmp/opt/daos/share/daos/source/
			tar --owner=0 --group=0 --numeric-owner -czf \"\$t.new\" -C \$tmp opt
			mv \"\$t.new\" \"\$t\"
			rm -rf \$tmp
		done
		ls -la $out/source"
}

# run a podman build on the host, keeping the ssh session open (rootless podman containers are
# stopped when the last session of the host user ends)
host_podman_build() {
	local ctx=$1 log=$2
	shift 2
	host_podman "cd $ctx && podman build --layers $* . > $log 2>&1; rc=\$?; tail -5 $log; exit \$rc"
}

build() {
	local kind=${1:-} ref=master patches="" pnames="" name="" ver="" client=0 ctx out
	[ -n "$kind" ] || die "usage: lab build el9|ubuntu|csi ..."
	shift
	[ "$kind" = ubuntu ] && { ver=${1:?Ubuntu version: 22.04 or 24.04}; shift; }
	if [ "$kind" = csi ]; then
		build_csi "$@"
		return
	fi
	while [ $# -gt 0 ]; do
		case $1 in
		--ref) ref=$2; shift 2 ;;
		--patches)
			# repeatable: the patch sets are applied in this order
			patches="$patches $(cd "$2" && pwd)" || die "no patch directory $2"
			pnames="$pnames${pnames:++}$(basename "$2")"
			shift 2
			;;
		--name) name=$2; shift 2 ;;
		--client) client=1; shift ;;
		*) die "unknown option $1" ;;
		esac
	done
	[ "$client" = 1 ] && [ "$kind" != ubuntu ] && die "--client is for ubuntu builds"
	[ -n "$name" ] || name=$kind${ver:+-$ver}-$ref${pnames:+-$pnames}
	[ "$client" = 1 ] && [ "${name%-client}" = "$name" ] && name=$name-client
	name=${name//\//_}
	ctx=$HOST_BUILDS/$name/ctx
	out=$HOST_BUILDS/$name/out
	# shellcheck disable=SC2086 # patch directories: absolute paths without spaces
	prepare_source "$name" "$ref" $patches
	case $kind in
	el9)
		vm_scp "$LAB_ROOT/build/el9/Containerfile" "$LAB_ROOT/build/el9/Containerfile.client" "lab:$ctx/"
		log "building $name (EL9); log: $ctx/build.log on the host"
		host_podman_build "$ctx" build.log -t "localhost/daos-build:$name" -f Containerfile \
			--build-arg JOBS="\$(nproc)"
		host_podman "set -e; rm -rf $out; mkdir -p $out; id=\$(podman create localhost/daos-build:$name)
			podman cp \$id:/out/. $out/; podman rm \$id >/dev/null
			rm -rf $ctx/client && mkdir -p $ctx/client/rpms && cp $out/rpms/*.rpm $ctx/client/rpms/
			rm -f $ctx/client/rpms/*debuginfo* $ctx/client/rpms/daos-server* $ctx/client/rpms/*spdk*
			cp $ctx/Containerfile.client $ctx/client/
			cd $ctx/client && podman build -q -t localhost/daos-client:$name -f Containerfile.client . >/dev/null
			ls -la $out; echo \"client image: localhost/daos-client:$name\""
		;;
	ubuntu)
		vm_scp "$LAB_ROOT/build/ubuntu/Containerfile" "lab:$ctx/"
		local targets=install
		# only the client and its dependencies (scons target "client")
		[ "$client" = 1 ] && targets="client install"
		log "building $name (Ubuntu $ver, QSG, scons $targets); log: $ctx/build.log on the host"
		host_podman_build "$ctx" build.log -t "localhost/daos-build:$name" -f Containerfile \
			--build-arg BASE_IMAGE=docker.io/library/ubuntu:$ver --build-arg DISTRO="ubuntu$ver" \
			--build-arg NAME="$name" --build-arg JOBS="\$(nproc)" \
			--build-arg "'SCONS_TARGETS=$targets'"
		host_podman "set -e; rm -rf $out; mkdir -p $out; id=\$(podman create localhost/daos-build:$name)
			podman cp \$id:/out/. $out/; podman rm \$id >/dev/null; ls -la $out"
		source_info "$name"
		;;
	*) die "unknown build kind $kind (el9, ubuntu, csi)" ;;
	esac
	log "build $name done: lab:$out (use @$name with lab deploy)"
}

# build_csi <base image> <tag>: CSI driver image from $CSI_DIR, pushed to the lab registry
build_csi() {
	local base=${1:?base image with the DAOS client} tag=${2:?image tag} ctx=$HOST_BUILDS/csi reg
	reg=$(grep '^REGISTRY=' "$WORK/lab.env" | cut -d= -f2)
	(cd "$CSI_DIR" && COPYFILE_DISABLE=1 tar czf - --no-xattrs --exclude=overlay --exclude=hack .) |
		host_ssh "rm -rf $ctx && mkdir -p $ctx/overlay && tar xzf - -C $ctx"
	host_podman_build "$ctx" build.log --build-arg BASE="$base" -t "localhost/daos-csi:$tag"
	host_podman "podman tag localhost/daos-csi:$tag $reg/daos-csi:$tag && podman push -q --tls-verify=false $reg/daos-csi:$tag"
	log "CSI image: $reg/daos-csi:$tag"
}
