/*
 * The selector's files (folder /private/var/db/negronimetal/stack, root:wheel 1777), plain C: option_select.m, the stacks' marks and the host test use this same code.
 *   state            option fails pending build     the rule's counts. Written by the compositor at each start, before the stack loads
 *   ok, failed       a stack's report to the next start (failed: its text is the reason)
 *   failed-OPTION    build reason                   this build failed. Holds across reboots, until a new build of the option or an owner's reset (XNUtils metaloption; install script RESET_FAILED=1)
 *
 * Why (2026-11-03, boot of 06:49): the install script's `: > stack/state` as root left a root-owned empty file; backboardd runs as mobile, the sticky bit stops it, fopen failed with no line, so the count never reached the disk.
 * After a reboot the count was 0, and native hung the GPU again. So: each write is durable (a CTL reboot is a reset 500 ms later, with no sync), a write that fails is not ignored (the compositor takes the default, one line).
 * A file of root's in this folder is a bug of the writer: only the compositor creates files here.
 */
#ifndef NMTL_OPTION_STORE_H
#define NMTL_OPTION_STORE_H
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "option_rule.h"

#ifndef NMTL_OPTION_DISK_HOOK   /* the host test keeps what reached the disk: its power loss brings back only that */
#define NMTL_OPTION_DISK_HOOK(dir, name)
#endif

static inline int nmtl_store_sync(int fd)
{
#ifdef F_FULLFSYNC
	if (fcntl(fd, F_FULLFSYNC) == 0)
		return 0;
#endif
	return fsync(fd);
}

static inline void nmtl_store_sync_dir(const char *dir)
{
	int fd = open(dir, O_RDONLY);
	if (fd >= 0) {
		(void)nmtl_store_sync(fd);
		close(fd);
	}
}

/* A small file: on the disk when this returns 0, whole or not at all. Else a positive errno, and the old file stays. A root-owned file in the sticky folder gives EPERM or EACCES here. */
static inline int nmtl_store_write(const char *dir, const char *name, const char *text)
{
	char tmp[512], path[512];
	int e = 0;
	const size_t n = strlen(text);
	snprintf(tmp, sizeof(tmp), "%s/.%s.%d", dir, name, (int)getpid());
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	(void)unlink(tmp);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
	if (fd < 0)
		return errno;
	if (write(fd, text, n) != (ssize_t)n)
		e = errno ? errno : EIO;
	if (e == 0 && nmtl_store_sync(fd) != 0)
		e = errno;
	close(fd);
	if (e == 0 && rename(tmp, path) != 0)
		e = errno;
	if (e != 0) {
		(void)unlink(tmp);
		return e;
	}
	nmtl_store_sync_dir(dir);
	NMTL_OPTION_DISK_HOOK(dir, name);
	return 0;
}

static inline void nmtl_store_remove(const char *dir, const char *name)
{
	char path[512];
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	if (unlink(path) == 0) {
		nmtl_store_sync_dir(dir);
		NMTL_OPTION_DISK_HOOK(dir, name);
	}
}

/* 0, or a positive errno (ENOENT: no file; EPERM, EACCES: a sandbox or the mode). A plain file only. */
static inline int nmtl_store_read(const char *dir, const char *name, char *out, size_t size)
{
	char path[512];
	struct stat st;
	out[0] = 0;
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
	if (fd < 0)
		return errno;
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
		close(fd);
		return EINVAL;
	}
	const ssize_t got = read(fd, out, size - 1);
	close(fd);
	if (got < 0) {
		out[0] = 0;
		return EIO;
	}
	out[got] = 0;
	return 0;
}

/*
 * What says "this build": the Mach-O's LC_UUID, a hash of the linked image, so the same code is the same build and a signature does not change it. An image with no such command: its size and time.
 * 0 when the file cannot be read: then no mark can be matched, and the caller treats this as a failed build.
 */
