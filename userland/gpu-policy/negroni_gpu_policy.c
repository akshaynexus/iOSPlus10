/*
 * negroni_gpu_policy: Metal / GL / CPU per process (negroni_gpu_policy.h; docs/gpu-hybrid-plan.md).
 *
 * Borrowed ideas (no code copied):
 *   - Bergamota gpu/eagl/launch/bgl-launch.c (MIT SPDX, 0826e48): a backboardd launcher that counts crash-loop
 *     strikes per boot and moves to the next renderer (Metal -> GL -> plain) when one fails.
 *   - ios-flame phone/metal2/SweetMetal2.mm (MIT, 745c434): clients list with "*" and "-NAME".
 *   - Our own NegroniMetal.mm dead-man (strike file "COUNT BOOT", boot session UUID, sandbox cache directory).
 */
#include "negroni_gpu_policy.h"

#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#endif

static char g_root[512];        /* tests: prefix for every absolute path */
static char g_test_boot[64];
static time_t g_test_start = (time_t)-1;
static char g_test_ext[128];
static int g_test_ext_set;
static void (*g_logger)(const char *line);

void ngp_test_set_root(const char *prefix) { snprintf(g_root, sizeof(g_root), "%s", prefix ? prefix : ""); }
void ngp_test_set_boot(const char *boot) { snprintf(g_test_boot, sizeof(g_test_boot), "%s", boot ? boot : ""); }
void ngp_test_set_proc_start(time_t t) { g_test_start = t; }
void ngp_test_set_ext(const char *ext)
{
	snprintf(g_test_ext, sizeof(g_test_ext), "%s", ext ? ext : "");
	g_test_ext_set = ext != NULL;
}
void ngp_set_logger(void (*fn)(const char *line)) { g_logger = fn; }

static void
plog(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	if (g_logger) {
		g_logger(line);
	} else {
		fprintf(stderr, "%s\n", line);
	}
}

const char *
ngp_api_name(enum ngp_api api)
{
	switch (api) {
	case NGP_METAL: return "metal";
	case NGP_GL: return "gl";
	case NGP_CPU: return "cpu";
	default: return "none";
	}
}

/* ---------------------------------------------------------------- small helpers */

static void
rooted(char *out, size_t size, const char *path)
{
	snprintf(out, size, "%s%s", path[0] == '/' ? g_root : "", path);
}

/* 1 = exists, 0 = ENOENT, -1 = cannot check */
static int
exists(const char *path)
{
	struct stat sb;
	if (stat(path, &sb) == 0) {
		return 1;
	}
	return errno == ENOENT ? 0 : -1;
}

static int
exists_rooted(const char *path)
{
	char p[700];
	rooted(p, sizeof(p), path);
	return exists(p);
}

static const char *
boot_id(void)
{
	if (g_test_boot[0]) {
		return g_test_boot;
	}
	static char u[64];
#ifdef __APPLE__
	size_t len = sizeof(u) - 1;
	if (!u[0] && sysctlbyname("kern.bootsessionuuid", u, &len, NULL, 0) != 0) {
		/* no session UUID (sandbox): the boot time is also unique per boot. Never the constant "-" when
		 * a fallback exists: "-" matches in every boot, so a strike or a failure record would never expire. */
		struct timeval bt;
		size_t bl = sizeof(bt);
		u[0] = 0;
		if (sysctlbyname("kern.boottime", &bt, &bl, NULL, 0) == 0 && bt.tv_sec > 0) {
			snprintf(u, sizeof(u), "boottime-%ld", (long)bt.tv_sec);
		}
	}
#else
	if (!u[0]) {
		FILE *f = fopen("/proc/sys/kernel/random/boot_id", "r");
		if (f) {
			if (!fgets(u, sizeof(u), f)) {
				u[0] = 0;
			}
			u[strcspn(u, "\r\n")] = 0;
			fclose(f);
		}
	}
#endif
	u[sizeof(u) - 1] = 0;
	return u[0] ? u : "-";
}

/* the start time of this process (0 = unknown) */
static time_t
proc_start(void)
{
	if (g_test_start != (time_t)-1) {
		return g_test_start;
	}
#ifdef __APPLE__
	static time_t t;
	if (!t) {
		struct kinfo_proc kp;
		size_t len = sizeof(kp);
		int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
		if (sysctl(mib, 4, &kp, &len, NULL, 0) == 0 && len > 0) {
			t = kp.kp_proc.p_starttime.tv_sec;
		}
	}
	return t;
#else
	return 0;
#endif
}

