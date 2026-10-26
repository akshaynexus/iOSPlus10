/*
 * ngl_test: negronigl from a shell on the phone (the gl_test of slop/HackiOS, over our library).
 *   ngl_test            GPU info, FBO triangle self test, IOSurface self test
 *   ngl_test -w SECS    wait up to SECS for RedwoodGPU first
 *   ngl_test --layer [WxH]  also a CAEAGLLayer drawable through the EAGLContext methods (the shim is
 *                       installed in this process): renderbufferStorage:fromDrawable:, clear, read back
 *                       by GL and from the drawable IOSurface, presentRenderbuffer: twice. Default 256x256.
 * Output on stdout (NEGRONIGL_LOG=stderr is set unless the environment has NEGRONIGL_LOG).
 * Without RedwoodGPU the library uses softpipe (CPU); NEGRONIGL_DRIVER=softpipe forces it.
 * Exit 0: all tests passed, 1: a test failed, 2: no screen at all, 3: --layer got no drawable surface
 * (the layer had no size: no CoreAnimation context in this process), the other tests passed.
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
bool ngl_soft(void);
const char *ngl_version(void);
int ngl_layer_selftest(int w, int h);

int
main(int argc, char **argv)
{
	int wait = 0, layer = 0, lw = 256, lh = 256;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-w") == 0 && i + 1 < argc) {
			wait = atoi(argv[++i]);
		} else if (strcmp(argv[i], "--layer") == 0) {
			layer = 1;
			if (i + 1 < argc && sscanf(argv[i + 1], "%dx%d", &lw, &lh) == 2) {
				i++;
			}
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
		printf("no gallium screen: neither freedreno nor softpipe\n");
		return 2;
	}
	if (ngl_soft()) {
		printf("driver: softpipe (CPU; RedwoodGPU not opened or NEGRONIGL_DRIVER=softpipe)\n");
	} else {
	struct ngl_gpu_info gi = {0};
	ngl_gpu_info(&gi);
	printf("RedwoodGPU: ABI %s, chip %#llx, GMEM %llu KiB, max %llu MHz\n",
	    gi.abi == 1 ? "scalar" : gi.abi == 2 ? "msm" : "?", (unsigned long long)gi.chip_id,
	    (unsigned long long)gi.gmem_size >> 10, (unsigned long long)gi.max_freq / 1000000);
	}
	bool a = ngl_selftest();
	bool b = ngl_surface_selftest();
	printf("selftest %s, surface selftest %s\n", a ? "PASS" : "FAIL", b ? "PASS" : "FAIL");
	if (!layer) {
		return a && b ? 0 : 1;
	}
	int l = ngl_layer_selftest(lw, lh);
	printf("layer selftest %dx%d %s\n", lw, lh, l > 0 ? "PASS" : l < 0 ? "NO DRAWABLE" : "FAIL");
	if (!(a && b) || l == 0) {
		return 1;
	}
	return l < 0 ? 3 : 0;
}
