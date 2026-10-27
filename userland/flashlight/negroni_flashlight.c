/*
 * NegroniFlashlight (iOSPlus10): the iOS side of the rear torch. Kernel: patch 0387 (bsd/dev/negroni_flash.c,
 * /dev/negroniflash, root:mobile 0660, write "0".."10"). Merge into NegroniCamera.driver (README.md here).
 *
 * How iOS 16.7.16 (20H392) drives the flashlight [V: disassembly of the 20H392 cache, out/camera/ios-re]:
 *   Control Center / AVFlashlight -> mediaserverd FigFlashlight (CMCapture flashlight_*):
 *     +[AVFlashlight hasFlashlight] = MGGetBoolAnswer("camera-flash") (AVFCapture 0x19f0c6338); MobileGestalt
 *       answers true when IODeviceTree:/product/camera has a "flash" property (libMobileGestalt 0x19c563598,
 *       presence only, any value).
 *     flashlight_setupDevice (0x1a2000a28): [BWFigCaptureDeviceVendor sharedCaptureDeviceVendor] ->
 *       registerClientWithPID:clientDescription:"FigFlashlight":clientPriority:canStealFromClientsWithSamePriority:
 *       deviceSharingWithOtherClientsAllowed:deviceAvailabilityChangedHandler: -> copyDeviceForClient:
 *       informClientWhenDeviceAvailableAgain:error: -> copyStreamForFlashlightWithPosition:1 (back) deviceType:2
 *       (wide) forDevice: -> if the stream's supportedProperties has HighCurrentTorchEnabled, setProperty it.
 *     flashlight_SetLevel (0x1a2000860): level > FigCaptureThermalMonitor maxTorchLevel -> error -16530;
 *       flashlight_setLevelInternal (0x1a2000bdc): [stream setProperty:kFigCaptureStreamProperty_TorchLevel
 *       ("TorchLevel") value:NSNumber float].
 *     flashlight_IsAvailable (0x1a20007b0): [vendor activeDeviceEquals:device].
 *     flashlight_teardownDevice (0x1a1f3e540): TorchLevel 0, then takeBackDevice:forClient:
 *       informClientWhenDeviceAvailableAgain:.
 *     the availability listener block (0x1a1fa9e70): activeDeviceEquals:, activeDeviceClientPriority.
 *   Camera.app (AVCaptureDevice torchMode): hasTorch/hasFlash come from CMCapture D22/AVCaptureSession.plist
 *   (back wide built-in_video:0 has hasTorch = hasFlash = true [V, plist of the phone]); the level reaches
 *   the same stream property "TorchLevel".
 *
 * So with the NegroniCamera device (camera_device.c) the stream's TorchLevel setter is the only place to
 * change: it calls negroni_flashlight_set(). Without a camera device (no /dev/negronicam, or it failed), the
 * camera vendor gives FigFlashlight no device; negroni_flashlight_vendor_for() then gives FigFlashlight (only
 * FigFlashlight, by the caller address) a small vendor of its own whose stream sets the level, as HakiOS
 * userland/src/inject_media.c does (MIT, the idea; this code is ours).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "negroni_flashlight.h"

static int fl_fd = -1;
static unsigned fl_said;
static pthread_mutex_t fl_lock = PTHREAD_MUTEX_INITIALIZER;
static Class fl_vendor_class, fl_device_class, fl_stream_class;
static id fl_vendor;
static uintptr_t fl_slide;

/*
 * The FigFlashlight code that asks for the vendor (unslid 20H392 addresses; the return address of the hook
 * lies inside): flashlight_IsAvailable .. flashlight_setupDevice (one block: IsAvailable, PowerOn, SetLevel,
 * GetLevel, NotifyForCurrentState, setupDevice), flashlight_teardownDevice, the availability listener block.
 */
static const struct { uintptr_t from, to; } fl_callers[] = {
	{ 0x1a20007b0UL, 0x1a2000bdcUL },
	{ 0x1a1f3e540UL, 0x1a1f3e668UL },
	{ 0x1a1fa9e70UL, 0x1a1faa0f8UL },
};

void
negroni_flashlight_set(float level)
{
	char text[8];
	unsigned n;
	ssize_t w = -1;

	level = level < 0 ? 0 : level > 1 ? 1 : level;
	n = (unsigned)(level * NEGRONIFLASH_LEVELS + 0.5f);
	if (level > 0 && n == 0) {
		n = 1;
	}
	int len = snprintf(text, sizeof(text), "%u\n", n);
	pthread_mutex_lock(&fl_lock);
	if (fl_fd >= 0) {
		w = write(fl_fd, text, (size_t)len);
	}
	pthread_mutex_unlock(&fl_lock);
	if (w != len || fl_said < 40) {
		fl_said++;
		os_log(OS_LOG_DEFAULT, "negroni: flashlight: TorchLevel %.3f -> level %u/%d%s", (double)level, n,
		    NEGRONIFLASH_LEVELS, fl_fd < 0 ? " (NO /dev/negroniflash)" : w != len ? " (REFUSED by the kernel)" : "");
	}
}

/* ---- the fallback vendor (no camera device) ---- */