/* the sandbox's own cache directory, with a trailing "/" ("" = none) */
static const char *
cache_dir(void)
{
	static char dir[512];
	if (g_root[0]) {
		snprintf(dir, sizeof(dir), "%s/cache/", g_root);
		mkdir(dir, 0700);
		return dir;
	}
	if (!dir[0]) {
#ifdef _CS_DARWIN_USER_CACHE_DIR
		if (confstr(_CS_DARWIN_USER_CACHE_DIR, dir, sizeof(dir)) == 0) {
			dir[0] = 0;
		}
#else
		const char *t = getenv("TMPDIR");
		snprintf(dir, sizeof(dir), "%s/", t && t[0] ? t : "/tmp");
#endif
	}
	return dir;
}

/* KEY from the environment, else from the KEY=VALUE file (Metal: NMTL_DIR/env, read by the plugin too) */
static long
env_num(const char *key, const char *file, long def)
{
	const char *v = getenv(key);
	if (v && *v) {
		return strtol(v, NULL, 0);
	}
	if (file == NULL) {
		return def;
	}
	char p[700];
	rooted(p, sizeof(p), file);
	FILE *f = fopen(p, "r");
	if (!f) {
		return def;
	}
	char line[512];
	size_t kl = strlen(key);
	long r = def;
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, key, kl) == 0 && line[kl] == '=') {
			r = line[kl + 1] && line[kl + 1] != '\n' ? strtol(line + kl + 1, NULL, 0) : def;
		}
	}
	fclose(f);
	return r;
}

/* a strike file "COUNT BOOT": the count of this boot (0 for another boot or no file), *mtime set */
static int
strike_count(const char *path, time_t *mtime)
{
	struct stat sb;
	*mtime = 0;
	if (stat(path, &sb) != 0) {
		return 0;
	}
	*mtime = sb.st_mtime;
	FILE *f = fopen(path, "r");
	if (!f) {
		return 0;
	}
	int n = 0;
	char boot[64] = "";
	if (fscanf(f, "%d %63s", &n, boot) < 1) {
		n = 0;
	}
	fclose(f);
	return strcmp(boot, boot_id()) == 0 ? n : 0;
}

/* the strike file of prog under dir (absolute, not rooted) or the cache directory's sub (first that exists) */
static void
strike_path(char *out, size_t size, const char *dir, const char *cache_sub, const char *prog)
{
	char p[700];
	snprintf(p, sizeof(p), "%s/strikes/%s", dir, prog);
	rooted(out, size, p);
	if (exists(out) == 1) {
		return;
	}
	snprintf(out, size, "%s%s/%s", cache_dir(), cache_sub, prog);
	if (exists(out) != 1) {
		rooted(out, size, p);
	}
}

static bool
suffix(const char *s, const char *sfx)
{
	size_t a = strlen(s), b = strlen(sfx);
	return a >= b && strcmp(s + a - b, sfx) == 0;
}

/* GPU watchdog marker of this boot (NegroniMetal.mm off_reason: "boot=" field; no field = this boot) */
static bool
gpu_lost(void)
{
	char p[700];
	rooted(p, sizeof(p), NGP_METAL_DIR "/strikes/gpu-lost");
	FILE *f = fopen(p, "r");
	if (!f) {
		return false;
	}
	char line[256] = "";
	bool lost = true;
	if (fgets(line, sizeof(line), f)) {
		char *b = strstr(line, "boot=");
		if (b) {
			char gboot[64] = "";
			sscanf(b + 5, "%63s", gboot);
			lost = !gboot[0] || strcmp(gboot, boot_id()) == 0;
		}
	}
	fclose(f);
	return lost;
}

/* failure records: NGP_DIR/state/<prog>, else <cache>/negronigpu-state/<prog>; lines "API BOOT reason" */
static bool
record_dir(char *out, size_t size, bool create)
{
	char p[700];
	rooted(p, sizeof(p), NGP_DIR);
	if (create) {
		mkdir(p, 0777);
		chmod(p, 0777);
	}
	snprintf(out, size, "%s/state", p);
	if (create) {
		mkdir(out, 0777);
		chmod(out, 0777);
	}
	if (access(out, create ? W_OK : R_OK) == 0) {
		return true;
	}
	snprintf(out, size, "%snegronigpu-state", cache_dir());
	if (create) {
		mkdir(out, 0700);
	}
	return access(out, create ? W_OK : R_OK) == 0;
}

