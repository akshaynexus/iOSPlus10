/*
 * laurel-memhog: a memory load for the swap test of docs/laurel_sprout/memory.md (scripts/laurel/mem-load.sh).
 * Takes N MiB of anonymous memory in 16 MiB steps, writes every page (so nothing stays zero-filled and shared), holds it for S
 * seconds and prints one line per 256 MiB and one at the end. Root sets its own jetsam limit to the whole RAM first
 * (MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT), so the per-process limit does not end the test before the compressor fills.
 *   laurel-memhog MIB [SECONDS=60] [FILL=0x5a]       FILL=0: zero pages (they compress to nothing); the default 0x5a + the page index: real data
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>

extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT 6

int
main(int argc, char **argv)
{
	unsigned long mib = argc > 1 ? strtoul(argv[1], NULL, 0) : 1024;
	unsigned long hold = argc > 2 ? strtoul(argv[2], NULL, 0) : 60;
	unsigned long fill = argc > 3 ? strtoul(argv[3], NULL, 0) : 0x5a;
	uint64_t memsize = 0; size_t len = sizeof(memsize);
	sysctlbyname("hw.memsize", &memsize, &len, NULL, 0);
	int r = memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), (uint32_t)(memsize >> 20), NULL, 0);
	printf("memhog: pid %d, limit set to %llu MiB: %s; taking %lu MiB, hold %lu s, fill 0x%lx\n", getpid(), (unsigned long long)(memsize >> 20), r == 0 ? "ok" : "refused", mib, hold, fill);
	fflush(stdout);
	const size_t step = 16u << 20;
	size_t taken = 0, page = (size_t)getpagesize();
	while (taken < mib << 20) {
		char *p = malloc(step);
		if (p == NULL) { printf("memhog: malloc failed at %zu MiB\n", taken >> 20); break; }
		for (size_t i = 0; i < step; i += page) {
			if (fill) { memset(p + i, (int)(fill + (i >> 12)), page); } else { memset(p + i, 0, page); }
		}
		taken += step;
		if ((taken & ((256u << 20) - 1)) == 0) { printf("memhog: %zu MiB taken\n", taken >> 20); fflush(stdout); }
	}
	printf("memhog: %zu MiB taken, holding %lu s\n", taken >> 20, hold);
	fflush(stdout);
	sleep((unsigned)hold);
	printf("memhog: done\n");
	return 0;
}
