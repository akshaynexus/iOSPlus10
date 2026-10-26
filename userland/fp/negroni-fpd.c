/*
 * negroni-fpd: tells the kernel when the fingerprint lock-screen glyph may show (patch 0354,
 * kern.negroni_fp_ui: 0 hidden, 1 glyph). Our own code, root launchd daemon, no toybox.
 *
 * The kernel cannot see the lock screen. SpringBoard posts the Darwin notifications
 *   com.apple.springboard.lockstate         state 1 = locked, 0 = unlocked (notify_get_state)
 *   com.apple.springboard.hasBlankedScreen  state 1 = screen off, 0 = on
 * (libnotify, public notify(3); both names are in SpringBoard 20H392 and are what the stock
 * biometric UI uses). glyph = locked && !blanked. Every change is one sysctlbyname write; the daemon
 * also writes the state at start (the boot's first state) and when a notification arrives with
 * the same value (cheap, idempotent). Log: stdout lines "negroni-fpd: ...".
 *   negroni-fpd [-v]        -v: log every notification
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <notify.h>
#include <dispatch/dispatch.h>
#include <sys/sysctl.h>

#define N_LOCK   "com.apple.springboard.lockstate"
#define N_BLANK  "com.apple.springboard.hasBlankedScreen"
#define SYSCTL   "kern.negroni_fp_ui"

static int tok_lock = -1, tok_blank = -1, verbose, last = -1;

static uint64_t
state_of(int tok)
{
	uint64_t s = 0;
	if (tok < 0 || notify_get_state((int)tok, &s) != NOTIFY_STATUS_OK) {
		return 0;
	}
	return s;
}

static void
apply(const char *why)
{
	uint64_t locked = state_of(tok_lock), blanked = state_of(tok_blank);
	int ui = (locked != 0 && blanked == 0) ? 1 : 0;
	if (ui == last && !verbose) {
		return;
	}
	if (sysctlbyname(SYSCTL, NULL, NULL, &ui, sizeof(ui)) != 0) {
		printf("negroni-fpd: %s: lockstate %llu blanked %llu -> %s = %d failed: %s (kernel without 0354?)\n", why,
		    (unsigned long long)locked, (unsigned long long)blanked, SYSCTL, ui, strerror(errno));
		fflush(stdout);
		return;
	}
	printf("negroni-fpd: %s: lockstate %llu blanked %llu -> %s = %d (%s)\n", why, (unsigned long long)locked,
	    (unsigned long long)blanked, SYSCTL, ui, ui ? "glyph" : "hidden");
	fflush(stdout);
	last = ui;
}

static int
watch(const char *name, int *tok)
{
	uint32_t st = notify_register_dispatch(name, tok, dispatch_get_main_queue(), ^(int t) {
		(void)t;
		apply(name);
	});
	if (st != NOTIFY_STATUS_OK) {
		printf("negroni-fpd: notify_register_dispatch(%s) failed: %u\n", name, st);
		fflush(stdout);
		return -1;
	}
	return 0;
}

int
main(int argc, char **argv)
{
	verbose = argc > 1 && strcmp(argv[1], "-v") == 0;
	printf("negroni-fpd: start (pid %d, uid %d)\n", getpid(), getuid());
	if (watch(N_LOCK, &tok_lock) != 0 || watch(N_BLANK, &tok_blank) != 0) {
		return 1;
	}
	apply("start");
	dispatch_main();
	return 0;
}
