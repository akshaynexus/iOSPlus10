/*
 * /usr/local/libexec/laurel-springboard: the start program of the launchd job com.apple.SpringBoard on the Mi A3 root
 * (scripts/laurel/root-statusbar.py sets the job's ProgramArguments[0] to it). It inserts liblaurel-notch.dylib (the
 * waterdrop as SpringBoard's display shape, laurel_notch.c) and execs Apple's SpringBoard at its own path: same pid,
 * the Mach services launchd prepared, SpringBoard.app stays as Apple shipped it. launchd does not pass DYLD_*
 * variables from a job to a system daemon (ios-topaz bbd_wrap.c), so this sets the variable itself.
 * Same pattern as userland/laurel/gpu/bbd_wrap.c:
 *   - no dylib with boot-arg notch=0 (whole word, also as the first boot-arg);
 *   - crash guard: every start writes "<boot session> <fast starts in a row> <time>" to /var/tmp/laurel-sb.state; a
 *     start less than FAST_S s after the previous one in the same boot counts as a fast exit; after MAX_FAST of them
 *     SpringBoard runs without the dylib for the rest of this boot (Apple's D22Zoomed shape; the bar still works);
 *   - no dylib when it is not on the root;
 *   - every decision: syslog + /var/tmp/laurel-notch.log ("LAUREL NOTCH: ..."); after "... inserted" the dylib
 *     writes "on:" or "off:"; no such line = dyld did not load it;
 *   - if the exec fails, wait 10 s and exit (launchd does not spin).
 * Docs: docs/laurel_sprout/rtc-statusbar.md "C".
 * Also inserts liblaurel-cellbar.dylib when it is on the root (no boot-arg cell=0); the crash guard covers both.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include <sys/sysctl.h>

#define REAL      "/System/Library/CoreServices/SpringBoard.app/SpringBoard"
#define DYLIB     "/usr/local/lib/liblaurel-notch.dylib"
#define CELLBAR   "/usr/local/lib/liblaurel-cellbar.dylib"      /* SIM, bars, network name: docs/laurel_sprout/cellular.md section 9 */
#define STATE     "/var/tmp/laurel-sb.state"
#define LOG       "/var/tmp/laurel-notch.log"
#define FAST_S    30
#define MAX_FAST  2

static void
say(const char *fmt, const char *a)
{
	char line[256];
	FILE *f;

	snprintf(line, sizeof(line), fmt, a);
	syslog(LOG_NOTICE, "LAUREL NOTCH: %s", line);
	if ((f = fopen(LOG, "a")) != NULL) {
		fprintf(f, "%ld LAUREL NOTCH: %s\n", (long)time(NULL), line);
		fclose(f);
	}
}

/* boot-arg NAME=0 as a whole word ("notch=0" must not match "xnotch=0", and may be the first word) */
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
	char args[1024] = "", session[64] = "", old[64] = "", n[16], list[128] = "";
	size_t len = sizeof(args) - 1;
	long now = (long)time(NULL), then = 0;
	int fast = 0, use = 1, cellbar;
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

	if (bootarg_zero(args, "notch")) {
		use = 0;
		say("off: %s in the boot-args: SpringBoard keeps its own display shape", "notch=0");
	} else if (fast >= MAX_FAST) {
		use = 0;
		snprintf(n, sizeof(n), "%d", fast);
		say("off: SpringBoard exited %s times within 30 s of its start: no dylib for this boot", n);
	} else if (access(DYLIB, R_OK) != 0) {
		use = 0;
		say("off: no %s on the root", DYLIB);
	}
	cellbar = fast < MAX_FAST && !bootarg_zero(args, "cell") && access(CELLBAR, R_OK) == 0;
	if (use) {
		strcpy(list, DYLIB);
		say("%s inserted into SpringBoard (the dylib logs on/off at the first shape request)", DYLIB);
	}
	if (cellbar) {
		if (list[0] != 0) {
			strcat(list, ":");
		}
		strcat(list, CELLBAR);
		say("%s inserted into SpringBoard (its own line: LAUREL CELLBAR)", CELLBAR);
	}
	if (list[0] != 0) {
		setenv("DYLD_INSERT_LIBRARIES", list, 1);
	} else {
		unsetenv("DYLD_INSERT_LIBRARIES");
	}
	argv[0] = (char *)REAL;
	execv(REAL, argv);
	say("exec of " REAL " failed: %s", strerror(errno));
	sleep(10);                                      /* (launchd restarts us: not in a tight loop) */
	return 127;
}
