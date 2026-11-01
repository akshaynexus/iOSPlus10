/*
 * Host mock test of RedwoodAudio.driver's input path (scripts/laurel/mic-host-test.sh). The real plug-in source is
 * compiled here with the kernel node replaced by a mock: what iOS would see (device "Codec", its stream, format,
 * data source, volume control) and what mediaserverd's I/O thread gets. Proves the plug-in, not iOS.
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int mic_fd_open, opens, closes, ioctls, open_fails, mock_short, mock_err;
static unsigned last_below, sink_frames;
static int16_t mock_samples[4096];

static int
mock_open(const char *path, int flags, ...)
{
	if (strcmp(path, "/dev/redwood-audio") == 0) {
		return 100;
	}
	if (strcmp(path, "/dev/redwood-mic") == 0) {
		if (open_fails) {
			errno = ENXIO;
			return -1;
		}
		if ((flags & 3) != O_RDONLY || !(flags & O_NONBLOCK)) {
			printf("FAIL: the mic must open O_RDONLY | O_NONBLOCK (the HAL thread must not wait)\n");
			exit(1);
		}
		opens++;
		mic_fd_open = 1;
		return 101;
	}
	errno = ENOENT;
	return -1;
}

static ssize_t
mock_read(int fd, void *buf, size_t n)
{
	if (fd != 101) {
		errno = EBADF;
		return -1;
	}
	if (mock_err) {
		errno = EIO;
		return -1;
	}
	n = mock_short != 0 && (size_t)mock_short < n ? (size_t)mock_short : n;
	memcpy(buf, mock_samples, n);
	return (ssize_t)n;
}

static ssize_t
mock_write(int fd, const void *buf, size_t n)
{
	(void)buf;
	if (fd == 2) {
		return (ssize_t)n;                      /* the plug-in's say() */
	}
	if (fd == 100) {
		sink_frames += (unsigned)(n / 4);
	}
	return (ssize_t)n;
}

static int
mock_close(int fd)
{
	if (fd == 101) {
		closes++;
		mic_fd_open = 0;
	}
	return 0;
}

static int
mock_ioctl(int fd, unsigned long c, ...)
{
	va_list ap;
	unsigned *arg;

	va_start(ap, c);
	arg = va_arg(ap, unsigned *);
	va_end(ap);
	if (fd == 101) {
		ioctls++;
		last_below = arg[0];
	}
	return 0;
}

#define open mock_open
#define read mock_read
#define write mock_write
#define close mock_close
#define ioctl mock_ioctl
#include "audio_plugin.c"
#undef open
#undef read
#undef write
#undef close
#undef ioctl

static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

static AudioServerPlugInDriverRef D;

static OSStatus
get(AudioObjectID o, UInt32 sel, UInt32 scope, void *out, UInt32 room, UInt32 *size)
{
	AudioObjectPropertyAddress a = { sel, scope, 0 };
	UInt32 s = 0;
	OSStatus st = (*D)->GetPropertyData(D, o, 1, &a, 0, NULL, room, &s, out);

	if (size != NULL) {
		*size = s;
	}
	return st;
}

static OSStatus
set_float(AudioObjectID o, UInt32 sel, Float32 v)
{
	AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, 0 };

	return (*D)->SetPropertyData(D, o, 1, &a, 0, NULL, sizeof(v), &v);
}

static OSStatus
host_changed(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a)
{
	(void)h; (void)o; (void)n; (void)a;
	return 0;
}

static const AudioServerPlugInHostInterface host_if = { host_changed, NULL, NULL, NULL, NULL };

#include "hal_test_cases.c"
