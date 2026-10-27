/*
 * NegroniCamera (iOSPlus10): ported from HakiOS userland/src/inject_media.c (commit 8851317), the hook part,
 * MIT License, Copyright (c) 2025-2026 the HakiOS authors (full text: userland/camera/LICENSE.HakiOS).
 * Our changes: see userland/camera/README.md "Changes to the HakiOS sources".
 *
 * NegroniCamera.driver: code of ours inside mediaserverd. mediaserverd loads every
 * .driver bundle in /System/Library/Audio/Plug-Ins/HAL at start (NegroniAudio.driver loads the same way); this
 * bundle's factory NegroniCamera_Create gives the HAL no audio driver (NULL), and its constructor, in
 * mediaserverd only, installs the method replacements below as soon as CMCapture is loaded.
 *
 * Guards (each fails safe: the method is left as it is, and mediaserverd is as without the bundle):
 *  - the dyld shared cache must be the 20H392 one (NEGRONICAM_CACHE_UUID): else nothing is replaced;
 *  - each method's implementation must be at its expected unslid 20H392 address (as HakiOS checks its
 *    20F66 ones), and its first instruction must be the one of the 20H392 cache (prologue): else that
 *    method is left alone and the log says "left alone";
 *  - the bundle pins itself in memory (RTLD_NODELETE): the HAL may let go of a plug-in whose factory gave
 *    nothing, and the replaced methods point into this image.
 *
 * The camera: +[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor] gives, where the stock one gives nil
 * (no Apple ISP driver: "Cannot find AppleH13CamIn driver"), a vendor made with our device's create
 * function (camera_device.c). With /dev/negronicam absent or failed, that create function fails at once,
 * so the capture stack has a vendor with no device instead of none at all [I: Camera.app shows its
 * "camera not available" state; the stock nil vendor came with a hung Camera launch, docs/notes.md "2026-10-26 handoff (main session, afternoon)"].
 * Scripts: scripts/camera/check-cache.sh checks the table against the cache on the host.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include "negronicam.h"

static void
say(const char *format, ...)
{
	char line[300];
	va_list ap;
	int n;

	va_start(ap, format);
	n = vsnprintf(line, sizeof(line), format, ap);
	va_end(ap);
	if (n < 0) {
		return;
	}
	if (n > (int)sizeof(line) - 1) {
		n = sizeof(line) - 1;
	}
	(void)write(2, line, (size_t)n);
	if (n > 0 && line[n - 1] == '\n') {
		line[n - 1] = 0;
	}
	os_log(OS_LOG_DEFAULT, "%{public}s", line);
}

extern const void *_dyld_get_shared_cache_range(size_t *length);
extern bool _dyld_get_shared_cache_uuid(uuid_t uuid);

#define CACHE_BASE 0x180000000UL                /* where the cache was built to be, before the slide (ipsw dyld info) */
#define NEGRONICAM_OFF_FILE "/var/db/negronicam/off"     /* present: the constructor does nothing */
#define NEGRONICAM_CACHE_UUID "8F970452-C9E3-3E88-B114-FEB1864BC9E0"   /* iOS 16.7.x 20H392 dyld_shared_cache_arm64 */

static uintptr_t slide;
static bool cache_ok;

/* +[BWCoreImageFilterRenderer prewarmPortraitFilterVersion:semanticStyleFilters:]: skipped (no portrait mode here) */
static void
prewarm_portrait_filter(__unused id self, __unused SEL selector, __unused int version, __unused BOOL styles)
{
}

/* ---- the camera's device vendor -------------------------------------------------------------------- */

extern int negroni_camera_device_create(const void *allocator, const void *options, void **out);
extern volatile bool negronicam_failed;
static IMP original_shared_vendor;

