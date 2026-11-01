/*
 * What the report reads on the phone (docs/laurel_sprout/xnutils.md): key=value text + kern.laurel_stats. Runs inside the helper, as
 * root, only while the app is on screen. Read-only. Rates and shares are differences between two calls of collect(): the first call of a
 * process has none, and then the key is absent, so the report says "not available".
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <ifaddrs.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <net/if.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>
#include "collect.h"

/* IOKit: the SDK has the .tbd; these few declarations are all this file needs */
typedef mach_port_t io_object_t;
extern const mach_port_t kIOMainPortDefault;
CFMutableDictionaryRef IOServiceMatching(const char *name);
io_object_t IOServiceGetMatchingService(mach_port_t port, CFDictionaryRef matching);
kern_return_t IORegistryEntryCreateCFProperties(io_object_t e, CFMutableDictionaryRef *p, CFAllocatorRef a, uint32_t options);
kern_return_t IOObjectRelease(io_object_t o);

/* libproc: not in the SDK; the same in every XNU */
#define PROC_ALL_PIDS     1
#define PROC_PIDTASKINFO  4
struct proc_taskinfo {
	uint64_t pti_virtual_size, pti_resident_size, pti_total_user, pti_total_system, pti_threads_user, pti_threads_system;
	int32_t pti_policy, pti_faults, pti_pageins, pti_cow_faults, pti_messages_sent, pti_messages_received, pti_syscalls_mach,
	    pti_syscalls_unix, pti_csw, pti_threadnum, pti_numrunning, pti_priority;
};
int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);

#define KERN_STATS_MAX  (160u * 1024u)
#define OUT_MAX         (KERN_STATS_MAX + 24u * 1024u)
#define MAX_CPUS        8
#define MAX_PROCS       768
#define TOP_N           6

static char *out;
static size_t at;
static struct {
	natural_t ticks[MAX_CPUS][CPU_STATE_MAX];
	int have_cpu;
	struct { int pid; uint64_t abs; } proc[MAX_PROCS];
	int nproc;
	uint64_t net_rx, net_tx, net_at;
} prev;

