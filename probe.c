#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/ioctl.h>
#include <linux/dm-ioctl.h>

#define DM_MPATH_PROBE_PATHS_CMD 18
#define DM_MPATH_PROBE_PATHS _IO(DM_IOCTL, DM_MPATH_PROBE_PATHS_CMD)

int main(int argc, char *argv[])
{
	int fd;
	
	if (argc != 2) {
		fprintf(stderr, "Usage: %s <dm-path>\n", argv[0]);
		exit(1);
	}
	fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "open of %s failed: %m\n", argv[1]);
		exit(1);
	}
	printf("probing\n");
	while (ioctl(fd, DM_MPATH_PROBE_PATHS) < 0) {
		if (errno == ENOTCONN) {
			printf("no usable paths\n");
			exit(1);
		} else if (errno != EINTR && errno != EAGAIN) {
			perror("ioctl failed");
			exit(1);
		}
	}
	close(fd);
	return 0;
}