/* +[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor] */
static id
shared_vendor(id self, SEL selector)
{
	id vendor = ((id (*)(id, SEL))original_shared_vendor)(self, selector);
	static id camera_vendor;
	static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

	if (vendor != NULL) {
		return vendor;          /* (an Apple ISP driver after all: as it is) */
	}
	pthread_mutex_lock(&lock);
	if (camera_vendor == NULL) {
		bool present = access(NEGRONICAM_DEVICE, F_OK) == 0;
		id made = ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("BWFigCaptureDeviceVendor"), sel_registerName("alloc"));

		camera_vendor = ((id (*)(id, SEL, void *))objc_msgSend)(made, sel_registerName("initWithDeviceCreateFunction:"),
		    (void *)negroni_camera_device_create);
		say("negroni: camera hooks: the camera's device vendor %s (%s %s)\n", camera_vendor ? "made (camera_device.c)" :
		    "CANNOT BE MADE", NEGRONICAM_DEVICE, present ? "there" : "NOT there: the vendor's device is refused, no wait");
	}
	pthread_mutex_unlock(&lock);
	return camera_vendor;
}

/*
 * Video stabilization, of which this hardware has none: the capture graph's VIS node
 * (-[FigCaptureVISPipeline _newVISNodeWithUpstreamOutput:...]) is made with the ISP's processing
 * session, and this device has no such session, so the node comes back nil, the VIS pipeline with
 * it, the movie file sink's tail pipeline with that, and captureSession_buildGraphWithConfiguration
 * tears the whole graph down -- the preview too, for all that the preview has nothing to do with
 * stabilizing a recording. The connection's stabilization method is where the whole stack reads the
 * wish from (+[FigVideoCaptureConnectionConfiguration videoStabilizationMethods:includeIris:] ->
 * cspc_getVideoStabilizationType -> the connections' FigCaptureVideoStabilizationType), and 0 there
 * means none: the graph is then built without a VIS pipeline anywhere
 * (+[FigCaptureVISPipeline visPipelineIsRequiredForFigCaptureVideoStabilizationType:] says no to
 * every type but 2 and 3), and recordings are as steady as the hand that holds the phone.
 */
static int
video_stabilization_method(id self, SEL selector)
{
	(void)self;
	(void)selector;
	return 0;
}

/*
 * The type the stack acts on. The connection configuration arrives from the application's
 * AVFoundation with the type in it, which is read straight out of the object and not computed from
 * the method above (-[FigCaptureSessionParsedConfiguration _computeVideoStabilizationTypes] only
 * fills in what the client left out), so the wish has to be refused here as well.
 */
static int
video_stabilization_type(id self, SEL selector)
{
	(void)self;
	(void)selector;
	return 0;                       /* kFigCaptureVideoStabilizationType_None */
}

/*
 * The microphone, which the capture stack has none of here. A capture session's sound comes through
 * CoreMedia's own capture audio session -- BWAudioSourceNode's start sets its properties and reads
 * its pull format, all of it through a brokered plug-in of the audio HAL -- and that plug-in is not
 * on this phone: the node's start comes back with 'nope', the HAL's word for "no such thing".
 *
 * Camera.app's session has an audio input in it, because it is a session for photographs and for
 * video both. The graph starts its source nodes late (startDeferredSourceNodesIfNeeded) and takes
 * the first error it gets for the whole graph's, so the session reported AVCaptureSessionRuntimeError
 * to the application, which took the session down and built it again, two seconds later, for ever:
 * the camera's preview came in bursts of five frames with the sensor powering down in between.
 *
 * The node is told that it started. It then produces no sound -- which is all a phone with no
 * capture audio has to offer -- and the rest of the graph, the preview and the photograph, runs.
 * Only that one error is swallowed: a microphone that is there and fails for another reason still
 * takes the session down, as it should. (The kernel's own microphone, adsp=1 mic=4, is a different
 * path: AVAudioRecorder and Voice Memos record through it, and nothing here touches it.)
 */
#define ERROR_NO_SUCH_THING     1852797029      /* 'nope' */

