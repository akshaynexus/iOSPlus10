/*
 * /usr/libexec/laurel-metal-gate (Mi A3): which processes get the NegroniMetal device (Turnip on the Adreno 610).
 * The backboardd wrapper (userland/laurel/gpu/bbd_wrap.c) starts it once per boot, detached; it never delays backboardd.
 *
 * The root's default list (/var/db/negronimetal/clients, scripts/laurel/root-add-metal.sh) is the probes only, because a
 * Metal device that half works makes CoreAnimation draw nothing. This gate widens it to "* -backboardd" (every process
 * but the GL window server) only when, in this order:
 *   1. the kernel has the GPU on (sysctl kern.laurel_gpu "on", laurel 2155) with the stage-1 SMMU tables (RedwoodGPU
 *      property LaurelGPUSMMU = "stage 1": in pass-through only backboardd may open the GPU, laurel 2150/2154);
 *   2. the kernel registered the plug-in (IOAcceleratorES MetalPluginName = NegroniMetal, laurel 2850);
 *   3. no GPU-lost mark (/var/db/negronimetal/strikes/gpu-lost, the plug-in's watchdog);
 *   4. the clients file is the gate's own (its first line is MARK): an owner's list is never changed;
 *   5. m2vtest (the bridge's self-test: compute, render, IOSurface import, all QuartzCore shaders through metal2vulkan
 *      and Turnip) exits 0 with "compute bad 0/1000, render bad 0/64, import bad 0/4096". The result is kept per build
 *      (kernel version + size and time of the plug-in and of Turnip) in /var/db/negronimetal/gate, so the test runs
 *      once per new build. A test that did not end (the GPU watchdog, a panic) counts as failed for that build.
 * Else the list goes back to the probes. The plug-in's own dead-man strikes still stop a process that crashes.
 * Sandboxed apps read only the bundle's files: BUNDLE/clients.local is written the same way when the root is writable.
 * One line: "LAUREL METAL CLIENTS: on: ..." or "off: <reason>: clients stay the probes" (syslog, metal.log, LOG).
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
#define MARK      "# laurel-metal-gate"
#define PROBES    "metalprobe m2vtest carenderprobe layerprobe"
#define WIDE      "* -backboardd"
#define PASS      "compute bad 0/1000, render bad 0/64, import bad 0/4096"
#define WAIT_S    90            /* for the GPU and the plug-in registration after boot */
#define TEST_S    240           /* m2vtest translates every QuartzCore shader: slow on the A53/A73 cores */

extern char **environ;

