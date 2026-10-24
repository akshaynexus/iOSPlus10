/*
 * usbreboot: reboot the phone from iOS (over SSH: scripts/net/ssh-phone.sh reboot-bootloader).
 *
 *   usbreboot [-n] [-f] bootloader|fastboot|recovery|normal
 *
 * A reboot mode other than "normal" needs kernel support: a writable string sysctl
 * kern.negroni_reboot_mode (or kern.sweet_reboot_mode, the bergamota interface of its patch
 * 0137) that the kernel's restart path turns into the PMIC/IMEM reboot reason. The negroni
 * kernel (slop patches, 2026-10-24) has no such sysctl and no restart handler at all, so
 * reboot(2) may stop at "MACH Reboot". Without the sysctl the tool refuses unless -f is given.
 *   -n  set the mode only, do not reboot      -f  reboot even without kernel reboot-mode support
 * The tool syncs, then calls reboot(RB_AUTOBOOT) (root only). Our own code.
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#define RB_AUTOBOOT 0	/* <sys/reboot.h>, not in the iPhoneOS SDK */

static const char *names[] = { "kern.negroni_reboot_mode", "kern.sweet_reboot_mode" };

int
main(int argc, char **argv)
{
	int only_set = 0, force = 0;
	const char *want = NULL;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-n")) {
			only_set = 1;
		} else if (!strcmp(argv[i], "-f")) {
			force = 1;
		} else {
			want = argv[i];
		}
	}
	const char *mode = NULL;
	if (want && (!strcmp(want, "bootloader") || !strcmp(want, "fastboot"))) {
		mode = "bootloader";
	} else if (want && !strcmp(want, "recovery")) {
		mode = "recovery";
	} else if (want && !strcmp(want, "normal")) {
		mode = "normal";
	}
	if (mode == NULL) {
		fprintf(stderr, "usage: usbreboot [-n] [-f] bootloader|fastboot|recovery|normal\n");
		return 2;
	}
	if (geteuid() != 0) {
		fprintf(stderr, "usbreboot: run as root\n");
		return 1;
	}

	const char *used = NULL;
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]) && used == NULL; i++) {
		if (sysctlbyname(names[i], NULL, NULL, (void *)mode, strlen(mode) + 1) == 0) {
			used = names[i];
		}
	}
	if (used != NULL) {
		char got[32] = "";
		size_t len = sizeof(got);
		sysctlbyname(used, got, &len, NULL, 0);
		printf("usbreboot: %s = %s\n", used, got);
	} else {
		printf("usbreboot: this kernel has no reboot-mode sysctl (kern.negroni_reboot_mode)\n");
		if (!force) {
			printf("usbreboot: not rebooting; -f reboots anyway (mode ignored, the kernel may hang at "
			    "\"MACH Reboot\": then hold Volume Up + Volume Down + Power for fastboot)\n");
			return 3;
		}
	}
	if (only_set) {
		return 0;
	}
	printf("usbreboot: sync + reboot (%s)\n", mode);
	fflush(stdout);
	sync();
	sleep(1);
	/* reboot(2) is not declared by the iOS SDK headers; the syscall is the same on iOS. */
	if (syscall(SYS_reboot, RB_AUTOBOOT, NULL) != 0) {
		perror("usbreboot: reboot");
		return 1;
	}
	return 0;
}
