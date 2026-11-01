/*
 * /usr/libexec/laurel-metal-gate (Mi A3): which processes get the NegroniMetal device (Turnip on the Adreno 610).
 * launchd starts it once at boot, as root (job com.laurel.metal-gate, scripts/laurel/metal-gate-job.py). The first design
 * started it from the backboardd wrapper: that is user mobile, /var/db/negronimetal is root's, so posix_spawn of m2vtest with
 * its log there failed and no list could be written (boot 2026-11-01 15:27: no "exec m2vtest" in the log, AegirPoster aborts).
 *
 * The root's default list (/var/db/negronimetal/clients, scripts/laurel/root-add-metal.sh) is the probes only, because a
 * Metal device that half works makes CoreAnimation draw nothing. This gate widens it to "* -backboardd" (every process
 * but the GL window server) only when, in this order:
 *   1. the kernel has the GPU on (sysctl kern.laurel_gpu "on", laurel 2155) with the stage-1 SMMU tables (RedwoodGPU
 *      property LaurelGPUSMMU = "stage 1": in pass-through only backboardd may open the GPU, laurel 2150/2154);
 *   2. the kernel registered the plug-in (IOAcceleratorES MetalPluginName = NegroniMetal, laurel 2850);
 *   3. no GPU-lost mark of this boot (/var/db/negronimetal/strikes/gpu-lost, the plug-in's watchdog);
 *   4. the clients file is the gate's own (its first line is MARK): an owner's list is never changed;
 *   5. m2vtest without a library (the bridge's self-test: compute, render, host-page import, seconds) exits 0 with
 *      "compute bad 0/1000, render bad 0/64, import bad 0/4096".
 * Sandboxed processes (posters, widgets, apps, the WebKit GPU process) cannot read /var/db: BUNDLE/clients.local gets the same
 * list. After a pass, m2vtest runs again at the lowest priority with QuartzCore's metallib (every shader through metal2vulkan
 * and Turnip's ir3, minutes): the numbers go to the log; a crash there (the shader compiler dies in every client) narrows the
 * list again. The results are kept per build (kernel version + size and time of the plug-in and of Turnip) in
 * /var/db/negronimetal/gate, so each test runs once per new build. A test that fails or does not end gets MAX_TRIES boots.
 * Lines, on the console (USB log), in syslog, metal.log and LOG: "LAUREL METAL CLIENTS: on: ...", "off: <reason>: ...".
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>

#define DB        "/private/var/db/negronimetal"
#define CLIENTS   DB "/clients"
#define GATE      DB "/gate"
#define TESTLOG   DB "/gate-m2vtest.log"
#define METALLOG  DB "/metal.log"
#define BUNDLE    "/System/Library/Extensions/NegroniMetal.bundle"
#define LOCAL     BUNDLE "/clients.local"
#define M2VTEST   "/usr/local/bin/m2vtest"
#define LOG       "/var/tmp/laurel-metal-gate.log"
#define BOOTFILE  "/var/tmp/laurel-metal-gate.boot"
#define QC_LIB    "/System/Library/Frameworks/QuartzCore.framework/default.metallib"
#define MARK      "# laurel-metal-gate"
#define PROBES    "metalprobe m2vtest carenderprobe layerprobe"
#define WIDE      "* -backboardd"
#define PASS      "compute bad 0/1000, render bad 0/64, import bad 0/4096"
#define WAIT_S    90            /* for the GPU and the plug-in registration after boot */
#define QUICK_S   300           /* the self-test while the system boots (seconds when the system is idle) */
#define FULL_S    1500          /* all of QuartzCore's shaders at the lowest priority */
#define MAX_TRIES 3             /* boots: an owner's reboot during a test is no verdict */

extern char **environ;

/* the per-build record: "<state> <tries> <full> <key>"; state new|running|retry|pass|fail, full = how often the long test started */
struct record {
	char state[16];
	int tries, full;
	char key[512];
};

static void
say(const char *fmt, ...)
{
	char line[640];
	va_list ap;
	FILE *f;
	int fd;

	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	syslog(LOG_NOTICE, "LAUREL METAL CLIENTS: %s", line);
	/* the USB log has the console, not syslog: the first version of this line never reached it */
	if ((fd = open("/dev/console", O_WRONLY | O_NOCTTY)) >= 0) {
		dprintf(fd, "LAUREL METAL CLIENTS: %s\n", line);
		close(fd);
	}
	for (int i = 0; i < 2; i++) {
		if ((f = fopen(i ? LOG : METALLOG, "a")) != NULL) {
			fprintf(f, "%ld LAUREL METAL CLIENTS: %s\n", (long)time(NULL), line);
			fclose(f);
		}
	}
}

