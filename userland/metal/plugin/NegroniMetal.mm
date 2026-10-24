/*
 * NegroniMetal.bundle: the Metal driver for the Adreno 730 of the OnePlus 10 Pro (iOS 16.7.16 20H392).
 *
 * Chain (docs/metal-design.md):
 *   Metal.framework _MTLRegisterDevices: IOServiceMatching("IOAcceleratorES") -> MetalPluginName "NegroniMetal" ->
 *   /System/Library/Extensions/NegroniMetal.bundle -> MetalPluginClassName "NegroniMTLDevice" (a _MTLDevice subclass,
 *   Metal checks isSubclassOfClass:) -> -initWithAcceleratorPort: (this file) -> the frontend's device
 *   (NativeBridgeMetalFrontend.mm, UniXNU's MIT frontend as ios-flame patched it for iOS 16) -> the metal2vulkan
 *   runtime (AIR -> SPIR-V, the Metal object model on Vulkan) -> Turnip (libvulkan_freedreno.dylib inside this bundle)
 *   -> the kernel GPU user client (docs/gpu-abi.md).
 *
 * The design of this file follows ios-flame phone/metal2/SweetMetal2.mm (MIT, NWylynko/ios-flame 745c434); the gate,
 * the dead-man switch and the paths are ours.
 *
 * Safety rules (bergamota docs/METAL_ADRENO630.md (a)/(h): a half-working device makes CoreAnimation draw nothing):
 *   - A process gets a device only when it is listed in /var/db/negronimetal/clients ("*" = all, "-NAME" = never NAME).
 *     The default file (scripts/metal/root-add-metal.sh) lists only the probes, so backboardd stays on the GL path.
 *   - /var/db/negronimetal/off (any content) disables the plugin for everyone.
 *   - Dead-man: each open writes a strike file for the process and clears it after 30 s alive. Two strikes in a row
 *     (two crashes inside 30 s after the device opened) disable the plugin for that process until the file is removed.
 *   - Any failure (no Turnip, no GPU, exception) returns nil: Metal's _MTLRegisterDevices skips a nil device
 *     (Metal 20H392 0x181b14584: cbz x0 after initWithAcceleratorPort:), so the process takes its CPU/GL paths.
 * Log: /dev/console and /var/db/negronimetal/metal.log (when it exists), lines "NMTL[pid name]: ...".
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "NativeBridgeMetalFrontend.h"
#include "bridge/NativeMetalObjects.h"

#ifndef NMTL_CLASS
#define NMTL_CLASS NegroniMTLDevice
#endif
#define NMTL_DIR "/var/db/negronimetal"

/* ---- log (the frontend calls sm2_logs: keep that name) ---- */
extern "C" void sm2_logs(const char *s)
{
	char buf[700];
	int n = snprintf(buf, sizeof(buf), "NMTL[%d %s]: %s\n", getpid(), getprogname(), s);
	if (n > (int)sizeof(buf) - 1)
		n = (int)sizeof(buf) - 1;
	static int console = -2, file = -2;
	if (console == -2)
		console = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (file == -2)
		file = open(NMTL_DIR "/metal.log", O_WRONLY | O_APPEND);
	if (console >= 0)
		write(console, buf, (size_t)n);
	if (file >= 0)
		write(file, buf, (size_t)n);
}

static void nlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void nlog(const char *fmt, ...)
{
	char buf[600];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	sm2_logs(buf);
}

/*
 * CPU caches: unless the kernel maps GPU buffers coherent, the GPU does not snoop the CPU caches, so libSystem's
 * sys_dcache_flush (a no-op on Apple GPUs) must clean+invalidate. EL0 cache maintenance must be enabled
 * (SCTLR_EL1.UCI, as ios-flame's kernel has it). This definition wins at link time for the bridge and the frontend.
 * docs/metal-design.md "Coherency" says when this can go.
 */
