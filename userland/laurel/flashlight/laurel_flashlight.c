/*
 * LaurelFlashlight.driver (iOSPlus10, Mi A3 laurel_sprout): the iOS side of the torch. Kernel: patch 2781
 * (bsd/dev/laurel_torch.c, /dev/laureltorch root:mobile 0660, write "0".."100" percent).
 *
 * How iOS 16.7.x (20H392) drives the flashlight [V: negroni's disassembly of the same cache, userland/flashlight/
 * README.md; addresses checked again on the laurel root's cache (UUID below): +[BWFigCaptureDeviceVendor
 * sharedCaptureDeviceVendor] at 0x1a1f40c84 starts with stp x22, x21, [sp, #-0x30]!; flashlight_setupDevice at
 * 0x1a2000a28 sends it at 0x1a2000a58]:
 *   Control Center / AVFlashlight -> XPC com.apple.coremedia.flashlight (a MachService of mediaserverd [V root plist])
 *   -> mediaserverd FigFlashlight (CMCapture flashlight_*): [BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]
 *   -> registerClientWithPID:... -> copyDeviceForClient:... -> copyStreamForFlashlightWithPosition:1 deviceType:2
 *   forDevice: -> [stream setProperty:"TorchLevel" value:NSNumber float 0..1]; teardown: TorchLevel 0 + takeBackDevice:.
 *   The button: +[AVFlashlight hasFlashlight] = MGGetBoolAnswer("camera-flash") = IODeviceTree:/product/camera
 *   "flash" (the kernel's LaurelTorch.cpp publishes it only when this bundle is in the root).
 *
 * One owner (2026-11-01, boot 18:40): a root with NegroniCamera.driver has its flashlight there (userland/camera/
 * camera_device.c torch_set): that plug-in replaces the same method and starts the same server. This bundle is only for a
 * root without it (CAMERA=0; scripts/laurel/root-flashlight.sh installs one or the other) and stands down when it sees it.
 * Such a root has StartRecorderServer false (topaz sweet-root-tweaks.py), so mediaserverd
 * has no capture device vendor and starts no FigFlashlight server. This bundle (loaded by the HAL in mediaserverd,
 * as RedwoodAudio.driver; its factory gives the HAL no driver) does two things in mediaserverd:
 *   1. replaces +[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]: for calls from FigFlashlight code (by
 *      return address, 20H392 ranges) it gives a small vendor of its own (one device, one stream that sets
 *      TorchLevel on /dev/laureltorch); every other caller gets the stock answer;
 *   2. starts FigFlashlightServerStart (only that server: the others need a camera) after the hook is in.
 * Guards (each one off = nothing changed, mediaserverd as without the bundle, one line why):
 *   the cache UUID is 20H392's; the method's address and first word are the expected ones; /dev/laureltorch opens;
 *   the bundle pins itself (RTLD_NODELETE); StartRecorderServer true = mediaserverd starts the servers itself (no
 *   second start). Messages FigFlashlight sends that these objects do not know are absorbed (nil) and logged
 *   once each, so a new selector cannot crash mediaserverd. Kill switch: TORCH=0 at root build, or /var/db/laurel/
 *   flashlight-off (file present = nothing done), or the kernel's torch=0 (no /dev/laureltorch).
 * The idea of a FigFlashlight-only vendor is HakiOS userland/src/inject_media.c (MIT) via negroni; this code is ours.
 * Lines (os_log and /dev/console = the USB log): "LAUREL FLASHLIGHT: on: ..." / "LAUREL FLASHLIGHT: off: <why>",
 * "LAUREL FLASHLIGHT: TorchLevel L -> P %" (first 40 and every refused write).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <uuid/uuid.h>

#define LF_DEVICE       "/dev/laureltorch"
#define LF_OFF_FILE     "/var/db/laurel/flashlight-off"
#define LF_CAMERA       "/System/Library/Audio/Plug-Ins/HAL/NegroniCamera.driver/NegroniCamera"
#define LF_CAMERA_OFF   "/var/db/negronicam/off"        /* NEGRONICAM_OFF_FILE: that plug-in then does nothing */
#define LF_CACHE_UUID   "8F970452-C9E3-3E88-B114-FEB1864BC9E0"  /* iOS 16.7.x 20H392 dyld_shared_cache_arm64 */
#define LF_CACHE_BASE   0x180000000UL
#define LF_VENDOR_IMP   0x1a1f40c84UL   /* +[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor] */
#define LF_VENDOR_FIRST 0xa9bd57f6u     /* stp x22, x21, [sp, #-0x30]! */

