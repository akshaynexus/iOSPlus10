/*
 * /usr/local/libexec/laurel-cameracaptured: the start program of the launchd job com.apple.cameracaptured on the Mi A3 iOS 26.5.2 23F84 root (ios26-root-spec.py flashlight()).
 * It inserts LaurelFlashlight.driver/LaurelFlashlight (built with LF_IOS26) and execs Apple's cameracaptured at its own path: same pid, the Mach services launchd prepared. Same pattern as
 * userland/laurel/notch/sb_wrap.c. launchd does not pass DYLD_* variables from a job to a system daemon, so this sets the variable itself. docs/laurel_sprout/ios26-parity.md "Flashlight".
 *   - no bundle with boot-arg torch=0 (whole word), with /var/db/laurel/flashlight-off, or when the file is not on the root;
 *   - crash guard: every start writes "<boot session> <fast starts in a row> <time>" to /var/tmp/laurel-cc.state; a start less than FAST_S s after the previous one in the same boot counts as a fast exit;
 *     after MAX_FAST of them cameracaptured runs without the bundle for the rest of this boot. The job's restart rate stays launchd's (ThrottleInterval 5): nothing here holds another job;
 *   - each decision: one line "LAUREL FLASHLIGHT: ..." to /dev/console (the USB log); after "inserted" the bundle says on or off itself, no such line = dyld did not load it;
 *   - if the exec fails, wait 10 s and exit (launchd does not spin).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/sysctl.h>

#define REAL      "/usr/libexec/cameracaptured"
#define BUNDLE    "/System/Library/Audio/Plug-Ins/HAL/LaurelFlashlight.driver/LaurelFlashlight"
#define OFF_FILE  "/var/db/laurel/flashlight-off"
#define STATE     "/var/tmp/laurel-cc.state"
#define FAST_S    30
#define MAX_FAST  2

static void
say(const char *why, const char *a)
{
	char line[256];
	int n = snprintf(line, sizeof(line), "LAUREL FLASHLIGHT: %s%s\n", why, a);
	int fd = open("/dev/console", O_WRONLY | O_NOCTTY | O_CLOEXEC);

	if (fd >= 0 && n > 0) {
		(void)write(fd, line, (size_t)(n < (int)sizeof(line) ? n : (int)sizeof(line) - 1));
		close(fd);
	}
}

/* boot-arg NAME=0 as a whole word */
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
	char args[1024] = "", session[64] = "", old[64] = "";
	size_t len = sizeof(args) - 1;
	long now = (long)time(NULL), then = 0;
	int fast = 0;
	FILE *f;

	(void)argc;
	(void)sysctlbyname("kern.bootargs", args, &len, NULL, 0);
	len = sizeof(session) - 1;
	(void)sysctlbyname("kern.bootsessionuuid", session, &len, NULL, 0);
	if ((f = fopen(STATE, "r")) != NULL) {
		if (fscanf(f, "%63s %d %ld", old, &fast, &then) != 3) {
			fast = 0;
		}
		fclose(f);
	}
	if (session[0] == 0 || strcmp(old, session) != 0) {
		fast = 0;
	} else if (now - then < FAST_S) {
		fast++;
	} else {
		fast = 0;
	}
	if ((f = fopen(STATE, "w")) != NULL) {
		fprintf(f, "%s %d %ld\n", session[0] ? session : "-", fast, now);
		fclose(f);
	}
	if (bootarg_zero(args, "torch")) {
		say("off: ", "torch=0 in the boot-args");
		unsetenv("DYLD_INSERT_LIBRARIES");
	} else if (access(OFF_FILE, F_OK) == 0) {
		say("off: ", OFF_FILE " exists");
		unsetenv("DYLD_INSERT_LIBRARIES");
	} else if (fast >= MAX_FAST) {
		say("off: ", "cameracaptured exited twice within 30 s of its start: no bundle for this boot");
		unsetenv("DYLD_INSERT_LIBRARIES");
	} else if (access(BUNDLE, R_OK) != 0) {
		say("off: no ", BUNDLE);
		unsetenv("DYLD_INSERT_LIBRARIES");
	} else {
		setenv("DYLD_INSERT_LIBRARIES", BUNDLE, 1);
		say("inserted into ", "cameracaptured");
	}
	argv[0] = (char *)REAL;
	execv(REAL, argv);
	say("exec of " REAL " failed: ", strerror(errno));
	sleep(10);
	return 127;
}
