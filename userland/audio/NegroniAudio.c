/*
 * NegroniAudio.driver: the CoreAudio HAL output device of iOS 16 on the OnePlus 10 Pro
 * (NE2211, SM8450). Stage 0 and stage d of docs/audio-plan.md.
 *
 * Adapted from HackiOS userland/src/audio_plugin.c (external/hackios-xnu-userland, commit
 * a79ff07), which plays iOS 16.5 sound with the same iPhone X (D22) identity. That code is
 * under the MIT licence:
 *
 *   Copyright (c) 2026 OOSEX GANG
 *
 *   Permission is hereby granted, free of charge, to any person obtaining a copy of this
 *   software and associated documentation files (the "Software"), to deal in the Software
 *   without restriction, including without limitation the rights to use, copy, modify, merge,
 *   publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
 *   to whom the Software is furnished to do so, subject to the following conditions:
 *
 *   The above copyright notice and this permission notice shall be included in all copies or
 *   substantial portions of the Software.
 *
 *   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 *   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
 *   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
 *   FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 *   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 *   DEALINGS IN THE SOFTWARE.
 *
 * Why it exists (docs/audio-plan.md stage 0): without an audio device, mediaserverd aborts
 * (std::terminate from a dispatch block: an uncaught C++ exception, logs/usblog-20261024-195455.txt,
 * scripts/debug/symbolicate.sh). The slop root tweaks remove VirtualAudio.plugin; then the HAL has
 * only CoreAudio's Null_Device and the routing layer has no route. VirtualAudio knows the iPhone
 * devices by UID and builds the speaker route only when these exist (HackiOS, verified on D22):
 *
 *   "Speaker"   stereo output -> /dev/negroni-audio (dropped while the node does not exist),
 *               plus a silent stereo input (on an iPhone: the amplifier sense data)
 *   "Hawking"   one silent input: the 'vhaw' companion of the default virtual device
 *   "Actuator"  one mono output (Taptic Engine haptics) -> /dev/negroni-haptic (patch 0302; the
 *               motor path of the kernel, see haptic_put()); dropped while the node does not exist
 *   "Codec"     one mono input (built-in mic, data source 'imic'): silence
 *
 * Clock: the system clock. The device says it plays NEGRONI_AUDIO_RATE frames per second of
 * mach_absolute_time(); the HAL I/O thread paces itself by that, with or without hardware.
 *
 * Volume: the Speaker output has a volume control (48 dB, linear in dB). Its value goes to the
 * kernel (NEGRONI_AUDIO_SET_VOLUME); the kernel adds it to its own safe maximum. HackiOS
 * observation: VirtualAudio sets it once to 0 dB and keeps the D22 speaker in software volume
 * mode, so iOS scales the samples itself.
 *
 * Stage 1 (I/O path): the HAL real-time I/O thread never makes a system call. WriteMix copies
 * the Speaker frames into a lock-free single-producer/single-consumer ring (RING_BYTES, 341 ms).
 * A writer thread (made at the Speaker's first StartIO, joined at its last StopIO) drains the
 * ring into /dev/negroni-audio every WRITER_NS. The kernel copies write() data into the APM
 * shared-memory ring of the ADSP graph (patches/xnu 0243+). Bytes the kernel does not take stay
 * in the ring for the next round. A full ring drops the new frames (counted). ENODEV (no sink):
 * the waiting frames are dropped (counted), the node stays open. Other write errors close the
 * node; the writer opens it again at most every 2 s.
 *
 * Log lines start "NegroniAudio:" (stderr, as HackiOS does).
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "negroni_audio.h"
#include "negroni_haptic.h"

#include "AudioServerPlugIn.h"

/* ---- the objects ---- */

enum {
	OBJECT_PLUGIN = 1,
	OBJECT_SPEAKER, OBJECT_SPEAKER_OUTPUT, OBJECT_SPEAKER_INPUT,
	OBJECT_HAWKING, OBJECT_HAWKING_INPUT,
	OBJECT_ACTUATOR, OBJECT_ACTUATOR_OUTPUT,
	OBJECT_CODEC, OBJECT_CODEC_INPUT,
	OBJECT_SPEAKER_VOLUME,          /* volume control of the Speaker output */
	OBJECT_CODEC_SOURCE,            /* data source control of the Codec input */
	OBJECT_LAST = OBJECT_CODEC_SOURCE
};

#define VOLUME_RANGE_DB         48.0
#define TRANSPORT_BUILT_IN      'bltn'
#define MIC_SOURCE              'imic'  /* VirtualAudio keeps only data sources it knows (HackiOS) */
#define MANUFACTURER            CFSTR("iOSPlus10")
#define TIMESTAMP_PERIOD        16384   /* frames between zero time stamps; the largest HAL buffer */
#define REOPEN_NS               2000000000ull   /* try /dev/negroni-audio again at most every 2 s */

struct device {
	AudioObjectID object;
	CFStringRef uid;
	AudioObjectID output, input;
	UInt32 output_channels, input_channels;
	unsigned running;
	UInt64 anchor;                  /* mach_absolute_time() at the first StartIO (0: never started) */
};

static struct device devices[] = {
	{ .object = OBJECT_SPEAKER, .uid = CFSTR("Speaker"), .output = OBJECT_SPEAKER_OUTPUT, .input = OBJECT_SPEAKER_INPUT,
	  .output_channels = NEGRONI_AUDIO_CHANNELS, .input_channels = 2 },
	{ .object = OBJECT_HAWKING, .uid = CFSTR("Hawking"), .input = OBJECT_HAWKING_INPUT, .input_channels = 1 },
	{ .object = OBJECT_ACTUATOR, .uid = CFSTR("Actuator"), .output = OBJECT_ACTUATOR_OUTPUT, .output_channels = 1 },
	{ .object = OBJECT_CODEC, .uid = CFSTR("Codec"), .input = OBJECT_CODEC_INPUT, .input_channels = 1 },
};
#define DEVICES                 (sizeof(devices) / sizeof(devices[0]))

static AudioServerPlugInHostRef host;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t io_lock = PTHREAD_MUTEX_INITIALIZER;     /* StartIO/StopIO (writer start and join); the writer never takes it */
static int sink = -1;                   /* /dev/negroni-audio, -1 = not open; changed by the writer only, under lock */
static UInt64 sink_tried;               /* mach_absolute_time() of the last open() */
static int sink_last_errno = -1;        /* errno of the last failed open(), -1 = none yet; writer thread only */
static const char *sink_path = NEGRONI_AUDIO_DEVICE;

