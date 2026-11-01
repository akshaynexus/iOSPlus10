/*
 * NegroniCamera (iOSPlus10, Mi A3 camera speed): the moving picture from whole rows of cells (camera_fast.c), and the rule that takes it to half the cells when a second's
 * pictures took too long. Pure C: tools/laurel-cam-test/cam9_test.c runs it on a host.
 */
#ifndef CAMERA_FAST_H
#define CAMERA_FAST_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "camera_isp.h"

#define FAST_MAX_CELLS  2048u
#define FAST_MAX_WIDTH  2048u

struct isp_fast {
	uint8_t         *plane, *y, *sharp, *cb, *cr;   /* cw x ch cells: Y, Y sharpened, cw/2 x ch: Cb, Cr */
	size_t          bytes;
	uint32_t        x0, y0, cw, ch, step;           /* the part of the sensor's cells, each step-th of them */
	uint32_t        table_cw, table_w;
	uint64_t        sequence;                       /* the frame in the planes (0: none): a second output of the same frame */
	uint16_t        cx[FAST_MAX_WIDTH], cx2[FAST_MAX_WIDTH];
	uint8_t         tx[FAST_MAX_WIDTH], tx2[FAST_MAX_WIDTH];
};

/* false: this picture is not larger than the cells, or is too large, or no memory: the caller has the old path */
bool isp_fast_begin(struct isp_fast *z, const struct isp *isp, const struct negronicam_frame *f, uint32_t width, uint32_t height, uint32_t step);
void isp_fast_cells(const struct isp_fast *z, const struct isp *isp, const struct negronicam_frame *f, const uint8_t *raw, uint32_t first, uint32_t end, bool video_range);
void isp_fast_sharpen(const struct isp_fast *z, uint32_t first, uint32_t end, float gain);
void isp_fast_scale(const struct isp_fast *z, uint8_t *y, size_t y_stride, uint8_t *uv, size_t uv_stride, uint32_t width, uint32_t height, uint32_t first, uint32_t end, float gain);

/*
 * The worker's clock, one line a second. Stages in microseconds summed over the second. The step: render (cells + sharpen + scale) over 24 ms on average for a second: every second
 * cell; back when it has stayed under 5 ms for 5 seconds (4 x 5 ms = 20 ms at every cell).
 */
enum { SPEED_READ, SPEED_MEASURE, SPEED_CELLS, SPEED_SHARPEN, SPEED_SCALE, SPEED_HANDLER, SPEED_STAGES };

struct speed {
	uint64_t        ticks[SPEED_STAGES], frame_ticks;       /* mach_absolute_time units */
	uint64_t        began, first_sequence, last_sequence;
	uint32_t        frames, given, rendered;
	uint32_t        step, calm_seconds;
};

#define SPEED_HALF_OVER_US      24000u
#define SPEED_BACK_UNDER_US     5000u
#define SPEED_BACK_SECONDS      5u

static inline uint32_t
speed_next_step(struct speed *s, uint32_t render_us_a_frame, uint32_t rendered)
{
	if (s->step == 0) {
		s->step = 1;
	}
	if (rendered == 0) {
		return s->step;
	}
	if (s->step == 1) {
		s->calm_seconds = 0;
		if (render_us_a_frame > SPEED_HALF_OVER_US) {
			s->step = 2;
		}
		return s->step;
	}
	s->calm_seconds = render_us_a_frame < SPEED_BACK_UNDER_US ? s->calm_seconds + 1 : 0;
	if (s->calm_seconds >= SPEED_BACK_SECONDS) {
		s->step = 1;
		s->calm_seconds = 0;
	}
	return s->step;
}
#endif
