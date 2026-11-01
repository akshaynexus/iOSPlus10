/*
 * The decoder core of LaurelHEVC. See hevc_core.h. FFmpeg (LGPL, libavcodec hevc decoder, unmodified, docs/laurel_sprout/hevc.md).
 */
#include "hevc_core.h"

#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/log.h>
#include <libavutil/pixdesc.h>
#include <libavutil/version.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

struct hv_core {
	AVCodecContext *ctx;
	AVPacket *pkt;
	AVFrame *frame;
	int draining;
};

int
hv_parse_hvcc(const uint8_t *h, size_t n, hv_info *out)
{
	/* HEVCDecoderConfigurationRecord: version at 0, profile at 1, level at 12, chroma at 16, depths at 17 + 18, lengthSizeMinusOne at 21 */
	if (h == NULL || n < 23 || h[0] != 1) {
		return -1;
	}
	out->profile = h[1] & 0x1f;
	out->level = h[12];
	out->chroma_idc = h[16] & 3;
	out->bits = (h[17] & 7) + 8;
	out->chroma_bits = (h[18] & 7) + 8;
	out->nal_length_size = (h[21] & 3) + 1;
	return out->nal_length_size == 3 ? -1 : 0;
}

const char *
hv_decoder_version(void)
{
	return av_version_info();
}

const char *
hv_error_text(int error, char *buf, size_t size)
{
	if (av_strerror(error, buf, size) != 0) {
		snprintf(buf, size, "error %d", error);
	}
	return buf;
}

hv_core *
hv_open(const uint8_t *hvcc, size_t size, int mode, char *err, size_t errsize)
{
	const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
	hv_core *c;
	long cpus = sysconf(_SC_NPROCESSORS_ONLN);
	int r;

	av_log_set_level(AV_LOG_QUIET);         /* a sandboxed daemon's stderr goes nowhere; errors come back as return values */
	if (codec == NULL) {
		snprintf(err, errsize, "libavcodec has no hevc decoder");
		return NULL;
	}
	c = av_mallocz(sizeof(*c));
	if (c == NULL) {
		snprintf(err, errsize, "no memory");
		return NULL;
	}
	c->ctx = avcodec_alloc_context3(codec);
	c->pkt = av_packet_alloc();
	c->frame = av_frame_alloc();
	if (c->ctx == NULL || c->pkt == NULL || c->frame == NULL) {
		snprintf(err, errsize, "no memory");
		goto fail;
	}
	c->ctx->extradata = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
	if (c->ctx->extradata == NULL) {
		snprintf(err, errsize, "no memory");
		goto fail;
	}
	memcpy(c->ctx->extradata, hvcc, size);
	c->ctx->extradata_size = (int)size;
	c->ctx->thread_count = cpus > 1 ? (int)(cpus > 8 ? 8 : cpus) : 1;
	c->ctx->thread_type = mode == HV_THREADS_FRAME ? FF_THREAD_FRAME | FF_THREAD_SLICE : FF_THREAD_SLICE;
	r = avcodec_open2(c->ctx, codec, NULL);
	if (r < 0) {
		char t[80];

		snprintf(err, errsize, "avcodec_open2: %s", hv_error_text(r, t, sizeof(t)));
		goto fail;
	}
	return c;
fail:
	hv_close(c);
	return NULL;
}

void
hv_close(hv_core *c)
{
	if (c == NULL) {
		return;
	}
	avcodec_free_context(&c->ctx);
	av_packet_free(&c->pkt);
	av_frame_free(&c->frame);
	av_free(c);
}

int
hv_send(hv_core *c, const uint8_t *data, size_t size, uint64_t tag)
{
	int r;

	av_packet_unref(c->pkt);
	r = av_new_packet(c->pkt, (int)size);       /* adds FFmpeg's input padding: the sample buffer's own bytes do not have it */
	if (r < 0) {
		return r;
	}
	memcpy(c->pkt->data, data, size);
	c->pkt->pts = (int64_t)tag;
	c->pkt->dts = AV_NOPTS_VALUE;
	r = avcodec_send_packet(c->ctx, c->pkt);
	av_packet_unref(c->pkt);
	return r;
}

int
hv_drain(hv_core *c)
{
	c->draining = 1;
	return avcodec_send_packet(c->ctx, NULL);
}

void
hv_flush(hv_core *c)
{
	av_frame_unref(c->frame);
	avcodec_flush_buffers(c->ctx);
	c->draining = 0;
}

