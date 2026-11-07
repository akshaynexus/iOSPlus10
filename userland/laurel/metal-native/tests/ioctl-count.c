/* Mi A3 iOS 26, host: counts the DRM msm ioctls of a process (LD_PRELOAD, before Mesa's drm-shim), with the callers of GEM_NEW and GEM_CLOSE
 * and the named-buffer count of each GEM_SUBMIT. Summary on stderr at exit. Tool of scripts/laurel/ios26-encode-bench.sh (IOCTL_COUNT=1).
 *   clang -O1 -shared -fPIC -o ioctl-count.so ioctl-count.c -ldl
 *   LD_PRELOAD=ioctl-count.so:libfreedreno_noop_drm_shim.so COMMAND */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>

#define DRM_COMMAND_BASE 0x40
#define DRM_MSM_GEM_NEW 0x02
#define DRM_MSM_GEM_SUBMIT 0x06
#define DRM_GEM_CLOSE 0x09
#define DRM_MSM_GET_PARAM 0x00
#define MSM_PARAM_LAUREL_RESIDENT 0x7c
#define STACKS 24
#define DEPTH 10

static int (*real_ioctl)(int, unsigned long, ...);
static unsigned long counts[256];
static unsigned long submits, submit_bos, submit_bos_max, gem_new_bytes;
struct stack { void *pcs[DEPTH]; int n; unsigned long hits; unsigned long bytes; };
static struct stack news[STACKS], closes[STACKS];
static int nnews, ncloses;

struct drm_msm_gem_new { uint64_t size; uint32_t flags; uint32_t handle; };
struct drm_msm_gem_submit { uint32_t flags; uint32_t fence; uint32_t nr_bos; uint32_t nr_cmds; uint64_t bos; uint64_t cmds; };
struct drm_msm_param { uint32_t pipe; uint32_t param; uint64_t value; uint32_t len; uint32_t pad; };
static unsigned long resident_submits;

static void note(struct stack *list, int *n, unsigned long bytes)
{
	void *pcs[DEPTH + 2];
	int depth = backtrace(pcs, DEPTH + 2) - 2;
	if (depth < 1)
		return;
	for (int i = 0; i < *n; i++) {
		if (list[i].n == depth && memcmp(list[i].pcs, pcs + 2, depth * sizeof(void *)) == 0) {
			list[i].hits++;
			list[i].bytes += bytes;
			return;
		}
	}
	if (*n == STACKS)
		return;
	memcpy(list[*n].pcs, pcs + 2, depth * sizeof(void *));
	list[*n].n = depth;
	list[*n].hits = 1;
	list[*n].bytes = bytes;
	(*n)++;
}

static void show(const char *what, struct stack *list, int n)
{
	for (int i = 0; i < n; i++) {
		fprintf(stderr, "ioctl-count: %s x%lu (%lu KB):\n", what, list[i].hits, list[i].bytes >> 10);
		char **syms = backtrace_symbols(list[i].pcs, list[i].n);
		for (int j = 0; j < list[i].n && syms != NULL; j++)
			fprintf(stderr, "    %s\n", syms[j]);
		free(syms);
	}
}

static void summary(void)
{
	fprintf(stderr, "ioctl-count: GEM_NEW %lu (%lu KB), GEM_CLOSE %lu, GEM_SUBMIT %lu (named buffers: %lu a submit, most %lu; %lu flagged resident); by nr:", counts[DRM_COMMAND_BASE + DRM_MSM_GEM_NEW], gem_new_bytes >> 10, counts[DRM_GEM_CLOSE], submits, submits ? submit_bos / submits : 0, submit_bos_max, resident_submits);
	for (int i = 0; i < 256; i++)
		if (counts[i])
			fprintf(stderr, " 0x%02x=%lu", i, counts[i]);
	fprintf(stderr, "\n");
	show("GEM_NEW", news, nnews);
	show("GEM_CLOSE", closes, ncloses);
}

int ioctl(int fd, unsigned long request, ...)
{
	va_list ap;
	va_start(ap, request);
	void *arg = va_arg(ap, void *);
	va_end(ap);
	if (real_ioctl == NULL) {
		real_ioctl = dlsym(RTLD_NEXT, "ioctl");
		atexit(summary);
	}
	unsigned nr = _IOC_NR(request);
	if (_IOC_TYPE(request) == 'd' && nr < 256) {
		counts[nr]++;
		if (nr == DRM_COMMAND_BASE + DRM_MSM_GEM_NEW) {
			gem_new_bytes += ((struct drm_msm_gem_new *)arg)->size;
			note(news, &nnews, ((struct drm_msm_gem_new *)arg)->size);
		} else if (nr == DRM_GEM_CLOSE) {
			note(closes, &ncloses, 0);
		} else if (nr == DRM_COMMAND_BASE + DRM_MSM_GET_PARAM && ((struct drm_msm_param *)arg)->param == MSM_PARAM_LAUREL_RESIDENT) {
			/* IOCTL_COUNT_RESIDENT=1: the host stands in for RedwoodGPU laurel 3060: the resident set is there (Turnip patch 0110's on path) */
			if (getenv("IOCTL_COUNT_RESIDENT") != NULL && getenv("IOCTL_COUNT_RESIDENT")[0] == '1') {
				((struct drm_msm_param *)arg)->value = 1;
				return 0;
			}
		} else if (nr == DRM_COMMAND_BASE + DRM_MSM_GEM_SUBMIT) {
			uint32_t bos = ((struct drm_msm_gem_submit *)arg)->nr_bos;
			resident_submits += (((struct drm_msm_gem_submit *)arg)->flags & 0x01000000) != 0;
			submits++;
			submit_bos += bos;
			if (bos > submit_bos_max)
				submit_bos_max = bos;
		}
	}
	return real_ioctl(fd, request, arg);
}
