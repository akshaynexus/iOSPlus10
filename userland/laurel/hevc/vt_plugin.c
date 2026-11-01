/*
 * HEVCH8.videodecoder: a software HEVC decoder for VideoToolbox on the Mi A3 iOS 16.7.16 (20H392) root. docs/laurel_sprout/hevc.md.
 *
 * How it gets loaded [V cache 20H392]: VTLoadVideoDecoders in VideoToolbox has a fixed list of dlopen paths + register functions.
 * "/System/Library/VideoDecoders/HEVCH8.videodecoder" + "HEVCH8Register" is on the list, and the iPhone X system has no such file.
 * That slot is this file. No injection and no hook: VideoToolbox loads it in every process that fills its decoder registry.
 * Clients of VTDecompressionSession (ImageIO -> CMPhoto, AVFoundation) decode through mediaserverd, so one sandbox matters: its own.
 * Selection [V vtSortRegistryItemsByRating]: the higher kVTVideoDecoderInfo_Rating comes first; Apple's VCPHEVC.videocodec has none.
 *
 * The decoder ABI below is private. It is read from VCPHEVC's own vtable and from VT's callers (offsets in hevc.md section 3).
 * Everything private comes through dlsym, so a system without a symbol gives one "off" line and Apple's decoder stays.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include "hevc_core.h"

extern const char *getprogname(void);

#define RATING          100
#define MAX_PENDING     64      /* samples whose pictures are still inside the decoder */
#define STRIKE_LIMIT    3

typedef void *VTVideoDecoderRef;
typedef void *VTVideoDecoderSession;
typedef void *VTVideoDecoderFrame;

enum { DECODE_TEMPORAL = 1 << 3, INFO_FRAME_DROPPED = 1 << 1 };
enum {
	ERR_ALLOC = -12904, ERR_BAD_DATA = -12909, ERR_UNSUPPORTED = -12910, ERR_MALFUNCTION = -12911,
	ERR_PROPERTY_NOT_SUPPORTED = -12782, ERR_VALUE_NOT_AVAILABLE = -12783,
};

/* CMBaseClass, CMBaseClass protocol = 0 [V VCPHEVC 0x1e22b6898: version 1, storage size, 0, invalidate, finalize, debug, copy, set] */
typedef struct {
	uint64_t version;
	size_t derived_storage_size;
	Boolean (*equal)(void *, void *);
	OSStatus (*invalidate)(void *);
	void (*finalize)(void *);
	CFStringRef (*copy_debug_description)(void *);
	OSStatus (*copy_property)(void *, CFStringRef, CFAllocatorRef, void *);
	OSStatus (*set_property)(void *, CFStringRef, CFTypeRef);
	OSStatus (*notification_barrier)(void *);
	const void *protocol_vtable;
} base_class;

/* VTVideoDecoderClass [V VCPHEVC 0x1e22b6948: version 3; offsets from VT's callers] */
typedef struct {
	uint64_t version;
	OSStatus (*start_session)(VTVideoDecoderRef, VTVideoDecoderSession, CMVideoFormatDescriptionRef);       /* +0x08 */
	OSStatus (*decode_frame)(VTVideoDecoderRef, VTVideoDecoderFrame, CMSampleBufferRef, uint32_t, uint32_t *); /* +0x10 */
	OSStatus (*copy_supported_properties)(VTVideoDecoderRef, CFDictionaryRef *);                            /* +0x18 */
	OSStatus (*set_properties)(VTVideoDecoderRef, CFDictionaryRef);                                         /* +0x20 */
	OSStatus (*copy_serializable_properties)(VTVideoDecoderRef, CFAllocatorRef, CFDictionaryRef *);         /* +0x28 */
	Boolean (*can_accept_format)(VTVideoDecoderRef, CMVideoFormatDescriptionRef);                           /* +0x30 */
	OSStatus (*finish_delayed_frames)(VTVideoDecoderRef);                                                   /* +0x38 */
	void *reserved[3];                                                                                      /* tile functions: none */
} decoder_class;

typedef struct {
	const void *reserved;
	const base_class *base;
	const decoder_class *derived;
} decoder_vtable;

typedef struct {
	VTVideoDecoderSession session;
	CFDataRef hvcc;
	hv_info info;
	hv_core *core;
	CFDictionaryRef colours;                /* attachments from the format description */
	OSType format;                          /* output format, 0 before the first picture */
	int width, height;
	uint64_t next_tag;
	struct { uint64_t tag; VTVideoDecoderFrame frame; bool used; } pending[MAX_PENDING];
} decoder;

/* The private functions, all from dlsym. */
static struct {
	CFTypeID (*class_id)(void);
	OSStatus (*derived_create)(CFAllocatorRef, const void *, CFTypeID, void *);
	void *(*storage)(void *);
	OSStatus (*set_attributes)(VTVideoDecoderSession, CFDictionaryRef);
	CVPixelBufferPoolRef (*pool)(VTVideoDecoderSession);
	OSStatus (*emit)(VTVideoDecoderSession, VTVideoDecoderFrame, OSStatus, uint32_t, CVImageBufferRef);
	CFDictionaryRef (*destination_attributes)(VTVideoDecoderSession);
	OSStatus (*register_with_info)(FourCharCode, CFDictionaryRef, void *);
	const CFStringRef *hw_key, *rating_key;
} vt;

static char strike_path[96];
static uint32_t struck;         /* 1: this process wrote its strike; 2: it cleared them */

static void
say(const char *format, ...)
{
	static int console = -2;
	char line[300];
	va_list ap;
	int n;

	va_start(ap, format);
	n = vsnprintf(line, sizeof(line), format, ap);
	va_end(ap);
	if (n <= 0) {
		return;
	}
	if (n >= (int)sizeof(line)) {
		n = sizeof(line) - 1;
	}
	if (console == -2) {
		console = open("/dev/console", O_WRONLY | O_NOCTTY | O_CLOEXEC);        /* the kernel's USB log, as NMTL and the camera do */
	}
	if (console >= 0) {
		(void)write(console, line, (size_t)n);
	}
	(void)write(2, line, (size_t)n);
}

/*
 * The dead-man. A crash in here costs mediaserverd, so sound, camera and every decode of the phone. A strike is written before the
 * first picture of a process and cleared after it: three strikes in a row and this decoder declines; VCPHEVC takes over.
 */
static int
strikes_read(void)
{
	static const char *const dirs[] = { "/var/mobile/Library/Caches", "/var/tmp", "/tmp" };
	char b[16] = "";
	int fd, n;

	if (strike_path[0] == '\0') {
		for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
			snprintf(strike_path, sizeof(strike_path), "%s/laurel-hevc-strikes", dirs[i]);
			fd = open(strike_path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
			if (fd >= 0) {
				close(fd);
				goto found;
			}
		}
		strike_path[0] = '-';   /* nowhere to write: no dead-man in this process */
		strike_path[1] = '\0';
	}
found:
	if (strike_path[0] == '-') {
		return 0;
	}
	fd = open(strike_path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		return 0;
	}
	n = (int)read(fd, b, sizeof(b) - 1);
	close(fd);
	return n > 0 ? atoi(b) : 0;
}

static void
strikes_write(int value)
{
	if (strike_path[0] == '\0' || strike_path[0] == '-') {
		return;
	}
	char b[16];
	int fd = open(strike_path, O_WRONLY | O_TRUNC | O_CLOEXEC);

	if (fd >= 0) {
		(void)write(fd, b, (size_t)snprintf(b, sizeof(b), "%d\n", value));
		close(fd);
	}
}

#include "vt_plugin_decode.h"
#include "vt_plugin_register.h"
