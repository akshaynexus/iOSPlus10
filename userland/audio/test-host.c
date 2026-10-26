/*
 * Host test of NegroniAudio (macOS build of the same source): a small stand-in for the HAL.
 * Loads the bundle executable, calls the factory, and checks what VirtualAudio needs
 * (docs/audio-plan.md stage 0): four devices by UID, stream formats, the volume control, the
 * clock, and I/O without /dev/negroni-audio (the samples are dropped, nothing blocks).
 * Stage 1: with a FIFO as the device node (NEGRONI_AUDIO_TEST_PATH, host build only): the ring
 * overflows and counts the dropped frames while nobody reads; then a reader thread gets every
 * frame in order (ring wrap, partial writes of the FIFO) and frames in = out + dropped.
 *   out/audio/host/test-host out/audio/host/NegroniAudio [FIFO] (userland/audio/build.sh runs it)
 */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "AudioServerPlugIn.h"

static int failures;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); failures++; } } while (0)

static OSStatus
changed(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a)
{
	(void)h; (void)o; (void)n; (void)a;
	return 0;
}

static const AudioServerPlugInHostInterface host_if = { changed, NULL, NULL, NULL, NULL };

static AudioServerPlugInDriverRef drv;

static UInt32
get(AudioObjectID o, UInt32 sel, UInt32 scope, UInt32 qsize, const void *q, void *out, UInt32 room)
{
	AudioObjectPropertyAddress a = { sel, scope, 0 };
	UInt32 size = 0;

	if (!(*drv)->HasProperty(drv, o, 0, &a)) {
		return 0;
	}
	if ((*drv)->GetPropertyData(drv, o, 0, &a, qsize, q, room, &size, out) != 0) {
		return 0;
	}
	return size;
}

/* The FIFO reader: checks each frame (left = n, right = ~n, n counts up with gaps from drops). */
static int fifo_fd = -1, reader_stop;
static UInt64 got_frames, bad_frames;
static UInt32 last_n;

static void *
reader(void *arg)
{
	static uint8_t buf[8192], part[4];
	unsigned have = 0;

	(void)arg;
	while (!__atomic_load_n(&reader_stop, __ATOMIC_ACQUIRE)) {
		ssize_t n = read(fifo_fd, buf, sizeof(buf));
		if (n <= 0) {
			usleep(1000);
			continue;
		}
		for (ssize_t i = 0; i < n; i++) {
			part[have++] = buf[i];
			if (have == 4) {
				uint16_t l = (uint16_t)(part[0] | part[1] << 8), r = (uint16_t)(part[2] | part[3] << 8);
				if ((uint16_t)~l != r) {
					bad_frames++;
				}
				last_n = l;
				got_frames++;
				have = 0;
			}
		}
	}
	return NULL;
}

static void
fill(int16_t *buf, UInt32 frames, UInt32 *counter)
{
	for (UInt32 i = 0; i < frames; i++, (*counter)++) {
		buf[2 * i] = (int16_t)(uint16_t)*counter;
		buf[2 * i + 1] = (int16_t)(uint16_t)~(uint16_t)*counter;
	}
}

