/*
 * /usr/libexec/backboardd on the Mi A3 (laurel_sprout) root: the stand-in that loads the GL path into the window server.
 * Based on ios-topaz userland/gpu/bbd_wrap.c (launchd does not pass DYLD_* variables from a job to a system daemon, so
 * this sets one and execs the real backboardd: same pid, same Mach services launchd prepared).
 *
 * What it adds to topaz's (docs/laurel_sprout/gpu.md "Recovery"):
 *   - no loader with boot-arg gpu=0 or gl=0 (whole-word match, also as the first boot-arg);
 *   - a crash guard: every start writes "<boot session> <starts in a row> <time>" to /var/tmp/laurel-bbd.state. A start
 *     less than FAST_S seconds after the previous one in the same boot counts as a fast exit of the one before; after
 *     MAX_FAST fast exits backboardd runs without the loader for the rest of this boot (CoreAnimation's software
 *     renderer), and one line says so;
 *   - every decision goes to syslog and to /var/tmp/laurel-bbd.log (launchd sends stderr to /dev/null);
 *   - if the loader is not on the root, nothing is inserted;
 *   - laurel 2155: no loader when the kernel says the GPU is off (sysctl kern.laurel_gpu = "off: <reason>": gpu=0,
 *     a failed bring-up, or the GPU watchdog after a GPU hang). The watchdog kills the GL backboardd; launchd
 *     starts this wrapper again, and backboardd comes back on CoreAnimation's software renderer at once (no 5 s
 *     wait for RedwoodGPU in the loader). "" (not decided yet, early boot) or "on": the loader as before;
 *   - if the exec of the real backboardd fails, it tries /usr/libexec/backboardd.real (a second copy root-add-gpu.sh
 *     may leave) and then waits 10 s before it exits, so launchd does not spin.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include <sys/sysctl.h>

#define REAL      "/usr/libexec/real/backboardd"
#define LOADER    "/topaz/lib/libtopaz-inject.dylib"
#define STATE     "/var/tmp/laurel-bbd.state"
#define LOG       "/var/tmp/laurel-bbd.log"
#define FAST_S    30
#define MAX_FAST  2

static void
say(const char *fmt, const char *a)
{
	char line[256];
	FILE *f;

	snprintf(line, sizeof(line), fmt, a);
	syslog(LOG_NOTICE, "LAUREL BBD: %s", line);
	if ((f = fopen(LOG, "a")) != NULL) {
		fprintf(f, "%ld LAUREL BBD: %s\n", (long)time(NULL), line);
		fclose(f);
	}
}

/* boot-arg NAME=0 as a whole word ("gl=0" must not match "xgl=0", and may be the first word) */
static int
bootarg_zero(const char *args, const char *name)
{
	size_t n = strlen(name);

	for (const char *p = args; *p != 0;) {
		while (*p == ' ') {
			p++;
		}
		const char *w = p;
		while (*p != 0 && *p != ' ') {
			p++;
		}
		if ((size_t)(p - w) == n + 2 && strncmp(w, name, n) == 0 && w[n] == '=' && w[n + 1] == '0') {
			return 1;
		}
	}
	return 0;
}

int
main(int argc, char *argv[])
{
	char args[1024] = "", session[64] = "", old[64] = "", gpu[160] = "";
	size_t len = sizeof(args) - 1;
	long now = (long)time(NULL), then = 0;
	int fast = 0, use_loader = 1;
	FILE *f;

	(void)argc;
	(void)sysctlbyname("kern.bootargs", args, &len, NULL, 0);
	len = sizeof(session) - 1;
	(void)sysctlbyname("kern.bootsessionuuid", session, &len, NULL, 0);
	len = sizeof(gpu) - 1;
	if (sysctlbyname("kern.laurel_gpu", gpu, &len, NULL, 0) != 0) {
		gpu[0] = 0;                             /* (a kernel without 2155: as before) */
	}

	/* crash guard: count starts in a row that came fast after the one before, in this boot only */
	if ((f = fopen(STATE, "r")) != NULL) {
		if (fscanf(f, "%63s %d %ld", old, &fast, &then) != 3) {
			fast = 0;
		}
		fclose(f);
	}
	if (session[0] == 0 || strcmp(old, session) != 0) {
		fast = 0;                               /* a new boot (or no session id): start clean */
	} else if (now - then < FAST_S) {
		fast++;
	} else {
		fast = 0;
	}
	if ((f = fopen(STATE, "w")) != NULL) {
		fprintf(f, "%s %d %ld\n", session[0] ? session : "-", fast, now);
		fclose(f);
	}

	if (bootarg_zero(args, "gpu") || bootarg_zero(args, "gl")) {
		use_loader = 0;
		say("off: %s in the boot-args: no GL loader", bootarg_zero(args, "gpu") ? "gpu=0" : "gl=0");
	} else if (strncmp(gpu, "off", 3) == 0) {
		use_loader = 0;
		say("off: the kernel turned the GPU off (%s): no GL loader, software renderer", gpu);
	} else if (fast >= MAX_FAST) {
		use_loader = 0;
		char n[16];
		snprintf(n, sizeof(n), "%d", fast);
		say("off: backboardd exited %s times within 30 s of its start: no GL loader for this boot", n);
	} else if (access(LOADER, R_OK) != 0) {
		use_loader = 0;
		say("off: no %s on the root", LOADER);
	}
	if (use_loader) {
		setenv("DYLD_INSERT_LIBRARIES", LOADER, 1);
		say("on: %s inserted", LOADER);
	} else {
		unsetenv("DYLD_INSERT_LIBRARIES");
	}
	argv[0] = (char *)REAL;
	execv(REAL, argv);
	say("exec of " REAL " failed: %s", strerror(errno));
	argv[0] = (char *)"/usr/libexec/backboardd.real";
	execv(argv[0], argv);
	sleep(10);                                      /* (launchd restarts us: not in a tight loop) */
	return 127;
}