static bool
recorded(const char *prog, enum ngp_api api, char *why, size_t size)
{
	char dir[600], p[800];
	bool found = false;
	for (int pass = 0; pass < 2 && !found; pass++) {
		if (pass == 0) {
			char d[700];
			rooted(d, sizeof(d), NGP_DIR "/state");
			snprintf(dir, sizeof(dir), "%s", d);
		} else {
			snprintf(dir, sizeof(dir), "%snegronigpu-state", cache_dir());
		}
		snprintf(p, sizeof(p), "%s/%s", dir, prog);
		FILE *f = fopen(p, "r");
		if (!f) {
			continue;
		}
		char line[512];
		while (fgets(line, sizeof(line), f)) {
			char a[16] = "", b[64] = "";
			int off = 0;
			if (sscanf(line, "%15s %63s %n", a, b, &off) >= 2 && strcmp(a, ngp_api_name(api)) == 0 &&
			    strcmp(b, boot_id()) == 0) {
				line[strcspn(line, "\r\n")] = 0;
				snprintf(why, size, "failure record %s: %s", p, line + off);
				found = true;
			}
		}
		fclose(f);
	}
	return found;
}

bool
ngp_record_failure(const char *prog, enum ngp_api api, const char *reason)
{
	char dir[600], p[800];
	if (!prog || !record_dir(dir, sizeof(dir), true)) {
		return false;
	}
	snprintf(p, sizeof(p), "%s/%s", dir, prog);
	FILE *f = fopen(p, "a");
	if (!f) {
		return false;
	}
	fprintf(f, "%s %s %.300s\n", ngp_api_name(api), boot_id(), reason ? reason : "-");
	fclose(f);
	chmod(p, 0666);
	plog("gpu-policy: %s: %s marked failed for this boot (%s); record %s", prog, ngp_api_name(api),
	    reason ? reason : "-", p);
	return true;
}

/* ---------------------------------------------------------------- off, extension point, order */

bool
ngp_off(void)
{
	const char *e = getenv("NEGRONIGPU");
	if (e && (strcmp(e, "0") == 0 || strcmp(e, "off") == 0)) {
		return true;
	}
	return exists_rooted(NGP_DIR "/off") == 1 || exists_rooted(NGP_GL_BUNDLE "/gpu-policy.off") == 1 ||
	    exists_rooted(NGP_METAL_BUNDLE "/gpu-policy.off") == 1;
}

static char g_point[128];

#ifdef __APPLE__
static void
read_point(void)
{
	CFBundleRef b = CFBundleGetMainBundle();
	if (!b) {
		return;
	}
	CFTypeRef ext = CFBundleGetValueForInfoDictionaryKey(b, CFSTR("NSExtension"));
	if (!ext || CFGetTypeID(ext) != CFDictionaryGetTypeID()) {
		return;
	}
	CFTypeRef id = CFDictionaryGetValue((CFDictionaryRef)ext, CFSTR("NSExtensionPointIdentifier"));
	if (id && CFGetTypeID(id) == CFStringGetTypeID() &&
	    !CFStringGetCString((CFStringRef)id, g_point, sizeof(g_point), kCFStringEncodingUTF8)) {
		g_point[0] = 0;
	}
}
#endif

const char *
ngp_extension_point(void)
{
	if (g_test_ext_set) {
		return g_test_ext;
	}
#ifdef __APPLE__
	static pthread_once_t once = PTHREAD_ONCE_INIT;
	pthread_once(&once, read_point);
#endif
	return g_point;
}

static enum ngp_api
api_of(const char *w)
{
	if (strcmp(w, "metal") == 0) return NGP_METAL;
	if (strcmp(w, "gl") == 0 || strcmp(w, "gles") == 0) return NGP_GL;
	if (strcmp(w, "cpu") == 0) return NGP_CPU;
	return NGP_NONE;
}

static bool
rule_matches(const char *pat, const char *prog, const char *ext)
{
	if (strncmp(pat, "ext:", 4) == 0) {
		return ext && ext[0] && fnmatch(pat + 4, ext, 0) == 0;
	}
	return fnmatch(pat, prog, 0) == 0;
}

