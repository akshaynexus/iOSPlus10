/* The run of cam5_test.c: included there, after the mock kernel and the mock graph. */
int
main(int argc, char **argv)
{
	CMBaseObjectRef device = NULL, o;
	long frames = argc > 1 ? atol(argv[1]) : 600;

	k.raw[0] = calloc(1, (size_t)(PW / 4 * 5) * PH);
	k.raw[1] = calloc(1, (size_t)(SW / 4 * 5) * SH);
	mock_cv_init();
	long base_objects = mock_live_objects;

	CHECK(negroni_camera_device_create(NULL, NULL, (void *)&device) == 0, "the device is not made");
	o = (CMBaseObjectRef)CFArrayGetValueAtIndex(((struct device *)derived_storage(device))->streams, 0);

	/* the graph's settings, as in the log */
	CFMutableDictionaryRef configs = CFDictionaryCreateMutable(NULL, 0, NULL, NULL), handlers = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
	CFMutableDictionaryRef enabled = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
	static const char *const names[2] = { "PrimaryScaler", "StillImage" };
	const uint32_t sizes[2][2] = { { 1504, 1128 }, { 4032, 3024 } };
	void (^picture)(CVPixelBufferRef, CMTime) = ^(CVPixelBufferRef pb, CMTime t) { graph_take(pb, false); };
	void (^still)(CVPixelBufferRef, CMTime) = ^(CVPixelBufferRef pb, CMTime t) { graph_take(pb, true); };

	for (int i = 0; i < 2; i++) {
		CFMutableDictionaryRef c = CFDictionaryCreateMutable(NULL, 0, NULL, NULL), h = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
		CFDictionaryRef pool = mock_pool(sizes[i][0], sizes[i][1], PF_420F);
		CFStringRef name = CFStringCreateWithCString(NULL, names[i], 0);

		CFDictionarySetValue(c, CFSTR("BufferPool"), pool);
		CFDictionarySetValue(h, CFSTR("PixelBufferHandler"), i ? (const void *)still : (const void *)picture);
		CFDictionarySetValue(configs, name, c);
		CFDictionarySetValue(handlers, name, h);
		CFDictionarySetValue(enabled, name, kCFBooleanTrue);
		CFRelease(c);
		CFRelease(h);
		CFRelease(pool);
		CFRelease(name);
	}
	/* phase 1: frames, no graph (mediaserverd pid 28's first session: 179 frames, footprint 15 MiB after it) */
	(void)stream_begin(o, false);
	until_seq(60);
	size_t h0 = heap();
	long o0 = mock_live_objects;

	until_seq(60 + (uint64_t)frames);
	size_t h1 = heap();

	printf("cam5: no graph: %ld frames: heap %+ld bytes, objects %+ld\n", frames, (long)(h1 - h0), mock_live_objects - o0);
	/* phase 2: pictures */
	CHECK(stream_set_property(o, CFSTR("VideoOutputConfigurations"), configs) == 0, "configs");
	CHECK(stream_set_property(o, CFSTR("VideoOutputHandlers"), handlers) == 0, "handlers");
	CHECK(stream_set_property(o, CFSTR("VideoOutputsEnabled"), enabled) == 0, "enabled");
	CFRelease(configs);
	CFRelease(handlers);
	CFRelease(enabled);
	(void)stream_begin(o, true);
	while (pictures < 60) {
		usleep(2000);
	}
	h0 = heap();
	o0 = mock_live_objects;
	long b0 = mock_live_buffers, p0 = pictures;

	while (pictures < p0 + frames) {
		usleep(2000);
	}
	h1 = heap();
	long grown = (long)(h1 - h0), n = pictures - p0;

	printf("cam5: pictures: %ld given: heap %+ld bytes = %+.1f bytes a picture, objects %+ld, live buffers %+ld (made %ld)\n", n, grown, (double)grown / (double)n,
	    mock_live_objects - o0, mock_live_buffers - b0, mock_buffers_made);
	/* (a kept pixel buffer more or less moves the sum by one buffer: 1504 x 1128 x 2) */
	/* (under AddressSanitizer heap() says 0 always: its own leak check is the test there; a buffer let go in this window then read as growth) */
	CHECK((h0 == 0 && h1 == 0) || grown - (mock_live_buffers - b0) * 1504 * 1128 * 2 < 64 * 1024, "the heap grows with the pictures: %ld bytes", grown);
	CHECK(mock_live_buffers <= HELD + 4 + 1, "live buffers %ld", mock_live_buffers);
	CHECK(md_missing == 0, "%ld pictures without metadata", md_missing);
#ifndef OLD_SOURCE
	CHECK(abs((int)k.focus - BEST_FOCUS) <= 60, "the first sweep ended at %u, the sharpest is at %d", k.focus, BEST_FOCUS);
	printf("cam5: focus: first sweep: lens at %u (sharpest %d)\n", k.focus, BEST_FOCUS);
	/* photographs: the mode is asked for, the frame taken, the preview comes back; the lens stays */
	for (int i = 0; i < 3; i++) {
		long before = photos, sw = k.switches;
		uint32_t lens = k.focus;

		CHECK(stream_set_property(o, CFSTR("StillImageCaptureNow"), kCFBooleanTrue) == 0, "shutter");
		while (photos == before) {
			usleep(2000);
		}
		uint64_t s = k.seq;

		until_seq(s + 5);
		CHECK(k.mode == 0 && k.switches == sw + 2, "photograph %d: mode %d, %ld switches", i, k.mode, k.switches - sw);
		CHECK(k.focus == lens, "the lens moved in a photograph: %u -> %u", lens, k.focus);
		CHECK(photo_width == 4032, "photograph width %ld", photo_width);
	}
	/* the tap */
	k.focus = 200;
	long scans = seen_status2;

	CHECK(stream_set_property(o, CFSTR("AutoFocusNow"), kCFBooleanTrue) == 0, "tap");
	until_seq(k.seq + 150);
	CHECK(seen_status2 > scans && abs((int)k.focus - BEST_FOCUS) <= 60, "tap: lens at %u", k.focus);
	CHECK(seen_status0_after > 0, "AFStatus does not come back to rest");
	printf("cam5: tap: lens at %u, %ld pictures said a focus scan\n", k.focus, seen_status2);
	dark_run(o);
#endif
	(void)stream_stop(o);
	for (int i = 0; i < 4; i++) {
		if (kept[i] != NULL) {
			CVPixelBufferRelease(kept[i]);
		}
	}
	CHECK(mock_live_buffers == 0, "%ld buffers kept after the stop", mock_live_buffers);
	CFRelease(device);
	printf("cam5: after the stop: objects %ld (said-once names %ld), buffers %ld, pictures %ld, photographs %ld\n", mock_live_objects - base_objects,
	    said_names ? CFDictionaryGetCount((CFDictionaryRef)said_names) : 0L, mock_live_buffers, pictures, photos);
	long left = mock_live_objects - base_objects - (said_names ? 1 + CFDictionaryGetCount((CFDictionaryRef)said_names) : 0);

	CHECK(left == 0, "%ld objects left", left);
	if (left != 0) {
		mock_dump_live();
	}
	free(k.raw[0]);
	free(k.raw[1]);
	printf("cam5: %s\n", failed ? "FAILED" : "OK");
	return failed ? 1 : 0;
}