static IMP original_audio_source_start;

static BOOL
audio_source_start(id self, SEL selector, id *error)
{
	BOOL started = ((BOOL (*)(id, SEL, id *))original_audio_source_start)(self, selector, error);
	id made = error != NULL ? *error : NULL;
	static bool said;

	if (started || made == NULL || ((long (*)(id, SEL))objc_msgSend)(made, sel_registerName("code")) != ERROR_NO_SUCH_THING) {
		return started;
	}
	*error = NULL;                  /* (autoreleased by the capture stack: not ours to give back) */
	if (!said) {
		said = true;
		say("negroni: camera hooks: there is no capture audio on this phone: the session's audio source gives nothing, "
		    "and the camera runs without it\n");
	}
	return true;
}

/*
 * A photograph's quality prioritization, "speed" at the most. Asked for "balanced" (Camera.app's) or
 * "quality", the capture device takes a scene for a low-light one whenever a frame was exposed at
 * least as long as the sensor's still image stabilization threshold
 * (-[BWFigVideoCaptureDevice _isLowLightSceneUsingFrameStatisticsByPortType:]) -- a threshold from
 * the sensor's tuning in CameraSetup.plist, 0 for a sensor it has no tuning for, as ours -- and
 * then asks the stream for a bracket of four frames for SIS fusion (captureType 4, BWSISNode), which
 * this port has nothing to fuse with: the photograph never came. With "speed" it asks for one frame
 * (-_resolveStillImageCaptureTypeFromStatisticsByPortType:..., captureType 1), which the stream
 * gives (camera_device.c, StillImageCaptureNow).
 */
static IMP original_quality_prioritization;

static int
quality_prioritization(id self, SEL selector)
{
	int asked = ((int (*)(id, SEL))original_quality_prioritization)(self, selector);
	static bool said;

	if (asked > 1 && !said) {
		said = true;
		say("negroni: camera hooks: a photograph's quality prioritization %d taken as 1 (speed): one frame, no SIS bracket\n",
		    asked);
	}
	return asked > 1 ? 1 : asked;
}

/*
 * A photograph's noise reduction (BWGNRNode, between the still image coordinator and the photo
 * encoder) is a FigSampleBufferProcessor of the iPhone's, which is handed the picture and never
 * hands one back here: the photograph stopped there, with no error, and the request with it (the
 * shutter's second press asked for nothing more). The picture goes past it to the node's output as
 * it came, as with no noise reduction to do.
 */
static void
gnr_render(id self, SEL selector, void *sample_buffer, id input)
{
	id output = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("output"));
	static bool said;

	(void)selector, (void)input;
	if (!said) {
		said = true;
		say("negroni: camera hooks: a photograph goes past the noise reduction, which has nothing to do it with here\n");
	}
	if (output != nil) {
		((void (*)(id, SEL, void *))objc_msgSend)(output, sel_registerName("emitSampleBuffer:"), sample_buffer);
	}
}

static bool
is_node(id node, const char *name)
{
	return node != nil && strcmp(object_getClassName(node), name) == 0;
}

/*
 * How long a photograph's encoding took, from the picture handed to the photo encoder node to the one
 * it hands on (HEVC in software, see register_hevc_encoder below: the slowest step of a photograph).
 */
