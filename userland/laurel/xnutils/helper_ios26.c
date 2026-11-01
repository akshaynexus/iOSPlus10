/*
 * The iOS 26 verbs of powermenu-helper (built with XT_IOS26: scripts/laurel/xnutils-build.sh, XNUTILS_IOS26=1). docs/laurel_sprout/ios26-metal.md section 10.
 *   metaloption default|hot    which Metal stack NegroniMetal.bundle's selector takes at the next start of a process; clears the selector's counts
 *   tumode auto|sysmem|gmem    the TU_DEBUG line of the env file (Turnip's render mode); next start of a process that reads /var/db
 *   liveglass on|off           the file that brings live CABackdropLayer capture back: within 5 s, no restart
 *   metalstate                 KEY=VALUE lines: setting, running stack, why, counts, Turnip mode, glass
 *   bench-begin | bench-end    the compositor counts its frames between them (NegroniMetal.mm bench_serve); bench-end prints the result
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "collect.h"
#include "helper_files.h"

#define XT_STACK_DIR   XT_DB "/stack"
#define XT_OPTION      XT_DB "/option"
#define XT_OPTION_LOCAL XT_METAL_BUNDLE "/option.local"
#define XT_ENV         XT_DB "/env"
#define XT_GLASS       XT_DB "/live-glass"
#define XT_BENCH_ON    XT_STACK_DIR "/bench-on"
#define XT_BENCH_OUT   XT_STACK_DIR "/bench-result"
#define XT_BENCH_WAIT_TICKS 30     /* 100 ms each */

static int
stack_dir(void)
{
	if (ensure_dir(XT_DB, 0755) != 0) {
		return -1;
	}
	if (mkdir(XT_STACK_DIR, 0777) != 0 && errno != EEXIST) {
		fprintf(stderr, "powermenu-helper: %s: %s\n", XT_STACK_DIR, strerror(errno));
		return -1;
	}
	(void)chmod(XT_STACK_DIR, 0777);        /* backboardd runs as mobile */
	return 0;
}

int
xt_do_metaloption(const char *name)
{
	char text[32];

	if (stack_dir() != 0) {
		return 1;
	}
	snprintf(text, sizeof(text), "%s\n", name);
	if (write_file(XT_OPTION, text) != 0) {
		return 1;
	}
	/* sandboxed processes read this copy; on a read-only system volume it stays as it was and they keep their stack, which does not touch the compositor */
	struct stat st;

	if (stat(XT_METAL_BUNDLE, &st) == 0 && write_file(XT_OPTION_LOCAL, text) != 0) {
		printf("OPTION_LOCAL=not written\n");
	}
	if (remove_file(XT_STACK_DIR "/state") != 0 || remove_file(XT_STACK_DIR "/ok") != 0 || remove_file(XT_STACK_DIR "/failed") != 0) {
		return 1;
	}
	return 0;
}

/* the env file without its TU_DEBUG lines; flag NULL: no new line. The other lines stay as they are */
int
xt_do_tumode(const char *flag)
{
	char text[8192], line[1024];
	size_t at = 0;
	FILE *f = fopen(XT_ENV, "r");

	text[0] = 0;
	if (f != NULL) {
		while (fgets(line, sizeof(line), f) != NULL) {
			size_t n = strlen(line);

			if (strncmp(line, "TU_DEBUG=", 9) == 0) {
				continue;
			}
			if (at + n + 64 >= sizeof(text)) {
				fclose(f);
				fprintf(stderr, "powermenu-helper: %s is too long\n", XT_ENV);
				return 1;
			}
			memcpy(text + at, line, n + 1);
			at += n;
		}
		fclose(f);
	}
	if (flag != NULL) {
		snprintf(text + at, sizeof(text) - at, "TU_DEBUG=%s\n", flag);
	}
	return (ensure_dir(XT_DB, 0755) != 0 || write_file(XT_ENV, text) != 0) ? 1 : 0;
}

int
xt_do_liveglass(int on)
{
	if (!on) {
		return remove_file(XT_GLASS) ? 1 : 0;
	}
	return (ensure_dir(XT_DB, 0755) != 0 || write_file(XT_GLASS, "powermenu-helper liveglass on\n") != 0) ? 1 : 0;
}

/* the first line, without its end; "" when there is none */
static void
first_line(const char *path, char *out, size_t size)
{
	FILE *f = fopen(path, "r");

	out[0] = 0;
	if (f == NULL) {
		return;
	}
	if (fgets(out, (int)size, f) == NULL) {
		out[0] = 0;
	}
	fclose(f);
	out[strcspn(out, "\r\n")] = 0;
}

int
xt_do_metalstate(void)
{
	char setting[64], active[240], state[64], line[1024], tu[64] = "auto";
	FILE *f = fopen(XT_ENV, "r");

	if (f != NULL) {
		while (fgets(line, sizeof(line), f) != NULL) {
			if (strncmp(line, "TU_DEBUG=", 9) == 0) {
				snprintf(tu, sizeof(tu), "%s", line + 9);
				tu[strcspn(tu, "\r\n")] = 0;
			}
		}
		fclose(f);
	}
	first_line(XT_OPTION, setting, sizeof(setting));
	first_line(XT_STACK_DIR "/active", active, sizeof(active));
	first_line(XT_STACK_DIR "/state", state, sizeof(state));
	char *why = strchr(active, ' ');

	if (why != NULL) {
		*why++ = 0;
	}
	printf("OPTION=%s\nACTIVE=%s\nWHY=%s\nSTATE=%s\nTUMODE=%s\nGLASS=%s\n", setting[0] ? setting : "default", active[0] ? active : "unknown", why ? why : "", state, tu,
	    access(XT_GLASS, F_OK) == 0 ? "live" : "bypass");
	return 0;
}

int
xt_do_bench_begin(void)
{
	if (stack_dir() != 0 || remove_file(XT_BENCH_OUT) != 0) {
		return 1;
	}
	return write_file(XT_BENCH_ON, "XNUtils\n") ? 1 : 0;
}

int
xt_do_bench_end(void)
{
	if (remove_file(XT_BENCH_ON) != 0) {
		return 1;
	}
	/* the plug-in looks each 500 ms */
	for (int i = 0; i < XT_BENCH_WAIT_TICKS; i++) {
		char line[128];
		FILE *f = fopen(XT_BENCH_OUT, "r");

		if (f != NULL) {
			while (fgets(line, sizeof(line), f) != NULL) {
				fputs(line, stdout);
			}
			fclose(f);
			return 0;
		}
		usleep(100000);
	}
	printf("PRESENTS=none\n");      /* no compositor on this stack answered: the app shows that, no number */
	return 0;
}
