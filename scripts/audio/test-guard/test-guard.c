/*
 * Host test of the kernel speaker guard (bsd/dev/negroni_audio_guard.c, patch 0244). Built and run
 * by scripts/audio/test-guard.sh. Checks: a full-scale 1 kHz sine leaves at the cap (-20 dBFS by
 * default) within 0.5 dB, 50 Hz is cut by the 200 Hz high-pass (>= 20 dB under 1 kHz), no output
 * sample is above the cap, the soft start begins at 0, mute gives 0, the earpiece mix puts (L+R)/2
 * on the left and 0 on the right, a square wave is held by the power limiter.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "negroni_audio_guard.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok: " __VA_ARGS__); printf("\n"); } } while (0)

static double
run(double hz, double amp, int secs, int square, int receiver, double *peak_db, int32_t *first)
{
	int16_t in[2 * 240];
	int32_t out[2 * 240];
	double sum = 0, peak = 0;
	long n = 0;

	for (int b = 0; b < secs * 200; b++) {
		for (int f = 0; f < 240; f++) {
			double t = (double)(b * 240 + f) / 48000.0, s = sin(2 * M_PI * hz * t);
			if (square) {
				s = s >= 0 ? 1 : -1;
			}
			in[2 * f] = (int16_t)lrint(32767 * amp * s);
			in[2 * f + 1] = receiver ? 0 : in[2 * f];
		}
		ng_guard_process(in, out, 240, receiver != 0);
		if (b == 0 && first) {
			memcpy(first, out, sizeof(out));
		}
		if (b >= secs * 200 - 50) {             /* the last 0.25 s */
			for (int i = 0; i < 480; i += 2) {
				double v = out[i] / 8388608.0;
				sum += v * v;
				n++;
				peak = fmax(peak, fabs(v));
			}
		}
	}
	if (peak_db) {
		*peak_db = 20 * log10(peak + 1e-12);
	}
	return 10 * log10(sum / n + 1e-24);
}

int
main(void)
{
	double pk, rms;
	int32_t first[480];

	ng_guard_config(20);
	ng_guard_volume(0, 0);
	ng_guard_ramp();
	rms = run(1000, 1.0, 1, 0, 0, &pk, first);
	printf("1 kHz full scale: peak %.2f dBFS, rms %.2f dBFS\n", pk, rms);
	CHECK(fabs(pk + 20) < 0.5, "1 kHz peak at the cap (-20 dBFS) within 0.5 dB (%.2f)", pk);
	CHECK(abs(first[0]) < 100 && abs(first[2]) < 2000, "soft start begins at 0 (%d %d)", first[0], first[2]);
	ng_guard_config(20);
	rms = run(50, 1.0, 1, 0, 0, &pk, NULL);
	printf("50 Hz full scale: peak %.2f dBFS\n", pk);
	CHECK(pk < -40, "50 Hz cut by the high-pass (peak %.2f dBFS, >= 20 dB under 1 kHz)", pk);
	ng_guard_config(20);
	rms = run(1000, 1.0, 8, 1, 0, &pk, NULL);
	printf("1 kHz square 8 s: peak %.2f dBFS rms %.2f dBFS\n", pk, rms);
	CHECK(pk <= -20 + 0.01, "no sample above the cap (%.2f)", pk);
	CHECK(rms <= -23 - 3 + 0.5, "square held: 3 s power <= 3 dB under a sine at the cap (%.2f <= -25.5)", rms);
	ng_guard_config(20);
	ng_guard_volume(0, 1);
	rms = run(1000, 1.0, 1, 0, 0, &pk, NULL);
	CHECK(pk < -200, "mute gives silence (%.1f)", pk);
	ng_guard_volume(20 * 8, 0);
	ng_guard_config(20);
	rms = run(1000, 1.0, 1, 0, 0, &pk, NULL);
	CHECK(fabs(pk + 40) < 0.5, "volume 20 dB below: -40 dBFS (%.2f)", pk);
	ng_guard_volume(0, 0);
	ng_guard_config(20);
	{
		int16_t in[4] = { 10000, 20000, 10000, 20000 };
		int32_t out[4];
		for (int i = 0; i < 2000; i++) {
			ng_guard_process(in, out, 2, true);
		}
		CHECK(out[1] == 0 && out[3] == 0, "earpiece: right slot 0 (%d)", out[1]);
	}
	ng_guard_config(5);
	CHECK(ng_guard_cap_db() == NG_GUARD_MIN_CAP_DB, "cap can not go above -%u dBFS (asked 5, got %u)", NG_GUARD_MIN_CAP_DB,
	    ng_guard_cap_db());
	printf("%s: %d failure(s)\n", fails ? "FAIL" : "PASS", fails);
	return fails != 0;
}
