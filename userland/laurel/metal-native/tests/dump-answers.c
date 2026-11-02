/* Host tool: every device query the default stack's bridge answers on FD610 through Turnip + drm-shim, as a table for the native stack: bridge/src/answers.tsv. Same answers on both stacks, so a framework takes the same path. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stddef.h>
struct NmbTextureDescriptor;
#include "NativeMetalObjects.h"
void sys_dcache_flush(void *start, size_t length) { (void)start; (void)length; }
int main(int argc, char **argv)
{
	NmbDevice *d = nmb_device_open(argv[1], argv[2]);
	if (d == NULL) {
		fprintf(stderr, "device: %s\n", nmb_last_error());
		return 1;
	}
	static const uint64_t args[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 16, 25, 55, 70, 80, 81, 115, 125, 252, 253, 260, 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010, 2001, 2002, 3001, 3002, 3003, 4001, 4002, 5001, 5002};
	for (size_t i = 0;; i++) {
		uint32_t kind;
		const char *s = nmb_device_answer_selector(i, &kind);
		if (s == NULL)
			break;
		if (kind == NMB_ANSWER_COUNT || kind == NMB_ANSWER_FLAG) {
			uint64_t v = 0;
			if (nmb_device_answer(d, s, 0, &v))
				printf("%s\t%u\t-\t%llu\n", s, kind, (unsigned long long)v);
			else
				printf("%s\t%u\t-\tnone\n", s, kind);
		} else {
			for (size_t a = 0; a < sizeof(args) / sizeof(args[0]); a++) {
				uint64_t v = 0;
				if (nmb_device_answer(d, s, args[a], &v))
					printf("%s\t%u\t%llu\t%llu\n", s, kind, (unsigned long long)args[a], (unsigned long long)v);
			}
		}
	}
	char name[128] = "", waivers[8192] = "";
	nmb_device_name(d, name, sizeof(name));
	nmb_device_family_waivers(d, waivers, sizeof(waivers));
	uint64_t t[3] = {0, 0, 0};
	nmb_device_max_threads_per_threadgroup(d, t);
	fprintf(stderr, "name %s, max buffer %llu, threads %llu %llu %llu\n", name, (unsigned long long)nmb_device_max_buffer_length(d), (unsigned long long)t[0], (unsigned long long)t[1], (unsigned long long)t[2]);
	fprintf(stderr, "waivers: %s\n", waivers);
	return 0;
}
