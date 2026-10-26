/*
 * The NegroniCamera ISP (camera_isp.c) on the host (macOS/Linux), for checks without the phone.
 *   isp-render --selftest                 synthetic RAW10 colour bars in each Bayer order through the preview
 *                                         path: each bar must come out its own colour (exit 1 if not)
 *   isp-render DUMP OUT.ppm [BAYER]       a frame read from /dev/negronicam on the phone (header + RAW10:
 *                                         dd if=/dev/negronicam bs=15040120 count=1 of=/tmp/f.raw) -> a PPM of
 *                                         its 2x2 cells, grey-world white balance as on the phone; BAYER 0-3
 *                                         overrides the header's order (try all four to find the IMX789's)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "camera_isp.h"

static void
put10(uint8_t *line, uint32_t x, int v)
{
	uint8_t *g = line + (x >> 2) * 5;
	int i = (int)(x & 3);

	g[i] = (uint8_t)(v >> 2);
	g[4] = (uint8_t)((g[4] & ~(3 << (i * 2))) | ((v & 3) << (i * 2)));
}

static int
selftest(void)
{
	enum { W = 64, H = 32, STRIDE = W * 5 / 4, OW = W / 2, OH = H / 2 };
	static const char *const order[4] = { "RGGB", "GRBG", "GBRG", "BGGR" };
	static const int bars[4][3] = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 1, 1, 1 } };      /* R, G, B, white */
	int failed = 0;

	for (uint32_t bayer = 0; bayer < 4; bayer++) {
		static uint8_t raw[STRIDE * H], out[OW * OH * 4];
		struct negronicam_frame f = { .header_bytes = sizeof(f), .width = W, .height = H, .stride = STRIDE, .format = 1,
			.bayer = bayer, .black = 64, .exposure_lines = 100, .line_ns = 10000, .gain = 256, .gain_unity = 256,
			.gain_max = 4096, .frame_lines = 3134, .frame_lines_min = 3134, .frame_lines_max = 0xfff0, .margin = 48, .sensor = 1,
			.focus = NEGRONICAM_NO_FOCUS };
		struct isp isp;
		int ok = 1;

		memcpy(f.magic, NEGRONICAM_MAGIC, 8);
		/* site colour of position (x&1, y&1): RGGB as cell_places() numbers them (0 TL, 1 TR, 2 BL, 3 BR) */
		static const int red_at[4] = { 0, 1, 2, 3 }, blue_at[4] = { 3, 2, 1, 0 };
		for (uint32_t y = 0; y < H; y++) {
			for (uint32_t x = 0; x < W; x++) {
				int site = (int)((y & 1) * 2 + (x & 1)), c = site == red_at[bayer] ? 0 : site == blue_at[bayer] ? 2 : 1;
				const int *bar = bars[x / (W / 4)];

				put10(raw + y * STRIDE, x, 64 + (bar[c] ? 800 : 0));
			}
		}
		isp_init(&isp);
		isp_render_bgra(&isp, &f, raw, out, OW * 4, OW, OH, 0, OH);
		for (int b = 0; b < 4; b++) {
			const uint8_t *p = out + (OH / 2 * OW + b * (OW / 4) + OW / 8) * 4;    /* BGRA, the bar's middle */
			int rgb[3] = { p[2], p[1], p[0] };

			for (int c = 0; c < 3; c++) {
				ok &= bars[b][c] ? rgb[c] > 200 : rgb[c] < 40;
			}
			printf("isp selftest: bayer %u %s bar %d: R %3d G %3d B %3d\n", bayer, order[bayer], b, rgb[0], rgb[1], rgb[2]);
		}
		printf("isp selftest: bayer %u %s: %s\n", bayer, order[bayer], ok ? "PASS" : "FAIL");
		failed |= !ok;
	}
	printf("isp selftest: %s\n", failed ? "FAIL" : "PASS");
	return failed;
}

int
main(int argc, char **argv)
{
	struct negronicam_frame f;
	struct isp isp;
	struct isp_stats st;
	FILE *in, *out;
	uint8_t *raw, *bgra;
	uint32_t w, h;

	if (argc == 2 && strcmp(argv[1], "--selftest") == 0) {
		return selftest();
	}
	if (argc < 3) {
		fprintf(stderr, "usage: %s --selftest | DUMP OUT.ppm [BAYER]\n", argv[0]);
		return 2;
	}
	if ((in = fopen(argv[1], "rb")) == NULL || fread(&f, sizeof(f), 1, in) != 1 || memcmp(f.magic, NEGRONICAM_MAGIC, 8) != 0 ||
	    f.header_bytes != sizeof(f) || f.width < 4 || f.height < 4 || f.width > 8192 || f.height > 8192) {
		fprintf(stderr, "%s: not an NCFRAME1 dump\n", argv[1]);
		return 1;
	}
	if (argc > 3) {
		f.bayer = (uint32_t)atoi(argv[3]) & 3;
	}
	raw = malloc((size_t)f.stride * f.height);
	if (fread(raw, 1, (size_t)f.stride * f.height, in) != (size_t)f.stride * f.height) {
		fprintf(stderr, "%s: short frame (%ux%u stride %u)\n", argv[1], f.width, f.height, f.stride);
		return 1;
	}
	fclose(in);
	w = f.width / 2 & ~1u;
	h = f.height / 2 & ~1u;
	bgra = malloc((size_t)w * h * 4);
	isp_init(&isp);
	for (int i = 0; i < 30; i++) {          /* (the phone's AWB moves a little each frame) */
		isp_measure(&isp, &f, raw, &st);
		isp_awb(&isp, &st);
	}
	isp_render_bgra(&isp, &f, raw, bgra, (size_t)w * 4, w, h, 0, h);
	if ((out = fopen(argv[2], "wb")) == NULL) {
		perror(argv[2]);
		return 1;
	}
	fprintf(out, "P6\n%u %u\n255\n", w, h);
	for (size_t i = 0; i < (size_t)w * h; i++) {
		uint8_t rgb[3] = { bgra[4 * i + 2], bgra[4 * i + 1], bgra[4 * i] };

		fwrite(rgb, 1, 3, out);
	}
	fclose(out);
	printf("%s: %ux%u bayer %u black %u seq %llu exposure %u lines gain %u/%u; mean R %.0f G %.0f B %.0f; wb R %.2f B %.2f -> %s (%ux%u)\n",
	    argv[1], f.width, f.height, f.bayer, f.black, (unsigned long long)f.sequence, f.exposure_lines, f.gain, f.gain_unity,
	    st.mean[0], st.mean[1], st.mean[2], isp.wb[0], isp.wb[2], argv[2], w, h);
	return 0;
}
