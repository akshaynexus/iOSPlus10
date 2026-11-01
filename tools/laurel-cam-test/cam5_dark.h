/*
 * The run with no light (laurel): frames of noise cut at black, as every frame of boot 20:02. A tap and the first sweep do not move the lens and
 * do not hold a photograph back (AFStatus 0); the shutter still gives a picture; when light comes the tap is done. A failed buffer pool is
 * covered too: a photograph asked for while the pool refuses comes when the pool gives one, and the preview comes back.
 */
#ifndef OLD_SOURCE
static void
dark_run(CMBaseObjectRef o)
{
	uint32_t lens = 300;
	long before = photos, sw;

	k.focus = lens;
	k.dark = true;
	until_seq(k.seq + 12);
	lens = k.focus;         /* (a walk that was under way has ended) */
	until_seq(k.seq + 4);
	long scans = seen_status2;

	CHECK(stream_set_property(o, CFSTR("AutoFocusNow"), kCFBooleanTrue) == 0, "tap in the dark");
	until_seq(k.seq + 80);
	CHECK(k.focus == lens, "a tap in the dark moved the lens: %u -> %u", lens, k.focus);
	CHECK(seen_status2 == scans, "a focus scan in the dark: %ld pictures", seen_status2 - scans);
	CHECK(stream_set_property(o, CFSTR("StillImageCaptureNow"), kCFBooleanTrue) == 0, "shutter in the dark");
	while (photos == before) {
		usleep(2000);
	}
	CHECK(photo_width == 4032, "dark photograph width %ld", photo_width);
	until_seq(k.seq + 5);
	CHECK(k.mode == 0, "dark photograph: the preview did not come back (mode %d)", k.mode);
	CHECK(k.focus == lens, "the lens moved in a dark photograph: %u -> %u", lens, k.focus);
	printf("cam5: no light: tap and shutter: lens stays at %u, %ld photographs, no scan\n", lens, photos);
	/* light again: the tap that waited */
	k.dark = false;
	until_seq(k.seq + 150);
	CHECK(seen_status2 > scans && abs((int)k.focus - BEST_FOCUS) <= 60, "light again: lens at %u", k.focus);
	printf("cam5: light again: lens at %u\n", k.focus);
	/* the pool refuses a photograph 10 times: it comes at the third try, and the preview returns */
	before = photos;
	sw = k.switches;
	mock_pool_refuse = 10;      /* (4 asks per try, HELD + 1) */
	CHECK(stream_set_property(o, CFSTR("StillImageCaptureNow"), kCFBooleanTrue) == 0, "shutter, pool refuses");
	while (photos == before) {
		usleep(2000);
	}
	until_seq(k.seq + 5);
	CHECK(mock_pool_refuse == 0, "the pool was asked too few times: %d left", mock_pool_refuse);
	CHECK(k.mode == 0 && k.switches == sw + 2, "after the refusal: mode %d, %ld switches", k.mode, k.switches - sw);
	printf("cam5: a pool that refuses: the photograph at a later try\n");
}
#endif
