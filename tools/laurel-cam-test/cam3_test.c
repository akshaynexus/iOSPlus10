/*
 * Host test of camera step 3 + 4 (laurel 2772 laurel_cam_dev.h, userland/camera/camera_isp.c): a mock NCFRAME1 client.
 * "Kernel" side = the pure code of the patch (header, ring, limits, gain code); client side = the loop of camera_device.c
 * worker(): header read, magic + size checks, full read, measure, white balance, exposure command, picture.
 * cc -I<headers> -Iuserland/camera tools/laurel-cam-test/cam3_test.c userland/camera/camera_isp.c -lm; run without arguments.
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include "negronicam.h"
#include "camera_isp.h"
#include "laurel_cam_dev.h"

static unsigned fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* the same layout as the client's header */
#define SAME(f) _Static_assert(offsetof(struct lcam_nc_frame, f) == offsetof(struct negronicam_frame, f), #f)
SAME(magic); SAME(header_bytes); SAME(width); SAME(height); SAME(stride); SAME(format); SAME(bayer); SAME(black); SAME(sequence);
SAME(time); SAME(exposure_lines); SAME(line_ns); SAME(gain); SAME(gain_unity); SAME(gain_max); SAME(frame_lines);
SAME(frame_lines_min); SAME(frame_lines_max); SAME(margin); SAME(sensor); SAME(focus); SAME(mode); SAME(focus_min); SAME(focus_max); SAME(sensor_w); SAME(sensor_h);
_Static_assert(sizeof(struct lcam_nc_frame) == sizeof(struct negronicam_frame), "header");
_Static_assert(sizeof(struct lcam_nc_command) == sizeof(struct negronicam_command), "command");
_Static_assert((int)LCAM_NC_EXPOSURE == (int)NEGRONICAM_EXPOSURE && (int)LCAM_NC_SENSOR == (int)NEGRONICAM_SENSOR &&
    (int)LCAM_NC_KEEP == (int)NEGRONICAM_KEEP && (int)LCAM_NC_FOCUS == (int)NEGRONICAM_FOCUS, "commands");
_Static_assert(LCAM_NC_NO_FOCUS == NEGRONICAM_NO_FOCUS, "no focus");

#define W 1280u
#define H 720u
#define STRIDE 1600u
#define BYTES (STRIDE * H)

/* ---- the mock device: scene = RGB in 16:9 parts, its level follows exposure x gain (AE closes on it) ---------- */

static struct {
	uint8_t buf[LCAM_NC_NBUF][BYTES];
	struct lcam_nc_ring ring;
	struct lcam_nc_limits lim;
	uint32_t line_ns, lines, gain, frame, bayer_filter;
	uint64_t given, time;
	double scene;                   /* level at 1 line x 1x gain, 10-bit steps above black */
} dev;

static void
put_px(uint8_t *b, uint32_t x, uint32_t y, uint32_t v)
{
	uint8_t *g = b + (size_t)y * STRIDE + (x / 4) * 5;
	unsigned s = 2 * (x & 3);

	g[x & 3] = (uint8_t)(v >> 2);
	g[4] = (uint8_t)((g[4] & ~(3u << s)) | (v & 3u) << s);
}

/* a scene with a colour per column band: R, G, B, grey (each cell's parts by the Bayer order of the filter) */
static void
mock_frame(uint8_t *b)
{
	static const float band[4][3] = { { 1, 0.1f, 0.1f }, { 0.1f, 1, 0.1f }, { 0.1f, 0.1f, 1 }, { 0.6f, 0.6f, 0.6f } };
	double level = dev.scene * dev.lines * dev.gain / LCAM_NC_GAIN_UNITY;
	/* per cell site, which colour (0 R, 1 G, 2 B): mm-camera filter 3 = RGGB */
	static const uint8_t cfa[4][4] = { { 2, 1, 1, 0 }, { 1, 2, 0, 1 }, { 1, 0, 2, 1 }, { 0, 1, 1, 2 } };

	memset(b, 0, BYTES);
	for (uint32_t y = 0; y < H; y++) {
		for (uint32_t x = 0; x < W; x++) {
			const float *c = band[x * 4 / W];
			double v = level * c[cfa[dev.bayer_filter][(y & 1) * 2 + (x & 1)]] + LCAM_NC_BLACK;

			put_px(b, x, y, v > 1023 ? 1023u : (uint32_t)v);
		}
	}
}

