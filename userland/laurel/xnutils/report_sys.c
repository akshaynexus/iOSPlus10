/* Report sections: CPU, thermal, memory, battery, clock, storage, kernel (report.h). */
#include <stdlib.h>
#include <string.h>
#include "report.h"

static void
mb_row(struct rp *r, const char *key, const char *kv)
{
	const char *v = rp_kv(r, kv);

	if (v != NULL) {
		rp_rowf(r, key, -1, "%s MiB", v);
	} else {
		rp_row(r, key, NULL, -1);
	}
}

/* 0.1 C with a sign; -1000 is the kernel's "no reading" */
static void
dc_row(struct rp *r, const char *key, const char *kv)
{
	long dc = rp_kvn(r, kv, -1000);

	if (dc <= -1000) {
		rp_row(r, key, NULL, -1);
	} else {
		rp_rowf(r, key, -1, "%ld.%ld C", dc / 10, labs(dc) % 10);
	}
}

void
rp_sec_cpu(struct rp *r)
{
	const struct rp_rec *gov = rp_r(r, "LAUREL CPUFREQ: on: OSM"), *st = rp_s(r, "LAUREL CPUFREQ");

	if (st != NULL && strcmp(st->a, "on") == 0 && gov != NULL) {
		rp_section(r, "CPU", "on", strstr(gov->text, "OSM"));
	} else {
		rp_state(r, "CPU", st, "no LAUREL CPUFREQ line");
	}
	if (rp_kv(r, "cpu.gold_mhz") != NULL) {
		rp_rowf(r, "Gold (A73)", -1, "%s MHz, busy %s %%, cap %s MHz", rp_kv(r, "cpu.gold_mhz"), rp_kv(r, "cpu.gold_busy"),
		    rp_kv(r, "cpu.gold_cap_mhz"));
		rp_rowf(r, "Silver (A53)", -1, "%s MHz, busy %s %%, cap %s MHz", rp_kv(r, "cpu.silver_mhz"), rp_kv(r, "cpu.silver_busy"),
		    rp_kv(r, "cpu.silver_cap_mhz"));
		rp_row(r, "Governor hold", rp_kv(r, "cpu.hold"), -1);
	} else {
		rp_row(r, "Clusters", NULL, -1);
	}
	rp_row(r, "Per core busy %", rp_kv(r, "cpu.cores"), -1);
	rp_line(r, "Last minute, Gold", rp_r(r, "LAUREL CPUFREQ: on: gold"));
	rp_line(r, "Last minute, Silver", rp_r(r, "LAUREL CPUFREQ: on: silver"));
	rp_row(r, "Top by CPU now", rp_kv(r, "top.cpu"), -1);
	rp_line(r, "Kernel top line", rp_r(r, "LAUREL CPU TOP"));
}

void
rp_sec_thermal(struct rp *r)
{
	const struct rp_rec *t = rp_s(r, "LAUREL THERMAL");

	rp_state(r, "Thermal", t, "no LAUREL THERMAL line");
	dc_row(r, "CPU sensor", "temp.cpu_dC");
	dc_row(r, "GPU sensor", "temp.gpu_dC");
	rp_line(r, "Last thermal line", rp_r(r, "LAUREL THERMAL: on: cpu"));
}

void
rp_sec_memory(struct rp *r)
{
	const struct rp_rec *w = rp_s(r, "LAUREL WIRED");
	long total = rp_kvn(r, "mem.total_mb", 0);
	char why[96] = "";

	if (total != 0) {
		snprintf(why, sizeof(why), "%ld MiB", total);
	}
	rp_section(r, "Memory", total != 0 ? "info" : "none", total != 0 ? why : "no host statistics");
	mb_row(r, "Free", "mem.free_mb");
	mb_row(r, "Active", "mem.active_mb");
	mb_row(r, "Inactive", "mem.inactive_mb");
	mb_row(r, "Wired", "mem.wired_mb");
	mb_row(r, "Compressor", "mem.compressor_mb");
	mb_row(r, "In the compressor (before)", "mem.compressed_mb");
	if (rp_kv(r, "mem.swap_used_mb") != NULL) {
		rp_rowf(r, "Swap", -1, "%s of %s MiB", rp_kv(r, "mem.swap_used_mb"), rp_kv(r, "mem.swap_total_mb"));
	} else {
		rp_row(r, "Swap", NULL, -1);
	}
	rp_row(r, "Jetsam pressure", rp_kv(r, "mem.pressure"), -1);
	if (rp_kv(r, "mem.level") != NULL) {
		rp_rowf(r, "Free for jetsam", -1, "%s %%", rp_kv(r, "mem.level"));
	} else {
		rp_row(r, "Free for jetsam", NULL, -1);
	}
	rp_srow(r, "Wired guard", w);
	rp_srow(r, "RAM window", rp_s(r, "LAUREL RAM"));
	rp_row(r, "Top by memory now", rp_kv(r, "top.rss"), -1);
}

