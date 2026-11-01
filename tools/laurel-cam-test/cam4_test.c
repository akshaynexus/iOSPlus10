/*
 * Host test of the Mi A3 camera quality work (patch 2773, userland/camera/camera_still.c). scripts/laurel/cam-test.sh runs it.
 *   cam4_test LIBDIR     LIBDIR = out/laurel/camera/lib: with the stock libraries, the real frame rates and the lens motor's data
 * Pure code only: no sensor, no XNU, no CMCapture ran here. What a phone does stays unproven.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "laurel_cam_mode.h"
#include "camera_isp.h"
#include "camera_isp_int.h"

static unsigned checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; printf("FAILED %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint8_t *
slurp(const char *path, size_t *size)
{
	FILE *f = fopen(path, "rb");
	uint8_t *b;

	if (f == NULL) {
		return NULL;
	}
	fseek(f, 0, SEEK_END);
	*size = (size_t)ftell(f);
	fseek(f, 0, SEEK_SET);
	b = malloc(*size);
	if (b == NULL || fread(b, 1, *size, f) != *size) {
		exit(1);
	}
	fclose(f);
	return b;
}

static void
test_library(const char *dir, const char *file)
{
	static const unsigned fps[7] = { 15, 30, 60, 90, 120, 30, 240 };
	char path[512];
	size_t size;
	uint8_t *b;
	struct lcam_lib l;
	const char *why = "";

	snprintf(path, sizeof(path), "%s/%s", dir, file);
	if ((b = slurp(path, &size)) == NULL) {
		printf("cam4: no %s: skipped\n", path);
		return;
	}
	CHECK(lcam_lib_parse(b, size, &l, &why) == 0, "%s: %s", file, why);
	for (int k = 0; k < 7; k++) {
		struct lcam_mode m;
		uint32_t hz = lcam_mode_vt_hz(&l, k);

		CHECK(lcam_lib_mode(&l, (uint32_t)k, &m) == 0, "mode %d", k);
		double f = (double)hz / m.line / m.frame;

		CHECK(fabs(f - fps[k]) < 0.5, "%s: mode %d: %.2f fps from the PLL, expected %u", file, k, f, fps[k]);
	}
	/* the boot of 18:40 [V]: 234 fps measured at 780 lines, 37.5 at 4862: line about 5.4 us; the library said 13.7 */
	struct lcam_smode s[LCAM_SM_N];

	for (unsigned i = 0; i < LCAM_SM_N; i++) {
		CHECK(lcam_mode_build(&l, i, &s[i]), "session mode %u", i);
	}
	CHECK(s[LCAM_SM_720].line_ns == 5333, "720 line %u ns", s[LCAM_SM_720].line_ns);
	CHECK(s[LCAM_SM_WINDOW].k == 2 && s[LCAM_SM_WINDOW].window && s[LCAM_SM_WINDOW].w == 1920 && s[LCAM_SM_WINDOW].h == 1440, "window");
	CHECK(s[LCAM_SM_WINDOW].stride == 2400 && s[LCAM_SM_WINDOW].bytes == 3456000, "window bytes %u", s[LCAM_SM_WINDOW].bytes);
	CHECK(s[LCAM_SM_WINDOW].sensor_w == 7680 && s[LCAM_SM_WINDOW].sensor_h == 5760, "window view %ux%u", s[LCAM_SM_WINDOW].sensor_w,
	    s[LCAM_SM_WINDOW].sensor_h);
	CHECK(s[LCAM_SM_WINDOW].frame > 1440 + 48, "window frame %u", s[LCAM_SM_WINDOW].frame);
	CHECK(s[LCAM_SM_1080].sensor_h == 4320 && s[LCAM_SM_720].sensor_w == 5120 && s[LCAM_SM_720].sensor_h == 2880, "stock views");
	CHECK(s[LCAM_SM_STILL].k == 1 && s[LCAM_SM_STILL].bytes == 15000000 && s[LCAM_SM_STILL].sensor_w == 8000, "still");
	/* a line must carry its bytes: 1920 x 10 bits on 4 lanes at the IOP rate of mode 2 (VCO 1640 MHz / 4 = 410 Mbit/s a lane) fits in the line time */
	CHECK(1920 * 10 / 4 * 1000 / 410 < s[LCAM_SM_WINDOW].line_ns, "window line time %u ns", s[LCAM_SM_WINDOW].line_ns);
	/* the window's values: 30 + 1440 + 30 = 1500 binned lines of 6000 / 4 */
	CHECK(lcam_window_regs[3].val == 0x6f && lcam_window_regs[2].val == 0x17, "Y end 5999");
	free(b);
}