static void
kv(const char *key, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

static void
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

/* the tokens of a list file, one line, without comment lines */
static int
read_list(const char *path, char *o, size_t cap)
{
	FILE *f = fopen(path, "r");
	char line[512];
	size_t n = 0;

	o[0] = 0;
	if (f == NULL) {
		return 0;
	}
	while (fgets(line, sizeof(line), f) != NULL) {
		if (line[0] == '#') {
			continue;
		}
		char *save = NULL;

		for (char *t = strtok_r(line, " \t\r\n", &save); t != NULL; t = strtok_r(NULL, " \t\r\n", &save)) {
			n += (size_t)snprintf(o + n, cap - n, "%s%s", n ? " " : "", t);
			if (n >= cap) {
				n = cap - 1;
			}
		}
	}
	fclose(f);
	return 1;
}

static int
first_line_is(const char *path, const char *mark)
{
	char line[128] = "";
	FILE *f = fopen(path, "r");

	if (f == NULL) {
		return 0;
	}
	if (fgets(line, sizeof(line), f) == NULL) {
		line[0] = 0;
	}
	fclose(f);
	return strncmp(line, mark, strlen(mark)) == 0;
}

static void
metal(void)
{
	char list[512], names[256] = "";
	struct stat st;
	int off = stat(XT_METAL_OFF, &st) == 0;

	kv("metal.off", "%d", off);
	int have = read_list(XT_METAL_CLIENTS, list, sizeof(list));

	if (have) {
		kv("metal.clients", "%s", list[0] ? list : "(empty)");
	}
	if (off) {
		kv("metal.mode", "off (off file)");
	} else if (!have) {
		kv("metal.mode", "no clients file");
	} else if (first_line_is(XT_METAL_CLIENTS, XT_GATE_MARK)) {
		kv("metal.mode", "auto (the gate's list)");
	} else if (strcmp(list, XT_METAL_WIDE) == 0) {
		kv("metal.mode", "all (own list)");
	} else if (strcmp(list, XT_METAL_PROBES) == 0) {
		kv("metal.mode", "probes (own list)");
	} else {
		kv("metal.mode", "custom (own list)");
	}
	if (read_list(XT_METAL_LOCAL, list, sizeof(list))) {
		kv("metal.local", "%s", list[0] ? list : "(empty)");
	}
	if (read_list(XT_METAL_GATE, list, sizeof(list))) {
		/* "<state> <tries> <full> <key>": the key is a long build hash */
		char *sp = strchr(list, ' ');

		sp = sp ? strchr(sp + 1, ' ') : NULL;
		sp = sp ? strchr(sp + 1, ' ') : NULL;
		if (sp != NULL) {
			*sp = 0;
		}
		kv("metal.gate", "%s", list);
	}
	int strikes = 0;
	DIR *d = opendir(XT_METAL_STRIKES);

	if (d != NULL) {
		size_t n = 0;

		for (struct dirent *e; (e = readdir(d)) != NULL;) {
			if (e->d_name[0] != '.') {
				strikes++;
				if (n + e->d_namlen + 3 < sizeof(names)) {
					n += (size_t)snprintf(names + n, sizeof(names) - n, "%s%s", n ? ", " : "", e->d_name);
				}
			}
		}
		closedir(d);
		kv("metal.strikes", strikes ? "%d: %s" : "%d%s", strikes, names);
	}
	if ((d = opendir(XT_METAL_CACHE)) != NULL) {
		long files = 0;
		uint64_t bytes = 0;

		for (struct dirent *e; (e = readdir(d)) != NULL;) {
			char p[300];

			if (e->d_name[0] == '.') {
				continue;
			}
			snprintf(p, sizeof(p), XT_METAL_CACHE "/%s", e->d_name);
			DIR *sub = opendir(p);

			if (sub == NULL) {
				continue;
			}
			for (struct dirent *f; (f = readdir(sub)) != NULL;) {
				char q[600];

				snprintf(q, sizeof(q), "%s/%s", p, f->d_name);
				if (f->d_name[0] != '.' && lstat(q, &st) == 0 && S_ISREG(st.st_mode)) {
					files++;
					bytes += (uint64_t)st.st_size;
				}
			}
			closedir(sub);
		}
		closedir(d);
		kv("metal.cache_files", "%ld", files);
		kv("metal.cache_bytes", "%llu", (unsigned long long)bytes);
	}
	kv("gl.off", "%d", stat(XT_GL_OFF, &st) == 0);
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

struct top { char name[33]; uint64_t v; };

static void
top_add(struct top *t, const char *name, uint64_t v)
{
	for (int i = 0; i < TOP_N; i++) {
		if (v > t[i].v) {
			memmove(&t[i + 1], &t[i], (size_t)(TOP_N - i - 1) * sizeof(t[0]));
			snprintf(t[i].name, sizeof(t[i].name), "%s", name);
			t[i].v = v;
			return;
		}
	}
}

/* Every process once: the only per-process cost of a tick. Times in mach units (ARM XNU). */
static void
procs(void)
{
	static int pids[MAX_PROCS];
	static __typeof__(prev.proc) now;
	static char all[8192];
	static mach_timebase_info_data_t tb;
	static uint64_t last;
	int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids));

	if (bytes <= 0) {
		return;
	}
	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	uint64_t t = mach_absolute_time(), span = last != 0 ? t - last : 0;
	struct top cpu[TOP_N + 1], rss[TOP_N + 1];
	int n = 0;
	size_t an = 1;

	last = t;
	all[0] = ',';
	all[1] = 0;
	memset(cpu, 0, sizeof(cpu));
	memset(rss, 0, sizeof(rss));
	for (int i = 0; i < bytes / (int)sizeof(int) && n < MAX_PROCS; i++) {
		struct proc_taskinfo ti;
		char name[33] = "";

		if (pids[i] <= 0 || proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &ti, (int)sizeof(ti)) != (int)sizeof(ti) ||
		    proc_name(pids[i], name, sizeof(name)) <= 0) {
			continue;
		}
		uint64_t abs = ti.pti_total_user + ti.pti_total_system, was = abs;

		for (int j = 0; j < prev.nproc; j++) {
			if (prev.proc[j].pid == pids[i]) {
				was = prev.proc[j].abs;
				break;
			}
		}
		now[n].pid = pids[i];
		now[n].abs = abs;
		n++;
		if (abs > was) {
			top_add(cpu, name, abs - was);
		}
		top_add(rss, name, ti.pti_resident_size);
		if (an + strlen(name) + 2 < sizeof(all)) {
			an += (size_t)snprintf(all + an, sizeof(all) - an, "%s,", name);
		}
	}
	memcpy(prev.proc, now, sizeof(now));
	prev.nproc = n;
	kv("procs.all", "%s", all);
	char b[320];
	size_t bn = 0;

	if (span != 0) {
		for (int i = 0; i < TOP_N && cpu[i].v != 0; i++) {
			uint64_t tenths = cpu[i].v * 1000 / span;

			bn += (size_t)snprintf(b + bn, sizeof(b) - bn, "%s%s %llu.%llu %%", i ? ", " : "", cpu[i].name, (unsigned long long)(tenths / 10), (unsigned long long)(tenths % 10));
		}
		kv("top.cpu", "%s", bn ? b : "all idle");
	}
	bn = 0;
	for (int i = 0; i < TOP_N && rss[i].v != 0; i++) {
		bn += (size_t)snprintf(b + bn, sizeof(b) - bn, "%s%s %llu MiB", i ? ", " : "", rss[i].name, (unsigned long long)(rss[i].v >> 20));
	}
	if (bn != 0) {
		kv("top.rss", "%s", b);
	}
}