int
main(int argc, char **argv)
{
	const char *fifo = argc > 2 ? argv[2] : NULL;

	if (fifo != NULL) {
		(void)unlink(fifo);
		if (mkfifo(fifo, 0600) != 0 || (fifo_fd = open(fifo, O_RDONLY | O_NONBLOCK)) < 0) {
			printf("FAIL: no FIFO %s: %s\n", fifo, strerror(errno));
			return 1;
		}
		/* phase 1 (no node) runs before the path is given: open a path that does not exist */
		setenv("NEGRONI_AUDIO_TEST_PATH", "/nonexistent/negroni-audio", 1);
	}
	void *h = dlopen(argc > 1 ? argv[1] : "NegroniAudio", RTLD_NOW);
	void *(*create)(CFAllocatorRef, CFUUIDRef);
	UInt32 words[8], n;
	CFStringRef s;
	AudioStreamBasicDescription f;

	if (h == NULL || (create = (void *(*)(CFAllocatorRef, CFUUIDRef))dlsym(h, "NegroniAudio_Create")) == NULL) {
		printf("FAIL: cannot load the bundle: %s\n", dlerror());
		return 1;
	}
	CHECK(create(NULL, kAudioServerPlugInDriverInterfaceUUID) == NULL, "factory answers a wrong type");
	drv = create(NULL, kAudioServerPlugInTypeUUID);
	CHECK(drv != NULL, "no driver");
	if (drv == NULL) {
		return 1;
	}
	void *iface = NULL;
	CHECK((*drv)->QueryInterface(drv, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &iface) == S_OK && iface == drv,
	    "QueryInterface");
	CHECK((*drv)->Initialize(drv, &host_if) == 0, "Initialize");

	/* the plug-in's devices, by UID */
	n = get(1, 'dev#', 'glob', 0, NULL, words, sizeof(words));
	CHECK(n == 16, "device list %u bytes", n);
	const char *uids[] = { "Speaker", "Hawking", "Actuator", "Codec" };
	AudioObjectID ids[4] = { 0 };
	for (int i = 0; i < 4; i++) {
		CFStringRef uid = CFStringCreateWithCString(NULL, uids[i], kCFStringEncodingUTF8);
		CHECK(get(1, 'uidd', 'glob', sizeof(uid), &uid, &ids[i], sizeof(ids[i])) == 4 && ids[i] != 0, "UID %s", uids[i]);
		CHECK(get(ids[i], 'uid ', 'glob', 0, NULL, &s, sizeof(s)) == sizeof(s) && CFEqual(s, uid), "device UID %s", uids[i]);
		if (s) {
			CFRelease(s);
		}
		CFRelease(uid);
	}
	CFStringRef none = CFSTR("Receiver");
	CHECK(get(1, 'uidd', 'glob', sizeof(none), &none, words, 4) == 4 && words[0] == 0, "unknown UID gives 0");

	/* Speaker: one output stream, stereo 16-bit 48 kHz; one input stream; volume control */
	n = get(ids[0], 'stm#', 'outp', 0, NULL, words, sizeof(words));
	CHECK(n == 4, "Speaker output streams %u bytes", n);
	AudioObjectID out = words[0];
	CHECK(get(out, 'sfmt', 'glob', 0, NULL, &f, sizeof(f)) == sizeof(f) && f.mSampleRate == 48000 && f.mChannelsPerFrame == 2 &&
	    f.mBitsPerChannel == 16 && f.mBytesPerFrame == 4, "Speaker format");
	CHECK(get(out, 'sdir', 'glob', 0, NULL, words, 4) == 4 && words[0] == 0, "output direction");
	CHECK(get(ids[0], 'stm#', 'inpt', 0, NULL, words, sizeof(words)) == 4, "Speaker input stream");
	CHECK(get(ids[1], 'stm#', 'outp', 0, NULL, words, sizeof(words)) == 0, "Hawking has no output");
	CHECK(get(ids[1], 'stm#', 'inpt', 0, NULL, words, sizeof(words)) == 4, "Hawking input");
	CHECK(get(ids[0], 'dflt', 'glob', 0, NULL, words, 4) == 4 && words[0] == 1, "Speaker can be default");
	CHECK(get(ids[3], 'dflt', 'glob', 0, NULL, words, 4) == 4 && words[0] == 0, "Codec cannot be default output");
	n = get(ids[0], 'ctrl', 'glob', 0, NULL, words, sizeof(words));
	CHECK(n == 4, "Speaker control list");
	AudioObjectID vol = words[0];
	Float32 v = 0.5f;
	AudioObjectPropertyAddress va = { 'lcsv', 'glob', 0 };
	CHECK((*drv)->SetPropertyData(drv, vol, 0, &va, 0, NULL, sizeof(v), &v) == 0, "set volume");
	CHECK(get(vol, 'lcdv', 'glob', 0, NULL, &v, sizeof(v)) == 4 && v > -24.01f && v < -23.99f, "volume 0.5 = -24 dB (%f)", v);
	v = -48.0f;
	CHECK(get(vol, 'lcds', 'glob', 0, NULL, &v, sizeof(v)) == 4 && v == 0.0f, "-48 dB -> 0");
	n = get(ids[3], 'ctrl', 'glob', 0, NULL, words, sizeof(words));
	CHECK(n == 4 && get(words[0], 'scci', 'glob', 0, NULL, words + 1, 4) == 4 && words[1] == 'imic', "Codec data source imic");
	CHECK(get(ids[0], 'zzzz', 'glob', 0, NULL, words, 4) == 0, "unknown property is absent");

	/* I/O: the clock runs from StartIO; writes never block without the device node */
	Float64 st;
	UInt64 ht, seed;
	CHECK((*drv)->StartIO(drv, ids[0], 1) == 0, "StartIO");
	usleep(400000);         /* 19200 frames > one 16384-frame period */
	CHECK((*drv)->GetZeroTimeStamp(drv, ids[0], 1, &st, &ht, &seed) == 0 && st == 16384.0, "zero time stamp %f", st);
	static int16_t buf[512 * 2];
	UInt64 t0 = mach_absolute_time();
	for (int i = 0; i < 1000; i++) {
		CHECK((*drv)->DoIOOperation(drv, ids[0], out, 1, 'rite', 512, NULL, buf, NULL) == 0, "DoIO write");
	}
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	UInt64 us = (mach_absolute_time() - t0) * tb.numer / tb.denom / 1000;
	CHECK(us < 200000, "1000 writes took %llu us", us);
	memset(buf, 0x55, sizeof(buf));
	CHECK((*drv)->DoIOOperation(drv, ids[1], ids[1] + 1, 1, 'read', 256, NULL, buf, NULL) == 0 && buf[0] == 0 && buf[255] == 0 &&
	    buf[256] == 0x5555, "Hawking input is 256 mono frames of silence");
	CHECK((*drv)->StopIO(drv, ids[0], 1) == 0, "StopIO");

	void (*stats)(UInt64 *) = (void (*)(UInt64 *))dlsym(h, "NegroniAudio_TestStats");
	if (fifo != NULL && stats != NULL) {
		UInt64 st4[4];
		UInt32 counter = 0;
		pthread_t rt;

		stats(st4);
		CHECK(st4[0] == 512000 && st4[1] == 512000 && st4[2] == 0, "no node: %llu in, %llu dropped, %llu bytes out", st4[0],
		    st4[1], st4[2]);
		/* phase 2: the FIFO as the node, nobody reads: the FIFO fills, then the ring; the rest is dropped */
		setenv("NEGRONI_AUDIO_TEST_PATH", fifo, 1);
		(*drv)->Initialize(drv, &host_if);      /* takes the new path (host build only) */
		CHECK((*drv)->StartIO(drv, ids[0], 1) == 0, "StartIO 2");
		t0 = mach_absolute_time();
		for (int i = 0; i < 200; i++) {         /* 102400 frames, > FIFO + ring (16384 frames) */
			fill(buf, 512, &counter);
			CHECK((*drv)->DoIOOperation(drv, ids[0], out, 1, 'rite', 512, NULL, buf, NULL) == 0, "DoIO write 2");
			if (i % 20 == 0) {
				usleep(6000);           /* let the writer run */
			}
		}
		us = (mach_absolute_time() - t0) * tb.numer / tb.denom / 1000;
		usleep(30000);
		stats(st4);
		CHECK(st4[0] == 102400 && st4[1] > 0 && st4[3] > 0 && st4[0] == st4[2] / 4 + st4[1] + st4[3] / 4,
		    "overflow: %llu in, %llu dropped, %llu frames out, %llu waiting", st4[0], st4[1], st4[2] / 4, st4[3] / 4);
		printf("overflow: %llu frames in, %llu dropped, %llu to the FIFO, %llu waiting in the ring\n", st4[0], st4[1],
		    st4[2] / 4, st4[3] / 4);
		/* phase 3: a reader: everything waiting arrives, then 300 paced periods arrive without a drop */
		pthread_create(&rt, NULL, reader, NULL);
		usleep(100000);
		stats(st4);
		CHECK(st4[3] == 0, "ring not drained: %llu bytes", st4[3]);
		UInt64 dropped_before = st4[1];
		for (int i = 0; i < 300; i++) {         /* 300 x 512 frames = 9.4 ring wraps */
			fill(buf, 512, &counter);
			CHECK((*drv)->DoIOOperation(drv, ids[0], out, 1, 'rite', 512, NULL, buf, NULL) == 0, "DoIO write 3");
			usleep(2000);
		}
		usleep(100000);
		CHECK((*drv)->StopIO(drv, ids[0], 1) == 0, "StopIO 2");
		usleep(20000);
		__atomic_store_n(&reader_stop, 1, __ATOMIC_RELEASE);
		pthread_join(rt, NULL);
		stats(st4);
		CHECK(st4[1] == dropped_before, "drops with a reader: %llu -> %llu", dropped_before, st4[1]);
		CHECK(got_frames == st4[2] / 4 && got_frames == st4[0] - st4[1], "FIFO got %llu frames, plug-in says %llu out, %llu in - %llu dropped",
		    got_frames, st4[2] / 4, st4[0], st4[1]);
		CHECK(bad_frames == 0 && last_n == (uint16_t)(counter - 1), "%llu torn frames, last %u of %u", bad_frames, last_n,
		    (unsigned)(uint16_t)(counter - 1));
		printf("ring: %llu frames through the FIFO, %llu dropped (all in the overflow phase), 0 torn\n", got_frames, st4[1]);
		close(fifo_fd);
		unlink(fifo);
	} else if (fifo != NULL) {
		CHECK(0, "no NegroniAudio_TestStats: build with -DNEGRONI_AUDIO_HOST_TEST");
	}

	/*
	 * The Actuator (haptics, patch 0302): silence is not sent; sound + 20 ms after it goes to the
	 * node (a FIFO here) in order; without the node it is dropped and nothing blocks.
	 */
	void (*hstats)(UInt64 *) = (void (*)(UInt64 *))dlsym(h, "NegroniAudio_TestHapticStats");
	if (fifo != NULL && hstats != NULL) {
		char hfifo[1024];
		UInt64 hs[4];
		static int16_t mono[480];
		int hfd;

		snprintf(hfifo, sizeof(hfifo), "%s.haptic", fifo);
		(void)unlink(hfifo);
		CHECK(mkfifo(hfifo, 0600) == 0 && (hfd = open(hfifo, O_RDONLY | O_NONBLOCK)) >= 0, "haptic FIFO");
		setenv("NEGRONI_HAPTIC_TEST_PATH", hfifo, 1);
		(*drv)->Initialize(drv, &host_if);
		n = get(ids[2], 'stm#', 'outp', 0, NULL, words, sizeof(words));
		CHECK(n == 4, "Actuator output stream");
		AudioObjectID act = words[0];
		CHECK(get(act, 'sfmt', 'glob', 0, NULL, &f, sizeof(f)) == sizeof(f) && f.mSampleRate == 48000 && f.mChannelsPerFrame == 1 &&
		    f.mBitsPerChannel == 16, "Actuator format S16 mono 48 kHz");
		CHECK((*drv)->StartIO(drv, ids[2], 1) == 0, "Actuator StartIO");
		memset(mono, 0, sizeof(mono));
		for (int i = 0; i < 50; i++) {          /* 500 ms of silence: none of it is sent */
			CHECK((*drv)->DoIOOperation(drv, ids[2], act, 1, 'rite', 480, NULL, mono, NULL) == 0, "Actuator silence");
		}
		for (int i = 0; i < 480; i++) {         /* one 10 ms tap: a 200 Hz sine, peak 20000 */
			mono[i] = (int16_t)(20000.0 * __builtin_sin(2 * 3.141592653589793 * 200.0 * i / 48000.0));
		}
		CHECK((*drv)->DoIOOperation(drv, ids[2], act, 1, 'rite', 480, NULL, mono, NULL) == 0, "Actuator tap");
		memset(mono, 0, sizeof(mono));
		for (int i = 0; i < 10; i++) {          /* 100 ms of silence: the first 20 ms (960 frames) go too */
			CHECK((*drv)->DoIOOperation(drv, ids[2], act, 1, 'rite', 480, NULL, mono, NULL) == 0, "Actuator silence 2");
		}
		usleep(60000);
		UInt64 got = 0, loud = 0;
		static int16_t rb[8192];
		ssize_t r;
		while ((r = read(hfd, rb, sizeof(rb))) > 0) {
			for (ssize_t i = 0; i < r / 2; i++) {
				loud += rb[i] > 256 || rb[i] < -256;
			}
			got += (UInt64)r / 2;
		}
		CHECK((*drv)->StopIO(drv, ids[2], 1) == 0, "Actuator StopIO");
		hstats(hs);
		CHECK(hs[0] == 61 * 480 && hs[1] == 480 + 960 && hs[2] == 0 && hs[3] == 50 * 480 + 8 * 480,
		    "Actuator: %llu in, %llu sent, %llu dropped, %llu skipped", hs[0], hs[1], hs[2], hs[3]);
		CHECK(got == 480 + 960 && loud > 300, "haptic FIFO got %llu frames (%llu loud)", got, loud);
		printf("actuator: %llu frames in, %llu to the node (%llu loud), %llu silent not sent\n", hs[0], got, loud, hs[3]);
		close(hfd);
		unlink(hfifo);
	} else if (fifo != NULL) {
		CHECK(0, "no NegroniAudio_TestHapticStats: build with -DNEGRONI_AUDIO_HOST_TEST");
	}

	printf("%s: %d failure(s)\n", failures ? "FAIL" : "PASS", failures);
	return failures != 0;
}