/*
 * The Speaker ring: bytes of S16LE stereo frames. head: bytes put in by the I/O thread (the only
 * producer), tail: bytes taken out by the writer thread (the only consumer). Both only grow; the
 * index in ring[] is the count modulo RING_BYTES. The producer reads tail with acquire and writes
 * head with release after the copy; the consumer does the opposite.
 */
#define RING_FRAMES             16384u  /* 341 ms at 48 kHz, a power of two */
#define RING_BYTES              (RING_FRAMES * NEGRONI_AUDIO_FRAME)
#define WRITER_NS               5000000ull      /* the writer drains the ring every 5 ms */
_Static_assert((RING_BYTES & (RING_BYTES - 1)) == 0, "the ring size must be a power of two");
static uint8_t ring[RING_BYTES];
static UInt64 ring_head, ring_tail;     /* atomics */
static UInt64 frames_in, frames_dropped, bytes_out;     /* atomics: since the Speaker started */
static pthread_t writer;
static bool writer_on;                  /* under lock: a writer thread exists */
static int writer_stop;                 /* atomic: 1 = the writer must end */
static Float64 ticks_per_frame;
static UInt64 ns_numer = 1, ns_denom = 1;
static Boolean inactive[OBJECT_LAST + 1];
static Float32 volume = 1.0f;

static void
say(const char *format, ...)
{
	char line[256];
	va_list ap;
	int n;

	memcpy(line, "NegroniAudio: ", 14);
	va_start(ap, format);
	n = vsnprintf(line + 14, sizeof(line) - 15, format, ap);
	va_end(ap);
	if (n < 0) {
		return;
	}
	n = n + 14 > (int)sizeof(line) - 2 ? (int)sizeof(line) - 2 : n + 14;
	line[n++] = '\n';
	(void)write(2, line, (size_t)n);
}

static Float32
scalar_to_db(Float32 scalar)
{
	scalar = scalar < 0 ? 0 : scalar > 1 ? 1 : scalar;
	return (Float32)(-VOLUME_RANGE_DB * (1.0 - scalar));
}

static Float32
db_to_scalar(Float32 db)
{
	Float32 scalar = (Float32)(1.0 + db / VOLUME_RANGE_DB);

	return scalar < 0 ? 0 : scalar > 1 ? 1 : scalar;
}

/* With the lock held. */
static void
volume_to_kernel(void)
{
	struct negroni_audio_volume v = { (uint32_t)lround(-scalar_to_db(volume) * 8), volume <= 0 };

	if (sink < 0) {
		return;
	}
	if (ioctl(sink, NEGRONI_AUDIO_SET_VOLUME, &v) < 0) {
		say("volume %.3f not given to the kernel (%s)", volume, strerror(errno));
		return;
	}
	say("volume %.3f: %s%.1f dB below the kernel maximum", volume, v.muted ? "muted, " : "", v.below / 8.0);
}

/*
 * Open /dev/negroni-audio if it is not open. The node exists only with the kernel audio stage;
 * without it the samples are dropped (stage 0). With the lock held; called from the writer
 * thread only (never the I/O thread), so open() may take its time.
 */
