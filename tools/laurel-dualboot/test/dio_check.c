/*
 * Host test of the phone's own helper code (ldbhelper.c built with no test define): the O_DIRECT rules of a block device with 4096-byte blocks, on a host file, with no root and no loop device.
 *   dio_check DEV HELPER ARGS...
 * The helper runs for real under ptrace. Its open of DEV really has O_DIRECT, on the host's file system. A host file system may not enforce what a 4.14 block device enforces (btrfs falls back to
 * buffered I/O), so this program applies the rule of fs/block_dev.c:227, :360 itself: `(pos | iov_iter_alignment(iter)) & (bdev_logical_block_size(bdev) - 1)` gives -EINVAL. Each pread and pwrite
 * on DEV: memory, offset and length must be on the block, or the call fails with EINVAL, as on the phone. BLKSSZGET and BLKROGET on DEV answer as a 4096-byte writable device.
 * Prints each refusal and one summary line; the exit code is the helper's. x86_64 Linux only (the helper's host build). Proves the code on the host. Nothing here proves anything about the phone.
 */
#define _GNU_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/reg.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <unistd.h>

#define BLK 4096ul
#define BLKSSZGET 0x1268ul
#define BLKROGET 0x125eul

static pid_t pid;
static long dev_fd = -1;
static unsigned long reads, writes, refused, direct_opens, plain_opens;

static void
peek_str(unsigned long addr, char *out, size_t n)
{
	struct iovec l = { out, n - 1 }, r = { (void *)addr, n - 1 };
	ssize_t g = process_vm_readv(pid, &l, 1, &r, 1, 0);
	out[g > 0 ? g : 0] = 0;
}
static void
poke_int(unsigned long addr, int v)
{
	struct iovec l = { &v, sizeof(v) }, r = { (void *)addr, sizeof(v) };
	if (process_vm_writev(pid, &l, 1, &r, 1, 0) != sizeof(v)) {
		perror("dio_check: process_vm_writev");
		exit(98);
	}
}

int
main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: dio_check DEV HELPER ARGS...\n");
		return 2;
	}
	const char *dev = argv[1];
	pid = fork();
	if (pid < 0) {
		perror("fork");
		return 98;
	}
	if (pid == 0) {
		if (ptrace(PTRACE_TRACEME, 0, 0, 0) != 0) {
			perror("dio_check: ptrace");
			_exit(98);
		}
		raise(SIGSTOP);
		execv(argv[2], argv + 2);
		perror("dio_check: exec");
		_exit(98);
	}
	int st;
	waitpid(pid, &st, 0);
	ptrace(PTRACE_SETOPTIONS, pid, 0, PTRACE_O_TRACESYSGOOD | PTRACE_O_EXITKILL);
	int entering = 1, pending_open = 0, fail_einval = 0, fake_ioctl = 0;
	unsigned long ioctl_arg = 0;
	for (;;) {
		if (ptrace(PTRACE_SYSCALL, pid, 0, 0) != 0 || waitpid(pid, &st, 0) < 0) {
			perror("dio_check: trace");
			return 98;
		}
		if (WIFEXITED(st) || WIFSIGNALED(st)) {
			break;
		}
		if (!WIFSTOPPED(st) || WSTOPSIG(st) != (SIGTRAP | 0x80)) {
			continue;
		}
		struct user_regs_struct u;
		ptrace(PTRACE_GETREGS, pid, 0, &u);
		if (entering) {
			long n = (long)u.orig_rax;
			if (n == SYS_openat) {
				char path[512];
				peek_str(u.rsi, path, sizeof(path));
				if (strcmp(path, dev) == 0) {
					pending_open = 1;
					if (u.rdx & O_DIRECT) {
						direct_opens++;
					} else {
						plain_opens++;
						printf("dio_check: %s opened without O_DIRECT\n", dev);
					}
				}
			} else if ((n == SYS_pread64 || n == SYS_pwrite64) && (long)u.rdi == dev_fd) {
				(n == SYS_pread64 ? &reads : &writes)[0]++;
				if ((u.rsi | u.rdx | u.r10) & (BLK - 1)) {
					printf("dio_check: EINVAL as on a 4096-byte block device: %s memory %#llx (%llu off the block), offset %llu, length %llu\n",
					    n == SYS_pread64 ? "pread" : "pwrite", u.rsi, u.rsi & (BLK - 1), u.r10, u.rdx);
					refused++;
					fail_einval = 1;
					u.orig_rax = (unsigned long long)-1;  /* the kernel runs no call; the exit stop gives EINVAL */
					ptrace(PTRACE_SETREGS, pid, 0, &u);
				}
			} else if (n == SYS_ioctl && (long)u.rdi == dev_fd && (u.rsi == BLKSSZGET || u.rsi == BLKROGET)) {
				fake_ioctl = (int)u.rsi;
				ioctl_arg = u.rdx;
				u.orig_rax = (unsigned long long)-1;
				ptrace(PTRACE_SETREGS, pid, 0, &u);
			}
		} else {
			if (pending_open) {
				pending_open = 0;
				if ((long long)u.rax >= 0) {
					dev_fd = (long)u.rax;
				}
			}
			if (fail_einval) {
				fail_einval = 0;
				u.rax = (unsigned long long)-EINVAL;
				ptrace(PTRACE_SETREGS, pid, 0, &u);
			}
			if (fake_ioctl) {
				poke_int(ioctl_arg, (unsigned long)fake_ioctl == BLKSSZGET ? 4096 : 0);
				fake_ioctl = 0;
				u.rax = 0;
				ptrace(PTRACE_SETREGS, pid, 0, &u);
			}
		}
		entering = !entering;
	}
	printf("dio_check: %lu O_DIRECT opens, %lu plain opens, %lu preads, %lu pwrites on the device, %lu refused\n", direct_opens, plain_opens, reads, writes, refused);
	return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}