/* a string property of the first service of a class, into out ("" if none) */
static void
registry_string(const char *class, const char *key, char *out, size_t n)
{
	io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(class));
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);

	out[0] = 0;
	if (s != 0) {
		CFTypeRef v = IORegistryEntryCreateCFProperty(s, k, NULL, 0);
		if (v != NULL && CFGetTypeID(v) == CFStringGetTypeID()) {
			CFStringGetCString((CFStringRef)v, out, (CFIndex)n, kCFStringEncodingUTF8);
		}
		if (v != NULL) {
			CFRelease(v);
		}
		IOObjectRelease(s);
	}
	CFRelease(k);
}

static void
file_key(const char *path, char *out, size_t n)
{
	struct stat st;

	if (stat(path, &st) == 0) {
		snprintf(out + strlen(out), n - strlen(out), "_%lld:%ld", (long long)st.st_size, (long)st.st_mtime);
	} else {
		snprintf(out + strlen(out), n - strlen(out), "_none");
	}
}

/* the first line of a file is MARK (the gate's own list), or the file is missing */
static int
ours(const char *path)
{
	char line[128] = "";
	FILE *f = fopen(path, "r");

	if (f == NULL) {
		return errno == ENOENT;
	}
	if (fgets(line, sizeof(line), f) == NULL) {
		line[0] = 0;
	}
	fclose(f);
	return strncmp(line, MARK, strlen(MARK)) == 0;
}

static int
write_list(const char *path, const char *why, const char *list)
{
	char tmp[256];
	FILE *f;

	snprintf(tmp, sizeof(tmp), "%s.gate", path);
	if ((f = fopen(tmp, "w")) == NULL) {
		return -1;
	}
	fprintf(f, "%s: %s (userland/laurel/metal/metal_gate.c; replace this file to keep a list of your own)\n%s\n", MARK, why,
	    list);
	fclose(f);
	chmod(tmp, 0644);
	return rename(tmp, path);
}

static void
load(struct record *r, const char *key)
{
	char had[640] = "";
	FILE *f = fopen(GATE, "r");

	snprintf(r->state, sizeof(r->state), "new");
	r->tries = r->full = 0;
	snprintf(r->key, sizeof(r->key), "%s", key);
	if (f != NULL) {
		char state[16], old[512];
		int tries, full;

		if (fgets(had, sizeof(had), f) != NULL && sscanf(had, "%15s %d %d %511s", state, &tries, &full, old) == 4 &&
		    strcmp(old, key) == 0) {
			snprintf(r->state, sizeof(r->state), "%s", state);
			r->tries = tries;
			r->full = full;
		}
		fclose(f);
	}
}

static void
save(const struct record *r)
{
	FILE *f = fopen(GATE, "w");

	if (f != NULL) {
		fprintf(f, "%s %d %d %s\n", r->state, r->tries, r->full, r->key);
		fclose(f);
		sync();                                 /* a test that hangs the phone must leave its mark */
	}
}

