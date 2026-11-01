/*
 * Host test of hevc_core.c, the same file as in the iOS plug-in: decodes samples as VideoToolbox would hand them over.
 *   hevc-test JOB OUT     JOB: "HVJ1", u32 hvcC size + bytes, u32 mode (0 slice, 1 frame threads), u32 count, count x (u32 size + bytes)
 *   OUT: for each picture in output order: "HVF1", u32 sample number, u32 w, u32 h, u32 bits, u32 monochrome, u32 full range, u32 matrix,
 *        then the buffer the plug-in would fill: Y rows + interleaved CbCr rows, 1 byte a sample at 8 bits ('420f'), 2 at more ('x420').
 * Prints: "pictures P of S samples, held back at most H, T ms" and exits 0 when every sample gave a picture. scripts/laurel/hevc-test.py runs it.
 */
#include "hevc_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint32_t
get32(FILE *f)
{
	uint8_t b[4];

	if (fread(b, 1, 4, f) != 4) {
		fprintf(stderr, "short job file\n");
		exit(2);
	}
	return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
}

static void
put32(FILE *f, uint32_t v)
{
	fwrite(&v, 4, 1, f);    /* the test runs little endian only */
}

static uint32_t pictures;

static int
drain(hv_core *c, FILE *o)
{
	hv_picture p;
	int r;

	while ((r = hv_next(c, &p)) > 0) {
		int sample = p.bits > 8 ? 2 : 1;
		size_t ys = (size_t)p.width * sample, uvs = (size_t)((p.width + 1) / 2) * 2 * sample;
		int ch = (p.height + 1) / 2;
		uint8_t *y = malloc(ys * p.height), *uv = malloc(uvs * ch);

		if (sample == 2) {
			hv_copy_p010(&p, y, ys, uv, uvs);
		} else {
			hv_copy_nv12(&p, y, ys, uv, uvs);
		}
		fwrite("HVF1", 1, 4, o);
		put32(o, (uint32_t)p.tag);
		put32(o, (uint32_t)p.width);
		put32(o, (uint32_t)p.height);
		put32(o, (uint32_t)p.bits);
		put32(o, p.plane[1] == NULL);
		put32(o, (uint32_t)p.full_range);
		put32(o, (uint32_t)p.matrix);
		fwrite(y, 1, ys * p.height, o);
		fwrite(uv, 1, uvs * ch, o);
		free(y);
		free(uv);
		pictures++;
	}
	return r;
}

int
main(int argc, char **argv)
{
	FILE *j, *o;
	char head[4], err[160] = "", t[80];
	uint32_t n, mode, count, held = 0;
	uint8_t *hvcc;
	hv_info info;
	hv_core *c;
	struct timespec a, b;
	int fail = 0, r;

	if (argc != 3 || (j = fopen(argv[1], "rb")) == NULL || (o = fopen(argv[2], "wb")) == NULL) {
		fprintf(stderr, "usage: hevc-test JOB OUT\n");
		return 2;
	}
	if (fread(head, 1, 4, j) != 4 || memcmp(head, "HVJ1", 4) != 0) {
		fprintf(stderr, "not a job file\n");
		return 2;
	}
	n = get32(j);
	hvcc = malloc(n);
	if (fread(hvcc, 1, n, j) != n || hv_parse_hvcc(hvcc, n, &info) != 0) {
		fprintf(stderr, "bad hvcC\n");
		return 2;
	}
	mode = get32(j);
	count = get32(j);
	c = hv_open(hvcc, n, (int)mode, err, sizeof(err));
	if (c == NULL) {
		fprintf(stderr, "hv_open: %s\n", err);
		return 1;
	}
	clock_gettime(CLOCK_MONOTONIC, &a);
	for (uint32_t i = 0; i < count; i++) {
		uint32_t size = get32(j);
		uint8_t *s = malloc(size);

		if (fread(s, 1, size, j) != size) {
			fprintf(stderr, "short sample\n");
			return 2;
		}
		r = hv_send(c, s, size, i);
		free(s);
		if (r < 0) {
			fprintf(stderr, "sample %u: %s\n", i, hv_error_text(r, t, sizeof(t)));
			fail = 1;
			continue;
		}
		r = drain(c, o);
		if (r < 0) {
			fprintf(stderr, "sample %u: %s\n", i, hv_error_text(r, t, sizeof(t)));
			fail = 1;
		}
		if (i + 1 - pictures > held) {
			held = i + 1 - pictures;
		}
	}
	hv_drain(c);
	drain(c, o);
	clock_gettime(CLOCK_MONOTONIC, &b);
	hv_close(c);
	fclose(o);
	printf("chroma_idc %d bits %d, %s, pictures %u of %u samples, held back at most %u, %.1f ms\n", info.chroma_idc, info.bits, hv_decoder_version(),
	    pictures, count, held, (double)(b.tv_sec - a.tv_sec) * 1e3 + (double)(b.tv_nsec - a.tv_nsec) / 1e6);
	return fail || pictures != count;
}
