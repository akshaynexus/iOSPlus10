/*
 * hcitest: talk H4 to the kernel transport (patch 0332) without bluetoothd. Our own code.
 *   hcitest [ctl|dev]     ctl (default): kernel control com.apple.uart.bluetooth, the way bluetoothd's POSIX
 *                         driver opens it (bluetoothd 0x100066bdc); dev: /dev/uart.bluetooth.
 * Sends HCI_Reset (01 03 0c 00), Read_Local_Version (01 01 10 00), Read_BD_ADDR (01 09 10 00) and one Broadcom
 * vendor command (01 79 fc 00, answered by the 0333 shim) and prints every event it reads (2 s per command).
 * bluetoothd must not hold the transport (one client at a time: EBUSY).
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <termios.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
/* sys/sys_domain.h and sys/kern_control.h are not in the iOS SDK: the same definitions (xnu bsd/sys) */
#ifndef PF_SYSTEM
#define PF_SYSTEM AF_SYSTEM
#endif
#define SYSPROTO_CONTROL 2
#define AF_SYS_CONTROL 2
#define CTLIOCGINFO 0xc0644e03          /* _IOWR('N', 3, struct ctl_info), bluetoothd 0x100066d34 */
struct ctl_info { u_int32_t ctl_id; char ctl_name[96]; };
struct sockaddr_ctl { u_char sc_len, sc_family; u_int16_t ss_sysaddr; u_int32_t sc_id, sc_unit, sc_reserved[5]; };

static int open_ctl(void)
{
	int fd = socket(PF_SYSTEM, SOCK_STREAM, SYSPROTO_CONTROL);
	if (fd < 0) { perror("socket"); return -1; }
	struct ctl_info ci; memset(&ci, 0, sizeof(ci));
	strlcpy(ci.ctl_name, "com.apple.uart.bluetooth", sizeof(ci.ctl_name));
	if (ioctl(fd, CTLIOCGINFO, &ci) < 0) { perror("CTLIOCGINFO"); close(fd); return -1; }
	struct sockaddr_ctl sc; memset(&sc, 0, sizeof(sc));
	sc.sc_len = sizeof(sc); sc.sc_family = AF_SYSTEM; sc.ss_sysaddr = AF_SYS_CONTROL; sc.sc_id = ci.ctl_id; sc.sc_unit = 0;
	if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) < 0) { perror("connect"); close(fd); return -1; }
	struct termios t; socklen_t l = sizeof(t);
	if (getsockopt(fd, SYSPROTO_CONTROL, TIOCGETA, &t, &l) == 0) {
		printf("termios from the kernel: speed %lu cflag %#lx\n", (unsigned long)t.c_ospeed, (unsigned long)t.c_cflag);
		cfmakeraw(&t); cfsetspeed(&t, 3000000); t.c_cflag |= CRTSCTS;
		if (setsockopt(fd, SYSPROTO_CONTROL, TIOCSETA, &t, sizeof(t)) < 0) perror("setsockopt TIOCSETA");
	} else perror("getsockopt TIOCGETA");
	return fd;
}

static void dump(const char *what, const unsigned char *b, ssize_t n)
{
	printf("%s %zd:", what, n);
	for (ssize_t i = 0; i < n; i++) printf(" %02x", b[i]);
	printf("\n");
}

static void cmd(int fd, const unsigned char *c, size_t n)
{
	dump("tx", c, (ssize_t)n);
	if (write(fd, c, n) != (ssize_t)n) { perror("write"); return; }
	for (;;) {
		struct pollfd p = { fd, POLLIN, 0 };
		int r = poll(&p, 1, 2000);
		if (r <= 0) { printf("  (no more data within 2 s)\n"); return; }
		unsigned char b[1100];
		ssize_t k = read(fd, b, sizeof(b));
		if (k <= 0) { perror("read"); return; }
		dump("  rx", b, k);
		if (k >= 7 && b[0] == 0x04 && b[1] == 0x0e && b[4] == c[1] && b[5] == c[2]) return;
	}
}

int main(int argc, char **argv)
{
	int dev = argc > 1 && strcmp(argv[1], "dev") == 0;
	int fd = dev ? open("/dev/uart.bluetooth", O_RDWR) : open_ctl();
	if (fd < 0) { if (dev) perror("/dev/uart.bluetooth"); return 1; }
	static const unsigned char reset[] = { 1, 0x03, 0x0c, 0 }, ver[] = { 1, 0x01, 0x10, 0 },
	    bd[] = { 1, 0x09, 0x10, 0 }, vsc[] = { 1, 0x79, 0xfc, 0 };
	cmd(fd, reset, sizeof(reset));
	cmd(fd, ver, sizeof(ver));
	cmd(fd, bd, sizeof(bd));
	cmd(fd, vsc, sizeof(vsc));
	close(fd);
	return 0;
}
