/*
 * Host test: does the plug-in's frame path keep memory? The real userland/camera/camera_device.c + camera_isp.c, over the mock of cam5_mock.c and a mock
 * /dev/negronicam. scripts/laurel/cam-leak-test.sh runs it plain (heap bytes per frame) and under AddressSanitizer (leaks, a use after free of a handler).
 * Phases: frames with no graph (as mediaserverd pid 28's first session), pictures with a graph that keeps 4 buffers, photographs, tap, stop, device released.
 * -DOLD_SOURCE: the sources of the build that ran at 18:40 (no MODE, no focus). No Apple code runs here: CMCapture's own memory is not tested.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <malloc.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "negronicam.h"
#include "cam5_mock.h"

static int mock_open(const char *p, int f, ...);
static ssize_t mock_read(int fd, void *b, size_t n);
static ssize_t mock_write(int fd, const void *b, size_t n);
static void *mock_dlsym(const char *n);
#define open(...) mock_open(__VA_ARGS__)
#define read(a, b, c) mock_read(a, b, c)
#define write(a, b, c) mock_write(a, b, c)
#define close(a) ((void)(a))
#define access(a, b) 0
#define dlsym(h, n) mock_dlsym(n)
#define pthread_setname_np(n) ((void)0)
#include "camera_device.c"
#undef open
#undef read
#undef write
#undef close
#undef access
#undef dlsym

int sysctlbyname(const char *n, void *o, size_t *os, void *i, size_t is) { return -1; }
void negronicam_memory_line(uint64_t f) { (void)f; }

/* ---- the kernel ---- */
#define PW 1920u
#define PH 1440u
#define SW 4000u
#define SH 3000u
static struct {
	uint64_t seq;
	uint32_t lines, gain, frame, focus;
	int mode;
	long switches;
	uint8_t *raw[2];
	int amplitude;
	volatile bool dark;     /* laurel: no light: noise cut at black, as boot 20:15 */
	bool painted_dark;
} k = { .lines = 1000, .gain = 256, .frame = 2604, .focus = 381 };
#define BEST_FOCUS 600

static void
put_px(uint8_t *raw, uint32_t stride, uint32_t x, uint32_t y, uint32_t v)
{
	uint8_t *g = raw + (size_t)y * stride + (x / 4) * 5;

	g[x & 3] = (uint8_t)(v >> 2);
	g[4] = (uint8_t)((g[4] & ~(3u << (2 * (x & 3)))) | (v & 3) << (2 * (x & 3)));
}

/* checks of 32 cells that lose contrast as the lens leaves BEST_FOCUS */
static void
paint(int mode)
{
	uint32_t w = mode ? SW : PW, h = mode ? SH : PH, stride = w / 4 * 5;
	int d = abs((int)k.focus - BEST_FOCUS), a = d > 400 ? 0 : 400 - d;

	if (k.dark) {
		if (k.painted_dark) {
			return;
		}
		k.painted_dark = true;
		for (uint32_t y = 0; y < h; y++) {
			for (uint32_t x = 0; x < w; x++) {
				put_px(k.raw[mode], stride, x, y, 64 + (uint32_t)(rand() % 4) - 1);     /* (63..66: mean under 1 above black) */
			}
		}
		return;
	}
	if (k.painted_dark) {
		k.painted_dark = false;
		k.amplitude = -1;
	}
	if (k.amplitude == a && mode == 0) {
		return;
	}
	k.amplitude = mode ? k.amplitude : a;
	for (uint32_t y = 0; y < h; y++) {
		for (uint32_t x = 0; x < w; x++) {
			put_px(k.raw[mode], stride, x, y, 64 + 100 + (uint32_t)(((x >> 6) ^ (y >> 6)) & 1 ? a / 2 : 0));
		}
	}
}