static void
time_photo_encoder(id output, CMSampleBufferRef sample_buffer)
{
	CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample_buffer);
	static uint64_t began;
	static mach_timebase_info_data_t timebase;
	id connection, input;

	if (image == NULL || CVPixelBufferGetWidth(image) < 3000) {
		return;                 /* not a photograph (iOSPlus10: previews are up to 2016 wide, PREVIEW_BIN) */
	}
	if (is_node(((id (*)(id, SEL))objc_msgSend)(output, sel_registerName("node")), "BWPhotoEncoderNode")) {
		if (began != 0) {
			if (timebase.denom == 0) {
				mach_timebase_info(&timebase);
			}
			say("negroni: camera hooks: a photograph of %zux%zu encoded in %.0f ms\n", CVPixelBufferGetWidth(image),
			    CVPixelBufferGetHeight(image), (double)(mach_absolute_time() - began) * timebase.numer / timebase.denom / 1e6);
		}
		began = 0;
		return;
	}
	connection = ((id (*)(id, SEL))objc_msgSend)(output, sel_registerName("connection"));
	input = connection != nil ? ((id (*)(id, SEL))objc_msgSend)(connection, sel_registerName("input")) : nil;
	if (input != nil && is_node(((id (*)(id, SEL))objc_msgSend)(input, sel_registerName("node")), "BWPhotoEncoderNode")) {
		began = mach_absolute_time();
	}
}

/*
 * A node's output given no sample buffer at all, which no node takes: the session's audio source
 * (-[BWAudioSourceNode _generateSamples]), whose audio unit never started here (see audio_source_start
 * above), fills the silence by a timer with buffers it fails to make and emits them all the same --
 * NULL. Live Photo's staging node added that to an array (-[BWIrisStagingNode renderSampleBuffer:forInput:])
 * and mediaserverd died of the NSInvalidArgumentException, every half a minute with Live Photo on, the
 * preview black for a second each time. A NULL is not passed on.
 */
static IMP original_emit_sample_buffer;

static void
emit_sample_buffer(id self, SEL selector, CMSampleBufferRef sample_buffer)
{
	static bool said;

	if (sample_buffer == NULL) {
		if (!said) {
			said = true;
			say("negroni: camera hooks: a node's output was given no sample buffer (the silent audio source's): not passed on\n");
		}
		return;
	}
	time_photo_encoder(self, sample_buffer);
	((void (*)(id, SEL, CMSampleBufferRef))original_emit_sample_buffer)(self, selector, sample_buffer);
}

/*
 * The photograph's encoder. Camera.app asks for HEIC -- HEVC inside a HEIF file, which CMPhoto makes
 * through VideoToolbox -- and VideoToolbox here has no HEVC encoder but the iPhone's hardware ones
 * (com.apple.videotoolbox.videoencoder.hevc and .hevc.gva, behind its AVE): the photo encoder node
 * failed with kVTCouldNotFindVideoEncoderErr (-12908). Apple's software HEVC codec is in the system
 * all the same, VCPHEVC.videocodec, whose decoder VideoToolbox takes here for every HEIC picture (see
 * the top), and there is an encoder in it, HEVCVideoEncoder_CreateInstance, that iOS never registers:
 * the codec's VCPHEVCRegisterEncoder is an empty function. It is registered here, as the codec
 * registers its decoder (VTRegisterVideoDecoderWithInfo, not hardware accelerated).
 */
static void
register_hevc_encoder(void)
{
	void *codec = dlopen("/System/Library/VideoCodecs/VCPHEVC.videocodec", RTLD_NOW | RTLD_LOCAL);
	void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW | RTLD_GLOBAL);
	void *create = codec != NULL ? dlsym(codec, "HEVCVideoEncoder_CreateInstance") : NULL;
	int (*register_encoder)(uint32_t, CFDictionaryRef, void *) = vt != NULL ? dlsym(vt, "VTRegisterVideoEncoderWithInfo") : NULL;
	CFStringRef *id_key = vt != NULL ? dlsym(vt, "kVTVideoEncoderList_EncoderID") : NULL;
	CFStringRef *name_key = vt != NULL ? dlsym(vt, "kVTVideoEncoderList_EncoderName") : NULL;
	CFStringRef *hardware_key = vt != NULL ? dlsym(vt, "kVTVideoEncoderList_IsHardwareAccelerated") : NULL;
	int status;

	if (create == NULL || register_encoder == NULL || id_key == NULL || name_key == NULL || hardware_key == NULL) {
		say("negroni: camera hooks: no software HEVC encoder to register (%s)\n", codec == NULL ? "no VCPHEVC.videocodec" :
		    create == NULL ? "no HEVCVideoEncoder_CreateInstance" : "VideoToolbox without VTRegisterVideoEncoderWithInfo");
		return;
	}
	const void *keys[] = { *id_key, *name_key, *hardware_key };
	const void *values[] = { CFSTR("com.apple.videotoolbox.videoencoder.hevc.vcp"), CFSTR("HEVC (VCPHEVC, software)"),
		kCFBooleanFalse };
	CFDictionaryRef info = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);

	status = register_encoder('hvc1', info, create);
	CFRelease(info);
	say("negroni: camera hooks: the software HEVC encoder of VCPHEVC.videocodec registered for 'hvc1' (%d)\n", status);
}

