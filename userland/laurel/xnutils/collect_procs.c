/* Every process once: the top lists and the name list of the report (collect_ios.c has the frame). */
#include <mach/mach_time.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "collect.h"

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

#define MAX_PROCS       768
#define TOP_N           6

static struct { struct { int pid; uint64_t abs; } proc[MAX_PROCS]; int nproc; } prev;

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
void
xt_collect_procs(void)
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

