/*
 * fuse-fd-mount: mount a dfuse filesystem and run the server with the mounted /dev/fuse as
 * /dev/fd/N (libfuse's "fd mount"), as privileged mount helpers do for an unprivileged FUSE server:
 * mount.fuse3 -o drop_privileges, CSI drivers that pass the descriptor to a sidecar.
 *
 *   fuse-fd-mount <mountpoint> <command> [args...]
 *
 * The descriptor is 10, so the command gets the mount point /dev/fd/10. The mount has the type
 * fuse.daos and the options that dfuse --multi-user would use itself (default_permissions,
 * allow_other). The kernel then gives the server pids relative to the pid namespace of this
 * process. Needs root.
 *
 * Build: gcc -O2 -Wall -o fuse-fd-mount fuse-fd-mount.c
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#define FUSE_FD 10

int
main(int argc, char **argv)
{
	char        opts[256];
	struct stat st;
	int         fd;

	if (argc < 3) {
		fprintf(stderr, "usage: %s <mountpoint> <command> [args...]\n", argv[0]);
		return 2;
	}
	if (stat(argv[1], &st) != 0) {
		perror(argv[1]);
		return 1;
	}
	fd = open("/dev/fuse", O_RDWR);
	if (fd < 0) {
		perror("/dev/fuse");
		return 1;
	}
	/* dup2() leaves FD_CLOEXEC off, so the descriptor survives the exec */
	if (fd != FUSE_FD && (dup2(fd, FUSE_FD) < 0 || close(fd) != 0)) {
		perror("dup2");
		return 1;
	}
	snprintf(opts, sizeof(opts),
		 "fd=%d,rootmode=%o,user_id=%u,group_id=%u,default_permissions,allow_other",
		 FUSE_FD, st.st_mode & S_IFMT, getuid(), getgid());
	if (mount("dfuse", argv[1], "fuse.daos", MS_NOSUID | MS_NODEV, opts) != 0) {
		perror("mount");
		return 1;
	}
	execvp(argv[2], argv + 2);
	perror(argv[2]);
	umount2(argv[1], MNT_DETACH);
	return 1;
}