/*
 * The methods replaced, each as soon as its class exists. `expected` is the unslid address of the code in
 * iOS 16.7.x (20H392, `ipsw dyld symaddr`, docs/camera-ios-2026-10-27.md section 3) and `first` its first
 * instruction word there: a method that is not what it was is left alone. `original`, where there is one,
 * keeps what was there. Checked on the host by scripts/camera/check-cache.sh.
 */
static struct replacement {
	const char *class_name, *selector;
	uintptr_t expected;
	uint32_t first;
	IMP replacement, *original;
	bool instance;                  /* an instance method, not a class method */
	bool done;
} replacements[] = {
	{ "BWCoreImageFilterRenderer", "prewarmPortraitFilterVersion:semanticStyleFilters:", 0x1a2165b8cUL, 0xa9be4ff4u,
	  (IMP)prewarm_portrait_filter, NULL, false, false },
	{ "BWFigCaptureDeviceVendor", "sharedCaptureDeviceVendor", 0x1a1f40c84UL, 0xa9bd57f6u,
	  (IMP)shared_vendor, &original_shared_vendor, false, false },
	{ "BWAudioSourceNode", "start:", 0x1a1f3f998UL, 0xd10583ffu,
	  (IMP)audio_source_start, &original_audio_source_start, true, false },
	{ "FigVideoCaptureConnectionConfiguration", "videoStabilizationMethod", 0x1a1ee9e78UL, 0xb01db7e8u,
	  (IMP)video_stabilization_method, NULL, true, false },
	{ "FigVideoCaptureConnectionConfiguration", "videoStabilizationType", 0x1a2128ec8UL, 0xd01da5e8u,
	  (IMP)video_stabilization_type, NULL, true, false },
	{ "FigCaptureStillImageSettings", "qualityPrioritization", 0x1a1fa335cUL, 0xb940fc00u,
	  (IMP)quality_prioritization, &original_quality_prioritization, true, false },
	{ "BWGNRNode", "renderSampleBuffer:forInput:", 0x1a1f18338UL, 0xd102c3ffu,
	  (IMP)gnr_render, NULL, true, false },
	{ "BWNodeOutput", "emitSampleBuffer:", 0x1a1ef3760UL, 0xd10343ffu,
	  (IMP)emit_sample_buffer, &original_emit_sample_buffer, true, false },
};

static unsigned replaced, left_alone;

