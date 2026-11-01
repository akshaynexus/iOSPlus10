/*
 * laurel 0005: the texture -> image hash of eagl.c, as it is in the patched file (scripts/laurel/gpu-surface-test.sh cuts image_of, image_new and
 * image_forget out of it into image_hash_cut.h): random new, replace and forget against a plain list. A wrong link here would crash the window server.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned GLuint;
typedef void *IOSurfaceRef;
struct image {
	GLuint texture;
	IOSurfaceRef surface;
	GLuint mirror, xr_source, xr_source2;
	bool sub_ok;
	uint8_t told;
	uint16_t next;
};
struct eagl {
	struct image images[512];
	unsigned image_count;
	uint16_t image_bucket[1024];
	unsigned contents_wanted;
};
static void glDeleteTextures(int n, GLuint *t) { (void)n; *t = 0; }
static IOSurfaceRef CFRetain(IOSurfaceRef s) { return s; }
static void CFRelease(IOSurfaceRef s) { (void)s; }
#define say(...) ((void)0)
#include "image_hash_cut.h"

int
main(void)
{
	static struct eagl e;
	static unsigned char have[3000];
	unsigned count = 0, seed = 12345, bad = 0;

	for (unsigned step = 0; step < 2000000; step++) {
		seed = seed * 1103515245u + 12345u;
		GLuint t = 1 + (seed >> 8) % 2999;
		if ((seed >> 4) & 1) {
			if (have[t] || count < 500) {
				struct image *i = image_new(&e, t, (void *)1);
				if (i == NULL || i->texture != t) {
					bad++;
				}
				count += !have[t];
				have[t] = 1;
			}
		} else {
			image_forget(&e, t);
			count -= have[t];
			have[t] = 0;
		}
		if ((step & 1023) == 0) {
			for (GLuint k = 1; k < 3000; k++) {
				struct image *i = image_of(&e, k);
				if ((i != NULL) != (have[k] != 0) || (i != NULL && i->texture != k)) {
					bad++;
				}
			}
			if (e.image_count != count) {
				bad++;
			}
		}
	}
	printf("%s image hash: %u images at the end, %u wrong answers\n", bad == 0 ? "ok  " : "FAIL", count, bad);
	return bad != 0;
}