void
rp_sec_battery(struct rp *r)
{
	const struct rp_rec *b = rp_s(r, "LAUREL BATTERY"), *c = rp_s(r, "LAUREL CHARGER");

	rp_state(r, "Battery", b, "no LAUREL BATTERY line");
	if (rp_kv(r, "bat.pct") != NULL) {
		rp_rowf(r, "Charge", -1, "%s %%", rp_kv(r, "bat.pct"));
		rp_rowf(r, "Current", -1, "%s mA", rp_kv(r, "bat.ma"));
		rp_rowf(r, "Voltage", -1, "%s mV", rp_kv(r, "bat.mv"));
		long t = rp_kvn(r, "bat.temp_cC", -100000);

		if (t > -100000) {
			rp_rowf(r, "Temperature", -1, "%ld.%ld C%s", t / 100, labs(t) / 10 % 10, rp_kvn(r, "bat.temp_est", 0) ? " (estimate: no NTC reading)" : "");
		} else {
			rp_row(r, "Temperature", NULL, -1);
		}
		rp_rowf(r, "Charging", -1, "%s; external power %s", rp_kvn(r, "bat.charging", 0) ? "yes" : "no", rp_kvn(r, "bat.external", 0) ? "yes" : "no");
		rp_row(r, "Cycles", rp_kv(r, "bat.cycles"), -1);
	} else {
		rp_row(r, "Power source", NULL, -1);
		rp_line(r, "Last battery line", rp_r(r, "LAUREL BATTERY: on: QG"));
	}
	rp_srow(r, "Charger", c);
	const struct rp_rec *z = rp_r(r, "LAUREL CHARGER: on: usbin");
	char zone[48];

	if (z != NULL && rp_after(z->text, " zone ", zone, sizeof(zone))) {
		rp_rowf(r, "JEITA zone", z->age, "%s", zone);
	} else {
		rp_row(r, "JEITA zone", NULL, -1);
	}
}

void
rp_sec_clock(struct rp *r)
{
	const struct rp_rec *s = rp_s(r, "LAUREL RTC");

	rp_state(r, "RTC and clock", s, "no LAUREL RTC line");
	rp_row(r, "Time now", rp_kv(r, "time.now"), -1);
	rp_srow(r, "RTC", s);
	rp_line(r, "Last RTC line", rp_r(r, "LAUREL RTC: saved"));
}

void
rp_sec_storage(struct rp *r)
{
	rp_section(r, "Storage", rp_kv(r, "disk.root_total_mb") != NULL ? "info" : "none", "");
	if (rp_kv(r, "disk.root_total_mb") != NULL) {
		rp_rowf(r, "Root", -1, "%s MiB free of %s MiB", rp_kv(r, "disk.root_free_mb"), rp_kv(r, "disk.root_total_mb"));
	} else {
		rp_row(r, "Root", NULL, -1);
	}
	rp_srow(r, "UFS solid state", rp_s(r, "LAUREL SSD"));
}

void
rp_sec_kernel(struct rp *r)
{
	const char *st = rp_kv(r, "stats.state");

	if (st != NULL && strncmp(st, "off", 3) == 0) {
		rp_section(r, "Kernel", "off", st);
	} else if (rp_kv(r, "up_ms") == NULL) {
		rp_section(r, "Kernel", "part", "this kernel has no kern.laurel_stats (patch 2911): most rows here stay empty");
	} else {
		rp_section(r, "Kernel", "on", "kern.laurel_stats reads the console ring");
	}
	rp_row(r, "Version", rp_kv(r, "kern.version"), -1);
	rp_row(r, "OS build", rp_kv(r, "kern.osversion"), -1);
	rp_row(r, "Boot-args", rp_kv(r, "kern.bootargs"), -1);
	long up = rp_kvn(r, "up_ms", -1000) / 1000;

	if (up < 0) {
		up = rp_kvn(r, "kern.uptime_s", -1);
	}
	if (up >= 0) {
		rp_rowf(r, "Uptime", -1, "%ld h %ld min %ld s", up / 3600, up / 60 % 60, up % 60);
	} else {
		rp_row(r, "Uptime", NULL, -1);
	}
	if (rp_kv(r, "log.bytes") != NULL) {
		rp_rowf(r, "Console read", -1, "%ld KiB, %s lines, %ld KiB lost before the first read, %s log thread passes",
		    rp_kvn(r, "log.bytes", 0) / 1024, rp_kv(r, "log.lines"), rp_kvn(r, "log.lost", 0) / 1024, rp_kv(r, "log.thread_scans"));
	} else {
		rp_row(r, "Console read", NULL, -1);
	}
}
