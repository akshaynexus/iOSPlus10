/*
 * powermenu-helper: the root part of XNUtils.app (formerly PowerMenu.app; userland/rebootapp/README.md).
 *
 *   powermenu-helper restart|shutdown|bootloader|check
 *
 * Installed as /usr/local/libexec/powermenu-helper, owner root, group mobile (501), mode 4750:
 * setuid root, and only root and members of group mobile can run it. The app runs as mobile and
 * spawns it; reboot(2) and the reboot-mode sysctl need euid 0.
 *
 * Caller check: real uid 0 (an SSH root shell) is allowed. Real uid 501 is allowed only when the
 * parent process is /Applications/XNUtils.app/XNUtils. Every other caller gets exit code 4.
 * The tool accepts exactly one of the four words. It reads no environment variable, opens no
 * file and starts no other program.
 *
 *   restart     sync, reboot(RB_AUTOBOOT)  (kernel 0211: reason of kern.negroni_reboot_mode,
 *               default normal = 0, PSCI SYSTEM_RESET)
 *   shutdown    sync, reboot(RB_HALT)      (kernel 0211: negroni_power_off, PSCI SYSTEM_OFF)
 *   bootloader  set kern.negroni_reboot_mode (or kern.sweet_reboot_mode) = "bootloader", read it
 *               back, sync, reboot(RB_AUTOBOOT): kernel patch 0213 writes reason 2 (ABL fastboot).
 *               If the kernel has no such sysctl (before 0213): exit 3, no reboot.
 *   check       caller check and kernel check only; prints the result, does not reboot.
 *
 * Exit codes: 0 check passed (bootloader supported) / 1 reboot(2) or sysctl failed /
 * 2 usage / 3 this kernel cannot select the bootloader / 4 caller not allowed /
 * 5 not setuid root (the install is wrong). Our own code.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#define RB_AUTOBOOT 0     /* <sys/reboot.h>, not in the iPhoneOS SDK */
#define RB_HALT     0x08
#define MOBILE_UID  501
#define APP_PATH    "/Applications/XNUtils.app/XNUtils"
#define PATH_BUF    4096  /* PROC_PIDPATHINFO_MAXSIZE */

int proc_pidpath(int pid, void *buffer, uint32_t buffersize); /* libproc, not in the SDK */

static const char *mode_names[] = { "kern.negroni_reboot_mode", "kern.sweet_reboot_mode" };

static int
caller_allowed(void)
{
	uid_t uid = getuid();
	if (uid == 0) {
		return 1;
	}
	if (uid != MOBILE_UID) {
		fprintf(stderr, "powermenu-helper: uid %u not allowed\n", (unsigned)uid);
		return 0;
	}
	char path[PATH_BUF] = "";
	pid_t ppid = getppid();
	if (proc_pidpath(ppid, path, sizeof(path)) <= 0) {
		fprintf(stderr, "powermenu-helper: no path for parent pid %d (errno %d)\n", (int)ppid, errno);
		return 0;
	}
	if (strcmp(path, APP_PATH) != 0) {
		fprintf(stderr, "powermenu-helper: parent %s is not %s\n", path, APP_PATH);
		return 0;
	}
	return 1;
}

/* The name of the reboot-mode sysctl of this kernel, or NULL. */
static const char *
mode_sysctl(void)
{
	for (size_t i = 0; i < sizeof(mode_names) / sizeof(mode_names[0]); i++) {
		size_t len = 0;
		if (sysctlbyname(mode_names[i], NULL, &len, NULL, 0) == 0) {
			return mode_names[i];
		}
	}
	return NULL;
}

static int
do_reboot(int how)
{
	sync();
	sleep(1);
	sync();
	/* reboot(2) is not declared by the iOS SDK headers; the syscall is the same on iOS. */
	syscall(SYS_reboot, how, NULL);
	perror("powermenu-helper: reboot");
	return 1;
}

int
main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: powermenu-helper restart|shutdown|bootloader|check\n");
		return 2;
	}
	const char *a = argv[1];
	int restart = !strcmp(a, "restart"), shutdown = !strcmp(a, "shutdown");
	int bootloader = !strcmp(a, "bootloader"), check = !strcmp(a, "check");
	if (!restart && !shutdown && !bootloader && !check) {
		fprintf(stderr, "usage: powermenu-helper restart|shutdown|bootloader|check\n");
		return 2;
	}
	if (geteuid() != 0) {
		fprintf(stderr, "powermenu-helper: not setuid root (install: root:mobile 4750)\n");
		return 5;
	}
	if (!caller_allowed()) {
		return 4;
	}
	if (restart) {
		return do_reboot(RB_AUTOBOOT);
	}
	if (shutdown) {
		return do_reboot(RB_HALT);
	}

	const char *name = mode_sysctl();
	if (check) {
		printf("powermenu-helper: caller ok; bootloader: %s\n",
		    name ? name : "not supported (no kern.negroni_reboot_mode in this kernel)");
		return name ? 0 : 3;
	}
	if (name == NULL) {
		fprintf(stderr, "powermenu-helper: this kernel has no kern.negroni_reboot_mode: not rebooting\n");
		return 3;
	}
	const char *mode = "bootloader";
	if (sysctlbyname(name, NULL, NULL, (void *)mode, strlen(mode) + 1) != 0) {
		perror("powermenu-helper: set reboot mode");
		return 1;
	}
	char got[32] = "";
	size_t len = sizeof(got);
	if (sysctlbyname(name, got, &len, NULL, 0) != 0 || strcmp(got, mode) != 0) {
		fprintf(stderr, "powermenu-helper: %s reads back \"%s\", not \"%s\": not rebooting\n", name, got, mode);
		return 1;
	}
	return do_reboot(RB_AUTOBOOT);
}