static void
test_motor(const char *dir)
{
	static const struct {
		const char *file;
		uint8_t r6, r7;
		uint16_t initial, steps;
	} want[2] = { { "libactuator_dw9800.so", 0x80, 0x5e, 381, 481 }, { "libactuator_laurus_dw9800w_qtech.so", 0x40, 0x7a, 150, 400 } };

	for (int i = 0; i < 2; i++) {
		char path[512];
		size_t size;
		uint8_t *b;
		struct lcam_vcm_lib v;

		snprintf(path, sizeof(path), "%s/%s", dir, want[i].file);
		if ((b = slurp(path, &size)) == NULL) {
			printf("cam4: no %s: skipped\n", path);
			continue;
		}
		CHECK(lcam_vcm_parse(b, size, &v) == 0, "%s", want[i].file);
		CHECK(v.addr7 == 0x0c && v.pos_reg == 3 && v.n == 3, "%s: address %#x position %#x n %u", want[i].file, v.addr7, v.pos_reg, v.n);
		CHECK(v.reg[0] == 2 && v.val[0] == 2 && v.reg[1] == 6 && v.val[1] == want[i].r6 && v.reg[2] == 7 && v.val[2] == want[i].r7, "%s: init", want[i].file);
		CHECK(v.initial == want[i].initial && v.steps == want[i].steps, "%s: %u %u", want[i].file, v.initial, v.steps);
		CHECK(lcam_vcm_parse(b, 64, &v) != 0, "a short file is refused");
		free(b);
	}
}

/* a slanted edge, 200 steps above black on one side and 800 on the other, RGGB, RAW10 */
#define W 256u
#define H 128u
static void
put_px(uint8_t *raw, uint32_t stride, uint32_t x, uint32_t y, uint32_t v)
{
	uint8_t *g = raw + (size_t)y * stride + (x / 4) * 5;

	g[x & 3] = (uint8_t)(v >> 2);
	g[4] = (uint8_t)((g[4] & ~(3u << (2 * (x & 3)))) | (v & 3) << (2 * (x & 3)));
}