extern "C" void sys_dcache_flush(void *start, size_t len)
{
	uintptr_t a = (uintptr_t)start & ~(uintptr_t)63, end = (uintptr_t)start + len;
	for (; a < end; a += 64)
		__asm__ volatile("dc civac, %0" ::"r"(a) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

/* Metal validation failures abort by default; MPS & co. report one on any non-Apple device: log instead (5 = NSLog). */
__attribute__((constructor)) static void nmtl_error_mode(void)
{
	void (*set)(unsigned, unsigned) = (void (*)(unsigned, unsigned))dlsym(RTLD_DEFAULT, "MTLFailureTypeSetErrorModeType");
	for (unsigned t = 0; set && t < 5; t++)
		set(t, 5);
}

/* Selectors the frontend lacks, each logged once (then the usual unrecognised-selector exception follows). */
static void missing(const char *cls, const char *sel)
{
	static NSMutableSet *seen;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		seen = [NSMutableSet new];
	});
	NSString *k = [NSString stringWithFormat:@"%s %s", cls, sel];
	@synchronized(seen) {
		if ([seen containsObject:k])
			return;
		[seen addObject:k];
	}
	nlog("MISSING %s -%s", cls, sel);
}

/* iOS 16 QuartzCore asks for a precompiled pipeline archive (Apple GPU code): there is none, it builds its pipelines. */
@interface NBDeviceMethods : NSObject
@end
@interface NBDeviceMethods (NegroniMetal)
@end
@implementation NBDeviceMethods (NegroniMetal)
- (id)newPipelineLibraryWithFilePath:(NSString *)path error:(NSError **)error
{
	(void)path;
	if (error)
		*error = [NSError errorWithDomain:@"NegroniMetal" code:1 userInfo:@{ NSLocalizedDescriptionKey : @"no pipeline libraries" }];
	return nil;
}
@end

/* ---- gate ---- */
static bool listed(void)
{
	if (access(NMTL_DIR "/off", F_OK) == 0) {
		nlog("%s exists: no Metal device", NMTL_DIR "/off");
		return false;
	}
	FILE *f = fopen(NMTL_DIR "/clients", "r");
	if (!f)
		return false;
	/* names separated by blanks or commas, "#" starts a comment, "*" = all, "-NAME" = never NAME (wins over "*") */
	bool yes = false, no = false;
	char line[512];
	while (fgets(line, sizeof(line), f)) {
		line[strcspn(line, "#\r\n")] = 0;
		char *save = NULL;
		for (char *name = strtok_r(line, " ,\t", &save); name; name = strtok_r(NULL, " ,\t", &save)) {
			if (name[0] == '-' && !strcmp(name + 1, getprogname()))
				no = true;
			else if (!strcmp(name, "*") || !strcmp(name, getprogname()))
				yes = true;
		}
	}
	fclose(f);
	return yes && !no;
}

/* Dead-man: true when this process may open the GPU now. Strikes live in NMTL_DIR/strikes/<name>. */
static bool deadman_arm(char *path, size_t size)
{
	mkdir(NMTL_DIR "/strikes", 0777);
	chmod(NMTL_DIR "/strikes", 0777);
	snprintf(path, size, NMTL_DIR "/strikes/%s", getprogname());
	int strikes = 0;
	if (FILE *f = fopen(path, "r")) {
		if (fscanf(f, "%d", &strikes) != 1)
			strikes = 0;
		fclose(f);
	}
	if (strikes >= 2) {
		nlog("dead-man: %d unclean starts in a row, no Metal device (rm %s to re-arm)", strikes, path);
		return false;
	}
	if (FILE *f = fopen(path, "w")) {
		fprintf(f, "%d\n", strikes + 1);
		fclose(f);
	}
	return true;
}

static void deadman_clear_later(const char *path)
{
	char *p = strdup(path);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		unlink(p);
		free(p);
	});
}

/* KEY=VALUE lines of NMTL_DIR/env into this process before the device opens (TU_DEBUG, MESA_*, METAL2VULKAN_*). */
static void load_env(void)
{
	FILE *ef = fopen(NMTL_DIR "/env", "r");
	if (!ef)
		return;
	char line[256];
	while (fgets(line, sizeof(line), ef)) {
		line[strcspn(line, "\r\n")] = 0;
		char *eq = strchr(line, '=');
		if (line[0] != '#' && eq) {
			*eq = 0;
			setenv(line, eq + 1, 1);
			nlog("env %s=%s", line, eq + 1);
		}
	}
	fclose(ef);
}

