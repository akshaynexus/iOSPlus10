/*
 * The decoder core of LaurelHEVC: HEVC samples (hvcC + length-prefixed NAL units) in, biplanar pictures out, through FFmpeg's
 * libavcodec. No Apple header here: the same file is built for the iOS plug-in (vt_plugin.c) and for the host test (hevc-test.c).
 * Not thread safe per object; one object per VideoToolbox session.
 */
#ifndef LAUREL_HEVC_CORE_H
#define LAUREL_HEVC_CORE_H

#include <stddef.h>
#include <stdint.h>

/* What hvcC says about a stream (ISO/IEC 14496-15). */
typedef struct {
	int chroma_idc;         /* 0 mono, 1 4:2:0, 2 4:2:2, 3 4:4:4 */
	int bits;               /* luma bit depth */
	int chroma_bits;
	int nal_length_size;    /* 1, 2 or 4 */
	int profile;            /* general_profile_idc */
	int level;              /* general_level_idc */
} hv_info;

/* One decoded picture: valid until the next hv_next() or hv_flush(). */
typedef struct {
	int width, height;
	int bits;               /* 8, 10 or 12 */
	int chroma_w_shift;     /* 0 or 1; 4:0:0 has plane[1] == NULL */
	int chroma_h_shift;
	int full_range;
	int matrix;             /* H.273 values: 0 means "unspecified here", the container may know better */
	int primaries;
	int transfer;
	uint64_t tag;           /* the tag given to hv_send() for this picture */
	const uint8_t *plane[3];
	int stride[3];
} hv_picture;

typedef struct hv_core hv_core;

enum {
	HV_THREADS_SLICE = 0,   /* stills and short clips: a picture comes out as soon as its sample went in, if the stream reorders nothing */
	HV_THREADS_FRAME = 1,   /* video with temporal processing: more speed, pictures come out later */
};

int hv_parse_hvcc(const uint8_t *hvcc, size_t size, hv_info *out);      /* 0, or -1 for a malformed record */
hv_core *hv_open(const uint8_t *hvcc, size_t size, int threads_mode, char *err, size_t errsize);
int hv_send(hv_core *c, const uint8_t *data, size_t size, uint64_t tag); /* 0, or a negative error */
int hv_drain(hv_core *c);                                                /* no more samples: hv_next() gives what is held back */
int hv_next(hv_core *c, hv_picture *out);                                /* 1 picture, 0 none now, negative on an error */
void hv_flush(hv_core *c);                                               /* forget held pictures; samples may follow again */
void hv_close(hv_core *c);
const char *hv_error_text(int error, char *buf, size_t size);
const char *hv_decoder_version(void);

/* Copies a picture of any chroma layout into the two planes of a 4:2:0 biplanar buffer (Cb, Cr interleaved). */
void hv_copy_nv12(const hv_picture *p, uint8_t *y, size_t y_stride, uint8_t *uv, size_t uv_stride);   /* 8 bits a sample */
void hv_copy_p010(const hv_picture *p, uint8_t *y, size_t y_stride, uint8_t *uv, size_t uv_stride);   /* 16 bits a sample, value in the high bits */
void hv_copy_l008(const hv_picture *p, uint8_t *y, size_t y_stride);                                  /* luma only */

#endif