extern const void *_dyld_get_shared_cache_range(size_t *length);
extern bool _dyld_get_shared_cache_uuid(uuid_t uuid);

static int lf_fd = -1, lf_console = -1;
static uintptr_t lf_slide;
static pthread_mutex_t lf_lock = PTHREAD_MUTEX_INITIALIZER;
static IMP lf_original_vendor;
static bool lf_hooked, lf_looked;
static Class lf_vendor_class, lf_device_class, lf_stream_class;
static id lf_vendor;
static unsigned lf_said;

/* FigFlashlight code that asks for the vendor (unslid 20H392; negroni userland/flashlight/negroni_flashlight.c) */
static const struct { uintptr_t from, to; } lf_callers[] = {
	{ 0x1a20007b0UL, 0x1a2000bdcUL },       /* IsAvailable .. setupDevice */
	{ 0x1a1f3e540UL, 0x1a1f3e668UL },       /* teardownDevice */
	{ 0x1a1fa9e70UL, 0x1a1faa0f8UL },       /* the availability listener block */
};

static void
say(const char *format, ...)
{
	char line[300];
	va_list ap;
	va_start(ap, format);
	int n = vsnprintf(line, sizeof(line), format, ap);
	va_end(ap);
	if (n < 0) {
		return;
	}
	n = n > (int)sizeof(line) - 2 ? (int)sizeof(line) - 2 : n;
	os_log(OS_LOG_DEFAULT, "%{public}s", line);
	line[n] = '\n';
	if (lf_console < 0) {
		lf_console = open("/dev/console", O_WRONLY | O_NOCTTY | O_CLOEXEC);
	}
	if (lf_console >= 0) {
		(void)write(lf_console, line, (size_t)n + 1);
	}
}

/* TorchLevel 0..1 -> /dev/laureltorch percent (>0 is at least 1 %) */
static void
lf_set(float level)
{
	char text[8];
	level = level < 0 ? 0 : level > 1 ? 1 : level;
	unsigned p = (unsigned)(level * 100.0f + 0.5f);
	if (level > 0 && p == 0) {
		p = 1;
	}
	int len = snprintf(text, sizeof(text), "%u\n", p);
	pthread_mutex_lock(&lf_lock);
	ssize_t w = lf_fd >= 0 ? write(lf_fd, text, (size_t)len) : -1;
	pthread_mutex_unlock(&lf_lock);
	if (w != len || lf_said < 40) {
		lf_said++;
		say("LAUREL FLASHLIGHT: TorchLevel %.3f -> %u %%%s", (double)level, p,
		    w == len ? "" : " (REFUSED by the kernel: see LAUREL TORCH lines)");
	}
}

/* ---- the FigFlashlight vendor, device and stream ---------------------------------------------------- */

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
	return class_createInstance(lf_device_class, 0);        /* +1: FigFlashlight releases it */
}

static id
fv_copy_stream(id self, SEL sel, int position, int type, id device)
{
	return device != NULL && object_getClass(device) == lf_device_class ? class_createInstance(lf_stream_class, 0) : NULL;
}

static void
fv_take_back(id self, SEL sel, id device, int client, BOOL inform)
{
	lf_set(0);
}