/* m2vtest under a time limit, at a low priority. 1 = passed, 0 = failed, -1 = it crashed (a signal of its own) */
static int
run_test(const char *library, int limit_s, int nice_value, char *why, size_t n)
{
	char *args[] = { (char *)M2VTEST, (char *)BUNDLE "/libvulkan_freedreno.dylib", (char *)DB "/cache/m2vtest", (char *)library, NULL };
	posix_spawn_file_actions_t fa;
	pid_t pid;
	int status = 0, fd, e;
	char text[8192] = "";

	mkdir(DB "/cache/m2vtest", 0755);
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_addopen(&fa, 1, TESTLOG, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	posix_spawn_file_actions_adddup2(&fa, 1, 2);
	e = posix_spawn(&pid, M2VTEST, &fa, NULL, args, environ);
	posix_spawn_file_actions_destroy(&fa);
	if (e != 0) {
		snprintf(why, n, "m2vtest did not start (%s)", strerror(e));
		return 0;
	}
	setpriority(PRIO_PROCESS, pid, nice_value);
	for (int t = 0; t < limit_s * 10; t++) {
		if (waitpid(pid, &status, WNOHANG) == pid) {
			pid = 0;
			break;
		}
		usleep(100000);
	}
	if (pid != 0) {
		kill(pid, SIGKILL);
		waitpid(pid, &status, 0);
		snprintf(why, n, "m2vtest did not end in %d s", limit_s);
		return 0;
	}
	if ((fd = open(TESTLOG, O_RDONLY)) >= 0) {
		ssize_t got = read(fd, text, sizeof(text) - 1);
		text[got > 0 ? got : 0] = 0;
		close(fd);
	}
	if (WIFSIGNALED(status)) {
		snprintf(why, n, "m2vtest died of signal %d (" TESTLOG ")", WTERMSIG(status));
		return -1;
	}
	if (WEXITSTATUS(status) != 0 || strstr(text, PASS) == NULL) {
		char *r = strstr(text, "result ");
		snprintf(why, n, "m2vtest failed (exit %d): %.180s", WEXITSTATUS(status), r ? r : "no result line (" TESTLOG ")");
		for (char *p = why; *p; p++) {
			*p = *p == '\n' ? ';' : *p;
		}
		return 0;
	}
	char *q = strstr(text, "QuartzCore: ");
	snprintf(why, n, "m2vtest passed: %.110s", q != NULL && strncmp(q, "QuartzCore: 0 functions", 23) != 0 ? q : PASS);
	for (char *p = why; *p; p++) {
		*p = *p == '\n' ? ' ' : *p;
	}
	return 1;
}

/* a mark from an earlier boot is stale (as in the plug-in's off_reason): 1 = the GPU was lost in this boot */
static int
gpu_lost_now(const char *session)
{
	char line[256] = "";
	FILE *f = fopen(DB "/strikes/gpu-lost", "r");
	const char *b;
	int lost = 1;

	if (f == NULL) {
		return 0;
	}
	if (fgets(line, sizeof(line), f) != NULL && (b = strstr(line, "boot=")) != NULL && session[0] != 0 &&
	    strncmp(b + 5, session, strlen(session)) != 0) {
		lost = 0;
	}
	fclose(f);
	if (!lost) {
		unlink(DB "/strikes/gpu-lost");
	}
	return lost;
}

static void
narrow(const char *why)
{
	write_list(CLIENTS, why, PROBES);
	if (ours(LOCAL)) {
		unlink(LOCAL);
	}
	say("off: %s: clients stay the probes (%s); poster extensions wait, then get no device (NegroniMetal.mm refused_pause)", why, PROBES);
}

/* 0 = every process but backboardd has the list now */
static int
widen(const char *why)
{
	if (write_list(CLIENTS, why, WIDE " " PROBES) != 0) {
		say("off: %s, but %s cannot be written (%s)", why, CLIENTS, strerror(errno));
		return -1;
	}
	if (!ours(LOCAL)) {
		say("on: %s; clients \"%s\", but %s is the owner's own list: sandboxed processes go by that", why, WIDE, LOCAL);
		return 0;
	}
	if (write_list(LOCAL, why, WIDE) != 0) {
		say("off: %s, but %s cannot be written (%s): sandboxed processes (posters, widgets, apps) get no device", why, LOCAL,
		    strerror(errno));
		return -1;
	}
	say("on: %s; GPU on, SMMU stage 1, plug-in registered: clients \"%s\" for every process that starts from now on", why, WIDE);
	return 0;
}

int
main(void)
{
	char session[64] = "", old[64] = "", gpu[160] = "", smmu[64] = "", plugin[64] = "", key[512] = "", why[400] = "";
	struct record r;
	size_t len;
	FILE *f;
	int ok;

	/* once per boot */
	len = sizeof(session) - 1;
	(void)sysctlbyname("kern.bootsessionuuid", session, &len, NULL, 0);
	if ((f = fopen(BOOTFILE, "r")) != NULL) {
		if (fscanf(f, "%63s", old) != 1) {
			old[0] = 0;
		}
		fclose(f);
	}
	if (session[0] != 0 && strcmp(old, session) == 0) {
		return 0;
	}
	if ((f = fopen(BOOTFILE, "w")) != NULL) {
		fprintf(f, "%s\n", session[0] ? session : "-");
		fclose(f);
	}
	if (access(DB, W_OK) != 0) {
		say("off: %s is not writable for uid %d (%s): the list stays", DB, (int)getuid(), strerror(errno));
		return 0;
	}
	if (!ours(CLIENTS)) {
		say("off: %s is the owner's own list (no '%s' first line): left as it is", CLIENTS, MARK);
		return 0;
	}

	/* 1-3: the kernel's GPU, stage 1, the plug-in registered */
	for (int t = 0; t < WAIT_S * 2; t++) {
		len = sizeof(gpu) - 1;
		if (sysctlbyname("kern.laurel_gpu", gpu, &len, NULL, 0) != 0) {
			gpu[0] = 0;
		} else {
			gpu[len < sizeof(gpu) ? len : sizeof(gpu) - 1] = 0;
		}
		registry_string("RedwoodGPU", "LaurelGPUSMMU", smmu, sizeof(smmu));
		registry_string("IOAcceleratorES", "MetalPluginName", plugin, sizeof(plugin));
		if (strncmp(gpu, "off", 3) == 0 || (strcmp(gpu, "on") == 0 && smmu[0] != 0 && plugin[0] != 0)) {
			break;
		}
		usleep(500000);
	}
	if (strcmp(gpu, "on") != 0) {
		snprintf(why, sizeof(why), "the GPU is not on (kern.laurel_gpu \"%s\")", gpu);
	} else if (strcmp(smmu, "stage 1") != 0) {
		snprintf(why, sizeof(why), "SMMU \"%s\", not stage 1: only backboardd may open the GPU", smmu);
	} else if (strcmp(plugin, "NegroniMetal") != 0) {
		snprintf(why, sizeof(why), "no NegroniMetal on IOAcceleratorES (\"%s\"; see the LAUREL METAL line)", plugin);
	} else if (gpu_lost_now(session)) {
		snprintf(why, sizeof(why), "the plug-in marked the GPU lost in this boot (" DB "/strikes/gpu-lost)");
	} else if (access(M2VTEST, X_OK) != 0) {
		snprintf(why, sizeof(why), "no " M2VTEST " (root without scripts/laurel/root-add-metal.sh)");
	}
	if (why[0] != 0) {
		narrow(why);
		return 0;
	}

	/* 5: the test, once per build */
	len = sizeof(key) - 1;
	(void)sysctlbyname("kern.version", key, &len, NULL, 0);
	for (char *p = key; *p; p++) {
		*p = (*p == '\n' || *p == ' ' || *p == '\t') ? '_' : *p;
	}
	file_key(BUNDLE "/NegroniMetal", key, sizeof(key));
	file_key(BUNDLE "/libvulkan_freedreno.dylib", key, sizeof(key));
	load(&r, key);
	if (strcmp(r.state, "fail") == 0) {
		narrow("m2vtest failed on this build in earlier boots (" TESTLOG "; rm " GATE " to test again)");
		return 0;
	}
	if (strcmp(r.state, "pass") != 0) {
		if (strcmp(r.state, "running") == 0 && r.tries >= MAX_TRIES) {
			snprintf(r.state, sizeof(r.state), "fail");
			save(&r);
			narrow("m2vtest did not end in 3 boots on this build (GPU hang or panic?)");
			return 0;
		}
		r.tries++;
		snprintf(r.state, sizeof(r.state), "running");
		save(&r);
		say("testing: m2vtest (compute, render, host pages), try %d of %d on this build", r.tries, MAX_TRIES);
		ok = run_test("/nonexistent", QUICK_S, 5, why, sizeof(why));
		len = sizeof(gpu) - 1;
		if (ok == 1 && (sysctlbyname("kern.laurel_gpu", gpu, &len, NULL, 0) != 0 || strcmp(gpu, "on") != 0)) {
			ok = 0;
			snprintf(why, sizeof(why), "the GPU went off during m2vtest (kern.laurel_gpu \"%s\")", gpu);
		}
		snprintf(r.state, sizeof(r.state), "%s", ok == 1 ? "pass" : r.tries >= MAX_TRIES ? "fail" : "retry");
		save(&r);
		if (ok != 1) {
			narrow(why);
			return 0;
		}
	} else {
		snprintf(why, sizeof(why), "m2vtest passed before on this build");
	}
	if (widen(why) != 0 || r.full >= 2) {
		return 0;
	}

	/* the long test: only its crash takes the list back; a reboot or the time limit is no verdict */
	r.full++;
	save(&r);
	ok = run_test(QC_LIB, FULL_S, 20, why, sizeof(why));
	if (ok == -1) {
		snprintf(r.state, sizeof(r.state), "fail");
		save(&r);
		narrow(why);
		return 0;
	}
	if (ok == 1) {
		r.full = 2;
		save(&r);
	}
	say("%s %s", ok == 1 ? "QuartzCore shaders:" : "QuartzCore shaders: no result:", why);
	return 0;
}