/* what the session thread does when write master `slot` finished a frame */
static void
mock_vfe_done(uint32_t slot)
{
	uint32_t refill;

	lcam_nc_ring_done(&dev.ring, slot, &refill);
	dev.time += 33;
	mock_frame(dev.buf[dev.ring.latest]);
}

/* read(2): header only for a header-size buffer, else header + frame */
static ssize_t
mock_read(void *out, size_t size)
{
	struct lcam_nc_frame h;

	if (dev.ring.frames <= dev.given) {
		return -1;              /* EAGAIN */
	}
	lcam_nc_header(&h, W, H, STRIDE, dev.bayer_filter, &dev.lim, dev.line_ns);
	h.sequence = dev.ring.frames;
	h.time = dev.time;
	h.exposure_lines = dev.lines;
	h.gain = dev.gain;
	h.frame_lines = dev.frame;
	dev.given = dev.ring.frames;
	memcpy(out, &h, size < sizeof(h) ? size : sizeof(h));
	if (size > sizeof(h)) {
		size_t n = size - sizeof(h) < BYTES ? size - sizeof(h) : BYTES;

		dev.ring.reading = (int)dev.ring.latest;
		memcpy((uint8_t *)out + sizeof(h), dev.buf[dev.ring.latest], n);
		dev.ring.reading = -1;
		return (ssize_t)(sizeof(h) + n);
	}
	return (ssize_t)sizeof(h);
}

/* write(2) + the session thread's handling of it */
static void
mock_write(const struct negronicam_command *c)
{
	uint32_t l = c->a, g = c->b, f = c->c;

	CHECK(c->command == NEGRONICAM_EXPOSURE, "command %u", c->command);
	lcam_nc_clamp(&dev.lim, &l, &g, &f);
	dev.lines = l;
	dev.gain = g;
	dev.frame = f;
}

/* ---- pure code checks ------------------------------------------------------------------------------------------- */

static void
test_pure(void)
{
	/* mode 6 of the stock library [V camera-tables.py]: line 5376, frame 780, vt 392 MHz */
	uint32_t ns = lcam_nc_line_ns(5376, 392000000), f = lcam_nc_frame_lines(780, ns, 30);
	struct lcam_nc_limits l = { f, f * 4, 48 };
	uint32_t a, b, c, r;
	struct lcam_nc_ring ring;

	CHECK(ns == 13714, "line %u ns", ns);
	CHECK(f == 2431, "frame lines %u for 30 fps", f);
	CHECK(lcam_nc_frame_lines(780, ns, 120) == 780, "never under the mode's frame");
	CHECK(lcam_nc_bayer(3) == 0 && lcam_nc_bayer(2) == 1 && lcam_nc_bayer(1) == 2 && lcam_nc_bayer(0) == 3, "bayer map");
	CHECK(lcam_nc_gain_code(256) == 0 && lcam_nc_gain_code(512) == 512 && lcam_nc_gain_code(4096) == 960, "gain code");
	CHECK(lcam_nc_gain_code(100) == 0 && lcam_nc_gain_code(99999) == 960, "gain code limits");
	a = 100; b = 512; c = 0;
	lcam_nc_clamp(&l, &a, &b, &c);
	CHECK(a == 100 && b == 512 && c == f, "short exposure: shortest frame (%u %u %u)", a, b, c);
	a = 5000; b = 9999; c = 0;
	lcam_nc_clamp(&l, &a, &b, &c);
	CHECK(a == 5000 && b == 4096 && c == 5048, "long exposure: longer frame, gain limit (%u %u %u)", a, b, c);
	a = 99999; b = 1; c = 99999;
	lcam_nc_clamp(&l, &a, &b, &c);
	CHECK(c == f * 4 && a == f * 4 - 48 && b == 256, "limits (%u %u %u)", a, b, c);
	a = 0; b = 256; c = 100;
	lcam_nc_clamp(&l, &a, &b, &c);
	CHECK(a == 4 && c == f, "at least 4 lines, frame not under the shortest (%u %u)", a, c);

	/* the ring (laurel 2773): 4 distinct buffers, always; a buffer being read never goes back into the VFE; no frame lost to a read */
	lcam_nc_ring_init(&ring);
	for (uint32_t i = 0; i < 1000; i++) {
		uint32_t slot = i & 1;
		bool busy = i % 7 == 3;

		ring.reading = busy ? (int)ring.latest : -1;
		uint32_t in = ring.cur[slot], reading = ring.latest;

		lcam_nc_ring_done(&ring, slot, &r);
		CHECK(ring.cur[0] != ring.cur[1] && ring.cur[0] != ring.latest && ring.cur[1] != ring.latest && ring.spare != ring.latest &&
		    ring.spare != ring.cur[0] && ring.spare != ring.cur[1], "four buffers (%u)", i);
		CHECK(ring.latest == in, "the finished frame comes out (%u)", i);
		CHECK(r == ring.cur[slot] && (!busy || r != reading), "a read buffer stays out (%u)", i);
	}
	CHECK(ring.frames == 1000, "no frame lost: %llu", (unsigned long long)ring.frames);
}