static BOOL
fv_active_equals(id self, SEL sel, id device)
{
	return device == NULL || object_getClass(device) == lf_device_class;
}

static int
fv_active_priority(id self, SEL sel)
{
	return 0;
}

/* no HighCurrentTorchEnabled: FigFlashlight then sets only TorchLevel */
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
	if (key != NULL && CFGetTypeID(key) == CFStringGetTypeID() && CFEqual(key, CFSTR("TorchLevel"))) {
		float level = 0;
		if (value != NULL && CFGetTypeID(value) == CFNumberGetTypeID()) {
			CFNumberGetValue((CFNumberRef)value, kCFNumberFloatType, &level);
		}
		lf_set(level);
	}
	return 0;
}

/* an unknown message: nil / 0, logged once per selector (no NSInvalidArgumentException in mediaserverd) */
static id
lf_signature(id self, SEL sel, SEL asked)
{
	struct objc_super up = { self, objc_getClass("NSObject") };
	id sig = ((id (*)(struct objc_super *, SEL, SEL))objc_msgSendSuper)(&up, sel, asked);
	if (sig == NULL) {
		sig = ((id (*)(Class, SEL, const char *))objc_msgSend)(objc_getClass("NSMethodSignature"),
		    sel_registerName("signatureWithObjCTypes:"), "@@:");
	}
	return sig;
}

static void
lf_forward(id self, SEL sel, id invocation)
{
	static const char *seen[32];
	static unsigned nseen;
	SEL asked = ((SEL (*)(id, SEL))objc_msgSend)(invocation, sel_registerName("selector"));
	const char *name = sel_getName(asked);
	pthread_mutex_lock(&lf_lock);
	bool first = true;
	for (unsigned i = 0; i < nseen; i++) {
		first &= seen[i] != name;
	}
	if (first && nseen < 32) {
		seen[nseen++] = name;
	}
	pthread_mutex_unlock(&lf_lock);
	if (first) {
		say("LAUREL FLASHLIGHT: %s got -%s: not known, answered nil", class_getName(object_getClass(self)), name);
	}
}

struct lf_method {
	const char *sel, *types;
	IMP imp;
};

static Class
lf_make_class(const char *name, const struct lf_method *m, size_t count)
{
	Class c = objc_allocateClassPair(objc_getClass("NSObject"), name, 0);
	if (c == NULL) {
		return objc_getClass(name);
	}
	for (size_t i = 0; i < count; i++) {
		class_addMethod(c, sel_registerName(m[i].sel), m[i].imp, m[i].types);
	}
	class_addMethod(c, sel_registerName("methodSignatureForSelector:"), (IMP)lf_signature, "@@::");
	class_addMethod(c, sel_registerName("forwardInvocation:"), (IMP)lf_forward, "v@:@");
	objc_registerClassPair(c);
	return c;
}

static void
lf_make_classes(void)
{
	static const struct lf_method vendor[] = {
		{ "registerClientWithPID:clientDescription:clientPriority:canStealFromClientsWithSamePriority:"
		  "deviceSharingWithOtherClientsAllowed:deviceAvailabilityChangedHandler:", "i@:i@iBB@", (IMP)fv_register },
		{ "copyDeviceForClient:informClientWhenDeviceAvailableAgain:error:", "@@:iB^i", (IMP)fv_copy_device },
		{ "copyStreamForFlashlightWithPosition:deviceType:forDevice:", "@@:ii@", (IMP)fv_copy_stream },
		{ "takeBackDevice:forClient:informClientWhenDeviceAvailableAgain:", "v@:@iB", (IMP)fv_take_back },
		{ "activeDeviceEquals:", "B@:@", (IMP)fv_active_equals },
		{ "activeDeviceClientPriority", "i@:", (IMP)fv_active_priority },
	};
	static const struct lf_method stream[] = {
		{ "supportedProperties", "@@:", (IMP)fs_supported },
		{ "setProperty:value:", "i@:@@", (IMP)fs_set },
	};
	lf_vendor_class = lf_make_class("LaurelFlashlightVendor", vendor, sizeof(vendor) / sizeof(vendor[0]));
	lf_device_class = lf_make_class("LaurelFlashlightDevice", NULL, 0);
	lf_stream_class = lf_make_class("LaurelFlashlightStream", stream, sizeof(stream) / sizeof(stream[0]));
}

