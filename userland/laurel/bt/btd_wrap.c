/*
 * /usr/local/libexec/laurel-bluetoothd: the start program of the launchd job com.apple.bluetoothd on the Mi A3 root
 * (scripts/bt/bt-launchd.py sets the job's ProgramArguments[0] to it). It inserts liblaurel-btpty.dylib (laurel_btpty.c:
 * openpty's central end non-blocking, so an accessory's iAP channel cannot stop bluetoothd's stack) and execs Apple's
 * bluetoothd at its own path with the job's arguments and environment (BT_HCI_TRANSPORT ...): same pid, the Mach services
 * launchd prepared. launchd does not pass DYLD_* variables from a job to a system daemon (ios-topaz bbd_wrap.c), so this
 * sets the variable itself. Same pattern as userland/laurel/notch/sb_wrap.c, without the crash guard: the library
 * interposes one libc function and makes one fcntl call.
 *   - no dylib with boot-arg laurel_btpty=0 (whole word), or when it is not on the root: one line, bluetoothd as Apple's;
 *   - every decision: syslog + /var/tmp/laurel-bt.log ("LAUREL BT PTY: ..."); the dylib then says "on:" from inside;
 *   - if the exec fails, wait 10 s and exit (launchd does not spin).
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>
#include <sys/sysctl.h>

#define REAL   "/usr/sbin/bluetoothd"
#define DYLIB  "/usr/local/lib/liblaurel-btpty.dylib"
#define LOG    "/var/tmp/laurel-bt.log"

static void
say(const char *fmt, const char *a)
{
	char line[400];
	FILE *f;

	snprintf(line, sizeof(line), fmt, a);
	syslog(LOG_NOTICE, "%s", line);
	if ((f = fopen(LOG, "a")) != NULL) {
		fprintf(f, "%s\n", line);
		fclose(f);
	}
}

static int
bootarg_off(const char *name)
{
	char args[1024] = "";
	size_t n = sizeof(args) - 1;
	char want[64];
	const char *p;

	if (sysctlbyname("kern.bootargs", args, &n, NULL, 0) != 0) {
		return 0;
	}
	snprintf(want, sizeof(want), "%s=0", name);
	for (p = strstr(args, want); p != NULL; p = strstr(p + 1, want)) {
		if ((p == args || p[-1] == ' ') && (p[strlen(want)] == '\0' || p[strlen(want)] == ' ')) {
			return 1;
		}
	}
	return 0;
}

int
main(int argc, char **argv)
{
	char **args = calloc((size_t)argc + 1, sizeof(char *));
	int i;

	openlog("laurel-bluetoothd", LOG_PID, LOG_DAEMON);
	if (args == NULL) {
		return 1;
	}
	args[0] = REAL;
	for (i = 1; i < argc; i++) {
		args[i] = argv[i];
	}
	if (bootarg_off("laurel_btpty")) {
		say("LAUREL BT PTY: off: boot-arg laurel_btpty=0: bluetoothd as Apple's%s", "");
	} else if (access(DYLIB, R_OK) != 0) {
		say("LAUREL BT PTY: off: no %s on the root: bluetoothd as Apple's", DYLIB);
	} else {
		setenv("DYLD_INSERT_LIBRARIES", DYLIB, 1);
		say("LAUREL BT PTY: %s inserted into bluetoothd", DYLIB);
	}
	execv(REAL, args);
	say("LAUREL BT PTY: exec of " REAL " failed: %s", strerror(errno));
	sleep(10);
	return 1;
}