@interface _MTLDevice : NSObject
@end

@interface NMTL_CLASS : _MTLDevice
- (id)initWithAcceleratorPort:(mach_port_t)port;
@end

@implementation NMTL_CLASS
- (id)initWithAcceleratorPort:(mach_port_t)port
{
	/* This object is dropped for the frontend's device. Initialise it first: -[_MTLDevice dealloc] releases its queues
	 * (ios-flame HANDOFF 2026-10-22 "iOS 16 fixes to the frontend"). */
	if (!(self = [super init]))
		return nil;
	static id device;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		if (!listed()) {
			nlog("not listed in %s: no Metal device", NMTL_DIR "/clients");
			return;
		}
		char strike[256];
		if (!deadman_arm(strike, sizeof(strike)))
			return;
		NSString *bundle = [[NSBundle bundleForClass:[NMTL_CLASS class]] bundlePath];
		NSString *turnip = [bundle stringByAppendingPathComponent:@"libvulkan_freedreno.dylib"];
		if (const char *t = getenv("NEGRONI_TURNIP"))
			turnip = @(t);
		/* shader + pipeline cache: NMTL_DIR/cache/<process>, else the sandboxed process's own cache directory */
		char cache[256];
		mkdir(NMTL_DIR "/cache", 0777);
		chmod(NMTL_DIR "/cache", 0777);
		snprintf(cache, sizeof(cache), NMTL_DIR "/cache/%s", getprogname());
		mkdir(cache, 0777);
		if (access(cache, W_OK) != 0) {
			char dir[256];
			if (confstr(_CS_DARWIN_USER_CACHE_DIR, dir, sizeof(dir) - 8)) {
				snprintf(cache, sizeof(cache), "%snegronimetal", dir);
				mkdir(cache, 0700);
			}
		}
		/* plain rows everywhere: no Apple framebuffer compression, no 10-bit deep framebuffer (ios-flame SweetMetal2.mm) */
		setenv("CA_DISABLE_FRAMEBUFFER_COMPRESSION", "1", 1);
		CFPreferencesSetAppValue(CFSTR("CAEnableFramebufferCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		CFPreferencesSetAppValue(CFSTR("CAEnableIOSurfaceCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		CFPreferencesSetAppValue(CFSTR("CAEnableDeepFramebuffer"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		setenv("METAL2VULKAN_LOG_PIPELINES", "1", 0);
		load_env();

		uint64_t registryID = 0;
		if (port)
			IORegistryEntryGetRegistryEntryID(port, &registryID);
		double t0 = CFAbsoluteTimeGetCurrent();
		@try {
			device = native_bridge_metal_open(turnip.UTF8String, cache, registryID, missing);
		} @catch (NSException *e) {
			nlog("device: exception %s", e.reason.UTF8String);
			device = nil;
		}
		nlog("device %s in %.0f ms (turnip %s, cache %s)%s%s", device ? [[device name] UTF8String] : "refused",
		     (CFAbsoluteTimeGetCurrent() - t0) * 1000, turnip.UTF8String, cache, device ? "" : ": ",
		     device ? "" : nmb_last_error());
		/* Extended-range (XR10) formats: withheld from backboardd (8-bit framebuffer), allowed elsewhere (ios-flame). */
		if (device && strcmp(getprogname(), "backboardd") != 0)
			class_replaceMethod(object_getClass(device), sel_registerName("supportsExtendedXR10Formats"),
					    imp_implementationWithBlock(^BOOL(id me) {
						    (void)me;
						    return YES;
					    }),
					    "B16@0:8");
		Dl_info self_info = { 0 };
		dladdr((void *)sm2_logs, &self_info);
		nlog("image base %p (atos -o NegroniMetal.dSYM -l BASE ADDR)", self_info.dli_fbase);
		if (device)
			deadman_clear_later(strike);
		else
			unlink(strike); /* a clean refusal is not a crash */
	});
	return device;
}
@end