/* +[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor] */
static id
lf_shared_vendor(id self, SEL sel)
{
	uintptr_t caller = (uintptr_t)__builtin_return_address(0) - lf_slide;
	for (size_t i = 0; i < sizeof(lf_callers) / sizeof(lf_callers[0]); i++) {
		if (caller >= lf_callers[i].from && caller < lf_callers[i].to) {
			pthread_mutex_lock(&lf_lock);
			if (lf_vendor == NULL) {
				lf_vendor = class_createInstance(lf_vendor_class, 0);
				say("LAUREL FLASHLIGHT: FigFlashlight asked for the capture device vendor: it gets the torch vendor "
				    "(caller %#lx)", (unsigned long)caller);
			}
			pthread_mutex_unlock(&lf_lock);
			return lf_vendor;
		}
	}
	return ((id (*)(id, SEL))lf_original_vendor)(self, sel);
}

static void
lf_image_added(__unused const struct mach_header *header, __unused intptr_t slide)
{
	Class cls;
	if (lf_looked || (cls = objc_getClass("BWFigCaptureDeviceVendor")) == NULL) {
		return;
	}
	lf_looked = true;
	Method m = class_getClassMethod(cls, sel_registerName("sharedCaptureDeviceVendor"));
	IMP imp = m != NULL ? method_getImplementation(m) : NULL;
	uint32_t first = 0;
	if (imp != NULL && (uintptr_t)imp == LF_VENDOR_IMP + lf_slide) {
		memcpy(&first, (const void *)imp, sizeof(first));
	}
	if (imp == NULL || (uintptr_t)imp != LF_VENDOR_IMP + lf_slide || first != LF_VENDOR_FIRST) {
		/* the first word is read only at the expected address: another image's replacement shows 0 here */
		Dl_info info;
		bool named = imp != NULL && dladdr((const void *)imp, &info) != 0 && info.dli_fname != NULL;
		say("LAUREL FLASHLIGHT: off: +[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor] is %#lx in %s (first word %#x), "
		    "expected %#lx (%#x): left alone, no FigFlashlight server", imp ? (unsigned long)((uintptr_t)imp - lf_slide) : 0UL,
		    named ? info.dli_fname : "an unknown image", first, LF_VENDOR_IMP, LF_VENDOR_FIRST);
		return;
	}
	lf_original_vendor = imp;
	method_setImplementation(m, (IMP)lf_shared_vendor);
	lf_hooked = true;
}

/* the stock rule (MediaToolbox feServer_ShouldStartSubServer): no plist or no key = start; else the key's value */
static int
lf_stock_starts_servers(void)
{
	CFPropertyListRef (*create)(CFStringRef) = (CFPropertyListRef (*)(CFStringRef))dlsym(RTLD_DEFAULT, "CelestialCFCreatePropertyList");
	const void *value = NULL;
	int starts = 1;
	if (create == NULL) {
		return -1;
	}
	CFPropertyListRef plist = create(CFSTR("SubServerConfiguration.plist"));
	if (plist != NULL && CFGetTypeID(plist) == CFDictionaryGetTypeID() &&
	    CFDictionaryGetValueIfPresent((CFDictionaryRef)plist, CFSTR("StartRecorderServer"), &value) &&
	    value != NULL && CFGetTypeID(value) == CFBooleanGetTypeID()) {
		starts = value == kCFBooleanTrue;
	}
	if (plist != NULL) {
		CFRelease(plist);
	}
	return starts;
}

