/* The switch files of the helper (helper.c has the verbs and their meaning). Paths are constants of collect.h: nothing from the caller. */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "collect.h"
#define PATH_BUF 4096
#ifdef XT_IOS26
#define XT_SHARED               /* helper_ios26.c writes with them */
#else
#define XT_SHARED static
#endif

XT_SHARED int
ensure_dir(const char *dir, mode_t mode)
{
	struct stat st;

	if (stat(dir, &st) == 0) {
		return S_ISDIR(st.st_mode) ? 0 : -1;
	}
	if (mkdir(dir, mode) != 0 || chown(dir, 0, 0) != 0 || chmod(dir, mode) != 0) {
		fprintf(stderr, "powermenu-helper: %s: %s\n", dir, strerror(errno));
		return -1;
	}
	return 0;
}

/* TEXT into PATH at once: PATH.new in the same folder (root:wheel 644), then rename */
XT_SHARED int
write_file(const char *path, const char *text)
{
	char tmp[PATH_BUF];

	snprintf(tmp, sizeof(tmp), "%s.new", path);
	unlink(tmp);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);

	if (fd < 0) {
		fprintf(stderr, "powermenu-helper: create %s: %s\n", tmp, strerror(errno));
		return -1;
	}
	size_t n = strlen(text);
	ssize_t w = n ? write(fd, text, n) : 0;

	if (w < 0 || (size_t)w != n || fchown(fd, 0, 0) != 0 || fchmod(fd, 0644) != 0 || fsync(fd) != 0) {
		fprintf(stderr, "powermenu-helper: write %s: %s\n", tmp, strerror(errno));
		close(fd);
		unlink(tmp);
		return -1;
	}
	close(fd);
	if (rename(tmp, path) != 0) {
		fprintf(stderr, "powermenu-helper: rename %s: %s\n", path, strerror(errno));
		unlink(tmp);
		return -1;
	}
	return 0;
}

#ifdef XT_IOS26
/*
 * A file in a folder that a mobile process can write: stack/, where the compositor (mobile) leaves its lines. This helper runs as root and prints what it reads, so a planted name must not reach another file:
 * no symlink (O_NOFOLLOW); no FIFO or device (O_NONBLOCK, then regular only: a FIFO must not hold the helper); no hard link to a file of root (one link only: XNU has no rule against linking a file you cannot read).
 * The checks are on the open file: no time between check and read. Owner: root or mobile, the two that write here. NULL, and one line, for anything else except "no such file".
 */
FILE *
open_planted(const char *path)
{
	int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
	struct stat st;

	if (fd < 0) {
		if (errno != ENOENT) {
			fprintf(stderr, "powermenu-helper: %s: %s\n", path, strerror(errno));
		}
		return NULL;
	}
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1 || (st.st_uid != 0 && st.st_uid != XT_MOBILE_UID)) {
		fprintf(stderr, "powermenu-helper: %s: refused: not a plain file of root or mobile with one link\n", path);
		close(fd);
		return NULL;
	}
	FILE *f = fdopen(fd, "r");

	if (f == NULL) {
		close(fd);
	}
	return f;
}
#endif

XT_SHARED int
remove_file(const char *path)
{
	if (unlink(path) != 0 && errno != ENOENT) {
		fprintf(stderr, "powermenu-helper: remove %s: %s\n", path, strerror(errno));
		return -1;
	}
	return 0;
}

/* the same text in both list files: the plug-in reads clients.local in sandboxed processes, which cannot read /var/db */
static int
write_lists(const char *text)
{
	if (write_file(XT_METAL_CLIENTS, text) != 0) {
		return -1;
	}
	struct stat st;

	return stat(XT_METAL_BUNDLE, &st) == 0 ? write_file(XT_METAL_LOCAL, text) : 0;
}

int
xt_do_metal(const char *what)
{
	char text[512];

	if (ensure_dir(XT_DB, 0755) != 0) {
		return 1;
	}
	if (strcmp(what, "off") == 0) {
		return write_file(XT_METAL_OFF, "powermenu-helper metal off\n") ? 1 : 0;
	}
#ifdef XT_IOS26
	/* No gate job on iOS 26, and a probes-only list leaves the compositor without the GPU: "auto" and "all" both give the root's list and clear "off". */
	snprintf(text, sizeof(text), "# XNUtils: the root's list\n%s\n", XT_METAL_WIDE);
	return (write_lists(text) != 0 || remove_file(XT_METAL_OFF) != 0) ? 1 : 0;
#endif
	if (strcmp(what, "auto") == 0) {
		snprintf(text, sizeof(text), XT_GATE_MARK ": XNUtils asked for the gate at the next boot\n" XT_METAL_PROBES "\n");
		/* the record of an earlier verdict stays out of the way of a new test */
		if (remove_file(XT_METAL_GATE) != 0) {
			return 1;
		}
	} else {
		snprintf(text, sizeof(text), "# XNUtils, own list: the gate leaves it alone\n%s\n", strcmp(what, "all") == 0 ? XT_METAL_WIDE : XT_METAL_PROBES);
	}
	return (write_lists(text) != 0 || remove_file(XT_METAL_OFF) != 0) ? 1 : 0;
}

int
xt_do_gl(int on)
{
	if (on) {
		return remove_file(XT_GL_OFF) ? 1 : 0;
	}
	if (ensure_dir(XT_GL_DIR, 0755) != 0) {
		return 1;
	}
	return write_file(XT_GL_OFF, "powermenu-helper gl off\n") ? 1 : 0;
}

int
xt_do_strikes_clear(void)
{
	DIR *d = opendir(XT_METAL_STRIKES);
	int n = 0;

	if (d == NULL) {
		printf("STRIKES_CLEARED=0\n");
		return 0;
	}
	for (struct dirent *e; (e = readdir(d)) != NULL;) {
		char p[PATH_BUF];
		struct stat st;

		if (e->d_name[0] == '.') {
			continue;
		}
		snprintf(p, sizeof(p), XT_METAL_STRIKES "/%s", e->d_name);
		if (lstat(p, &st) == 0 && S_ISREG(st.st_mode) && unlink(p) == 0) {
			n++;
		}
	}
	closedir(d);
	printf("STRIKES_CLEARED=%d\n", n);
	return 0;
}

