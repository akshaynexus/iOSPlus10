/*
 * laurel: what an IOSurface holds, as blue-first 8-bit pixels. eagl.c uses this for every surface that OpenGL ES cannot take
 * as it is, above all for what CoreAnimation hands to -attachImage: without a GL format of its own (QuartzCore 20H392
 * CA::OGL::GLESContext::attach_surface_texture: any OSType outside its short list goes there, the answer is not looked at, so a
 * refusal there is a blank layer). No iOS headers here: the host test (tests/surface_formats_test.c) runs this on Linux.
 * docs/laurel_sprout/gpu.md "IOSurface formats" has the table and where each layout comes from.
 */
#ifndef LAUREL_SURFACE_FORMATS_H
#define LAUREL_SURFACE_FORMATS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum lsf_kind {
	LSF_BGRA, LSF_RGBA,
	LSF_XR_BGR10,           /* 'w30r' = BGR10_XR: bits 31-30 unused, red 29-20, green 19-10, blue 9-0; value = (code - 384) / 510 */
	LSF_BGR10A2,            /* 'l10r' = BGR10A2Unorm: alpha 31-30, red 29-20, green 19-10, blue 9-0 */
	LSF_RGB10A2,            /* 'R10k' = RGB10A2Unorm (RenderBox's table): alpha 31-30, blue 29-20, green 19-10, red 9-0 */
	LSF_XR_BGRA16,          /* 'w40a' = BGRA10_XR: four 16-bit fields B G R A, each code in its top 10 bits */
	LSF_XR_2P,              /* 'b3a8' = RGB10A8_2P_XR10: plane 0 the BGR10_XR word, plane 1 alpha bytes */
	LSF_HALF, LSF_FLOAT,    /* 'RGhA', 'RGfA', 'L00h', '2C0h', ...: `channels` of them */
	LSF_565, LSF_555, LSF_4444,
	LSF_L8, LSF_A8, LSF_LA8, LSF_RG8, LSF_L16,
	LSF_RGB8_2P,            /* '_RB4' = RGB8_444_2P: plane 0 green bytes, plane 1 (blue, red) byte pairs, no alpha */
	LSF_YUV_2P8,            /* '420f' ...: plane 0 Y bytes, plane 1 (Cb, Cr) byte pairs */
	LSF_YUV_2P10,           /* 'x420' ...: 16-bit words, the code in the top 10 bits */
	LSF_YUV_2P10P,          /* 'pf20' ...: 32-bit words of three 10-bit codes */
	LSF_YUV_1P10,           /* 'xf4p': Cb 9-0, Y 19-10, Cr 29-20 */
	LSF_YUYV, LSF_UYVY,     /* 'yuvs', 'yuvf'; '2vuy', '2vuf' */
};

enum lsf_matrix { LSF_MATRIX_601, LSF_MATRIX_709, LSF_MATRIX_2020 };

struct lsf_format {
	uint32_t ostype;
	uint8_t kind, full_range, sub_x, sub_y, channels;
	bool guess;             /* the OSType is not known here: picked by the surface's layout */
	const char *what;       /* for the log */
};

struct lsf_plane {
	const uint8_t *base;
	size_t row;
	uint32_t width, height, bytes;  /* bytes: of an element */
};

/* Always an answer: a known OSType, else the nearest layout (guess = true). `planes` = 0 for a surface without plane info. */
const struct lsf_format *lsf_find(uint32_t ostype, unsigned planes, const struct lsf_plane *plane);

/* The format of a texture that Metal draws over a surface the kernel calls BGRA (the kernel keeps 'w30r' and kin as BGRA). NULL: none. */
const struct lsf_format *lsf_of_metal(uint32_t pixel_format);

/*
 * Convert: `out` gets width x height blue-first pixels, `out_row` bytes apart. `linear`: RGhA and kin hold linear light (the surface's
 * colour space says so): sRGB-encoded for the 8-bit picture. Colours outside 0...1 are clipped: the panel is 8-bit sRGB.
 */
void lsf_convert(const struct lsf_format *f, enum lsf_matrix matrix, bool linear, const struct lsf_plane *plane, unsigned planes,
    uint32_t width, uint32_t height, uint8_t *out, size_t out_row, bool invert);

/* What a picture holds, from up to 64 x 64 samples: how many are not black (A8: not clear), how many differ from the first. */
struct lsf_contents {
	uint32_t samples, lit, unlike;
	uint8_t mean[3];        /* red, green, blue */
};
void lsf_contents_of_pixels(const struct lsf_format *f, const uint8_t *pixels, size_t row, uint32_t width, uint32_t height,
    struct lsf_contents *c);
void lsf_contents_of_rb4(const struct lsf_plane *plane, uint32_t width, uint32_t height, struct lsf_contents *c);
void lsf_contents_of_words(enum lsf_kind kind, const uint8_t *words, size_t row, uint32_t width, uint32_t height, struct lsf_contents *c);

/*
 * laurel 0006: the surfaces that were black at a first draw and have not been seen lit since, for the LAUREL BLANK line. Note: new surface (the caller
 * fills `who`), NULL when it is on the list already or the list is full. Filled: off the list, counted with the time it took. Take: one older than
 * `age` ms comes off the list.
 */
#define LSF_BLANKS 32
struct lsf_blank {
	uint32_t surface, pixels, width, height;
	uint64_t since_ms;
	char who[20];
};
struct lsf_blanks {
	struct lsf_blank list[LSF_BLANKS];
	unsigned count, lost, seen, filled;
	uint64_t filled_ms;
};
struct lsf_blank *lsf_blank_note(struct lsf_blanks *b, uint32_t surface, uint32_t pixels, uint32_t width, uint32_t height, uint64_t now_ms);
bool lsf_blank_filled(struct lsf_blanks *b, uint32_t surface, uint64_t now_ms);
bool lsf_blank_take(struct lsf_blanks *b, uint64_t now_ms, uint64_t age, struct lsf_blank *out);

/* Four characters for the log, printable or dots. */
void lsf_name(uint32_t ostype, char name[5]);

#endif