static int
fv_register(id self, SEL sel, int pid, id desc, int priority, BOOL steal, BOOL share, id handler)
{
	return 1;                               /* the client id */
}

static id
fv_copy_device(id self, SEL sel, int client, BOOL inform, int *error)
{
	if (error != NULL) {
		*error = 0;
	}
	return class_createInstance(fl_device_class, 0);        /* +1, released by FigFlashlight */
}

static id
fv_copy_stream(id self, SEL sel, int position, int type, id device)
{
	return device != NULL && object_getClass(device) == fl_device_class ? class_createInstance(fl_stream_class, 0) : NULL;
}

static void
fv_take_back(id self, SEL sel, id device, int client, BOOL inform)
{
	negroni_flashlight_set(0);
}

static BOOL
fv_active_equals(id self, SEL sel, id device)
{
	return device == NULL || object_getClass(device) == fl_device_class;
}

static int
fv_active_priority(id self, SEL sel)
{
	return 0;
}

/* no HighCurrentTorchEnabled: FigFlashlight then sets nothing but TorchLevel */
static CFDictionaryRef
fs_supported(id self, SEL sel)
{
	static CFDictionaryRef none;
	if (none == NULL) {
		none = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	}
	return none;
}

static int
fs_set(id self, SEL sel, CFStringRef key, CFTypeRef value)
{
	float level = 0;
	if (key != NULL && CFEqual(key, CFSTR("TorchLevel"))) {
		if (value != NULL && CFGetTypeID(value) == CFNumberGetTypeID()) {
			CFNumberGetValue((CFNumberRef)value, kCFNumberFloatType, &level);
		}
		negroni_flashlight_set(level);
	}
	return 0;
}

struct fl_method {
	const char *sel, *types;
	IMP imp;
};

static Class
fl_make_class(const char *name, const struct fl_method *m, size_t count)
{
	Class c = objc_allocateClassPair(objc_getClass("NSObject"), name, 0);
	if (c == NULL) {
		return objc_getClass(name);
	}
	for (size_t i = 0; i < count; i++) {
		class_addMethod(c, sel_registerName(m[i].sel), m[i].imp, m[i].types);
	}
	objc_registerClassPair(c);
	return c;
}

bool
negroni_flashlight_init(uintptr_t slide)
{
	static const struct fl_method vendor[] = {
		{ "registerClientWithPID:clientDescription:clientPriority:canStealFromClientsWithSamePriority:"
		  "deviceSharingWithOtherClientsAllowed:deviceAvailabilityChangedHandler:", "i@:i@iBB@", (IMP)fv_register },
		{ "copyDeviceForClient:informClientWhenDeviceAvailableAgain:error:", "@@:iB^i", (IMP)fv_copy_device },
		{ "copyStreamForFlashlightWithPosition:deviceType:forDevice:", "@@:ii@", (IMP)fv_copy_stream },
		{ "takeBackDevice:forClient:informClientWhenDeviceAvailableAgain:", "v@:@iB", (IMP)fv_take_back },
		{ "activeDeviceEquals:", "B@:@", (IMP)fv_active_equals },
		{ "activeDeviceClientPriority", "i@:", (IMP)fv_active_priority },
	};
	static const struct fl_method stream[] = {
		{ "supportedProperties", "@@:", (IMP)fs_supported },
		{ "setProperty:value:", "i@:@@", (IMP)fs_set },
	};

	fl_slide = slide;
	fl_fd = open(NEGRONIFLASH_DEVICE, O_WRONLY | O_CLOEXEC);
	if (fl_fd < 0) {
		os_log(OS_LOG_DEFAULT, "negroni: flashlight: off: %s cannot be opened (kernel torch off or absent)",
		    NEGRONIFLASH_DEVICE);
		return false;
	}
	fl_vendor_class = fl_make_class("NegroniFlashlightVendor", vendor, sizeof(vendor) / sizeof(vendor[0]));
	fl_device_class = fl_make_class("NegroniFlashlightDevice", NULL, 0);
	fl_stream_class = fl_make_class("NegroniFlashlightStream", stream, sizeof(stream) / sizeof(stream[0]));
	os_log(OS_LOG_DEFAULT, "negroni: flashlight: on: %s open", NEGRONIFLASH_DEVICE);
	return true;
}

void *
negroni_flashlight_vendor_for(uintptr_t return_address)
{
	uintptr_t caller = return_address - fl_slide;
	if (fl_fd < 0 || fl_vendor_class == NULL) {
		return NULL;
	}
	for (size_t i = 0; i < sizeof(fl_callers) / sizeof(fl_callers[0]); i++) {
		if (caller >= fl_callers[i].from && caller < fl_callers[i].to) {
			pthread_mutex_lock(&fl_lock);
			if (fl_vendor == NULL) {
				fl_vendor = class_createInstance(fl_vendor_class, 0);
				os_log(OS_LOG_DEFAULT, "negroni: flashlight: no camera device: FigFlashlight gets its own vendor");
			}
			pthread_mutex_unlock(&fl_lock);
			return (void *)fl_vendor;
		}
	}
	return NULL;
}