/* on the main queue, after FigMediaServerStart: CMCapture in, the hook in, then the one server */
static void
lf_start_server(__unused void *context)
{
	int stock = lf_stock_starts_servers();
	void *cm = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW | RTLD_GLOBAL);
	if (cm == NULL) {
		say("LAUREL FLASHLIGHT: off: CMCapture does not load (%s)", dlerror());
		return;
	}
	lf_image_added(NULL, 0);
	if (!lf_hooked) {
		return;                 /* lf_image_added said why */
	}
	if (stock != 0) {
		say(stock > 0 ? "LAUREL FLASHLIGHT: on: vendor hook in; StartRecorderServer is on: mediaserverd starts FigFlashlight itself" :
		    "LAUREL FLASHLIGHT: off: CelestialCFCreatePropertyList not found (cannot tell whether mediaserverd starts the servers)");
		return;
	}
	void (*start)(void) = (void (*)(void))dlsym(cm, "FigFlashlightServerStart");
	if (start == NULL) {
		say("LAUREL FLASHLIGHT: off: FigFlashlightServerStart not found in CMCapture");
		return;
	}
	start();
	say("LAUREL FLASHLIGHT: on: FigFlashlight server started (com.apple.coremedia.flashlight), vendor hook in, %s open: "
	    "Control Center TorchLevel 0..1 -> 0..100 %% (kernel cap 150 mA)", LF_DEVICE);
}

static bool
lf_pin_self(void)
{
	Dl_info info;
	if (dladdr((const void *)lf_pin_self, &info) == 0 || info.dli_fname == NULL) {
		return false;
	}
	return dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD | RTLD_NODELETE) != NULL;
}

__attribute__((constructor))
static void
lf_init(void)
{
	const char *name = getprogname();
	uuid_t uuid;
	uuid_string_t text = "?";
	size_t length = 0;

	if (name == NULL || strcmp(name, "mediaserverd") != 0) {
		return;
	}
	if (access(LF_OFF_FILE, F_OK) == 0) {
		say("LAUREL FLASHLIGHT: off: %s exists", LF_OFF_FILE);
		return;
	}
	if (access(LF_CAMERA, F_OK) == 0 && access(LF_CAMERA_OFF, F_OK) != 0) {
		say("LAUREL FLASHLIGHT: off: NegroniCamera.driver is in the root: it owns the flashlight (LAUREL CAMERA: ios: the flashlight lines)");
		return;
	}
	if (_dyld_get_shared_cache_uuid(uuid)) {
		uuid_unparse_upper(uuid, text);
	}
	if (strcmp(text, LF_CACHE_UUID) != 0) {
		say("LAUREL FLASHLIGHT: off: dyld shared cache %s is not 20H392 (%s)", text, LF_CACHE_UUID);
		return;
	}
	lf_fd = open(LF_DEVICE, O_WRONLY | O_CLOEXEC);
	if (lf_fd < 0) {
		say("LAUREL FLASHLIGHT: off: %s does not open (kernel torch off: see the LAUREL TORCH line)", LF_DEVICE);
		return;
	}
	if (!lf_pin_self()) {
		say("LAUREL FLASHLIGHT: off: cannot pin the bundle in memory (RTLD_NODELETE)");
		close(lf_fd);
		lf_fd = -1;
		return;
	}
	lf_slide = (uintptr_t)_dyld_get_shared_cache_range(&length) - LF_CACHE_BASE;
	lf_make_classes();
	/* the main queue runs once mediaserverd's main() is in its run loop: after FigMediaServerStart */
	dispatch_async_f(dispatch_get_main_queue(), NULL, lf_start_server);
}

/* the CFPlugIn factory the HAL calls (Info.plist): no audio driver in this bundle */
__attribute__((visibility("default"))) void *LaurelFlashlight_Create(CFAllocatorRef allocator, CFUUIDRef type);

void *
LaurelFlashlight_Create(__unused CFAllocatorRef allocator, __unused CFUUIDRef type)
{
	return NULL;
}
