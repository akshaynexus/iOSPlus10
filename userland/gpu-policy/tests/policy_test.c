/*
 * Host test of negroni_gpu_policy (scripts/gpu/policy-test.sh). A fake root in a temp directory holds the
 * phone's control files; boot id and process start time are set by the test.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "../negroni_gpu_policy.h"

static char root[512];
static int fails, passes;

#define CHECK(cond, ...) do { if (cond) { passes++; } else { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); \
	printf(__VA_ARGS__); printf("\n"); } } while (0)

static void
mkdirs(const char *rel)
{
	char p[800], *s;
	snprintf(p, sizeof(p), "%s%s", root, rel);
	for (s = p + strlen(root) + 1; (s = strchr(s, '/')); s++) {
		*s = 0;
		mkdir(p, 0777);
		*s = '/';
	}
	mkdir(p, 0777);
}

static void
put(const char *rel, const char *text)
{
	char p[800], d[800];
	snprintf(d, sizeof(d), "%s", rel);
	*strrchr(d, '/') = 0;
	mkdirs(d);
	snprintf(p, sizeof(p), "%s%s", root, rel);
	FILE *f = fopen(p, "w");
	fputs(text, f);
	fclose(f);
}

/* file mtime in the past (before the "process start") */
static void
age(const char *rel)
{
	char p[800];
	snprintf(p, sizeof(p), "%s%s", root, rel);
	struct timeval tv[2] = {{1000, 0}, {1000, 0}};
	utimes(p, tv);
}

static void
rm(const char *rel)
{
	char p[800];
	snprintf(p, sizeof(p), "%s%s", root, rel);
	unlink(p);
}

static void
quiet(const char *line)
{
	(void)line;
}