static void
sink_open(void)
{
	UInt64 now = mach_absolute_time();

	if (sink >= 0 || (sink_tried != 0 && (now - sink_tried) * ns_numer / ns_denom < REOPEN_NS)) {
		return;
	}
	sink_tried = now;
	sink = open(sink_path, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (sink >= 0) {
		say("%s open: the Speaker output goes to the kernel", sink_path);
		sink_last_errno = 0;
		volume_to_kernel();
	} else if (errno != sink_last_errno) {
		/* log the first miss and each change only: the retry runs every 2 s (~43k lines a day) */
		sink_last_errno = errno;
		say("%s: %s: the Speaker output is dropped (retry every 2 s, logged again on a change)", sink_path,
		    strerror(errno));
	}
}

/* With the lock held. */
static void
sink_close(int error)
{
	if (sink >= 0) {
		say("%s: write error %s: closed, opened again in 2 s", sink_path, strerror(error));
		(void)close(sink);
		sink = -1;
		sink_tried = mach_absolute_time();
	}
}

/* Drop every byte that waits in the ring (consumer side), counting the frames. */
static void
ring_drop_all(void)
{
	UInt64 head = __atomic_load_n(&ring_head, __ATOMIC_ACQUIRE), tail = ring_tail;

	if (head != tail) {
		__atomic_fetch_add(&frames_dropped, (head - tail) / NEGRONI_AUDIO_FRAME, __ATOMIC_RELAXED);
		__atomic_store_n(&ring_tail, head - (head - tail) % NEGRONI_AUDIO_FRAME, __ATOMIC_RELEASE);
	}
}

/* One round of the writer: write what waits in the ring (at most two pieces: the ring wraps). */
static void
writer_round(void)
{
	int fd;

	pthread_mutex_lock(&lock);
	sink_open();
	fd = sink;
	pthread_mutex_unlock(&lock);
	if (fd < 0) {
		ring_drop_all();
		return;
	}
	for (int piece = 0; piece < 2; piece++) {
		UInt64 head = __atomic_load_n(&ring_head, __ATOMIC_ACQUIRE), tail = ring_tail;
		UInt32 at = (UInt32)(tail % RING_BYTES), n = (UInt32)(head - tail);
		ssize_t took;

		if (n == 0) {
			return;
		}
		if (n > RING_BYTES - at) {
			n = RING_BYTES - at;
		}
		took = write(fd, ring + at, n);
		if (took < 0) {
			int error = errno;
			if (error == EAGAIN || error == EINTR) {
				return;         /* the kernel ring is full: the bytes stay here for the next round */
			}
			ring_drop_all();
			if (error != ENODEV) {  /* ENODEV: the node is there, no sink runs */
				pthread_mutex_lock(&lock);
				if (sink == fd) {
					sink_close(error);
				}
				pthread_mutex_unlock(&lock);
			}
			return;
		}
		__atomic_fetch_add(&bytes_out, (UInt64)took, __ATOMIC_RELAXED);
		__atomic_store_n(&ring_tail, tail + (UInt64)took, __ATOMIC_RELEASE);
		if ((UInt32)took < n) {
			return;                 /* a partial write: the rest goes in the next round */
		}
	}
}

/*
 * Every 30 s while the Speaker runs: the kernel's counters and its guard (patch 0244: the peaks before
 * and after the guard since the last call, the least guard gain). Writer thread only (it owns `sink`).
 */
static void
kernel_stats(void)
{
	struct negroni_audio_stats st;

	if (sink < 0 || ioctl(sink, NEGRONI_AUDIO_GET_STATS, &st) < 0) {
		return;
	}
	say("kernel: state %u, frames in %llu played %llu dropped %llu; guard peak in %u out %u (of 32768), "
	    "least gain %.1f dB", st.state, (unsigned long long)st.frames_in, (unsigned long long)st.frames_played,
	    (unsigned long long)st.frames_dropped, st.peak_in, st.peak_out,
	    st.limiter_gain_q15 ? 20.0 * log10(st.limiter_gain_q15 / 32768.0) : -120.0);
}

static void *
writer_main(__unused void *arg)
{
	struct timespec pause = { 0, (long)WRITER_NS };
	unsigned rounds = 0;

	(void)pthread_setname_np("NegroniAudio writer");
	while (!__atomic_load_n(&writer_stop, __ATOMIC_ACQUIRE)) {
		writer_round();
		if (++rounds % (unsigned)(30000000000ull / WRITER_NS) == 0) {
			kernel_stats();
		}
		(void)nanosleep(&pause, NULL);
	}
	writer_round();                 /* what the last cycles put in */
	return NULL;
}

/* The I/O thread (the only producer): no lock, no system call. */
static void
ring_put(const void *frames, UInt32 count)
{
	UInt64 head = ring_head, tail = __atomic_load_n(&ring_tail, __ATOMIC_ACQUIRE);
	UInt32 room = (UInt32)((RING_BYTES - (head - tail)) / NEGRONI_AUDIO_FRAME), n = count < room ? count : room;
	UInt32 bytes = n * NEGRONI_AUDIO_FRAME, at = (UInt32)(head % RING_BYTES), first = bytes < RING_BYTES - at ? bytes : RING_BYTES - at;

	__atomic_fetch_add(&frames_in, count, __ATOMIC_RELAXED);
	if (n < count) {
		__atomic_fetch_add(&frames_dropped, count - n, __ATOMIC_RELAXED);
	}
	memcpy(ring + at, frames, first);
	memcpy(ring, (const uint8_t *)frames + first, bytes - first);
	__atomic_store_n(&ring_head, head + bytes, __ATOMIC_RELEASE);
}

/*
 * The Actuator (haptics, docs/haptics-plan.md section 8): what iOS plays on it goes to
 * /dev/negroni-haptic (patches/xnu 0302), where the kernel turns it into the PM8350B motor's
 * amplitude. The same model as the Speaker: the I/O thread copies into a lock-free SPSC ring
 * (no system call), a haptic writer thread (made at the Actuator's first StartIO, joined at its
 * last StopIO) writes the ring to the node. Only sound and the HRING_TAIL frames after it are
 * copied: long silences cost nothing, and the kernel takes no data as silence. The writer polls
 * every HWRITER_FAST_NS while sound came in the last HWRITER_IDLE_AFTER_NS, else every
 * HWRITER_SLOW_NS (the first tap after a pause waits at most that long).
 */
#define HRING_FRAMES            16384u  /* 341 ms of S16 mono, a power of two */
#define HRING_TAIL              (NEGRONI_HAPTIC_RATE / 50)      /* 20 ms of silence after sound */
#define HWRITER_FAST_NS         2000000ull
#define HWRITER_SLOW_NS         8000000ull
#define HWRITER_IDLE_AFTER_NS   500000000ull
#define HAPTIC_SAID_MAX         12
_Static_assert((HRING_FRAMES & (HRING_FRAMES - 1)) == 0, "the haptic ring size must be a power of two");
static int16_t hring[HRING_FRAMES];
static UInt64 hring_head, hring_tail;   /* atomics, in frames */
static UInt64 hframes_in, hframes_sent, hframes_dropped, hframes_skipped;      /* atomics */
static UInt32 htail_left;               /* I/O thread only: silent frames still to copy */
static int haptic_fd = -1;              /* the haptic writer only */
static UInt64 haptic_tried;
static int haptic_last_errno = -1;
static unsigned haptic_said;
static const char *haptic_path = NEGRONI_HAPTIC_DEVICE;
static pthread_t hwriter;
static bool hwriter_on;                 /* under lock */
static int hwriter_stop;                /* atomic */

/* The I/O thread (the only producer): no lock, no system call. */
static void
haptic_put(const int16_t *s, UInt32 count)
{
	UInt32 peak = 0;

	for (UInt32 i = 0; i < count; i++) {
		UInt32 v = s[i] < 0 ? (UInt32)(-(int32_t)s[i]) : (UInt32)s[i];
		peak = v > peak ? v : peak;
	}
	__atomic_fetch_add(&hframes_in, count, __ATOMIC_RELAXED);
	if (peak > NEGRONI_HAPTIC_SILENT) {
		htail_left = HRING_TAIL;
	} else if (htail_left == 0) {
		__atomic_fetch_add(&hframes_skipped, count, __ATOMIC_RELAXED);
		return;
	} else {
		htail_left = htail_left > count ? htail_left - count : 0;
	}
	UInt64 head = hring_head, tail = __atomic_load_n(&hring_tail, __ATOMIC_ACQUIRE);
	UInt32 room = (UInt32)(HRING_FRAMES - (head - tail)), n = count < room ? count : room;
	UInt32 at = (UInt32)(head % HRING_FRAMES), first = n < HRING_FRAMES - at ? n : HRING_FRAMES - at;

	if (n < count) {
		__atomic_fetch_add(&hframes_dropped, count - n, __ATOMIC_RELAXED);
	}
	memcpy(hring + at, s, (size_t)first * 2);
	memcpy(hring, s + first, (size_t)(n - first) * 2);
	__atomic_store_n(&hring_head, head + n, __ATOMIC_RELEASE);
}

/* The haptic writer thread only. */
static void
haptic_open(void)
{
	UInt64 now = mach_absolute_time();

	if (haptic_fd >= 0 || (haptic_tried != 0 && (now - haptic_tried) * ns_numer / ns_denom < REOPEN_NS)) {
		return;
	}
	haptic_tried = now;
	haptic_fd = open(haptic_path, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (haptic_fd >= 0) {
		haptic_last_errno = 0;
		say("%s open: the Actuator (haptics) goes to the motor", haptic_path);
	} else if (errno != haptic_last_errno) {
		haptic_last_errno = errno;
		say("%s: %s: the Actuator output is dropped (boot-args negronihap=1 negronihap_ui=1 make the node; "
		    "retry every 2 s, logged again on a change)", haptic_path, strerror(errno));
	}
}

/* One round: write what waits (at most two pieces: the ring wraps). Returns true if frames went. */
static bool
haptic_round(void)
{
	bool sent = false;

	haptic_open();
	for (int piece = 0; piece < 2; piece++) {
		UInt64 head = __atomic_load_n(&hring_head, __ATOMIC_ACQUIRE), tail = hring_tail;
		UInt32 at = (UInt32)(tail % HRING_FRAMES), n = (UInt32)(head - tail);

		if (n == 0) {
			break;
		}
		if (n > HRING_FRAMES - at) {
			n = HRING_FRAMES - at;
		}
		if (haptic_fd < 0) {
			__atomic_fetch_add(&hframes_dropped, n, __ATOMIC_RELAXED);
			__atomic_store_n(&hring_tail, tail + n, __ATOMIC_RELEASE);
			continue;
		}
		ssize_t took = write(haptic_fd, hring + at, (size_t)n * 2);
		if (took < 0) {
			if (errno == EAGAIN || errno == EINTR) {
				break;
			}
			say("%s: write error %s: closed, opened again in 2 s", haptic_path, strerror(errno));
			(void)close(haptic_fd);
			haptic_fd = -1;
			haptic_tried = mach_absolute_time();
			continue;               /* the next piece is dropped */
		}
		UInt32 frames = (UInt32)took / 2;
		if (haptic_said < HAPTIC_SAID_MAX) {
			UInt32 peak = 0;
			for (UInt32 i = 0; i < frames; i++) {
				UInt32 v = hring[at + i] < 0 ? (UInt32)(-(int32_t)hring[at + i]) : (UInt32)hring[at + i];
				peak = v > peak ? v : peak;
			}
			if (peak > NEGRONI_HAPTIC_SILENT) {
				haptic_said++;
				say("the Actuator plays: %u frames to the motor, peak %u of 32768%s", frames, peak,
				    haptic_said == HAPTIC_SAID_MAX ? " (no more of these lines)" : "");
			}
		}
		__atomic_fetch_add(&hframes_sent, frames, __ATOMIC_RELAXED);
		__atomic_store_n(&hring_tail, tail + frames, __ATOMIC_RELEASE);
		sent = frames != 0;
		if (frames < n) {
			break;
		}
	}
	return sent;
}

static void *
hwriter_main(__unused void *arg)
{
	UInt64 last_sent = 0;

	(void)pthread_setname_np("NegroniAudio haptic writer");
	while (!__atomic_load_n(&hwriter_stop, __ATOMIC_ACQUIRE)) {
		UInt64 now = mach_absolute_time();
		if (haptic_round()) {
			last_sent = now;
		}
		bool fast = last_sent != 0 && (now - last_sent) * ns_numer / ns_denom < HWRITER_IDLE_AFTER_NS;
		struct timespec pause = { 0, (long)(fast ? HWRITER_FAST_NS : HWRITER_SLOW_NS) };
		(void)nanosleep(&pause, NULL);
	}
	(void)haptic_round();
	if (haptic_fd >= 0) {
		(void)close(haptic_fd);
		haptic_fd = -1;
	}
	return NULL;
}

#ifdef NEGRONI_AUDIO_HOST_TEST
/* test-host.c only (not in the iOS build): the ring counters. */
__attribute__((visibility("default"))) void NegroniAudio_TestStats(UInt64 out[4]);
void
NegroniAudio_TestStats(UInt64 out[4])
{
	out[0] = __atomic_load_n(&frames_in, __ATOMIC_ACQUIRE);
	out[1] = __atomic_load_n(&frames_dropped, __ATOMIC_ACQUIRE);
	out[2] = __atomic_load_n(&bytes_out, __ATOMIC_ACQUIRE);
	out[3] = __atomic_load_n(&ring_head, __ATOMIC_ACQUIRE) - __atomic_load_n(&ring_tail, __ATOMIC_ACQUIRE);
}

/* test-host.c only: the Actuator counters (in, sent, dropped, skipped as silence). */
__attribute__((visibility("default"))) void NegroniAudio_TestHapticStats(UInt64 out[4]);
void
NegroniAudio_TestHapticStats(UInt64 out[4])
{
	out[0] = __atomic_load_n(&hframes_in, __ATOMIC_ACQUIRE);
	out[1] = __atomic_load_n(&hframes_sent, __ATOMIC_ACQUIRE);
	out[2] = __atomic_load_n(&hframes_dropped, __ATOMIC_ACQUIRE);
	out[3] = __atomic_load_n(&hframes_skipped, __ATOMIC_ACQUIRE);
}
#endif

static struct device *
device_of(AudioObjectID object)
{
	for (unsigned i = 0; i < DEVICES; i++) {
		if (object == devices[i].object || (object != 0 && (object == devices[i].output || object == devices[i].input))) {
			return &devices[i];
		}
	}
	return NULL;
}

static AudioStreamBasicDescription
format_of(AudioObjectID stream)
{
	const struct device *d = device_of(stream);
	UInt32 channels = d == NULL ? 2 : stream == d->output ? d->output_channels : d->input_channels;

	return (AudioStreamBasicDescription) {
		       .mSampleRate = NEGRONI_AUDIO_RATE, .mFormatID = kAudioFormatLinearPCM,
		       .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
		       .mBytesPerPacket = 2 * channels, .mFramesPerPacket = 1, .mBytesPerFrame = 2 * channels,
		       .mChannelsPerFrame = channels, .mBitsPerChannel = 16,
	};
}

static HRESULT
query_interface(void *driver, REFIID uuid, LPVOID *interface)
{
	CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
	Boolean ours = requested != NULL && (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID));

	if (requested != NULL) {
		CFRelease(requested);
	}
	if (interface == NULL || !ours) {
		return E_NOINTERFACE;
	}
	*interface = driver;            /* one static driver: no reference counts */
	return S_OK;
}

static ULONG
add_ref(__unused void *driver)
{
	return 1;
}

static ULONG
release(__unused void *driver)
{
	return 1;
}

static OSStatus
initialize(__unused AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef the_host)
{
	mach_timebase_info_data_t timebase;

	host = the_host;
	mach_timebase_info(&timebase);
	ns_numer = timebase.numer;
	ns_denom = timebase.denom ? timebase.denom : 1;
	ticks_per_frame = 1e9 * timebase.denom / timebase.numer / NEGRONI_AUDIO_RATE;
#ifdef NEGRONI_AUDIO_HOST_TEST
	if (getenv("NEGRONI_AUDIO_TEST_PATH") != NULL) {
		sink_path = getenv("NEGRONI_AUDIO_TEST_PATH");
		sink_tried = 0;         /* a new path: no 2 s wait */
	}
	if (getenv("NEGRONI_HAPTIC_TEST_PATH") != NULL) {
		haptic_path = getenv("NEGRONI_HAPTIC_TEST_PATH");
		haptic_tried = 0;
	}
#endif
	say("initialized: Speaker, Hawking, Actuator, Codec (timebase %u/%u)", timebase.numer, timebase.denom);
	return 0;
}

static OSStatus
create_device(__unused AudioServerPlugInDriverRef driver, __unused CFDictionaryRef description,
    __unused const AudioServerPlugInClientInfo *client, __unused AudioObjectID *object)
{
	return kAudioHardwareUnsupportedOperationError;
}

static OSStatus
destroy_device(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object)
{
	return kAudioHardwareUnsupportedOperationError;
}

static OSStatus
device_client(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object,
    __unused const AudioServerPlugInClientInfo *client)
{
	return 0;
}

static OSStatus
configuration_change(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object, __unused UInt64 action,
    __unused void *info)
{
	return 0;
}

/* A property value: size bytes, or an empty list, or (neither) no such property. */
struct value {
	UInt32 size;
	bool empty;
	bool string;                    /* a CFString: the caller gets its own reference */
	union {
		UInt32 words[4];
		Float64 number;
		Float32 decimal;
		CFStringRef string;
		AudioValueRange range;
		AudioStreamBasicDescription format;
		AudioStreamRangedDescription ranged;
	} u;
};

static struct value
control_property(AudioObjectID object, UInt32 selector, UInt32 qualifier_size, const void *qualifier)
{
	struct value v;

	memset(&v, 0, sizeof(v));
#define WORD(x)         (v.u.words[0] = (x), v.size = sizeof(UInt32))
#define STRING(x)       (v.u.string = (x), v.string = true, v.size = sizeof(CFStringRef))
#define FLOAT(x)        (v.u.decimal = (x), v.size = sizeof(Float32))
	bool vol = object == OBJECT_SPEAKER_VOLUME;

	switch (selector) {
	case kAudioObjectPropertyBaseClass:
		WORD(vol ? kAudioLevelControlClassID : kAudioSelectorControlClassID);
		break;
	case kAudioObjectPropertyClass:
		WORD(vol ? kAudioVolumeControlClassID : kAudioDataSourceControlClassID);
		break;
	case kAudioObjectPropertyOwner:
		WORD(vol ? OBJECT_SPEAKER : OBJECT_CODEC);
		break;
	case kAudioObjectPropertyOwnedObjects:
		v.empty = true;
		break;
	case kAudioControlPropertyScope:
		WORD(vol ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput);
		break;
	case kAudioControlPropertyElement:
		WORD(0);
		break;
	}
	if (vol) {
		switch (selector) {
		case kAudioLevelControlPropertyScalarValue:
			FLOAT(volume);
			break;
		case kAudioLevelControlPropertyDecibelValue:
			FLOAT(scalar_to_db(volume));
			break;
		case kAudioLevelControlPropertyDecibelRange:
			v.u.range.mMinimum = -VOLUME_RANGE_DB;
			v.u.range.mMaximum = 0;
			v.size = sizeof(AudioValueRange);
			break;
		case kAudioLevelControlPropertyConvertScalarToDecibels:
		case kAudioLevelControlPropertyConvertDecibelsToScalar:
			FLOAT(0);       /* converted in place in get_property_data() */
			break;
		}
	} else {
		switch (selector) {
		case kAudioSelectorControlPropertyCurrentItem:
		case kAudioSelectorControlPropertyAvailableItems:
			WORD(MIC_SOURCE);
			break;
		case kAudioSelectorControlPropertyItemName:
			if (qualifier_size == sizeof(UInt32) && qualifier != NULL && *(const UInt32 *)qualifier == MIC_SOURCE) {
				STRING(CFSTR("Bottom"));
			} else {
				STRING(CFSTR(""));
			}
			break;
		}
	}
#undef WORD
#undef STRING
#undef FLOAT
	return v;
}

static struct value
property(AudioObjectID object, const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier)
{
	UInt32 selector = address->mSelector, scope = address->mScope;
	const struct device *d = device_of(object);
	struct value v;

	if (object == OBJECT_SPEAKER_VOLUME || object == OBJECT_CODEC_SOURCE) {
		return control_property(object, selector, qualifier_size, qualifier);
	}
	memset(&v, 0, sizeof(v));
	if (object != OBJECT_PLUGIN && d == NULL) {
		return v;
	}
#define WORD(x)         (v.u.words[0] = (x), v.size = sizeof(UInt32))
#define LIST(x)         (v.u.words[v.size / sizeof(UInt32)] = (x), v.size += sizeof(UInt32))
#define STRING(x)       (v.u.string = (x), v.string = true, v.size = sizeof(CFStringRef))
	switch (selector) {
	case kAudioObjectPropertyBaseClass:
		WORD(kAudioObjectClassID);
		return v;
	case kAudioObjectPropertyClass:
		WORD(object == OBJECT_PLUGIN ? kAudioPlugInClassID : object == d->object ? kAudioDeviceClassID : kAudioStreamClassID);
		return v;
	case kAudioObjectPropertyOwner:
		WORD(object == OBJECT_PLUGIN ? 0 : object == d->object ? OBJECT_PLUGIN : d->object);
		return v;
	}
	if (object == OBJECT_PLUGIN) {
		switch (selector) {
		case kAudioObjectPropertyManufacturer:
			STRING(MANUFACTURER);
			break;
		case kAudioObjectPropertyOwnedObjects:
		case kAudioPlugInPropertyDeviceList:
			for (unsigned i = 0; i < DEVICES; i++) {
				LIST(devices[i].object);
			}
			break;
		case kAudioPlugInPropertyBoxList:
			v.empty = true;
			break;
		case kAudioPlugInPropertyTranslateUIDToBox:
			WORD(0);
			break;
		case kAudioPlugInPropertyTranslateUIDToDevice:
			WORD(0);
			for (unsigned i = 0; i < DEVICES; i++) {
				if (qualifier_size == sizeof(CFStringRef) && qualifier != NULL && *(const CFStringRef *)qualifier != NULL &&
				    CFEqual(*(const CFStringRef *)qualifier, devices[i].uid)) {
					WORD(devices[i].object);
				}
			}
			break;
		case kAudioPlugInPropertyResourceBundle:
			STRING(CFSTR(""));
			break;
		}
	} else if (object == d->object) {
		switch (selector) {
		case kAudioObjectPropertyManufacturer:
			STRING(MANUFACTURER);
			break;
		case kAudioObjectPropertyName:
		case kAudioDevicePropertyDeviceUID:
		case kAudioDevicePropertyModelUID:
			STRING(d->uid);
			break;
		case kAudioDevicePropertyTransportType:
			WORD(TRANSPORT_BUILT_IN);
			break;
		case kAudioDevicePropertyRelatedDevices:
			WORD(d->object);
			break;
		case kAudioDevicePropertyClockDomain:
		case kAudioDevicePropertyLatency:
		case kAudioDevicePropertySafetyOffset:
		case kAudioDevicePropertyIsHidden:
			WORD(0);
			break;
		case kAudioDevicePropertyDeviceIsAlive:
			WORD(1);
			break;
		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
			WORD(d->output != 0);
			break;
		case kAudioDevicePropertyDeviceIsRunning:
			WORD(d->running != 0);
			break;
		case kAudioObjectPropertyOwnedObjects:
		case kAudioDevicePropertyStreams:
			if (scope != kAudioObjectPropertyScopeInput && d->output != 0) {
				LIST(d->output);
			}
			if (scope != kAudioObjectPropertyScopeOutput && d->input != 0) {
				LIST(d->input);
			}
			if (selector == kAudioObjectPropertyOwnedObjects && d->object == OBJECT_SPEAKER) {
				LIST(OBJECT_SPEAKER_VOLUME);
			}
			if (selector == kAudioObjectPropertyOwnedObjects && d->object == OBJECT_CODEC && scope != kAudioObjectPropertyScopeOutput) {
				LIST(OBJECT_CODEC_SOURCE);
			}
			v.empty = v.size == 0;
			break;
		case kAudioObjectPropertyControlList:
			if (d->object == OBJECT_SPEAKER) {
				LIST(OBJECT_SPEAKER_VOLUME);
			}
			if (d->object == OBJECT_CODEC) {
				LIST(OBJECT_CODEC_SOURCE);
			}
			v.empty = v.size == 0;
			break;
		case kAudioDevicePropertyNominalSampleRate:
			v.u.number = NEGRONI_AUDIO_RATE;
			v.size = sizeof(Float64);
			break;
		case kAudioDevicePropertyAvailableNominalSampleRates:
			v.u.range.mMinimum = v.u.range.mMaximum = NEGRONI_AUDIO_RATE;
			v.size = sizeof(AudioValueRange);
			break;
		case kAudioDevicePropertyPreferredChannelsForStereo:
			v.u.words[0] = 1;
			v.u.words[1] = 2;
			v.size = 2 * sizeof(UInt32);
			break;
		case kAudioDevicePropertyZeroTimeStampPeriod:
			WORD(TIMESTAMP_PERIOD);
			break;
		}
	} else {
		switch (selector) {
		case kAudioStreamPropertyIsActive:
			WORD(!inactive[object]);
			break;
		case kAudioStreamPropertyDirection:
			WORD(object == d->input);
			break;
		case kAudioStreamPropertyTerminalType:
			WORD(object == d->input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
			break;
		case kAudioStreamPropertyStartingChannel:
			WORD(1);
			break;
		case kAudioStreamPropertyLatency:
			WORD(0);
			break;
		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
			v.u.format = format_of(object);
			v.size = sizeof(AudioStreamBasicDescription);
			break;
		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			v.u.ranged.mFormat = format_of(object);
			v.u.ranged.mSampleRateRange.mMinimum = v.u.ranged.mSampleRateRange.mMaximum = NEGRONI_AUDIO_RATE;
			v.size = sizeof(AudioStreamRangedDescription);
			break;
		}
	}
#undef WORD
#undef LIST
#undef STRING
	return v;
}

/* Properties asked for that we do not have: the first 64 (object, selector, scope), once each. */
#define UNKNOWN_TOLD            64
static UInt32 unknown_told[UNKNOWN_TOLD][3];
static unsigned unknown_count;

static void
unknown(AudioObjectID object, const AudioObjectPropertyAddress *address)
{
	UInt32 s = address->mSelector, c = address->mScope;
	const struct device *d = device_of(object);
	char uid[32] = "-";

	for (unsigned i = 0; i < unknown_count; i++) {
		if (unknown_told[i][0] == object && unknown_told[i][1] == s && unknown_told[i][2] == c) {
			return;
		}
	}
	if (unknown_count >= UNKNOWN_TOLD) {
		return;
	}
	unknown_told[unknown_count][0] = object;
	unknown_told[unknown_count][1] = s;
	unknown_told[unknown_count][2] = c;
	unknown_count++;
	if (d != NULL) {
		(void)CFStringGetCString(d->uid, uid, sizeof(uid), kCFStringEncodingUTF8);
	}
	say("object %u (%s) has no '%c%c%c%c' (%#x), scope '%c%c%c%c', element %u", (unsigned)object, uid,
	    (int)(s >> 24 & 0xff), (int)(s >> 16 & 0xff), (int)(s >> 8 & 0xff), (int)(s & 0xff), (unsigned)s,
	    (int)(c >> 24 & 0xff), (int)(c >> 16 & 0xff), (int)(c >> 8 & 0xff), (int)(c & 0xff), (unsigned)address->mElement);
}

static Boolean
has_property(__unused AudioServerPlugInDriverRef driver, AudioObjectID object, __unused pid_t client,
    const AudioObjectPropertyAddress *address)
{
	struct value v;

	if (address == NULL) {
		return false;
	}
	v = property(object, address, 0, NULL);
	if (v.size == 0 && !v.empty) {
		unknown(object, address);
	}
	return v.size != 0 || v.empty;
}

static OSStatus
is_property_settable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
    const AudioObjectPropertyAddress *address, Boolean *settable)
{
	const struct device *d = device_of(object);

	if (address == NULL || settable == NULL || !has_property(driver, object, client, address)) {
		return kAudioHardwareUnknownPropertyError;
	}
	if (object == OBJECT_SPEAKER_VOLUME) {
		*settable = address->mSelector == kAudioLevelControlPropertyScalarValue ||
		    address->mSelector == kAudioLevelControlPropertyDecibelValue;
	} else if (object == OBJECT_CODEC_SOURCE) {
		*settable = address->mSelector == kAudioSelectorControlPropertyCurrentItem;
	} else if (object == OBJECT_PLUGIN || d == NULL) {
		*settable = false;
	} else if (object == d->object) {
		*settable = address->mSelector == kAudioDevicePropertyNominalSampleRate;
	} else {
		*settable = address->mSelector == kAudioStreamPropertyIsActive ||
		    address->mSelector == kAudioStreamPropertyVirtualFormat || address->mSelector == kAudioStreamPropertyPhysicalFormat;
	}
	return 0;
}

static OSStatus
get_property_data_size(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
    const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier, UInt32 *size)
{
	if (address == NULL || size == NULL || !has_property(driver, object, client, address)) {
		return object < OBJECT_PLUGIN || object > OBJECT_LAST ? kAudioHardwareBadObjectError : kAudioHardwareUnknownPropertyError;
	}
	*size = property(object, address, qualifier_size, qualifier).size;
	return 0;
}

static OSStatus
get_property_data(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
    const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier, UInt32 room, UInt32 *size,
    void *data)
{
	struct value v;

	if (address == NULL || size == NULL || data == NULL || !has_property(driver, object, client, address)) {
		return object < OBJECT_PLUGIN || object > OBJECT_LAST ? kAudioHardwareBadObjectError : kAudioHardwareUnknownPropertyError;
	}
	if (object == OBJECT_SPEAKER_VOLUME && (address->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels ||
	    address->mSelector == kAudioLevelControlPropertyConvertDecibelsToScalar)) {
		if (room < sizeof(Float32)) {
			return kAudioHardwareBadPropertySizeError;
		}
		*(Float32 *)data = address->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels ?
		    scalar_to_db(*(Float32 *)data) : db_to_scalar(*(Float32 *)data);
		*size = sizeof(Float32);
		return 0;
	}
	pthread_mutex_lock(&lock);
	v = property(object, address, qualifier_size, qualifier);
	pthread_mutex_unlock(&lock);
	if (v.size > room) {
		/* lists may be read in part; anything else must fit */
		if (address->mSelector != kAudioObjectPropertyOwnedObjects && address->mSelector != kAudioDevicePropertyStreams &&
		    address->mSelector != kAudioPlugInPropertyDeviceList && address->mSelector != kAudioObjectPropertyControlList) {
			return kAudioHardwareBadPropertySizeError;
		}
		v.size = room - room % sizeof(UInt32);
	}
	memcpy(data, &v.u, v.size);
	if (v.string && v.size == sizeof(CFStringRef)) {
		CFRetain(v.u.string);
	}
	*size = v.size;
	return 0;
}

static OSStatus
set_property_data(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
    const AudioObjectPropertyAddress *address, __unused UInt32 qualifier_size, __unused const void *qualifier, UInt32 size,
    const void *data)
{
	Boolean settable = false;

	if (address == NULL || data == NULL || is_property_settable(driver, object, client, address, &settable) != 0) {
		return kAudioHardwareUnknownPropertyError;
	}
	if (!settable) {
		return kAudioHardwareIllegalOperationError;
	}
	if (object == OBJECT_SPEAKER_VOLUME) {
		AudioObjectPropertyAddress changed[2] = {
			{ kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, 0 },
			{ kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, 0 },
		};
		Float32 wanted;

		if (size != sizeof(Float32)) {
			return kAudioHardwareBadPropertySizeError;
		}
		wanted = *(const Float32 *)data;
		if (wanted != wanted) {         /* NaN */
			return kAudioHardwareIllegalOperationError;
		}
		wanted = address->mSelector == kAudioLevelControlPropertyDecibelValue ? db_to_scalar(wanted) :
		    wanted < 0 ? 0 : wanted > 1 ? 1 : wanted;
		pthread_mutex_lock(&lock);
		volume = wanted;
		volume_to_kernel();
		pthread_mutex_unlock(&lock);
		if (host != NULL) {
			host->PropertiesChanged(host, OBJECT_SPEAKER_VOLUME, 2, changed);
		}
		return 0;
	}
	if (object == OBJECT_CODEC_SOURCE) {
		return size == sizeof(UInt32) ? (*(const UInt32 *)data == MIC_SOURCE ? 0 : kAudioHardwareIllegalOperationError) :
		       kAudioHardwareBadPropertySizeError;
	}
	if (address->mSelector == kAudioStreamPropertyIsActive) {
		if (size != sizeof(UInt32)) {
			return kAudioHardwareBadPropertySizeError;
		}
		pthread_mutex_lock(&lock);
		inactive[object] = *(const UInt32 *)data == 0;
		pthread_mutex_unlock(&lock);
		return 0;
	}
	if (address->mSelector == kAudioDevicePropertyNominalSampleRate) {
		return size == sizeof(Float64) && *(const Float64 *)data == NEGRONI_AUDIO_RATE ? 0 : kAudioDeviceUnsupportedFormatError;
	}
	/* a stream format: only the one there is */
	if (size != sizeof(AudioStreamBasicDescription)) {
		return kAudioHardwareBadPropertySizeError;
	} else {
		const AudioStreamBasicDescription *wanted = data, format = format_of(object);

		return wanted->mSampleRate == format.mSampleRate && wanted->mFormatID == format.mFormatID &&
		       wanted->mChannelsPerFrame == format.mChannelsPerFrame && wanted->mBitsPerChannel == format.mBitsPerChannel &&
		       (wanted->mFormatFlags & kAudioFormatFlagIsSignedInteger) ? 0 : kAudioDeviceUnsupportedFormatError;
	}
}

static OSStatus
start_io(__unused AudioServerPlugInDriverRef driver, AudioObjectID object, __unused UInt32 client)
{
	struct device *d = device_of(object);

	if (d == NULL || object != d->object) {
		return kAudioHardwareBadObjectError;
	}
	pthread_mutex_lock(&io_lock);
	pthread_mutex_lock(&lock);
	if (d->running++ == 0) {
		__atomic_store_n(&d->anchor, mach_absolute_time(), __ATOMIC_RELEASE);
		if (d->object == OBJECT_SPEAKER && !writer_on) {
			/* no writer runs: nobody else touches the ring or the counters now */
			ring_head = ring_tail = 0;
			__atomic_store_n(&frames_in, 0, __ATOMIC_RELAXED);
			__atomic_store_n(&frames_dropped, 0, __ATOMIC_RELAXED);
			__atomic_store_n(&bytes_out, 0, __ATOMIC_RELAXED);
			__atomic_store_n(&writer_stop, 0, __ATOMIC_RELEASE);
			writer_on = pthread_create(&writer, NULL, writer_main, NULL) == 0;
			say("Speaker starts (writer thread %s)", writer_on ? "runs" : "failed: the output is dropped");
		}
		if (d->object == OBJECT_ACTUATOR && !hwriter_on) {
			/* no haptic writer runs: nobody else touches its ring now */
			hring_head = hring_tail = 0;
			htail_left = 0;
			__atomic_store_n(&hwriter_stop, 0, __ATOMIC_RELEASE);
			hwriter_on = pthread_create(&hwriter, NULL, hwriter_main, NULL) == 0;
			say("Actuator starts (haptic writer thread %s)", hwriter_on ? "runs" : "failed: haptics are dropped");
		}
	}
	pthread_mutex_unlock(&lock);
	pthread_mutex_unlock(&io_lock);
	return 0;
}

static OSStatus
stop_io(__unused AudioServerPlugInDriverRef driver, AudioObjectID object, __unused UInt32 client)
{
	struct device *d = device_of(object);

	if (d == NULL || object != d->object) {
		return kAudioHardwareBadObjectError;
	}
	bool join = false;
	pthread_t thread;

	pthread_mutex_lock(&io_lock);
	pthread_mutex_lock(&lock);
	bool hjoin = false;
	pthread_t hthread;
	if (d->running != 0 && --d->running == 0 && d->object == OBJECT_SPEAKER && writer_on) {
		__atomic_store_n(&writer_stop, 1, __ATOMIC_RELEASE);
		thread = writer;
		writer_on = false;
		join = true;
	} else if (d->running == 0 && d->object == OBJECT_ACTUATOR && hwriter_on) {
		__atomic_store_n(&hwriter_stop, 1, __ATOMIC_RELEASE);
		hthread = hwriter;
		hwriter_on = false;
		hjoin = true;
	}
	pthread_mutex_unlock(&lock);
	if (hjoin) {
		(void)pthread_join(hthread, NULL);
		say("Actuator stops: %llu frames in, %llu to the motor, %llu dropped, %llu silent (not sent)",
		    __atomic_load_n(&hframes_in, __ATOMIC_ACQUIRE), __atomic_load_n(&hframes_sent, __ATOMIC_ACQUIRE),
		    __atomic_load_n(&hframes_dropped, __ATOMIC_ACQUIRE), __atomic_load_n(&hframes_skipped, __ATOMIC_ACQUIRE));
	}
	if (join) {
		/* outside the lock: the writer takes it to open the node */
		(void)pthread_join(thread, NULL);
		UInt64 in = __atomic_load_n(&frames_in, __ATOMIC_ACQUIRE);
		say("Speaker stops: %llu.%02llu s of frames in, %llu frames to the kernel, %llu dropped", in / NEGRONI_AUDIO_RATE,
		    in % NEGRONI_AUDIO_RATE * 100 / NEGRONI_AUDIO_RATE, __atomic_load_n(&bytes_out, __ATOMIC_ACQUIRE) / NEGRONI_AUDIO_FRAME,
		    __atomic_load_n(&frames_dropped, __ATOMIC_ACQUIRE));
	}
	pthread_mutex_unlock(&io_lock);
	return 0;
}

/*
 * The last device time at a multiple of TIMESTAMP_PERIOD frames, and its host time. Called on
 * the HAL real-time I/O thread: no lock (start_io holds it during open()), no loop. anchor is
 * one aligned 64-bit word, written by start_io only.
 */
static OSStatus
get_zero_time_stamp(__unused AudioServerPlugInDriverRef driver, AudioObjectID object, __unused UInt32 client,
    Float64 *sample_time, UInt64 *host_time, UInt64 *seed)
{
	Float64 ticks_per_period = ticks_per_frame * TIMESTAMP_PERIOD;
	UInt64 now = mach_absolute_time();
	struct device *d = device_of(object);
	UInt64 anchor, periods;

	if (d == NULL || sample_time == NULL || host_time == NULL || seed == NULL) {
		return kAudioHardwareBadObjectError;
	}
	anchor = __atomic_load_n(&d->anchor, __ATOMIC_ACQUIRE);
	if (anchor == 0 || now < anchor) {      /* not started yet: the clock stands at 0 */
		anchor = now;
	}
	periods = (UInt64)((Float64)(now - anchor) / ticks_per_period);
	*sample_time = (Float64)periods * TIMESTAMP_PERIOD;
	*host_time = anchor + (UInt64)((Float64)periods * ticks_per_period);
	*seed = 1;
	return 0;
}

static OSStatus
will_do_io_operation(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object, __unused UInt32 client,
    UInt32 operation, Boolean *will_do, Boolean *in_place)
{
	if (will_do == NULL || in_place == NULL) {
		return kAudioHardwareIllegalOperationError;
	}
	*will_do = operation == kAudioServerPlugInIOOperationReadInput || operation == kAudioServerPlugInIOOperationWriteMix;
	*in_place = true;
	return 0;
}

static OSStatus
begin_end_io_operation(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object, __unused UInt32 client,
    __unused UInt32 operation, __unused UInt32 frames, __unused const AudioServerPlugInIOCycleInfo *cycle)
{
	return 0;
}

/* The HAL I/O thread: no locks, no waits, no system calls. */
static OSStatus
do_io_operation(__unused AudioServerPlugInDriverRef driver, __unused AudioObjectID object, AudioObjectID stream,
    __unused UInt32 client, UInt32 operation, UInt32 frames, __unused const AudioServerPlugInIOCycleInfo *cycle, void *buffer,
    __unused void *secondary)
{
	const struct device *d = device_of(stream);

	if (d == NULL || buffer == NULL) {
		return kAudioHardwareBadObjectError;
	}
	if (operation == kAudioServerPlugInIOOperationReadInput) {
		/* every input is silent: Speaker sense, Hawking, Codec (no microphone driver) */
		memset(buffer, 0, (size_t)frames * 2 * (stream == d->input ? d->input_channels : 1));
	} else if (operation == kAudioServerPlugInIOOperationWriteMix && stream == OBJECT_SPEAKER_OUTPUT) {
		ring_put(buffer, frames);       /* the writer thread gives it to the kernel */
	} else if (operation == kAudioServerPlugInIOOperationWriteMix && stream == OBJECT_ACTUATOR_OUTPUT) {
		haptic_put(buffer, frames);     /* the haptic writer gives it to /dev/negroni-haptic */
	}
	return 0;
}

static AudioServerPlugInDriverInterface interface = {
	NULL, query_interface, add_ref, release, initialize, create_device, destroy_device, device_client, device_client,
	configuration_change, configuration_change, has_property, is_property_settable, get_property_data_size,
	get_property_data, set_property_data, start_io, stop_io, get_zero_time_stamp, will_do_io_operation,
	begin_end_io_operation, do_io_operation, begin_end_io_operation,
};
static AudioServerPlugInDriverInterface *driver = &interface;

/* The factory named in Info.plist (CFPlugInFactories). */
__attribute__((visibility("default"))) void *NegroniAudio_Create(CFAllocatorRef allocator, CFUUIDRef type);

void *
NegroniAudio_Create(__unused CFAllocatorRef allocator, CFUUIDRef type)
{
	return type != NULL && CFEqual(type, kAudioServerPlugInTypeUUID) ? &driver : NULL;
}