static inline int nmtl_option_build_id(const char *image, char *out, size_t size)
{
	uint8_t head[65536];
	struct stat st;
	out[0] = 0;
	int fd = open(image, O_RDONLY);
	if (fd < 0)
		return 0;
	const ssize_t got = read(fd, head, sizeof(head));
	const int have_stat = fstat(fd, &st) == 0;
	close(fd);
	uint32_t magic = 0, ncmds = 0;
	if (got >= 32) {
		memcpy(&magic, head, 4);
		memcpy(&ncmds, head + 16, 4);
	}
	if (magic == 0xfeedfacfu) {
		size_t at = 32;
		for (uint32_t i = 0; i < ncmds && at + 8 <= (size_t)got; i++) {
			uint32_t cmd, len;
			memcpy(&cmd, head + at, 4);
			memcpy(&len, head + at + 4, 4);
			if (len < 8 || at + len > (size_t)got)
				break;
			if (cmd == 0x1b && len == 24) { /* LC_UUID */
				const uint8_t *u = head + at + 8;
				snprintf(out, size, "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X", u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
				return 1;
			}
			at += len;
		}
	}
	if (!have_stat)
		return 0;
	snprintf(out, size, "size-%lld-time-%lld", (long long)st.st_size, (long long)st.st_mtime);
	return 1;
}

static inline void nmtl_store_one_line(char *text)
{
	for (char *c = text; *c; c++) {
		if (*c == '\n' || *c == '\r') {
			*c = 0;
			return;
		}
		if ((unsigned char)*c < 0x20)
			*c = ' ';
	}
}

/*
 * Which stack this start takes, and what the next start needs to know. dir: the stack folder. image: the file of option `wanted`, or NULL when it is absent (known() false).
 * why: a reason when the result is not what was wanted (the caller logs one line). note: a line for a new build that clears an old mark.
 * The compositor writes before it returns, so a hang, a kill or a reset in the stack's first frame leaves the count on the disk.
 */
static inline const char *nmtl_option_select(const char *dir, const char *wanted, const char *image, int (*known)(const char *), int compositor, char *why, size_t why_size, char *note, size_t note_size)
{
	struct nmtl_option_state s;
	char text[128], reported[160] = "", mark[256], build[48] = "", name[48] = "";
	why[0] = 0;
	note[0] = 0;
	const int state_read = nmtl_store_read(dir, "state", text, sizeof(text));
	nmtl_option_state_read(text, &s);
	const int ok = compositor && nmtl_store_read(dir, "ok", mark, sizeof(mark)) != ENOENT;
	const int failed = compositor && nmtl_store_read(dir, "failed", reported, sizeof(reported)) != ENOENT;
	nmtl_store_one_line(reported);
	const bool real = wanted != NULL && wanted[0] != 0 && strcmp(wanted, NMTL_OPTION_DEFAULT) != 0 && known(wanted);
	bool held = false, denied = state_read == EPERM || state_read == EACCES;
	if (real) {
		if (image == NULL || !nmtl_option_build_id(image, build, sizeof(build)))
			snprintf(build, sizeof(build), "unknown");
		if (strcmp(s.option, wanted) == 0 && s.build[0] != 0 && strcmp(s.build, build) != 0)
			memset(&s, 0, sizeof(s));       /* a new build: the old build's count says nothing about it */
		snprintf(name, sizeof(name), "failed-%.32s", wanted);
		const int mark_read = nmtl_store_read(dir, name, mark, sizeof(mark));
		denied = denied || mark_read == EPERM || mark_read == EACCES;
		if (mark_read == 0) {
			nmtl_store_one_line(mark);
			char *rest = strchr(mark, ' ');
			if (rest != NULL)
				*rest++ = 0;
			if (strcmp(mark, build) == 0) {
				held = true;
				snprintf(why, why_size, "build %s failed (%.120s): a new build or an owner's reset tries it again", build, rest != NULL ? rest : "no reason");
			} else if (compositor) {
				snprintf(note, note_size, "new build %s: the failed mark of build %.48s is gone", build, mark);
				nmtl_store_remove(dir, name);
			}
		}
	}
	const char *pick;
	if (held) {
		pick = NMTL_OPTION_DEFAULT;
	} else if (real && !compositor && denied && strcmp(wanted, "native") == 0) {
		/* a sandboxed client cannot see the compositor's verdict. A stream of this stack can turn the GPU off for all, so it does not guess */
		pick = NMTL_OPTION_DEFAULT;
		snprintf(why, why_size, "this process cannot read the stack folder (errno %d): it cannot see a failed mark", state_read != 0 ? state_read : EPERM);
	} else {
		pick = nmtl_option_choose(wanted, known, &s, ok, failed, compositor, why, why_size);
		if (real)
			snprintf(s.build, sizeof(s.build), "%s", build);
	}
	if (compositor) {
		if (real && !held && s.fails >= NMTL_OPTION_FAILS) {
			char line[256];
			snprintf(line, sizeof(line), "%s %.180s\n", build, reported[0] ? reported : "no lit screen in 2 starts");
			const int e = nmtl_store_write(dir, name, line);
			size_t have = strlen(why);
			if (e != 0)
				snprintf(why + have, why_size - have, " (the mark is not written: errno %d)", e);
			else
				snprintf(why + have, why_size - have, ": build %s stays off until a new build or an owner's reset", build);
		}
		snprintf(text, sizeof(text), "%s %d %d %s\n", s.option[0] ? s.option : "-", s.fails, s.pending, s.build[0] ? s.build : "-");
		const int e = nmtl_store_write(dir, "state", text);
		/* no count on the disk: a stack that hangs would be tried again at each boot. The default has no risk to count */
		if (e != 0 && strcmp(pick, NMTL_OPTION_DEFAULT) != 0) {
			snprintf(why, why_size, "the selector cannot write stack/state (errno %d): remove that file as root", e);
			pick = NMTL_OPTION_DEFAULT;
		}
		/* after the state: a loss here sees a report twice, never a count that is gone */
		nmtl_store_remove(dir, "ok");
		nmtl_store_remove(dir, "failed");
	}
	return pick;
}
#endif