static ssize_t
mock_read(int fd, void *b, size_t n)
{
	struct negronicam_frame h;
	int mode = k.mode;
	uint32_t w = mode ? SW : PW, ht = mode ? SH : PH, stride = w / 4 * 5;

	memset(&h, 0, sizeof(h));
	memcpy(h.magic, NEGRONICAM_MAGIC, 8);
	h.header_bytes = sizeof(h);
	h.width = w;
	h.height = ht;
	h.stride = stride;
	h.format = 1;
	h.black = 64;
	h.sequence = ++k.seq;
	h.time = k.seq * 33000000;
	h.exposure_lines = k.lines;
	h.line_ns = 12800;
	h.gain = k.gain;
	h.gain_unity = 256;
	h.gain_max = 4096;
	h.frame_lines = k.frame;
	h.frame_lines_min = 2604;
	h.frame_lines_max = 2604 * 4;
	h.margin = 48;
	h.sensor = 1;
#ifdef OLD_SOURCE
	h.focus = NEGRONICAM_NO_FOCUS;
#else
	h.focus = k.focus;
	h.focus_min = 48;
	h.focus_max = 960;
	h.mode = (uint32_t)mode;
	h.sensor_w = mode ? 8000 : 7680;
	h.sensor_h = mode ? 6000 : 5760;
#endif
	if (n < sizeof(h)) {
		errno = EINVAL;
		return -1;
	}
	memcpy(b, &h, sizeof(h));
	if (n == sizeof(h)) {
		return (ssize_t)n;
	}
	paint(mode);
	memcpy((uint8_t *)b + sizeof(h), k.raw[mode], (size_t)stride * ht);
	return (ssize_t)(sizeof(h) + (size_t)stride * ht);
}

static int mock_open(const char *p, int f, ...) { return strcmp(p, NEGRONICAM_DEVICE) == 0 ? 100 : -1; }

static ssize_t
mock_write(int fd, const void *b, size_t n)
{
	if (fd == 100) {
		const struct negronicam_command *c = b;

		if (c->command == NEGRONICAM_EXPOSURE) {
			k.lines = c->a;
			k.gain = c->b;
			k.frame = c->c;
		} else if (c->command == NEGRONICAM_FOCUS) {
			k.focus = c->a;
		}
#ifndef OLD_SOURCE
		else if (c->command == NEGRONICAM_MODE) {
			k.switches += k.mode != (int)c->a;
			k.mode = (int)c->a;
		}
#endif
	}
	return (ssize_t)n;
}

/* ---- CMCapture's part, in shape ---- */
OSStatus
mock_derived_create(CFAllocatorRef a, const struct vtable *vt, CMBaseClassID c, CMBaseObjectRef *o)
{
	*o = (CMBaseObjectRef)mock_derived_make((void *)vt, vt->base->storage_size);
	return 0;
}
void mock_derived_finalize(struct mock_obj *o) { ((const struct vtable *)mock_derived_vt(o))->base->finalize((CMBaseObjectRef)o); }
static void *storage_of(CMBaseObjectRef o) { return mock_derived_storage((struct mock_obj *)o); }
static CMBaseClassID class_id(void) { return NULL; }

static void *
mock_dlsym(const char *n)
{
	static CFStringRef slots[64];
	static int used;

	if (strcmp(n, "CMDerivedObjectCreate") == 0) { return (void *)mock_derived_create; }
	if (strcmp(n, "CMBaseObjectGetDerivedStorage") == 0) { return (void *)storage_of; }
	if (strstr(n, "GetClassID") != NULL) { return (void *)class_id; }
	slots[used] = mock_cfstr(n);
	return &slots[used++];
}

static CVPixelBufferRef kept[4];
static unsigned kept_at;
static long pictures, photos, photo_width, seen_status2, seen_status0_after, md_missing;

static void
graph_take(CVPixelBufferRef pb, bool still)
{
	CFTypeRef m = CVBufferGetAttachment(pb, md_attachment, NULL);

	md_missing += m == NULL;
	if (m != NULL) {
		CFTypeRef st_ = CFDictionaryGetValue(m, md_key[MD_AF_STATUS]);
		int64_t v = 0;

		CFNumberGetValue(st_, kCFNumberSInt64Type, &v);
		seen_status2 += v == 2;
		seen_status0_after += v == 0 && seen_status2 > 0;
	}
	if (still) {
		photos++;
		photo_width = (long)CVPixelBufferGetWidth(pb);
		return;
	}
	pictures++;
	if (kept[kept_at] != NULL) {
		CVPixelBufferRelease(kept[kept_at]);
	}
	kept[kept_at] = mock_pb_retain(pb);
	kept_at = (kept_at + 1) % 4;
}

static size_t heap(void) { struct mallinfo2 m = mallinfo2(); return m.uordblks + m.hblkhd; }
static void until_seq(uint64_t s) { while (k.seq < s) { usleep(2000); } }
#define CHECK(c, ...) do { if (!(c)) { failed++; printf("FAILED line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)
static unsigned failed;
#include "cam5_dark.h"
#include "cam5_run.h"