/* first matching line of one file: count of APIs (0 = no match) */
static int
order_from(const char *file, const char *prog, const char *ext, enum ngp_api order[3], char *rule, size_t rsize)
{
	char p[700];
	rooted(p, sizeof(p), file);
	FILE *f = fopen(p, "r");
	if (!f) {
		return 0;
	}
	char line[512];
	int lineno = 0, n = 0;
	while (n == 0 && fgets(line, sizeof(line), f)) {
		lineno++;
		char copy[512];
		line[strcspn(line, "#\r\n")] = 0;
		snprintf(copy, sizeof(copy), "%s", line);
		char *save = NULL, *pat = strtok_r(line, " \t,", &save);
		if (!pat || !rule_matches(pat, prog, ext)) {
			continue;
		}
		for (char *w = strtok_r(NULL, " \t,", &save); w && n < 3; w = strtok_r(NULL, " \t,", &save)) {
			enum ngp_api a = api_of(w);
			bool dup = false;
			for (int i = 0; i < n; i++) {
				dup |= order[i] == a;
			}
			if (a != NGP_NONE && !dup) {
				order[n++] = a;
			}
		}
		if (n > 0) {
			snprintf(rule, rsize, "%s:%d %s", file, lineno, copy);
		}
	}
	fclose(f);
	return n;
}

int
ngp_order(const char *prog, const char *ext, enum ngp_api order[3], char *rule, size_t rule_size)
{
	static const char *const files[] = {
		NGP_DIR "/policy",
		NGP_GL_BUNDLE "/gpu-policy.local",
		NGP_METAL_BUNDLE "/gpu-policy.local",
		NGP_GL_BUNDLE "/gpu-policy",
		NGP_METAL_BUNDLE "/gpu-policy",
	};
	char dummy[8];
	if (!rule) {
		rule = dummy;
		rule_size = sizeof(dummy);
	}
	if (!ext) {
		ext = ngp_extension_point();
	}
	for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
		int n = order_from(files[i], prog, ext, order, rule, rule_size);
		if (n > 0) {
			return n;
		}
	}
	order[0] = NGP_METAL;
	order[1] = NGP_GL;
	order[2] = NGP_CPU;
	snprintf(rule, rule_size, "default: metal gl cpu");
	return 3;
}

/* ---------------------------------------------------------------- health */

/* NegroniMetal.mm read_clients/listed: "*" or the name in any file, "-NAME" in none */
static void
read_clients(const char *file, const char *prog, bool *yes, bool *no)
{
	char p[700];
	rooted(p, sizeof(p), file);
	FILE *f = fopen(p, "r");
	if (!f) {
		return;
	}
	char line[512];
	while (fgets(line, sizeof(line), f)) {
		line[strcspn(line, "#\r\n")] = 0;
		char *save = NULL;
		for (char *w = strtok_r(line, " ,\t", &save); w; w = strtok_r(NULL, " ,\t", &save)) {
			if (w[0] == '-' && strcmp(w + 1, prog) == 0) {
				*no = true;
			} else if (strcmp(w, "*") == 0 || strcmp(w, prog) == 0) {
				*yes = true;
			}
		}
	}
	fclose(f);
}

static bool
bootarg_metal_off(void)
{
#ifdef __APPLE__
	if (g_root[0]) {
		return false;
	}
	char args[1024] = "";
	size_t len = sizeof(args) - 1;
	if (sysctlbyname("kern.bootargs", args, &len, NULL, 0) != 0) {
		return false;
	}
	args[sizeof(args) - 1] = 0;
	for (char *p = strstr(args, "negronimetal=0"); p; p = strstr(p + 1, "negronimetal=0")) {
		char after = p[strlen("negronimetal=0")];
		if ((p == args || p[-1] == ' ') && (after == 0 || after == ' ')) {
			return true;
		}
	}
#endif
	return false;
}

/* jetsam limit in MiB (0 = none/unknown): NegroniMetal.mm memory_limit_mb */
static long
memory_limit_mb(void)
{
#if defined(__APPLE__) && defined(TASK_VM_INFO_REV4_COUNT)
	if (g_root[0]) {
		return env_num("NGP_TEST_LIMIT_MB", NULL, 0);
	}
	task_vm_info_data_t vm;
	mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &n) == KERN_SUCCESS && n >= TASK_VM_INFO_REV4_COUNT &&
	    vm.limit_bytes_remaining) {
		return (long)((vm.phys_footprint + vm.limit_bytes_remaining) >> 20);
	}
	return 0;
