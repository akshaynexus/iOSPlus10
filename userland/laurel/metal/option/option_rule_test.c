/* Host test of option_rule.h and option_store.h: scripts/laurel/option-rule-test.sh */
#include <stdlib.h>
#include <dirent.h>
/* What reached the disk: only a durable write or remove copies to this shadow. A power loss (a CTL reboot: a reset with no sync) brings back the shadow and nothing else. */
static void test_disk_hook(const char *dir, const char *name);
#define NMTL_OPTION_DISK_HOOK(dir, name) test_disk_hook(dir, name)
#include "option_store.h"
#include "present_stats.h"
static char g_disk[256];
static void test_disk_hook(const char *dir, const char *name)
{
	char from[512], to[512], data[512];
	snprintf(from, sizeof(from), "%s/%s", dir, name);
	snprintf(to, sizeof(to), "%s/%s", g_disk, name);
	FILE *f = fopen(from, "r");
	if (f == NULL) {
		unlink(to);
		return;
	}
	const size_t n = fread(data, 1, sizeof(data), f);
	fclose(f);
	f = fopen(to, "w");
	if (f != NULL) {
		fwrite(data, 1, n, f);
		fclose(f);
	}
}
static int known(const char *n) { return !strcmp(n, "hot") || !strcmp(n, "native"); }
static int fails_seen;
static void want(const char *label, const char *got, const char *expect)
{
	if (strcmp(got, expect) != 0) {
		printf("FAIL %s: got %s, want %s\n", label, got, expect);
		fails_seen++;
	} else {
		printf("ok   %s: %s\n", label, got);
	}
}