static void
memory(void)
{
	vm_statistics64_data_t v;
	mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
	vm_size_t page = 0;
	uint64_t total = 0;
	size_t len = sizeof(total);
	int level = 0;

	host_page_size(mach_host_self(), &page);
	if (sysctlbyname("hw.memsize", &total, &len, NULL, 0) == 0) {
		kv("mem.total_mb", "%llu", (unsigned long long)(total >> 20));
	}
	if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&v, &c) == KERN_SUCCESS && page != 0) {
#define MB(x) ((unsigned long long)((uint64_t)(x) * page >> 20))
		kv("mem.free_mb", "%llu", MB(v.free_count));
		kv("mem.active_mb", "%llu", MB(v.active_count));
		kv("mem.inactive_mb", "%llu", MB(v.inactive_count));
		kv("mem.wired_mb", "%llu", MB(v.wire_count));
		kv("mem.compressor_mb", "%llu", MB(v.compressor_page_count));
		kv("mem.compressed_mb", "%llu", MB(v.total_uncompressed_pages_in_compressor));
#undef MB
	}
	struct xsw_usage sw;

	len = sizeof(sw);
	if (sysctlbyname("vm.swapusage", &sw, &len, NULL, 0) == 0) {
		kv("mem.swap_used_mb", "%llu", (unsigned long long)(sw.xsu_used >> 20));
		kv("mem.swap_total_mb", "%llu", (unsigned long long)(sw.xsu_total >> 20));
	}
	len = sizeof(level);
	if (sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, NULL, 0) == 0) {
		kv("mem.pressure", "%s", level <= 1 ? "normal" : level == 2 ? "warning" : "critical");
	}
	len = sizeof(level);
	if (sysctlbyname("kern.memorystatus_level", &level, &len, NULL, 0) == 0) {
		kv("mem.level", "%d", level);
	}
}