static void
image_added(__unused const struct mach_header *header, __unused intptr_t image_slide)
{
	for (size_t i = 0; i < sizeof(replacements) / sizeof(replacements[0]); i++) {
		struct replacement *r = &replacements[i];
		Class cls;
		Method method;
		IMP original;
		uint32_t first = 0;

		if (r->done || (cls = objc_getClass(r->class_name)) == NULL) {
			continue;
		}
		r->done = true;
		method = r->instance ? class_getInstanceMethod(cls, sel_registerName(r->selector)) :
		    class_getClassMethod(cls, sel_registerName(r->selector));
		original = method ? method_getImplementation(method) : NULL;
		if (original != NULL && (uintptr_t)original == r->expected + slide) {
			memcpy(&first, (const void *)original, sizeof(first));
		}
		if (original == NULL || (uintptr_t)original != r->expected + slide || first != r->first) {
			left_alone++;
			say("negroni: camera hooks: %c[%s %s]: found %#lx (first word %#x), expected %#lx (%#x); left alone\n",
			    r->instance ? '-' : '+', r->class_name, r->selector, original ? (unsigned long)((uintptr_t)original - slide) : 0UL,
			    first, (unsigned long)r->expected, r->first);
			continue;
		}
		if (r->original != NULL) {
			*r->original = original;
		}
		method_setImplementation(method, r->replacement);
		replaced++;
		say("negroni: camera hooks: %c[%s %s] replaced (%u of %zu)\n", r->instance ? '-' : '+', r->class_name, r->selector,
		    replaced, sizeof(replacements) / sizeof(replacements[0]));
	}
}

/* keep this image loaded for the life of the process: the replaced methods point into it (false: not pinned) */
static bool
pin_self(void)
{
	Dl_info info;

	if (dladdr((const void *)pin_self, &info) == 0 || info.dli_fname == NULL) {
		say("negroni: camera hooks: cannot find this image (dladdr): nothing replaced\n");
		return false;
	}
	if (dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD | RTLD_NODELETE) == NULL) {
		say("negroni: camera hooks: cannot pin %s (%s): nothing replaced\n", info.dli_fname, dlerror());
		return false;
	}
	return true;
}

__attribute__((constructor))
static void
negroni_camera_init(void)
{
	const char *name = getprogname();
	size_t length = 0;
	uuid_t uuid;
	uuid_string_t text = "?";

	if (name == NULL || strcmp(name, "mediaserverd") != 0) {
		return;
	}
	/* hot off switch (scripts/camera/phone-camera.sh off|on): no hooks, mediaserverd as without the bundle */
	if (access(NEGRONICAM_OFF_FILE, F_OK) == 0) {
		say("negroni: camera hooks: %s exists: off, nothing replaced\n", NEGRONICAM_OFF_FILE);
		return;
	}
	if (_dyld_get_shared_cache_uuid(uuid)) {
		uuid_unparse_upper(uuid, text);
	}
	cache_ok = strcmp(text, NEGRONICAM_CACHE_UUID) == 0;
	if (!cache_ok) {
		say("negroni: camera hooks: dyld shared cache %s is not 20H392 (%s): nothing replaced\n", text, NEGRONICAM_CACHE_UUID);
		return;
	}
	if (!pin_self()) {
		return;         /* the HAL could unload us under replaced methods: no hooks at all */
	}
	slide = (uintptr_t)_dyld_get_shared_cache_range(&length) - CACHE_BASE;
	say("negroni: camera hooks: in mediaserverd (pid %d), cache 20H392, slide %#lx, %s %s\n", getpid(), (unsigned long)slide,
	    NEGRONICAM_DEVICE, access(NEGRONICAM_DEVICE, F_OK) == 0 ? "there" : "NOT there (boot-arg negronicam=7)");
	if (access(NEGRONICAM_DEVICE, F_OK) == 0) {
		register_hevc_encoder();
	}
	_dyld_register_func_for_add_image(image_added);         /* also called for every image already there */
}

/*
 * The CFPlugIn factory the HAL calls (Info.plist CFPlugInFactories): no audio driver here. The HAL loads the
 * bundle's code to call it, which is what runs the constructor above.
 */
__attribute__((visibility("default"))) void *NegroniCamera_Create(CFAllocatorRef allocator, CFUUIDRef type);

void *
NegroniCamera_Create(__unused CFAllocatorRef allocator, __unused CFUUIDRef type)
{
	static bool said;

	if (!said) {
		said = true;
		say("negroni: camera hooks: HAL factory called: no audio driver in this bundle (%u methods replaced, %u left alone so far)\n",
		    replaced, left_alone);
	}
	return NULL;
}