#else
	return env_num("NGP_TEST_LIMIT_MB", NULL, 0);
#endif
}

static long
metal_strike_limit(const char *prog)
{
	long limit = env_num("NEGRONIMETAL_STRIKE_LIMIT", NGP_METAL_DIR "/env",
	    env_num("NEGRONIMETAL_MAX_STRIKES", NGP_METAL_DIR "/env", 2));
	if (suffix(prog, "Poster") || suffix(prog, "PosterExtension") || suffix(prog, "PosterProvider")) {
		limit *= 2;
	}
	return limit;
}

enum ngp_health
ngp_metal_health(const char *prog, char *why, size_t size)
{
	char p[700];
	snprintf(why, size, "ok");
	rooted(p, sizeof(p), NGP_METAL_BUNDLE "/off");
	if (exists(p) != 0) {
		snprintf(why, size, "%s exists (or cannot be checked)", NGP_METAL_BUNDLE "/off");
		return NGP_DISABLED;
	}
	if (exists_rooted(NGP_METAL_DIR "/off") == 1) {
		snprintf(why, size, "%s exists", NGP_METAL_DIR "/off");
		return NGP_DISABLED;
	}
	bool yes = false, no = false;
	read_clients(NGP_METAL_BUNDLE "/clients", prog, &yes, &no);
	read_clients(NGP_METAL_BUNDLE "/clients.local", prog, &yes, &no);
	read_clients(NGP_METAL_DIR "/clients", prog, &yes, &no);
	if (!yes || no) {
		snprintf(why, size, "not listed in the NegroniMetal clients files");
		return NGP_DISABLED;
	}
	if (bootarg_metal_off()) {
		snprintf(why, size, "boot-arg negronimetal=0");
		return NGP_DISABLED;
	}
	long min_mb = env_num("NEGRONIMETAL_MIN_LIMIT_MB", NGP_METAL_DIR "/env", 40), lim = memory_limit_mb();
	if (min_mb > 0 && lim > 0 && lim < min_mb) {
		snprintf(why, size, "jetsam limit %ld MiB is below %ld MiB (NegroniMetal memory rule)", lim, min_mb);
		return NGP_DISABLED;
	}
	if (gpu_lost()) {
		snprintf(why, size, "the GPU watchdog marked the GPU lost in this boot (%s)", NGP_METAL_DIR "/strikes/gpu-lost");
		return NGP_FAILED;
	}
	time_t mt = 0;
	strike_path(p, sizeof(p), NGP_METAL_DIR, "negronimetal-strikes", prog);
	int n = strike_count(p, &mt);
	long limit = metal_strike_limit(prog);
	time_t start = proc_start();
	/* a file written after this process started = the plugin armed it in this process: Metal is in use here */
	bool ours = start > 0 && mt >= start;
	if (n >= limit && !ours) {
		snprintf(why, size, "Metal dead-man: %d unclean starts in a row this boot (limit %ld, %s)", n, limit, p);
		return NGP_FAILED;
	}
	if (recorded(prog, NGP_METAL, why, size)) {
		return NGP_FAILED;
	}
	return NGP_OK;
}

static long
gl_strike_limit(void)
{
	return env_num("NEGRONIGL_STRIKE_LIMIT", NGP_GL_DIR "/env", 2);
}

static char g_armed[700];
static int g_armed_on, g_frames;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

enum ngp_health
ngp_gl_health(const char *prog, const char *gl_bundle, char *why, size_t size)
{
	char p[700], q[700];
	snprintf(why, size, "ok");
	if (exists_rooted(NGP_GL_DIR "/off") == 1) {
		snprintf(why, size, "%s exists", NGP_GL_DIR "/off");
		return NGP_DISABLED;
	}
	snprintf(q, sizeof(q), "%s/off", gl_bundle ? gl_bundle : NGP_GL_BUNDLE);
	rooted(p, sizeof(p), q);
	if (exists(p) != 0) {
		snprintf(why, size, "%s exists (or cannot be checked)", q);
		return NGP_DISABLED;
	}
	if (gpu_lost()) {
		snprintf(why, size, "the GPU watchdog marked the GPU lost in this boot: GL uses the same GPU");
		return NGP_FAILED;
	}
	time_t mt = 0;
	strike_path(p, sizeof(p), NGP_GL_DIR, "negronigl-strikes", prog);
	int n = strike_count(p, &mt);
	long limit = gl_strike_limit();
	pthread_mutex_lock(&g_lock);
	bool ours = g_armed_on && strcmp(g_armed, p) == 0;
	pthread_mutex_unlock(&g_lock);
	if (n >= limit && !ours) {
		snprintf(why, size, "GL dead-man: %d unclean starts in a row this boot (limit %ld, %s)", n, limit, p);
		return NGP_FAILED;
	}
	if (recorded(prog, NGP_GL, why, size)) {
		return NGP_FAILED;
	}
	return NGP_OK;
}

