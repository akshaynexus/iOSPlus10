/*
 * What the report reads on the phone (docs/laurel_sprout/xnutils.md): key=value text + kern.laurel_stats. Runs inside the helper, as
 * root, only while the app is on screen. Read-only. Rates and shares are differences between two calls of collect(): the first call of a
 * process has none, and then the key is absent, so the report says "not available".
 */
#include <mach/mach.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>
#include "collect.h"

#define KERN_STATS_MAX  (160u * 1024u)
#define OUT_MAX         (KERN_STATS_MAX + 24u * 1024u)
#define MAX_CPUS        8

static char *out;
static size_t at;
static struct {
	natural_t ticks[MAX_CPUS][CPU_STATE_MAX];
	int have_cpu;
} prev;

void
kv(const char *key, const char *fmt, ...)
{
	va_list ap;
	int n = snprintf(out + at, OUT_MAX - at, "%s=", key);

	at += (size_t)n;
	va_start(ap, fmt);
	n = vsnprintf(out + at, OUT_MAX - at, fmt, ap);
	va_end(ap);
	if (n > 0) {
		size_t m = (size_t)n < OUT_MAX - at ? (size_t)n : OUT_MAX - at - 1;

		for (size_t i = 0; i < m; i++) {        /* a value is one line */
			if (out[at + i] == '\n' || out[at + i] == '\t') {
				out[at + i] = ' ';
			}
		}
		at += m;
	}
	if (at + 1 < OUT_MAX) {
		out[at++] = '\n';
		out[at] = 0;
	}
}

static void
sysctl_string(const char *key, const char *name)
{
	char b[512];
	size_t len = sizeof(b);

	if (sysctlbyname(name, b, &len, NULL, 0) == 0 && len > 0) {
		b[len - 1] = 0;
		kv(key, "%s", b);
	}
}

static void
cpu_cores(void)
{
	natural_t count = 0;
	mach_msg_type_number_t size = 0;
	processor_info_array_t info = NULL;

	if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &size) != KERN_SUCCESS) {
		return;
	}
	processor_cpu_load_info_t l = (processor_cpu_load_info_t)info;
	char b[128];
	size_t n = 0;

	if (count > MAX_CPUS) {
		count = MAX_CPUS;
	}
	for (natural_t c = 0; c < count; c++) {
		uint64_t all = 0, idle = l[c].cpu_ticks[CPU_STATE_IDLE] - prev.ticks[c][CPU_STATE_IDLE];

		for (int s = 0; s < CPU_STATE_MAX; s++) {
			all += l[c].cpu_ticks[s] - prev.ticks[c][s];
			prev.ticks[c][s] = l[c].cpu_ticks[s];
		}
		if (prev.have_cpu && all != 0) {
			n += (size_t)snprintf(b + n, sizeof(b) - n, "%scpu%u %llu", c ? ", " : "", c, (unsigned long long)((all - idle) * 100 / all));
		}
	}
	vm_deallocate(mach_task_self(), (vm_address_t)info, size);
	if (prev.have_cpu && n != 0) {
		kv("cpu.cores", "%s", b);
	}
	prev.have_cpu = 1;
}

char *
collect(void)
{
	if (out == NULL && (out = malloc(OUT_MAX)) == NULL) {
		return NULL;
	}
	at = 0;
	out[0] = 0;
	size_t len = KERN_STATS_MAX;

	if (sysctlbyname("kern.laurel_stats", out, &len, NULL, 0) == 0 && len > 0) {
		if (strncmp(out, "off", 3) == 0) {
			char why[64];

			snprintf(why, sizeof(why), "%s", out);
			kv("stats.state", "%s", why);
		} else {
			at = strnlen(out, len);
		}
	}
	sysctl_string("gpu.state", "kern.laurel_gpu");
	sysctl_string("camera.state", "kern.laurel_camera");
	sysctl_string("camera.stream", "kern.laurel_camera_stream");
	sysctl_string("cell.state", "kern.laurel_cell");
	sysctl_string("ipa.state", "kern.laurel_ipa");
	sysctl_string("kern.version", "kern.version");
	sysctl_string("kern.osversion", "kern.osversion");
	sysctl_string("kern.bootargs", "kern.bootargs");
	struct timeval boot;
	size_t blen = sizeof(boot);
	time_t now = time(NULL);

	if (sysctlbyname("kern.boottime", &boot, &blen, NULL, 0) == 0) {
		kv("kern.uptime_s", "%ld", (long)(now - boot.tv_sec));
	}
	char when[64];
	struct tm tm;

	if (localtime_r(&now, &tm) != NULL && strftime(when, sizeof(when), "%Y-%m-%d %H:%M:%S %z", &tm) != 0) {
		kv("time.now", "%s", when);
	}
	xt_collect_files();
	cpu_cores();
	xt_collect_procs();
	xt_collect_memory();
	xt_collect_battery();
	xt_collect_network();
	struct statfs fs;

	if (statfs("/", &fs) == 0) {
		kv("disk.root_total_mb", "%llu", (unsigned long long)((uint64_t)fs.f_blocks * fs.f_bsize >> 20));
		kv("disk.root_free_mb", "%llu", (unsigned long long)((uint64_t)fs.f_bavail * fs.f_bsize >> 20));
	}
	return out;
}