static int
cfnum(CFDictionaryRef d, const char *name, long *v)
{
	CFStringRef k = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
	CFTypeRef o = k ? CFDictionaryGetValue(d, k) : NULL;
	int ok = 0;

	if (o != NULL && CFGetTypeID(o) == CFNumberGetTypeID()) {
		ok = CFNumberGetValue((CFNumberRef)o, kCFNumberLongType, v);
	} else if (o != NULL && CFGetTypeID(o) == CFBooleanGetTypeID()) {
		*v = CFBooleanGetValue((CFBooleanRef)o) ? 1 : 0;
		ok = 1;
	}
	if (k != NULL) {
		CFRelease(k);
	}
	return ok;
}

/* The registry of SweetBattery (an IOPMPowerSource; its 10 s sample). No new read of the PMIC. */
static void
battery(void)
{
	io_object_t e = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMPowerSource"));
	CFMutableDictionaryRef d = NULL;
	long v;

	if (e == 0) {
		return;
	}
	if (IORegistryEntryCreateCFProperties(e, &d, kCFAllocatorDefault, 0) == KERN_SUCCESS && d != NULL) {
		long cur, max;

		if (cfnum(d, "CurrentCapacity", &cur) && cfnum(d, "MaxCapacity", &max) && max > 0) {
			kv("bat.pct", "%ld", cur * 100 / max);
		}
		if (cfnum(d, "InstantAmperage", &v) || cfnum(d, "Amperage", &v)) {
			kv("bat.ma", "%d", (int)v);
		}
		if (cfnum(d, "Voltage", &v)) {
			kv("bat.mv", "%ld", v);
		}
		if (cfnum(d, "Temperature", &v)) {
			kv("bat.temp_cC", "%ld", v);
		}
		if (cfnum(d, "SweetBatteryTemperatureEstimated", &v)) {
			kv("bat.temp_est", "%ld", v);
		}
		if (cfnum(d, "IsCharging", &v)) {
			kv("bat.charging", "%ld", v);
		}
		if (cfnum(d, "ExternalConnected", &v)) {
			kv("bat.external", "%ld", v);
		}
		if (cfnum(d, "CycleCount", &v)) {
			kv("bat.cycles", "%ld", v);
		}
		CFRelease(d);
	}
	IOObjectRelease(e);
}

static void
network(void)
{
	struct ifaddrs *list = NULL;

	if (getifaddrs(&list) != 0) {
		return;
	}
	for (struct ifaddrs *i = list; i != NULL; i = i->ifa_next) {
		if (strcmp(i->ifa_name, "en0") != 0 || i->ifa_addr == NULL || i->ifa_addr->sa_family != AF_LINK || i->ifa_data == NULL) {
			continue;
		}
		const struct if_data *d = i->ifa_data;
		uint64_t rx = d->ifi_ibytes, tx = d->ifi_obytes, t = (uint64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

		if (prev.net_at != 0 && t > prev.net_at) {
			uint64_t ms = (t - prev.net_at) / 1000000 + 1;

			/* if_data counts wrap at 4 GiB: a wrap shows one rate of 0 */
			kv("net.en0_rx_kbps", "%llu", (unsigned long long)(rx >= prev.net_rx ? (rx - prev.net_rx) * 8 / ms : 0));
			kv("net.en0_tx_kbps", "%llu", (unsigned long long)(tx >= prev.net_tx ? (tx - prev.net_tx) * 8 / ms : 0));
		}
		prev.net_rx = rx;
		prev.net_tx = tx;
		prev.net_at = t;
		break;
	}
	freeifaddrs(list);
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
	metal();
	cpu_cores();
	procs();
	memory();
	battery();
	network();
	struct statfs fs;

	if (statfs("/", &fs) == 0) {
		kv("disk.root_total_mb", "%llu", (unsigned long long)((uint64_t)fs.f_blocks * fs.f_bsize >> 20));
		kv("disk.root_free_mb", "%llu", (unsigned long long)((uint64_t)fs.f_bavail * fs.f_bsize >> 20));
	}
	return out;
}