static enum ngp_health
health(enum ngp_api a, const char *prog, const char *gl_bundle, char *why, size_t size)
{
	switch (a) {
	case NGP_METAL: return ngp_metal_health(prog, why, size);
	case NGP_GL: return ngp_gl_health(prog, gl_bundle, why, size);
	default: snprintf(why, size, "ok"); return NGP_OK;
	}
}

static const char *
health_name(enum ngp_health h)
{
	return h == NGP_OK ? "ok" : h == NGP_DISABLED ? "disabled" : "FAILED";
}

enum ngp_api
ngp_choose(const char *prog, const char *ext, const char *gl_bundle, char *why, size_t size)
{
	if (ngp_off()) {
		snprintf(why, size, "gpu-policy off (%s/off, BUNDLE/gpu-policy.off or NEGRONIGPU=0)", NGP_DIR);
		return NGP_NONE;
	}
	enum ngp_api order[3];
	char rule[600], hw[400];
	int n = ngp_order(prog, ext, order, rule, sizeof(rule));
	size_t len = (size_t)snprintf(why, size, "%s [%s]", prog, rule);
	for (int i = 0; i < n; i++) {
		enum ngp_health h = health(order[i], prog, gl_bundle, hw, sizeof(hw));
		if (order[i] == NGP_CPU || h == NGP_OK) {
			if (len < size) {
				snprintf(why + len, size - len, ": %s", ngp_api_name(order[i]));
			}
			return order[i];
		}
		if (len < size) {
			len += (size_t)snprintf(why + len, size - len, "; %s %s: %s", ngp_api_name(order[i]), health_name(h), hw);
		}
		if (h == NGP_DISABLED) {
			if (len < size) {
				snprintf(why + len, size - len, i == 0 ? ": no decision" : ": cpu");
			}
			return i == 0 ? NGP_NONE : NGP_CPU;
		}
	}
	if (len < size) {
		snprintf(why + len, size - len, ": cpu (every API in the order failed in this boot)");
	}
	return NGP_CPU;
}

enum ngp_api
ngp_gl_fallback(const char *prog, const char *ext, const char *gl_bundle, char *why, size_t size)
{
	if (ngp_off()) {
		snprintf(why, size, "gpu-policy off");
		return NGP_NONE;
	}
	enum ngp_api order[3];
	char rule[600], mw[400], gw[400];
	int n = ngp_order(prog, ext, order, rule, sizeof(rule));
	int im = -1, ig = -1;
	for (int i = 0; i < n; i++) {
		if (order[i] == NGP_METAL && im < 0) im = i;
		if (order[i] == NGP_GL && ig < 0) ig = i;
	}
	if (im < 0 || ig < 0 || ig < im) {
		snprintf(why, size, "%s [%s]: GL is not the fallback for Metal", prog, rule);
		return NGP_NONE;
	}
	for (int i = 0; i < im; i++) {          /* an API before Metal (cpu) that is always ok */
		if (order[i] == NGP_CPU) {
			snprintf(why, size, "%s [%s]: cpu first", prog, rule);
			return NGP_NONE;
		}
	}
	enum ngp_health hm = ngp_metal_health(prog, mw, sizeof(mw));
	if (hm != NGP_FAILED) {
		snprintf(why, size, "%s [%s]: metal %s (%s): no fallback", prog, rule, health_name(hm), mw);
		return NGP_NONE;
	}
	enum ngp_health hg = ngp_gl_health(prog, gl_bundle, gw, sizeof(gw));
	if (hg == NGP_OK) {
		snprintf(why, size, "%s [%s]: metal FAILED (%s): gl", prog, rule, mw);
		return NGP_GL;
	}
	snprintf(why, size, "%s [%s]: metal FAILED (%s); gl %s (%s): cpu", prog, rule, mw, health_name(hg), gw);
	return hg == NGP_FAILED ? NGP_CPU : NGP_NONE;
}