/* ---- the files: the real order of the log of 2026-11-03 06:47 to 06:49 ---- */
static char g_dir[256], g_image[300];
static void wipe(const char *dir)
{
	DIR *d = opendir(dir);
	struct dirent *e;
	char p[600];
	while (d != NULL && (e = readdir(d)) != NULL) {
		if (e->d_name[0] == '.' && (e->d_name[1] == 0 || e->d_name[1] == '.'))
			continue;
		snprintf(p, sizeof(p), "%s/%s", dir, e->d_name);
		if (unlink(p) != 0)
			rmdir(p);
	}
	if (d != NULL)
		closedir(d);
}
static void power_loss(void)
{
	DIR *d;
	struct dirent *e;
	char from[600], to[600], data[512];
	wipe(g_dir);
	d = opendir(g_disk);
	while (d != NULL && (e = readdir(d)) != NULL) {
		if (e->d_name[0] == '.')
			continue;
		snprintf(from, sizeof(from), "%s/%s", g_disk, e->d_name);
		snprintf(to, sizeof(to), "%s/%s", g_dir, e->d_name);
		FILE *f = fopen(from, "r");
		size_t n = f ? fread(data, 1, sizeof(data), f) : 0;
		if (f)
			fclose(f);
		f = fopen(to, "w");
		if (f) {
			fwrite(data, 1, n, f);
			fclose(f);
		}
	}
	if (d != NULL)
		closedir(d);
}
static void put_image(uint8_t tag)
{
	/* a thin Mach-O head: one command, LC_UUID */
	uint8_t m[56] = {0};
	const uint32_t magic = 0xfeedfacfu, ncmds = 1, cmd = 0x1b, len = 24;
	memcpy(m, &magic, 4);
	memcpy(m + 16, &ncmds, 4);
	memcpy(m + 32, &cmd, 4);
	memcpy(m + 36, &len, 4);
	memset(m + 40, tag, 16);
	FILE *f = fopen(g_image, "w");
	fwrite(m, 1, sizeof(m), f);
	fclose(f);
}
static char g_why[320], g_note[160];
static const char *boot_start(const char *wanted) { return nmtl_option_select(g_dir, wanted, g_image, known, 1, g_why, sizeof(g_why), g_note, sizeof(g_note)); }
static const char *client_start(const char *wanted) { return nmtl_option_select(g_dir, wanted, g_image, known, 0, g_why, sizeof(g_why), g_note, sizeof(g_note)); }
static void has(const char *label, const char *text, const char *part)
{
	if (strstr(text, part) == NULL) {
		printf("FAIL %s: [%s] has no [%s]\n", label, text, part);
		fails_seen++;
	} else {
		printf("ok   %s\n", label);
	}
}
static void fresh_store(uint8_t tag)
{
	wipe(g_dir);
	wipe(g_disk);
	put_image(tag);
}
static void store_tests(void)
{
	char root[] = "/tmp/nmtl-option-XXXXXX", text[128], id[48];
	if (mkdtemp(root) == NULL) {
		printf("FAIL mkdtemp\n");
		fails_seen++;
		return;
	}
	snprintf(g_dir, sizeof(g_dir), "%s/stack", root);
	snprintf(g_disk, sizeof(g_disk), "%s/disk", root);
	snprintf(g_image, sizeof(g_image), "%s/image", root);
	mkdir(g_dir, 0755);
	mkdir(g_disk, 0755);

	/* the log: 840 hangs, 862 has no device, 868 falls back, a reset, the boot of 06:49 */
	fresh_store(0xA1);
	want("840: first start", boot_start("native"), "native");
	if (nmtl_store_read(g_disk, "state", text, sizeof(text)) != 0 || strncmp(text, "native 0 1 A1A1A1A1", 19) != 0) { printf("FAIL the count is not on the disk before the stack loads: [%s]\n", text); fails_seen++; }
	want("862: no count yet, the GPU is off", boot_start("native"), "native");
	(void)nmtl_store_write(g_dir, "failed", "no device\n");
	want("868: the reported failure", boot_start("native"), "default");
	has("868: one line that names the build", g_why, "build A1A1A1A1-A1A1-A1A1-A1A1-A1A1A1A1A1A1 stays off");
	if (nmtl_store_read(g_disk, "failed-native", text, sizeof(text)) != 0) { printf("FAIL the mark is not on the disk\n"); fails_seen++; }
	has("the mark holds the reason", text, "no device");
	power_loss();
	for (int boot = 0; boot < 5; boot++) {
		want("after a reset: the same build stays off", boot_start("native"), "default");
		has("the line says why", g_why, "failed (no device)");
		want("SpringBoard follows", client_start("native"), "default");
		power_loss();
	}
	/* a lit screen of the default stack, written by this very fallback */
	(void)nmtl_store_write(g_dir, "ok", "lit\n");
	want("the default's lit screen does not clear it", boot_start("native"), "default");
	/* the owner sets default for now, later native again: the same build */
	want("setting default", boot_start("default"), "default");
	power_loss();
	want("native again, the same build: off", boot_start("native"), "default");
	/* the old selector's state */
	wipe(g_dir);
	(void)nmtl_store_write(g_dir, "state", "native 2 1\n");
	want("a count of the old selector: default", boot_start("native"), "default");
	if (nmtl_store_read(g_disk, "failed-native", text, sizeof(text)) != 0) { printf("FAIL old count gave no mark\n"); fails_seen++; }

	/* a new build */
	fresh_store(0xA1);
	(void)boot_start("native");
	(void)nmtl_store_write(g_dir, "failed", "the kernel turned the GPU off\n");
	want("mark", boot_start("native"), "default");
	put_image(0xB2);
	want("a new build: tried", boot_start("native"), "native");
	has("one line for it", g_note, "new build B2B2B2B2");
	if (nmtl_store_read(g_dir, "failed-native", text, sizeof(text)) != ENOENT) { printf("FAIL the old mark stays\n"); fails_seen++; }
	power_loss();
	want("the new build: one count, the second try", boot_start("native"), "native");
	power_loss();
	want("the new build also fails: default", boot_start("native"), "default");
	has("its own mark", g_why, "build B2B2B2B2");
	put_image(0xA1);
	want("back to the first build: it has no mark now: a new try", boot_start("native"), "native");

	/* the owner's reset: what metaloption and RESET_FAILED remove */
	fresh_store(0xC3);
	(void)boot_start("native");
	(void)nmtl_store_write(g_dir, "failed", "no device\n");
	(void)boot_start("native");
	nmtl_store_remove(g_dir, "state");
	nmtl_store_remove(g_dir, "failed-native");
	want("the owner's reset", boot_start("native"), "native");

	/* a hang, a reset before any other start: at most 2 hangs a build */
	fresh_store(0xD4);
	want("hang 1", boot_start("native"), "native");
	power_loss();
	want("hang 2, after a reset", boot_start("native"), "native");
	power_loss();
	want("no third hang", boot_start("native"), "default");
	has("the count's line", g_why, "failed in 2 starts");
	has("the mark's text", g_why, "stays off");

	/* a good start: lit, then a reset */
	fresh_store(0xE5);
	want("good", boot_start("native"), "native");
	(void)nmtl_store_write(g_dir, "ok", "lit\n");
	power_loss();
	want("lit survives a reset", boot_start("native"), "native");
	if (nmtl_store_read(g_disk, "state", text, sizeof(text)) != 0 || strncmp(text, "native 0 1", 10) != 0) { printf("FAIL a lit start counted: [%s]\n", text); fails_seen++; }
	/* lit, then the GPU is lost: the report wins */
	(void)nmtl_store_write(g_dir, "ok", "lit\n");
	(void)nmtl_store_write(g_dir, "failed", "the kernel turned the GPU off\n");
	want("lit and failed: failed", boot_start("native"), "default");

	/* the cause of 06:49: the state cannot be written (a root-owned file in the sticky folder). No count on the disk: the stack is not taken */
	fresh_store(0xF6);
	{
		char p[300];
		snprintf(p, sizeof(p), "%s/state", g_dir);
		mkdir(p, 0755); /* rename over it fails, as over root's file */
		want("a state that cannot be written: default", boot_start("native"), "default");
		has("the line says it", g_why, "cannot write stack/state");
		want("the default itself needs no count", boot_start("default"), "default");
		rmdir(p);
	}

	/* a sandboxed client: the folder cannot be read. It cannot see a mark: not native; another option is not its risk */
	if (geteuid() != 0) {
		fresh_store(0x11);
		chmod(g_dir, 0);
		want("sandboxed client, native: default", client_start("native"), "default");
		want("sandboxed client, hot", client_start("hot"), "hot");
		chmod(g_dir, 0755);
	}
	/* a client that can read, with no mark: it follows the setting */
	fresh_store(0x12);
	want("a client with no mark", client_start("native"), "native");

	/* build ids */
	put_image(0x4C);
	(void)nmtl_option_build_id(g_image, id, sizeof(id));
	want("LC_UUID", id, "4C4C4C4C-4C4C-4C4C-4C4C-4C4C4C4C4C4C");
	{
		FILE *f = fopen(g_image, "w");
		fputs("not a Mach-O", f);
		fclose(f);
	}
	(void)nmtl_option_build_id(g_image, id, sizeof(id));
	has("no LC_UUID: size and time", id, "size-12-time-");
	unlink(g_image);
	wipe(g_dir);
	want("no such image: no id", nmtl_option_build_id(g_image, id, sizeof(id)) ? "yes" : "no", "no");
	wipe(g_disk);
	rmdir(g_dir);
	rmdir(g_disk);
	rmdir(root);
}
int main(void)
{
	struct nmtl_option_state s;
	char why[160];
	memset(&s, 0, sizeof(s));
	want("missing setting", nmtl_option_choose(NULL, known, &s, 0, 0, 1, why, sizeof(why)), "default");
	want("empty setting", nmtl_option_choose("", known, &s, 0, 0, 1, why, sizeof(why)), "default");
	want("unknown option", nmtl_option_choose("junk", known, &s, 0, 0, 1, why, sizeof(why)), "default");
	if (why[0] == 0) { printf("FAIL unknown option has no reason\n"); fails_seen++; }
	/* the third option goes through the same rule: a reported failure returns it to the default at once */
	{
		struct nmtl_option_state n;
		memset(&n, 0, sizeof(n));
		want("native: first start", nmtl_option_choose("native", known, &n, 0, 0, 1, why, sizeof(why)), "native");
		want("native: reported failure: the default", nmtl_option_choose("native", known, &n, 0, 1, 1, why, sizeof(why)), "default");
		want("native: stays default until written again", nmtl_option_choose("native", known, &n, 0, 0, 1, why, sizeof(why)), "default");
	}
	want("first start", nmtl_option_choose("hot", known, &s, 0, 0, 1, why, sizeof(why)), "hot");
	want("second start, no ok: 1 fail", nmtl_option_choose("hot", known, &s, 0, 0, 1, why, sizeof(why)), "hot");
	want("third start, no ok: 2 fails, default", nmtl_option_choose("hot", known, &s, 0, 0, 1, why, sizeof(why)), "default");
	want("stays default in a crash loop", nmtl_option_choose("hot", known, &s, 0, 0, 1, why, sizeof(why)), "default");
	want("the default's lit screen clears nothing", nmtl_option_choose("hot", known, &s, 1, 0, 1, why, sizeof(why)), "default");
	want("a client follows the failed state", nmtl_option_choose("hot", known, &s, 0, 0, 0, why, sizeof(why)), "default");
	want("setting default clears", nmtl_option_choose("default", known, &s, 0, 0, 1, why, sizeof(why)), "default");
	if (s.fails || s.pending) { printf("FAIL state not cleared\n"); fails_seen++; }
	want("chosen again", nmtl_option_choose("hot", known, &s, 0, 0, 1, why, sizeof(why)), "hot");
	want("a lit screen resets", nmtl_option_choose("hot", known, &s, 1, 0, 1, why, sizeof(why)), "hot");
	want("still fine after ok", nmtl_option_choose("hot", known, &s, 1, 0, 1, why, sizeof(why)), "hot");
	want("reported failure: at once", nmtl_option_choose("hot", known, &s, 0, 1, 1, why, sizeof(why)), "default");
	memset(&s, 0, sizeof(s));
	want("clients do not count", nmtl_option_choose("hot", known, &s, 0, 0, 0, why, sizeof(why)), "hot");
	want("clients do not count (2)", nmtl_option_choose("hot", known, &s, 0, 0, 0, why, sizeof(why)), "hot");
	if (s.fails) { printf("FAIL a client counted\n"); fails_seen++; }
	nmtl_option_state_read("garbage", &s);
	if (s.option[0]) { printf("FAIL garbage state kept\n"); fails_seen++; }
	nmtl_option_state_read("hot 1 1\n", &s);
	want("state text read", s.fails == 1 && s.pending == 1 ? "yes" : "no", "yes");
	{
		uint64_t base[NMTL_PRESENT_BINS] = { 0 }, now[NMTL_PRESENT_BINS] = { 0 };
		struct nmtl_present_summary p;
		char text[200];
		base[20] = 7;
		now[20] = 7 + 50;       /* 50 at 20 ms */
		now[33] = 45;           /* 45 at 33 ms */
		now[127] = 5;           /* 5 at 127 ms or more */
		nmtl_present_summarize(now, base, &p);
		snprintf(text, sizeof(text), "%llu %u %u %u", (unsigned long long)p.frames, p.p50, p.p95, p.max);
		want("histogram: frames p50 p95 max", text, "100 20 33 127");
		memcpy(now, base, sizeof(now));
		nmtl_present_summarize(now, base, &p);
		snprintf(text, sizeof(text), "%llu %u %u %u", (unsigned long long)p.frames, p.p50, p.p95, p.max);
		want("histogram: no frames", text, "0 0 0 0");
		nmtl_present_text(text, sizeof(text), &p, 0, "hot");
		want("no frames, no division by 0", strstr(text, "PRESENT_FPS=0.0") ? "yes" : "no", "yes");
	}
	store_tests();
	printf("option-rule-test: %s\n", fails_seen ? "FAIL" : "PASS");
	return fails_seen != 0;
}
