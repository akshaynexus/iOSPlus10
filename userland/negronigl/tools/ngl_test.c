/*
 * ngl_test: negronigl from a shell on the phone (the gl_test of slop/HackiOS, over our library).
 *   ngl_test            GPU info, FBO triangle self test, IOSurface self test
 *   ngl_test -w SECS    wait up to SECS for RedwoodGPU first
 * Output on stdout (NEGRONIGL_LOG=stderr is set unless the environment has NEGRONIGL_LOG).
 * Exit 0: all tests passed, 1: a test failed, 2: no GPU.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct ngl_gpu_info {
	int abi;
	uint64_t chip_id, gmem_size, gmem_base, max_freq;
};
bool ngl_init(void);
bool ngl_selftest(void);
bool ngl_surface_selftest(void);
bool ngl_gpu_info(struct ngl_gpu_info *info);
const char *ngl_version(void);

int
main(int argc, char **argv)
{
	int wait = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-w") == 0 && i + 1 < argc) {
			wait = atoi(argv[++i]);
		}
	}
	setenv("NEGRONIGL_LOG", "stderr", 0);
	printf("%s\n", ngl_version());
	bool up = ngl_init();
	for (int s = 0; !up && s < wait; s++) {
		sleep(1);
		up = ngl_init();
	}
	if (!up) {
		printf("no GPU: RedwoodGPU service missing or not answering\n");
		return 2;
	}
	struct ngl_gpu_info gi = {0};
	ngl_gpu_info(&gi);
	printf("RedwoodGPU: ABI %s, chip %#llx, GMEM %llu KiB, max %llu MHz\n",
	    gi.abi == 1 ? "scalar" : gi.abi == 2 ? "msm" : "?", (unsigned long long)gi.chip_id,
	    (unsigned long long)gi.gmem_size >> 10, (unsigned long long)gi.max_freq / 1000000);
	bool a = ngl_selftest();
	bool b = ngl_surface_selftest();
	printf("selftest %s, surface selftest %s\n", a ? "PASS" : "FAIL", b ? "PASS" : "FAIL");
	return a && b ? 0 : 1;
}