static void
say(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	FILE *f;

	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	syslog(LOG_NOTICE, "LAUREL METAL CLIENTS: %s", line);
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
		snprintf(out + strlen(out), n - strlen(out), " %lld:%ld", (long long)st.st_size, (long)st.st_mtime);
	} else {
		snprintf(out + strlen(out), n - strlen(out), " none");
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

/* m2vtest under a time limit, at low priority; 1 = passed */
static int
run_test(char *why, size_t n)
{
	char *args[] = { (char *)M2VTEST, (char *)BUNDLE "/libvulkan_freedreno.dylib", (char *)DB "/cache/m2vtest",
		         (char *)"/System/Library/Frameworks/QuartzCore.framework/default.metallib", NULL };
	posix_spawn_file_actions_t fa;
	pid_t pid;
	int status = 0, fd;
	char text[8192] = "";

	mkdir(DB "/cache/m2vtest", 0755);
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_addopen(&fa, 1, TESTLOG, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	posix_spawn_file_actions_adddup2(&fa, 1, 2);
	if (posix_spawn(&pid, M2VTEST, &fa, NULL, args, environ) != 0) {
		snprintf(why, n, "m2vtest did not start (%s)", strerror(errno));
		posix_spawn_file_actions_destroy(&fa);
		return 0;
	}
	posix_spawn_file_actions_destroy(&fa);
	setpriority(PRIO_PROCESS, pid, 10);
	for (int t = 0; t < TEST_S * 10; t++) {
		if (waitpid(pid, &status, WNOHANG) == pid) {
			pid = 0;
			break;
		}
		usleep(100000);
	}
	if (pid != 0) {
		kill(pid, SIGKILL);
		waitpid(pid, &status, 0);
		snprintf(why, n, "m2vtest did not end in %d s", TEST_S);
		return 0;
	}
	if ((fd = open(TESTLOG, O_RDONLY)) >= 0) {
		ssize_t got = read(fd, text, sizeof(text) - 1);
		text[got > 0 ? got : 0] = 0;
		close(fd);
	}
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0 || strstr(text, PASS) == NULL) {
		char *r = strstr(text, "result ");
		snprintf(why, n, "m2vtest failed (status %#x): %.120s", status, r ? r : "no result line (" TESTLOG ")");
		for (char *p = why; *p; p++) {
			*p = *p == '\n' ? ';' : *p;
		}
		return 0;
	}
	char *q = strstr(text, "QuartzCore: ");
	snprintf(why, n, "m2vtest passed: %.110s", q ? q : PASS);
	for (char *p = why; *p; p++) {
		*p = *p == '\n' ? ' ' : *p;
	}
	return 1;
}

int
main(void)
{
	char session[64] = "", old[64] = "", gpu[160] = "", smmu[64] = "", plugin[64] = "", key[512] = "", had[600] = "";
	char why[400] = "";
	size_t len;
	FILE *f;

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
	if (access(CLIENTS, F_OK) != 0 && errno != ENOENT) {
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
	} else if (access(DB "/strikes/gpu-lost", F_OK) == 0) {
		snprintf(why, sizeof(why), "the plug-in marked the GPU lost (" DB "/strikes/gpu-lost)");
	} else if (access(M2VTEST, X_OK) != 0) {
		snprintf(why, sizeof(why), "no " M2VTEST " (root without scripts/laurel/root-add-metal.sh)");
	}

	/* 5: the test, once per build */
	if (why[0] == 0) {
		len = sizeof(key) - 1;
		(void)sysctlbyname("kern.version", key, &len, NULL, 0);
		for (char *p = key; *p; p++) {
			*p = (*p == '\n' || *p == ' ') ? '_' : *p;
		}
		file_key(BUNDLE "/NegroniMetal", key, sizeof(key));
		file_key(BUNDLE "/libvulkan_freedreno.dylib", key, sizeof(key));
		if ((f = fopen(GATE, "r")) != NULL) {
			if (fgets(had, sizeof(had), f) == NULL) {
				had[0] = 0;
			}
			fclose(f);
			had[strcspn(had, "\n")] = 0;
		}
		if (strncmp(had, "pass ", 5) == 0 && strcmp(had + 5, key) == 0) {
			snprintf(why, sizeof(why), "m2vtest passed before on this build");
		} else if (strncmp(had, "fail ", 5) == 0 && strcmp(had + 5, key) == 0) {
			snprintf(why, sizeof(why), "m2vtest failed before on this build (" TESTLOG ")");
		} else if (strncmp(had, "running ", 8) == 0 && strcmp(had + 8, key) == 0) {
			snprintf(why, sizeof(why), "m2vtest did not end in an earlier boot on this build (GPU hang or panic?)");
			if ((f = fopen(GATE, "w")) != NULL) {
				fprintf(f, "fail %s\n", key);
				fclose(f);
			}
		} else {
			if ((f = fopen(GATE, "w")) != NULL) {
				fprintf(f, "running %s\n", key);
				fclose(f);
				sync();
			}
			int ok = run_test(why, sizeof(why));
			if ((f = fopen(GATE, "w")) != NULL) {
				fprintf(f, "%s %s\n", ok ? "pass" : "fail", key);
				fclose(f);
			}
			if (ok) {
				goto wide;
			}
		}
		if (strncmp(why, "m2vtest passed", 14) == 0) {
			goto wide;
		}
	}
	write_list(CLIENTS, why, PROBES);
	if (ours(LOCAL)) {
		unlink(LOCAL);
	}
	say("off: %s: clients stay the probes (%s)", why, PROBES);
	return 0;
wide:
	if (write_list(CLIENTS, why, WIDE " " PROBES) != 0) {
		say("off: %s, but %s cannot be written (%s)", why, CLIENTS, strerror(errno));
		return 0;
	}
	int apps = ours(LOCAL) && write_list(LOCAL, why, WIDE) == 0;
	say("on: %s; GPU on, SMMU stage 1, plug-in registered: clients \"%s\" from the next process start%s", why, WIDE,
	    apps ? " (sandboxed apps too: " LOCAL ")" : " (not sandboxed apps: the bundle is read-only)");
	return 0;
}