/* ---- the client ----------------------------------------------------------------------------------------------- */

static void
test_client(uint32_t filter, const char *name)
{
	struct negronicam_frame head;
	static uint8_t frame[sizeof(struct negronicam_frame) + BYTES];
	struct isp isp;
	struct isp_stats st;
	static uint8_t y[1128 * 1504], uv[1128 * 1504 / 2], y2[1128 * 1504], uv2[1128 * 1504 / 2], cells[640 * 360 * 3];
	const uint32_t pw = 1504, ph = 1128;

	dev.bayer_filter = filter;
	dev.line_ns = lcam_nc_line_ns(5376, 392000000);
	dev.lim = (struct lcam_nc_limits){ lcam_nc_frame_lines(780, dev.line_ns, LCAM_NC_FPS), 0, LCAM_NC_MARGIN };
	dev.lim.frame_max = dev.lim.frame_min * LCAM_NC_FRAME_MULT;
	dev.lines = 732;
	dev.gain = 4 * LCAM_NC_GAIN_UNITY;
	dev.frame = dev.lim.frame_min;
	dev.scene = 0.05;
	dev.given = 0;
	lcam_nc_ring_init(&dev.ring);
	isp_init(&isp);

	/* first the header, as worker() */
	mock_vfe_done(0);
	ssize_t n = mock_read(&head, sizeof(head));
	CHECK(n == (ssize_t)sizeof(head), "header read");
	CHECK(memcmp(head.magic, NEGRONICAM_MAGIC, 8) == 0 && head.header_bytes == sizeof(head) && head.format == 1, "magic");
	CHECK(head.width == W && head.height == H && head.stride == STRIDE && head.stride >= head.width * 5 / 4, "size");
	CHECK(head.sensor == 1 && head.focus == NEGRONICAM_NO_FOCUS && head.gain_unity == 256 && head.black == 64, "fields");
	CHECK(head.bayer == lcam_nc_bayer(filter), "bayer %u", head.bayer);
	CHECK(mock_read(&head, sizeof(head)) == -1, "no new frame: EAGAIN");

	/* the AE closes: green's mean towards 15 % of white */
	uint32_t writes = 0;
	const struct negronicam_frame *f = (const void *)frame;

	for (unsigned i = 1; i < 60; i++) {
		mock_vfe_done(i & 1);
		n = mock_read(frame, sizeof(frame));
		CHECK(n == (ssize_t)sizeof(frame), "frame read %zd", n);
		CHECK(f->sequence == dev.ring.frames, "sequence %llu", (unsigned long long)f->sequence);
		isp_measure(&isp, f, frame + f->header_bytes, &st);
		isp_awb(&isp, &st);
		struct negronicam_command c;
		if (isp_ae(&isp, f, &st, &c)) {
			mock_write(&c);
			writes++;
		}
	}
	double want = 0.15 * 959;
	CHECK(writes > 0 && st.mean[1] > want * 0.7 && st.mean[1] < want * 1.3, "%s: AE: green %.0f, want %.0f, %u writes, %u lines gain %u",
	    name, st.mean[1], want, writes, dev.lines, dev.gain);
	CHECK(dev.frame >= dev.lim.frame_min && dev.lines + LCAM_NC_MARGIN <= dev.frame, "exposure inside the frame");

	/*
	 * The preview: 4:3 picture from the middle of the 16:9 frame: cells 480x360; 8-bit path = float path (within 6 steps) away
	 * from the bands' edges (there the two differ on purpose: one mixes after the gamma, one before).
	 */
	uint32_t cw, ch;
	isp.zoom = 1;
	isp_cells_size(&isp, f, pw, ph, &cw, &ch);
	CHECK(cw == 480 && ch == 360, "cells %ux%u", cw, ch);
	isp_render_cells(&isp, f, frame + f->header_bytes, cells, cw, ch, 0, ch);
	isp_scale_nv12(cells, cw, ch, y, pw, uv, pw, pw, ph, 0, ph, false);
	isp_render_nv12(&isp, f, frame + f->header_bytes, y2, pw, uv2, pw, pw, ph, 0, ph, false);
	uint32_t worst = 0, xw = 0, yw = 0;
	for (uint32_t r = 8; r < ph - 8; r += 7) {
		for (uint32_t x = 8; x < pw - 8; x += 5) {
			uint32_t d = y[r * pw + x] > y2[r * pw + x] ? y[r * pw + x] - y2[r * pw + x] : y2[r * pw + x] - y[r * pw + x];
			uint32_t at = x > 251 ? (x > 752 ? (x > 1253 ? x - 1253 : (1253 - x < x - 752 ? 1253 - x : x - 752)) :
			    (752 - x < x - 251 ? 752 - x : x - 251)) : 251 - x;

			if (d > worst && at > 16) {
				worst = d;
				xw = x;
				yw = r;
			}
		}
	}
	CHECK(worst <= 6, "%s: 8-bit picture against the float one: Y differs by %u at %u,%u", name, worst, xw, yw);

	/* colours: the frame's bands 1, 2 are in the 4:3 crop: green at 1/3 of the picture's width, blue at 2/3 (crop = middle 3/4) */
	uint32_t yg = y[ph / 2 * pw + pw * 5 / 16], yb = y[ph / 2 * pw + pw * 11 / 16];
	uint8_t cbg = uv[ph / 4 * pw + (pw * 5 / 16 & ~1u)], crg = uv[ph / 4 * pw + (pw * 5 / 16 & ~1u) + 1];
	uint8_t cbb = uv[ph / 4 * pw + (pw * 11 / 16 & ~1u)], crb = uv[ph / 4 * pw + (pw * 11 / 16 & ~1u) + 1];
	CHECK(yg > yb && cbg < 128 && crg < 128, "%s: green band: Y %u Cb %u Cr %u", name, yg, cbg, crg);
	CHECK(cbb > 128 && crb < 128 + 8, "%s: blue band: Y %u Cb %u Cr %u", name, yb, cbb, crb);
	printf("cam3: %s: AE green %.0f (want %.0f) in %u writes, %u lines gain %u/256; white balance R %.2f B %.2f; green band Cb %u Cr %u, blue band Cb %u Cr %u\n",
	    name, st.mean[1], want, writes, dev.lines, dev.gain, isp.wb[0], isp.wb[2], cbg, crg, cbb, crb);
}

int
main(void)
{
	test_pure();
	test_client(3, "RGGB");         /* the library's filter 3 */
	test_client(0, "BGGR");
	test_client(2, "GRBG");
	test_client(1, "GBRG");
	printf("cam3: %u checks, %u failed\n", checks, fails);
	return fails ? 1 : 0;
}