int
hv_next(hv_core *c, hv_picture *p)
{
	const AVPixFmtDescriptor *d;
	int r;

	av_frame_unref(c->frame);
	r = avcodec_receive_frame(c->ctx, c->frame);
	if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) {
		return 0;
	}
	if (r < 0) {
		return r;
	}
	d = av_pix_fmt_desc_get(c->frame->format);
	/* grayN (one component, no PLANAR flag in FFmpeg) or planar YUV; hevc gives nothing else up to 12 bits */
	if (d == NULL || (d->flags & AV_PIX_FMT_FLAG_RGB) != 0 || d->comp[0].depth > 12 ||
	    !(d->nb_components == 1 || (d->nb_components == 3 && (d->flags & AV_PIX_FMT_FLAG_PLANAR) != 0))) {
		return AVERROR_PATCHWELCOME;
	}
	p->width = c->frame->width;
	p->height = c->frame->height;
	p->bits = d->comp[0].depth;
	p->chroma_w_shift = d->log2_chroma_w;
	p->chroma_h_shift = d->log2_chroma_h;
	p->full_range = c->frame->color_range == AVCOL_RANGE_JPEG || c->frame->format == AV_PIX_FMT_YUVJ420P ||
	    c->frame->format == AV_PIX_FMT_YUVJ422P || c->frame->format == AV_PIX_FMT_YUVJ444P;
	p->matrix = c->frame->colorspace == AVCOL_SPC_UNSPECIFIED ? 0 : (int)c->frame->colorspace;
	p->primaries = c->frame->color_primaries == AVCOL_PRI_UNSPECIFIED ? 0 : (int)c->frame->color_primaries;
	p->transfer = c->frame->color_trc == AVCOL_TRC_UNSPECIFIED ? 0 : (int)c->frame->color_trc;
	p->tag = (uint64_t)c->frame->pts;
	for (int i = 0; i < 3; i++) {
		p->plane[i] = c->frame->data[i];
		p->stride[i] = c->frame->linesize[i];
	}
	return 1;
}

/* The chroma row of a picture that goes with an output 4:2:0 chroma row. */
static const uint8_t *
chroma_row(const hv_picture *p, int plane, int y)
{
	return p->plane[plane] + (ptrdiff_t)p->stride[plane] * (p->chroma_h_shift ? y : y * 2);
}

void
hv_copy_l008(const hv_picture *p, uint8_t *dst, size_t stride)
{
	for (int y = 0; y < p->height; y++, dst += stride) {
		const uint8_t *s = p->plane[0] + (ptrdiff_t)p->stride[0] * y;

		if (p->bits == 8) {
			memcpy(dst, s, (size_t)p->width);
		} else {
			const uint16_t *w = (const uint16_t *)s;

			for (int x = 0; x < p->width; x++) {
				dst[x] = (uint8_t)(w[x] >> (p->bits - 8));
			}
		}
	}
}

void
hv_copy_nv12(const hv_picture *p, uint8_t *y, size_t y_stride, uint8_t *uv, size_t uv_stride)
{
	int cw = (p->width + 1) / 2, ch = (p->height + 1) / 2;

	hv_copy_l008(p, y, y_stride);
	for (int r = 0; r < ch; r++, uv += uv_stride) {
		if (p->plane[1] == NULL) {
			memset(uv, 0x80, (size_t)cw * 2);       /* monochrome: neutral chroma */
		} else if (p->bits == 8) {
			const uint8_t *cb = chroma_row(p, 1, r), *cr = chroma_row(p, 2, r);
			int step = p->chroma_w_shift ? 1 : 2;

			for (int x = 0; x < cw; x++) {
				uv[x * 2] = cb[x * step];
				uv[x * 2 + 1] = cr[x * step];
			}
		} else {
			const uint16_t *cb = (const uint16_t *)chroma_row(p, 1, r), *cr = (const uint16_t *)chroma_row(p, 2, r);
			int step = p->chroma_w_shift ? 1 : 2, sh = p->bits - 8;

			for (int x = 0; x < cw; x++) {
				uv[x * 2] = (uint8_t)(cb[x * step] >> sh);
				uv[x * 2 + 1] = (uint8_t)(cr[x * step] >> sh);
			}
		}
	}
}

void
hv_copy_p010(const hv_picture *p, uint8_t *y, size_t y_stride, uint8_t *uv, size_t uv_stride)
{
	int cw = (p->width + 1) / 2, ch = (p->height + 1) / 2;
	int sh = 16 - p->bits;

	for (int r = 0; r < p->height; r++, y += y_stride) {
		uint16_t *d = (uint16_t *)y;
		const uint8_t *s = p->plane[0] + (ptrdiff_t)p->stride[0] * r;

		for (int x = 0; x < p->width; x++) {
			d[x] = p->bits == 8 ? (uint16_t)(s[x] << 8) : (uint16_t)(((const uint16_t *)s)[x] << sh);
		}
	}
	for (int r = 0; r < ch; r++, uv += uv_stride) {
		uint16_t *d = (uint16_t *)uv;
		int step = p->chroma_w_shift ? 1 : 2;

		if (p->plane[1] == NULL) {
			for (int x = 0; x < cw * 2; x++) {
				d[x] = 0x8000;
			}
			continue;
		}
		const uint8_t *cb = chroma_row(p, 1, r), *cr = chroma_row(p, 2, r);

		for (int x = 0; x < cw; x++) {
			if (p->bits == 8) {
				d[x * 2] = (uint16_t)(cb[x * step] << 8);
				d[x * 2 + 1] = (uint16_t)(cr[x * step] << 8);
			} else {
				d[x * 2] = (uint16_t)(((const uint16_t *)cb)[x * step] << sh);
				d[x * 2 + 1] = (uint16_t)(((const uint16_t *)cr)[x * step] << sh);
			}
		}
	}
}
