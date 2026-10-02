/*
 * idmap-bind: create an idmapped bind mount, as container runtimes do for volumes of containers in
 * user namespaces (runc: open_tree + mount_setattr(MOUNT_ATTR_IDMAP) + move_mount).
 *
 *   idmap-bind <pid> <source> <target>
 *
 * The idmapping is the one of the user namespace of <pid>. Needs root and Linux >= 5.12; the
 * filesystem of <source> must support idmapped mounts (FUSE: Linux >= 6.12 and FUSE_ALLOW_IDMAP).
 *
 * Build: gcc -O2 -Wall -o idmap-bind idmap-bind.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/mount.h>

#ifndef SYS_open_tree
#define SYS_open_tree 428
#endif
#ifndef SYS_move_mount
#define SYS_move_mount 429
#endif
#ifndef SYS_mount_setattr
#define SYS_mount_setattr 442
#endif
#ifndef MOUNT_ATTR_IDMAP
#define MOUNT_ATTR_IDMAP 0x00100000
struct mount_attr {
	uint64_t attr_set;
	uint64_t attr_clr;
	uint64_t propagation;
	uint64_t userns_fd;
};
#endif

int
main(int argc, char **argv)
{
	struct mount_attr attr = {0};
	char              ns_path[64];
	int               tree, userns;

	if (argc != 4) {
		fprintf(stderr, "usage: %s <pid> <source> <target>\n", argv[0]);
		return 2;
	}

	snprintf(ns_path, sizeof(ns_path), "/proc/%s/ns/user", argv[1]);
	userns = open(ns_path, O_RDONLY | O_CLOEXEC);
	if (userns < 0) {
		fprintf(stderr, "open %s: %s\n", ns_path, strerror(errno));
		return 1;
	}

	tree = syscall(SYS_open_tree, AT_FDCWD, argv[2], OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC);
	if (tree < 0) {
		fprintf(stderr, "open_tree %s: %s\n", argv[2], strerror(errno));
		return 1;
	}

	attr.attr_set  = MOUNT_ATTR_IDMAP;
	attr.userns_fd = userns;
	if (syscall(SYS_mount_setattr, tree, "", AT_EMPTY_PATH, &attr, sizeof(attr)) != 0) {
		fprintf(stderr, "mount_setattr(MOUNT_ATTR_IDMAP) %s: %s\n", argv[2], strerror(errno));
		return 1;
	}

	if (syscall(SYS_move_mount, tree, "", AT_FDCWD, argv[3], MOVE_MOUNT_F_EMPTY_PATH) != 0) {
		fprintf(stderr, "move_mount %s: %s\n", argv[3], strerror(errno));
		return 1;
	}
	return 0;
}
