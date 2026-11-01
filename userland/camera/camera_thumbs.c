/*
 * NegroniCamera (iOSPlus10, Mi A3, laurel): Camera.app's filter thumbnails without Metal (media_hooks.c, BWMultiFilterThumbnailNode).
 * The stock node writes one picture per filter, one under the other, thumbnail width x (thumbnail height x filters) in one buffer
 * ([V] -[BWMultiFilterThumbnailNode didSelectFormat:forInput:], 20H392 0x1a1fbaef8: setWidth: thumbnail width, setHeight: height x
 * [_filters count]). No filter here: the same picture in every place, the middle of the frame with the thumbnail's proportions, nearest
 * sample: a few hundred thousand bytes a frame at most, and the strip shows the scene with no effect.
 */
#include <CoreVideo/CoreVideo.h>
#include <stdbool.h>
#include <stdint.h>

#define THUMB_420F 0x34323066u          /* '420f' */
#define THUMB_420V 0x34323076u          /* '420v' */

static bool
two_plane(CVPixelBufferRef b)
{
	uint32_t pf = CVPixelBufferGetPixelFormatType(b);

	return pf == THUMB_420F || pf == THUMB_420V;
}

/* true: every place of `out` has the picture. false: nothing is good in `out` (not to be given on) */
bool
negronicam_thumbnails_fill(CVImageBufferRef picture, CVPixelBufferRef out, unsigned count)
{
	if (!two_plane(picture) || !two_plane(out) || count == 0) {
		return false;
	}
	size_t iw = CVPixelBufferGetWidth(picture), ih = CVPixelBufferGetHeight(picture);
	size_t ow = CVPixelBufferGetWidth(out), oh = CVPixelBufferGetHeight(out), place = oh / count;

	if (iw < 2 || ih < 2 || ow < 2 || place < 2) {
		return false;
	}
	/* the middle of the frame with the place's proportions */
	size_t cw = ih * ow / place < iw ? ih * ow / place : iw, ch = iw * place / ow < ih ? iw * place / ow : ih;
	size_t x0 = (iw - cw) / 2, y0 = (ih - ch) / 2;

	CVPixelBufferLockBaseAddress(picture, 1);       /* kCVPixelBufferLock_ReadOnly */
	CVPixelBufferLockBaseAddress(out, 0);

	const uint8_t *iy = CVPixelBufferGetBaseAddressOfPlane(picture, 0), *iuv = CVPixelBufferGetBaseAddressOfPlane(picture, 1);
	uint8_t *oy = CVPixelBufferGetBaseAddressOfPlane(out, 0), *ouv = CVPixelBufferGetBaseAddressOfPlane(out, 1);
	size_t iys = CVPixelBufferGetBytesPerRowOfPlane(picture, 0), iuvs = CVPixelBufferGetBytesPerRowOfPlane(picture, 1);
	size_t oys = CVPixelBufferGetBytesPerRowOfPlane(out, 0), ouvs = CVPixelBufferGetBytesPerRowOfPlane(out, 1);
	bool ok = iy != NULL && iuv != NULL && oy != NULL && ouv != NULL && iys >= iw && iuvs >= iw && oys >= ow && ouvs >= ow;

	for (size_t r = 0; ok && r < oh; r++) {
		size_t at = r % place, sy = y0 + at * ch / place;
		const uint8_t *from = iy + sy * iys;
		uint8_t *to = oy + r * oys;

		for (size_t x = 0; x < ow; x++) {
			to[x] = from[x0 + x * cw / ow];
		}
		if ((r & 1) == 0) {
			const uint8_t *cf = iuv + (sy / 2) * iuvs;
			uint8_t *ct = ouv + (r / 2) * ouvs;

			for (size_t x = 0; x + 1 < ow; x += 2) {
				size_t sx = (x0 + x * cw / ow) & ~(size_t)1;

				ct[x] = cf[sx];
				ct[x + 1] = cf[sx + 1];
			}
		}
	}
	CVPixelBufferUnlockBaseAddress(out, 0);
	CVPixelBufferUnlockBaseAddress(picture, 1);
	return ok;
}