int
main(void)
{
	char why[1200];
	const char *t = getenv("TMPDIR");
	snprintf(root, sizeof(root), "%s/ngp-test-XXXXXX", t && t[0] ? t : "/tmp");
	if (!mkdtemp(root)) {
		perror("mkdtemp");
		return 2;
	}
	ngp_test_set_root(root);
	ngp_test_set_boot("BOOT-A");
	ngp_test_set_proc_start(2000);      /* files aged to 1000 are older than the process */
	ngp_test_set_ext("");
	ngp_set_logger(quiet);
	enum ngp_api o[3];
	char rule[600];

	/* 1. no files: default order; Metal disabled (not listed) -> no decision */
	CHECK(ngp_order("backboardd", NULL, o, rule, sizeof(rule)) == 3 && o[0] == NGP_METAL && o[1] == NGP_GL, "default order");
	CHECK(ngp_choose("backboardd", NULL, NULL, why, sizeof(why)) == NGP_NONE, "unlisted -> none: %s", why);

	/* 2. clients "*": Metal ok */
	put("/var/db/negronimetal/clients", "*\n");
	CHECK(ngp_choose("backboardd", NULL, NULL, why, sizeof(why)) == NGP_METAL, "listed -> metal: %s", why);
	CHECK(ngp_gl_fallback("backboardd", NULL, NULL, why, sizeof(why)) == NGP_NONE, "metal ok -> no fallback: %s", why);

	/* 3. staged policy file: posters metal cpu */
	char src[1024];
	snprintf(src, sizeof(src), "%s", SRCDIR "/gpu-policy");
	FILE *f = fopen(src, "r");
	CHECK(f != NULL, "staged policy file %s", src);
	if (f) {
		char buf[8192];
		size_t n = fread(buf, 1, sizeof(buf) - 1, f);
		buf[n] = 0;
		fclose(f);
		put("/System/Library/Extensions/NegroniGL.bundle/gpu-policy", buf);
	}
	CHECK(ngp_order("AegirPoster", NULL, o, rule, sizeof(rule)) == 2 && o[0] == NGP_METAL && o[1] == NGP_CPU,
	    "poster order: %s", rule);
	ngp_test_set_ext("com.apple.widgetkit-extension");
	CHECK(ngp_order("FitnessWidget", NULL, o, rule, sizeof(rule)) == 2 && o[1] == NGP_CPU, "ext rule: %s", rule);
	ngp_test_set_ext("");
	CHECK(ngp_order("MyGame", NULL, o, rule, sizeof(rule)) == 3 && o[1] == NGP_GL, "catch-all: %s", rule);

	/* 4. Metal strikes at the limit, this boot, older than the process: FAILED -> GL fallback for backboardd */
	put("/var/db/negronimetal/strikes/backboardd", "2 BOOT-A\n");
	age("/var/db/negronimetal/strikes/backboardd");
	CHECK(ngp_metal_health("backboardd", why, sizeof(why)) == NGP_FAILED, "strikes -> failed: %s", why);
	CHECK(ngp_gl_fallback("backboardd", NULL, NULL, why, sizeof(why)) == NGP_GL, "fallback gl: %s", why);
	CHECK(ngp_choose("backboardd", NULL, NULL, why, sizeof(why)) == NGP_GL, "choose gl: %s", why);

	/* 5. same strikes from another boot: ignored */
	put("/var/db/negronimetal/strikes/backboardd", "2 BOOT-OLD\n");
	age("/var/db/negronimetal/strikes/backboardd");
	CHECK(ngp_metal_health("backboardd", why, sizeof(why)) == NGP_OK, "old boot strikes ignored: %s", why);

	/* 6. strike file written after the process started = armed by the plugin in this process: Metal in use */
	put("/var/db/negronimetal/strikes/backboardd", "2 BOOT-A\n");     /* mtime now > 2000 */
	CHECK(ngp_metal_health("backboardd", why, sizeof(why)) == NGP_OK, "own armed strike is not a failure: %s", why);
	age("/var/db/negronimetal/strikes/backboardd");

	/* 7. poster limit is twice the limit: 2 strikes are not enough; and its policy has no GL */
	put("/var/db/negronimetal/strikes/AegirPoster", "2 BOOT-A\n");
	age("/var/db/negronimetal/strikes/AegirPoster");
	CHECK(ngp_metal_health("AegirPoster", why, sizeof(why)) == NGP_OK, "poster limit 4: %s", why);
	put("/var/db/negronimetal/strikes/AegirPoster", "4 BOOT-A\n");
	age("/var/db/negronimetal/strikes/AegirPoster");
	CHECK(ngp_gl_fallback("AegirPoster", NULL, NULL, why, sizeof(why)) == NGP_NONE, "poster: no gl: %s", why);
	CHECK(ngp_choose("AegirPoster", NULL, NULL, why, sizeof(why)) == NGP_CPU, "poster -> cpu: %s", why);

	/* 8. env file strike limit 3 */
	put("/var/db/negronimetal/env", "NEGRONIMETAL_STRIKE_LIMIT=3\n");
	CHECK(ngp_metal_health("backboardd", why, sizeof(why)) == NGP_OK, "limit 3 from env file: %s", why);
	rm("/var/db/negronimetal/env");

	/* 9. GL dead-man: arm, crash (no clear), arm, crash -> refused; GL FAILED -> both failed -> cpu */
	ngp_test_reset();
	CHECK(ngp_gl_arm("backboardd", why, sizeof(why)), "arm 1: %s", why);
	ngp_test_reset();                     /* the process "crashed": the strike stays */
	age("/var/db/negronigl/strikes/backboardd");
	CHECK(ngp_gl_arm("backboardd", why, sizeof(why)), "arm 2: %s", why);
	ngp_test_reset();
	age("/var/db/negronigl/strikes/backboardd");
	CHECK(!ngp_gl_arm("backboardd", why, sizeof(why)), "arm 3 refused: %s", why);
	CHECK(ngp_gl_health("backboardd", NULL, why, sizeof(why)) == NGP_FAILED, "gl failed: %s", why);
	CHECK(ngp_gl_fallback("backboardd", NULL, NULL, why, sizeof(why)) == NGP_CPU, "both failed -> cpu: %s", why);
	CHECK(ngp_choose("backboardd", NULL, NULL, why, sizeof(why)) == NGP_CPU, "choose cpu: %s", why);
	rm("/var/db/negronigl/strikes/backboardd");

	/* 10. arm then good frames: strike removed */
	ngp_test_reset();
	CHECK(ngp_gl_arm("MyGame", why, sizeof(why)), "arm game: %s", why);
	for (int i = 0; i < NGP_GL_OK_FRAMES; i++) {
		ngp_gl_frame_ok();
	}
	char p[800];
	snprintf(p, sizeof(p), "%s/var/db/negronigl/strikes/MyGame", root);
	CHECK(access(p, F_OK) != 0, "strike cleared after %d frames", NGP_GL_OK_FRAMES);

	/* 11. GL off file: DISABLED -> no fallback even when Metal failed */
	put("/var/db/negronigl/off", "");
	CHECK(ngp_gl_fallback("backboardd", NULL, NULL, why, sizeof(why)) == NGP_NONE, "gl off -> none: %s", why);
	rm("/var/db/negronigl/off");
	CHECK(ngp_gl_fallback("backboardd", NULL, NULL, why, sizeof(why)) == NGP_GL, "gl back: %s", why);

	/* 12. GPU lost this boot: Metal and GL both FAILED -> cpu; stale marker ignored */
	rm("/var/db/negronimetal/strikes/backboardd");
	put("/var/db/negronimetal/strikes/gpu-lost", "lost at 123 boot=BOOT-A\n");
	CHECK(ngp_choose("backboardd", NULL, NULL, why, sizeof(why)) == NGP_CPU, "gpu lost -> cpu: %s", why);
	put("/var/db/negronimetal/strikes/gpu-lost", "lost at 123 boot=BOOT-OLD\n");
	CHECK(ngp_choose("backboardd", NULL, NULL, why, sizeof(why)) == NGP_METAL, "stale gpu-lost ignored: %s", why);
	rm("/var/db/negronimetal/strikes/gpu-lost");

	/* 13. failure record (the later NegroniMetal hook): Metal FAILED this boot -> GL */
	CHECK(ngp_record_failure("backboardd", NGP_METAL, "open refused: test"), "record");
	CHECK(ngp_metal_health("backboardd", why, sizeof(why)) == NGP_FAILED && strstr(why, "open refused"), "record read: %s", why);
	ngp_test_set_boot("BOOT-B");
	CHECK(ngp_metal_health("backboardd", why, sizeof(why)) == NGP_OK, "record of another boot ignored: %s", why);
	ngp_test_set_boot("BOOT-A");

	/* 14. owner policy first: "backboardd metal cpu" stops the GL fallback */
	put("/var/db/negronigpu/policy", "backboardd metal cpu\n");
	CHECK(ngp_gl_fallback("backboardd", NULL, NULL, why, sizeof(why)) == NGP_NONE, "owner rule wins: %s", why);
	put("/var/db/negronigpu/policy", "# empty\n");

	/* 15. Metal off file: DISABLED (owner) -> no decision, no fallback */
	put("/var/db/negronimetal/off", "");
	CHECK(ngp_choose("backboardd", NULL, NULL, why, sizeof(why)) == NGP_NONE, "metal off -> none: %s", why);
	CHECK(ngp_gl_fallback("backboardd", NULL, NULL, why, sizeof(why)) == NGP_NONE, "metal off -> no fallback: %s", why);
	rm("/var/db/negronimetal/off");

	/* 16. memory rule: a 30 MiB limit is DISABLED, not FAILED */
	setenv("NGP_TEST_LIMIT_MB", "30", 1);
	CHECK(ngp_metal_health("MyGame", why, sizeof(why)) == NGP_DISABLED, "memory rule: %s", why);
	unsetenv("NGP_TEST_LIMIT_MB");

	/* 17. component off */
	put("/var/db/negronigpu/off", "");
	CHECK(ngp_choose("backboardd", NULL, NULL, why, sizeof(why)) == NGP_NONE, "component off: %s", why);
	rm("/var/db/negronigpu/off");

	/* 18. deny line wins over "*" in Metal clients */
	put("/var/db/negronimetal/clients", "* -chronod\n");
	CHECK(ngp_metal_health("chronod", why, sizeof(why)) == NGP_DISABLED, "-chronod: %s", why);

	char cmd[700];
	snprintf(cmd, sizeof(cmd), "rm -rf '%s'", root);
	if (system(cmd) != 0) {
		printf("note: could not remove %s\n", root);
	}
	printf("policy_test: %d passed, %d failed\n", passes, fails);
	return fails ? 1 : 0;
}