static void
test_demosaic(void)
{
	uint32_t stride = W / 4 * 5;
	uint8_t *raw = calloc(1, (size_t)stride * H);
	struct negronicam_frame f;
	struct isp *isp = malloc(sizeof(*isp));
	float *lines[5];
	int32_t tags[5] = { -1, -1, -1, -1, -1 };
	uint8_t rgb[3 * W];

	memset(&f, 0, sizeof(f));
	f.width = W;
	f.height = H;
	f.stride = stride;
	f.black = 64;
	f.bayer = 0;
	isp_init(isp);
	for (int i = 0; i < 5; i++) {
		lines[i] = malloc(sizeof(float) * W);
	}
	/* flat grey comes out grey, for every Bayer order */
	for (uint32_t y = 0; y < H; y++) {
		for (uint32_t x = 0; x < W; x++) {
			put_px(raw, stride, x, y, 64 + 300);
		}
	}
	for (uint32_t order = 0; order < 4; order++) {
		f.bayer = order;
		memset(tags, 0xff, sizeof(tags));
		for (uint32_t y = 0; y < H; y += 17) {
			isp_mhc_row(isp, &f, raw, y, lines, tags, rgb);
			for (uint32_t x = 0; x < W; x++) {
				CHECK(rgb[3 * x] == rgb[3 * x + 1] && rgb[3 * x + 1] == rgb[3 * x + 2], "flat grey order %u at %u,%u: %u %u %u", order, x, y,
				    rgb[3 * x], rgb[3 * x + 1], rgb[3 * x + 2]);
			}
		}
	}
	/* colour bars keep their colour: red, green, blue sites differ */
	f.bayer = 0;
	for (uint32_t y = 0; y < H; y++) {
		for (uint32_t x = 0; x < W; x++) {
			static const uint32_t bar[4][3] = { { 900, 50, 50 }, { 50, 900, 50 }, { 50, 50, 900 }, { 500, 500, 500 } };
			const uint32_t *c = bar[x * 4 / W];
			int colour = (y & 1) == 0 ? ((x & 1) == 0 ? 0 : 1) : ((x & 1) == 0 ? 1 : 2);

			put_px(raw, stride, x, y, 64 + c[colour]);
		}
	}
	memset(tags, 0xff, sizeof(tags));
	isp_mhc_row(isp, &f, raw, 64, lines, tags, rgb);
	CHECK(rgb[3 * 32] > 200 && rgb[3 * 32 + 1] < 110 && rgb[3 * 32 + 2] < 110, "red bar %u %u %u", rgb[3 * 32], rgb[3 * 32 + 1], rgb[3 * 32 + 2]);
	CHECK(rgb[3 * 96 + 1] > 200 && rgb[3 * 96] < 110 && rgb[3 * 96 + 2] < 110, "green bar");
	CHECK(rgb[3 * 160 + 2] > 200 && rgb[3 * 160] < 110 && rgb[3 * 160 + 1] < 110, "blue bar");
	/* the lens shading follows the frame's part of the sensor: at the edge of a frame that shows half of it, the gain of a quarter of the way */
	float g[3], full[3];

	isp->lsc.on = true;
	for (int c = 0; c < 3; c++) {
		for (int gy = 0; gy < LSC_H; gy++) {
			for (int gx = 0; gx < LSC_W; gx++) {
				isp->lsc.gain[c][gy][gx] = 1 + (float)gx / (LSC_W - 1);
			}
		}
	}
	isp->lsc_u = 0.5f;
	isp->lsc_v = 1;
	lsc_at(isp, 1, 0.5f, g);
	isp->lsc_u = 1;
	lsc_at(isp, 0.75f, 0.5f, full);
	CHECK(fabsf(g[0] - full[0]) < 0.001f, "shading on a part: %f %f", g[0], full[0]);
	isp->lsc.on = false;
	/* the finish: a step edge gets steeper, flat stays flat, noise under the coring stays as it is */
	uint32_t w = 64, h = 32;
	uint8_t *yp = malloc((size_t)w * h), *uv = malloc((size_t)w * h / 2);

	memset(uv, 128, (size_t)w * h / 2);
	for (uint32_t r = 0; r < h; r++) {
		for (uint32_t x = 0; x < w; x++) {
			yp[r * w + x] = x < 32 ? 80 : 160;
		}
	}
	isp_finish_rows(yp, w, uv, w, w, h, 0, h, 1, true);
	CHECK(yp[10 * w + 31] < 80 && yp[10 * w + 32] > 160, "edge steeper: %u %u", yp[10 * w + 31], yp[10 * w + 32]);
	CHECK(yp[10 * w + 10] == 80 && yp[10 * w + 50] == 160, "flat stays");
	for (uint32_t r = 0; r < h; r++) {
		for (uint32_t x = 0; x < w; x++) {
			yp[r * w + x] = (uint8_t)(100 + ((x ^ r) & 1));
		}
	}
	isp_finish_rows(yp, w, uv, w, w, h, 0, h, 16, true);
	CHECK(yp[10 * w + 10] >= 100 && yp[10 * w + 10] <= 101, "noise is not sharpened: %u", yp[10 * w + 10]);
	/* AE no longer waits for ever for a value the kernel clamped */
	struct negronicam_frame fr = f;
	struct isp_stats st;
	struct negronicam_command c;

	memset(&st, 0, sizeof(st));
	st.mean[1] = 20;
	st.bright = 40;
	fr.exposure_lines = 100;
	fr.gain = fr.gain_unity = 256;
	fr.gain_max = 4096;
	fr.frame_lines = fr.frame_lines_min = 2604;
	fr.frame_lines_max = 2604 * 4;
	fr.margin = 48;
	bool first = isp_ae(isp, &fr, &st, &c), blocked = false, again = false;

	CHECK(first, "AE asks");
	fr.exposure_lines = c.a + 7;    /* never what it asked */
	for (int i = 0; i < 20; i++) {
		bool a = isp_ae(isp, &fr, &st, &c);

		blocked = blocked || !a;
		again = again || a;
		if (a) {
			break;
		}
	}
	CHECK(blocked && again, "AE waits, then goes on");
	free(raw);
}

/* the tuning file the root step makes goes through the plug-in's loader */
static void
test_tuning(const char *path)
{
	struct isp *isp = malloc(sizeof(*isp));

	isp_init(isp);
	if (path == NULL || access(path, R_OK) != 0) {
		printf("cam4: no tuning file: skipped\n");
		return;
	}
	CHECK(isp_load_tuning(isp, path), "%s loads", path);
	if (isp->tuning != NULL) {
		isp_tune(isp, 200, 2600);
		float warm = isp->ccm[0][0];

		CHECK(isp->lsc.on && isp->lsc.gain[0][0][0] > 2 && isp->lsc.gain[0][6][8] < 1.3f, "shading grid: corner %.2f middle %.2f", isp->lsc.gain[0][0][0],
		    isp->lsc.gain[0][6][8]);
		isp_tune(isp, 200, 6500);
		for (int r = 0; r < 3; r++) {
			CHECK(fabsf(isp->ccm[r][0] + isp->ccm[r][1] + isp->ccm[r][2] - 1) < 0.03f, "matrix row %d sums to 1", r);
		}
		CHECK(isp->ccm[0][0] > warm, "the warm light's matrix has less red: %.3f %.3f", warm, isp->ccm[0][0]);
	}
}

int
main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : ".";

	test_library(dir, "libmmcamera_laurus_imx586_qtech.so");
	test_library(dir, "libmmcamera_laurus_imx586_sunny.so");
	test_motor(dir);
	test_demosaic();
	test_tuning(argc > 2 ? argv[2] : NULL);
	printf("cam4: %u checks, %u failed\n", checks, failed);
	return failed ? 1 : 0;
}
