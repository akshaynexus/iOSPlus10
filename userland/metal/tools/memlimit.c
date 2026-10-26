/* memlimit: the jetsam memory limit and the physical footprint of processes (iOS, run as root).
 *   memlimit [PID|NAME]...     no argument: every process
 * Columns: pid, footprint MiB, active limit MiB (0 = none), inactive limit MiB, flags, name.
 * Own task: task_vm_info.limit_bytes_remaining (what NegroniMetal reads without privilege) is printed too.
 * Built and run by scripts/metal/memlimit.sh (scripts/net/phone-run.sh -s). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
/* libproc (no header in the iOS SDK) */
#define PROC_ALL_PIDS 1
#define PROC_PIDPATHINFO_MAXSIZE 4096
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);
#include <mach/mach.h>

#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES 8
typedef struct memorystatus_memlimit_properties {
	int32_t memlimit_active;
	uint32_t memlimit_active_attr;
	int32_t memlimit_inactive;
	uint32_t memlimit_inactive_attr;
} memorystatus_memlimit_properties_t;
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);

static void one(pid_t pid, const char *filter)
{
	char name[PROC_PIDPATHINFO_MAXSIZE] = "";
	proc_pidpath(pid, name, sizeof(name));
	const char *base = strrchr(name, '/');
	base = base ? base + 1 : name;
	if (filter && strcmp(filter, base) != 0)
		return;
	memorystatus_memlimit_properties_t p;
	memset(&p, 0, sizeof(p));
	int r = memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES, pid, 0, &p, sizeof(p));
	struct rusage_info_v4 ru;
	memset(&ru, 0, sizeof(ru));
	proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ru);
	if (r == 0)
		printf("%6d %7.1f %6d %6d 0x%x/0x%x %s\n", pid, ru.ri_phys_footprint / 1048576.0, p.memlimit_active,
		       p.memlimit_inactive, p.memlimit_active_attr, p.memlimit_inactive_attr, base);
	else
		printf("%6d %7.1f      ?      ? (errno %d) %s\n", pid, ru.ri_phys_footprint / 1048576.0, errno, base);
}

int main(int argc, char **argv)
{
	task_vm_info_data_t vm;
	mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &n) == KERN_SUCCESS)
		printf("self: phys_footprint %.1f MiB limit_bytes_remaining %.1f MiB (count %u)\n", vm.phys_footprint / 1048576.0,
		       (double)vm.limit_bytes_remaining / 1048576.0, n);
	printf("%6s %7s %6s %6s %s %s\n", "pid", "fpMiB", "actMB", "inaMB", "attrs", "name");
	int npids = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / (int)sizeof(pid_t) + 64;
	pid_t *pids = calloc(npids, sizeof(pid_t));
	npids = proc_listpids(PROC_ALL_PIDS, 0, pids, npids * (int)sizeof(pid_t)) / (int)sizeof(pid_t);
	if (argc < 2) {
		for (int i = 0; i < npids; i++)
			if (pids[i] > 0)
				one(pids[i], NULL);
		return 0;
	}
	for (int a = 1; a < argc; a++) {
		char *end;
		long pid = strtol(argv[a], &end, 10);
		if (*end == 0 && pid > 0)
			one((pid_t)pid, NULL);
		else
			for (int i = 0; i < npids; i++)
				if (pids[i] > 0)
					one(pids[i], argv[a]);
	}
	return 0;
}