/* ---------------------------------------------------------------- GL dead-man */

static void
gl_clear(const char *why)
{
	pthread_mutex_lock(&g_lock);
	bool on = g_armed_on;
	g_armed_on = 0;
	char p[700];
	snprintf(p, sizeof(p), "%s", g_armed);
	pthread_mutex_unlock(&g_lock);
	if (on) {
		unlink(p);
		plog("gpu-policy: GL dead-man: strike cleared (%s)", why);
	}
}

static void
gl_atexit(void)
{
	gl_clear("exit()");
}

static void *
gl_timer(void *arg)
{
	(void)arg;
	sleep(15);
	gl_clear("15 s after the GL path was installed");
	return NULL;
}

static bool
gl_strike_dir(char *out, size_t size)
{
	char p[700];
	rooted(p, sizeof(p), NGP_GL_DIR);
	mkdir(p, 0755);
	snprintf(out, size, "%s/strikes", p);
	mkdir(out, 0777);
	chmod(out, 0777);
	if (access(out, W_OK) == 0) {
		return true;
	}
	snprintf(out, size, "%snegronigl-strikes", cache_dir());
	mkdir(out, 0700);
	return access(out, W_OK) == 0;
}

bool
ngp_gl_arm(const char *prog, char *why, size_t size)
{
	char dir[600], p[700];
	if (!gl_strike_dir(dir, sizeof(dir))) {
		snprintf(why, size, "GL dead-man: no writable strikes directory (%s/strikes, cache directory)", NGP_GL_DIR);
		return false;
	}
	snprintf(p, sizeof(p), "%s/%s", dir, prog);
	/* once per process: the shim (negronigl.dylib) and the bundle can both be in backboardd, each with its own
	 * copy of this file, so the mark is in the environment (process-wide). The image that armed clears it. */
	const char *mark = getenv("NEGRONIGPU_GL_ARMED");
	pthread_mutex_lock(&g_lock);
	bool again = (g_armed[0] != 0 && strcmp(g_armed, p) == 0) || (mark && strcmp(mark, p) == 0 && !g_root[0]);
	pthread_mutex_unlock(&g_lock);
	if (again) {
		snprintf(why, size, "GL dead-man: already armed in this process (%s)", p);
		return true;
	}
	time_t mt;
	int n = strike_count(p, &mt);
	long limit = gl_strike_limit();
	if (n >= limit) {
		snprintf(why, size, "GL dead-man: %d unclean starts in a row this boot (limit %ld; rm %s to re-arm)", n, limit, p);
		return false;
	}
	int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
	char line[96];
	int len = snprintf(line, sizeof(line), "%d %s\n", n + 1, boot_id());
	bool ok = fd >= 0 && write(fd, line, (size_t)len) == len;
	if (fd >= 0) {
		fsync(fd);
		close(fd);
	}
	if (!ok) {
		snprintf(why, size, "GL dead-man: cannot write %s: %s", p, strerror(errno));
		return false;
	}
	pthread_mutex_lock(&g_lock);
	bool first = !g_armed[0];
	snprintf(g_armed, sizeof(g_armed), "%s", p);
	g_armed_on = 1;
	g_frames = 0;
	pthread_mutex_unlock(&g_lock);
	if (first) {
		atexit(gl_atexit);
	}
	setenv("NEGRONIGPU_GL_ARMED", p, 1);
	pthread_t th;
	if (pthread_create(&th, NULL, gl_timer, NULL) == 0) {
		pthread_detach(th);
	}
	snprintf(why, size, "GL dead-man: strike %d armed (limit %ld, %s)", n + 1, limit, p);
	plog("gpu-policy: %s", why);
	return true;
}

void
ngp_gl_frame_ok(void)
{
	if (!__atomic_load_n(&g_armed_on, __ATOMIC_RELAXED)) {
		return;
	}
	if (__atomic_add_fetch(&g_frames, 1, __ATOMIC_RELAXED) >= NGP_GL_OK_FRAMES) {
		gl_clear("first GL frames flushed");
	}
}

void
ngp_gl_disarm(const char *why)
{
	gl_clear(why ? why : "clean refusal");
}

void
ngp_test_reset(void)
{
	pthread_mutex_lock(&g_lock);
	g_armed[0] = 0;
	g_armed_on = 0;
	g_frames = 0;
	pthread_mutex_unlock(&g_lock);
}
