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
 *   - Control files live in the bundle too (Chlorophyll plugin/chlorophyll_plugin.m, MIT: every process that loads the plugin
 *     can read its bundle; a sandboxed app cannot read /var/db, and an unreadable kill switch would fail open):
 *       BUNDLE/off            (any content) no device in any process: the kill switch that reaches sandboxed apps too
 *       BUNDLE/clients        the test tools (scripts/metal/build.sh stages it; every push replaces it)
 *       BUNDLE/clients.local  the owner's list for sandboxed apps (not staged, so a push keeps it)
 *     and /var/db/negronimetal/{off,clients} as before, for the processes that can read them.
 *   - A process gets a device only when one of the clients files lists it ("*" = all, "-NAME" = never NAME; a "-NAME" in
 *     any file wins). The staged files list only the probes, so backboardd stays on the GL path.
 *   - Fail closed: when BUNDLE/off cannot be checked (stat fails with anything but ENOENT), the process gets no device.
 *     /var/db/negronimetal/off, when the sandbox hides it (EPERM/EACCES), leaves the decision to BUNDLE/off.
 *   - Dead-man: each open writes a strike file for the process and clears it after 30 s alive. Two strikes in a row
 *     (two crashes inside 30 s after the device opened) disable the plugin for that process until the file is removed.
 *     Strikes live in /var/db/negronimetal/strikes, else (sandbox) in the process's own cache directory; a process that
 *     can write neither gets no device.
 *   - GPU watchdog (backboardd): command buffers pending and none completed for NEGRONIMETAL_WATCHDOG_S seconds (default
 *     10): it logs, writes /var/db/negronimetal/strikes/gpu-lost (no device for new processes until it is removed) and
 *     stops handing out the device in this process. No crash; NEGRONIMETAL_WATCHDOG_EXIT=1 adds _exit(0), so launchd
 *     restarts backboardd without a device (Chlorophyll inject/bgmtl_inject.m does that).
 *   - Any failure (no Turnip, no GPU, exception) returns nil: Metal's _MTLRegisterDevices skips a nil device
 *     (Metal 20H392 0x181b14584: cbz x0 after initWithAcceleratorPort:), so the process takes its CPU/GL paths.
 * Log: /dev/console and /var/db/negronimetal/metal.log (when it exists), lines "NMTL[pid name]: ...".
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <pthread.h>
#include <IOSurface/IOSurfaceRef.h>
#include <unistd.h>
#include "NativeBridgeMetalFrontend.h"
#include "bridge/NativeMetalObjects.h"

#ifndef NMTL_CLASS
#define NMTL_CLASS NegroniMTLDevice
#endif
#ifndef NMTL_DIR
#define NMTL_DIR "/var/db/negronimetal" /* the host test (scripts/metal/host-plugin-test.sh) sets its own */
#endif

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
	/* Workaround environment variables (Chlorophyll):
	 * - CA_USE_CGTEXTUREDATA=0: QuartzCore reads past mapped file for Apple GPU tiled layout in asset catalogs.
	 * - CI_USE_MTL_DAG_FOR_CIKL_SRC=0: CoreImage crashes in +[CIKernel kernelsWithString:] / SBRendererService with empty argument list.
	 */
	setenv("CA_USE_CGTEXTUREDATA", "0", 0);
	setenv("CI_USE_MTL_DAG_FOR_CIKL_SRC", "0", 0);
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
/* The plugin bundle's directory: the control files every process can read (set before the gate runs). */
static char g_bundle[512];

/* stat() of a control file: 1 = exists, 0 = does not exist, -1 = cannot tell (errno kept in *err) */
static int ctl_state(const char *path, int *err)
{
	struct stat st;
	if (stat(path, &st) == 0)
		return 1;
	*err = errno;
	return (errno == ENOENT || errno == ENOTDIR) ? 0 : -1;
}


/* KEY from the environment (NMTL_DIR/env sets it) as a number, else def */
static long env_num(const char *key, long def)
{
	const char *v = getenv(key);
	return v && *v ? strtol(v, NULL, 0) : def;
}

/* The boot session UUID: strikes or markers from an earlier boot do not count */
static const char *boot_id(void)
{
	static char u[64];
	size_t len = sizeof(u) - 1;
	if (!u[0] && sysctlbyname("kern.bootsessionuuid", u, &len, NULL, 0) != 0)
		u[0] = 0;
	u[sizeof(u) - 1] = 0;
	return u[0] ? u : "-";
}

/* NULL when no kill switch is set, else why there is no device (fail closed: an unreadable BUNDLE/off is "off") */
static const char *off_reason(char *why, size_t size)
{
	char path[600];
	int err = 0;
	snprintf(path, sizeof(path), "%s/off", g_bundle);
	switch (ctl_state(path, &err)) {
	case 1:
		snprintf(why, size, "%s exists", path);
		return why;
	case -1:
		snprintf(why, size, "cannot check %s (%s): fail closed", path, strerror(err));
		return why;
	}
	err = 0;
	switch (ctl_state(NMTL_DIR "/off", &err)) {
	case 1:
		snprintf(why, size, "%s exists", NMTL_DIR "/off");
		return why;
	case -1:
		/* the sandbox hides /var/db (EPERM/EACCES): BUNDLE/off, checked above, decides. Anything else: closed. */
		if (err != EPERM && err != EACCES) {
			snprintf(why, size, "cannot check %s (%s): fail closed", NMTL_DIR "/off", strerror(err));
			return why;
		}
	}
	err = 0;
	if (ctl_state(NMTL_DIR "/strikes/gpu-lost", &err) == 1) {
		FILE *gf = fopen(NMTL_DIR "/strikes/gpu-lost", "r");
		char line[256] = "";
		bool stale = false;
		if (gf) {
			if (fgets(line, sizeof(line), gf)) {
				char *b = strstr(line, "boot=");
				if (b) {
					char gboot[64] = "";
					sscanf(b + 5, "%63s", gboot);
					if (gboot[0] && strcmp(gboot, boot_id()) != 0)
						stale = true;
				}
			}
			fclose(gf);
		}
		if (stale) {
			nlog("GPU watchdog: removing stale gpu-lost marker from previous boot (%s)", boot_id());
			unlink(NMTL_DIR "/strikes/gpu-lost");
		} else {
			snprintf(why, size, "the GPU watchdog marked the GPU lost (rm %s to re-arm)", NMTL_DIR "/strikes/gpu-lost");
			return why;
		}
	}
	return NULL;
}

/* One clients file: names separated by blanks or commas, "#" starts a comment, "*" = all, "-NAME" = never NAME.
 * Returns false when the file cannot be read. */
static bool read_clients(const char *path, bool *yes, bool *no)
{
	FILE *f = fopen(path, "r");
	if (!f)
		return false;
	char line[512];
	while (fgets(line, sizeof(line), f)) {
		line[strcspn(line, "#\r\n")] = 0;
		char *save = NULL;
		for (char *name = strtok_r(line, " ,\t", &save); name; name = strtok_r(NULL, " ,\t", &save)) {
			if (name[0] == '-' && !strcmp(name + 1, getprogname()))
				*no = true;
			else if (!strcmp(name, "*") || !strcmp(name, getprogname()))
				*yes = true;
		}
	}
	fclose(f);
	return true;
}

/* Listed in any readable clients file, and denied ("-NAME") in none. No readable file: not listed. */
static bool listed(void)
{
	bool yes = false, no = false;
	char path[600];
	snprintf(path, sizeof(path), "%s/clients", g_bundle);
	read_clients(path, &yes, &no);
	snprintf(path, sizeof(path), "%s/clients.local", g_bundle);
	read_clients(path, &yes, &no);
	read_clients(NMTL_DIR "/clients", &yes, &no);
	return yes && !no;
}

/* The directory for this process's strike file: NMTL_DIR/strikes, else (a sandboxed process cannot write /var/db) its own
 * cache directory. False when neither is writable. */
static bool strikes_dir(char *dir, size_t size)
{
	mkdir(NMTL_DIR "/strikes", 0777);
	chmod(NMTL_DIR "/strikes", 0777);
	snprintf(dir, size, NMTL_DIR "/strikes");
	if (access(dir, W_OK) == 0)
		return true;
	char cache[400];
	if (confstr(_CS_DARWIN_USER_CACHE_DIR, cache, sizeof(cache)) == 0)
		return false;
	snprintf(dir, size, "%snegronimetal-strikes", cache);
	mkdir(dir, 0700);
	return access(dir, W_OK) == 0;
}

static char g_active_strike[256];
static void deadman_clean_exit(void)
{
	if (g_active_strike[0]) {
		unlink(g_active_strike);
		g_active_strike[0] = 0;
	}
}

/* Dead-man: true when this process may open the GPU now. Strikes live in <strikes_dir>/<name>. A process that cannot
 * keep a strike file gets no device: without it, a crash loop would never stop. */
static bool deadman_arm(char *path, size_t size)
{
	char dir[450];
	if (!strikes_dir(dir, sizeof(dir))) {
		nlog("dead-man: no writable strikes directory (%s/strikes, cache directory): no Metal device", NMTL_DIR);
		return false;
	}
	snprintf(path, size, "%s/%s", dir, getprogname());
	int strikes = 0;
	char file_boot[64] = "";
	if (FILE *f = fopen(path, "r")) {
		if (fscanf(f, "%d %63s", &strikes, file_boot) < 1)
			strikes = 0;
		fclose(f);
	}
	/* Strikes from an earlier boot do not count (reboot reset) */
	if (file_boot[0] && strcmp(file_boot, boot_id()) != 0)
		strikes = 0;
	const long max_strikes = env_num("NEGRONIMETAL_MAX_STRIKES", 2);
	if (strikes >= max_strikes) {
		nlog("dead-man: %d unclean starts in a row (limit %ld), no Metal device (rm %s to re-arm)", strikes, max_strikes, path);
		return false;
	}
	FILE *f = fopen(path, "w");
	bool ok = f && fprintf(f, "%d %s\n", strikes + 1, boot_id()) > 0;
	if (f && fclose(f) != 0)
		ok = false;
	if (!ok) {
		nlog("dead-man: cannot write %s: no Metal device", path);
		return false;
	}
	strlcpy(g_active_strike, path, sizeof(g_active_strike));
	static dispatch_once_t atexit_once;
	dispatch_once(&atexit_once, ^{
		atexit(deadman_clean_exit);
	});
	return true;
}

static void deadman_clear_later(const char *path)
{
	char *p = strdup(path);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		unlink(p);
		free(p);
		if (g_active_strike[0] && !strcmp(g_active_strike, path))
			g_active_strike[0] = 0;
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

/* ---- fast checks before Turnip opens: each one is a clean "no device" ---- */
static bool bootarg_off(void)
{
	char args[1024] = { 0 };
	size_t n = sizeof(args) - 1;
	if (sysctlbyname("kern.bootargs", args, &n, NULL, 0) != 0)
		return false;
	for (char *p = strstr(args, "negronimetal="); p; p = strstr(p + 1, "negronimetal="))
		if ((p == args || p[-1] == ' ') && p[13] == '0')
			return true;
	return false;
}

/* The GPU user client (docs/gpu-abi.md): without RedwoodGPU Turnip has no device, so do not even load it. */
static bool gpu_service_present(void)
{
#ifdef NMTL_HOST_TEST
	return getenv("NMTL_HOST_NO_GPU") == NULL; /* the Mac has no RedwoodGPU: the test says which answer it wants */
#endif
	io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("RedwoodGPU"));
	if (!s)
		return false;
	IOObjectRelease(s);
	return true;
}


/* ---- IOSurface imports: tell Turnip's DRM layer which surface a CPU range is (kernel import by surface ID) ---- */
static void (*note_surface)(const void *, uint64_t, uint32_t);
static void surface_hook(const void *base, uint64_t bytes, uint32_t surface)
{
	note_surface(base, bytes, surface);
}
static void hook_surfaces(const char *turnip)
{
	void *h = dlopen(turnip, RTLD_NOW | RTLD_NOLOAD);
	note_surface = h ? (void (*)(const void *, uint64_t, uint32_t))dlsym(h, "redwood_drm_note_surface") : NULL;
	if (note_surface)
		native_bridge_metal_set_surface_hook(surface_hook);
	else
		nlog("Turnip has no redwood_drm_note_surface: IOSurface textures need the kernel's user-page import");
}

/*
 * Self-test before the device is handed out (a device that registers but cannot draw makes CoreAnimation draw nothing):
 * clear a 64x64 IOSurface-backed BGRA8 texture on the GPU and read the surface back on the CPU. That is the render
 * server's path: IOSurface import (kernel + Turnip), command submission, fence, cache maintenance. When it fails, a
 * plain texture clear tells "GPU works, surface import does not" from "GPU does not work" in the log. No shaders:
 * load-action clears only, so no pipeline compile can stall it.
 */
static BOOL pixel_ok(uint32_t v) /* BGRA8 (0.25, 0.5, 0.75, 1) = 0xff4080bf, +-1 */
{
	int b = v & 0xff, g = (v >> 8) & 0xff, r = (v >> 16) & 0xff, a = v >> 24;
	return b >= 0xbe && b <= 0xc0 && g >= 0x7f && g <= 0x81 && r >= 0x3f && r <= 0x41 && a == 0xff;
}

static NSString *clear_into(id<MTLCommandQueue> q, id<MTLTexture> t)
{
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = t;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
	id<MTLCommandBuffer> cb = [q commandBuffer];
	if (!cb)
		return @"no command buffer";
	id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
	if (!e)
		return @"no render encoder";
	[e endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	if (cb.status != MTLCommandBufferStatusCompleted)
		return [NSString stringWithFormat:@"command buffer status %ld error %@", (long)cb.status, cb.error];
	return nil;
}

static NSString *selftest(id<MTLDevice> d)
{
	const int W = 64, H = 64;
	id<MTLCommandQueue> q = [d newCommandQueue];
	if (!q)
		return @"no command queue";
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
											 width:W height:H mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	NSDictionary *props = @{
		(id)kIOSurfaceWidth : @(W), (id)kIOSurfaceHeight : @(H), (id)kIOSurfaceBytesPerElement : @4,
		(id)kIOSurfaceBytesPerRow : @(W * 4), (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
	};
	IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
	NSString *why = s ? nil : @"IOSurfaceCreate failed";
	if (s) {
		id<MTLTexture> t = [d newTextureWithDescriptor:td iosurface:s plane:0];
		why = t ? clear_into(q, t) : @"newTextureWithDescriptor:iosurface:plane: nil";
		if (!why) {
			IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
			const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(s);
			size_t bpr = IOSurfaceGetBytesPerRow(s);
			int bad = 0;
			for (int y = 0; y < H; y++)
				for (int x = 0; x < W; x++)
					bad += !pixel_ok(((const uint32_t *)(base + y * bpr))[x]);
			uint32_t first = *(const uint32_t *)base;
			IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
			if (bad)
				why = [NSString stringWithFormat:@"IOSurface clear: %d of %d pixels wrong, first 0x%08x", bad, W * H, first];
		}
		CFRelease(s);
	}
	if (!why)
		return nil;
	/* diagnosis only: does the GPU draw into its own memory? */
	td.storageMode = MTLStorageModeShared;
	id<MTLTexture> t = [d newTextureWithDescriptor:td];
	NSString *plain = t ? clear_into(q, t) : @"newTextureWithDescriptor: nil";
	if (!plain) {
		uint32_t px[64 * 64];
		[t getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
		int bad = 0;
		for (int i = 0; i < W * H; i++)
			bad += !pixel_ok(px[i]);
		plain = bad ? [NSString stringWithFormat:@"%d of %d pixels wrong, first 0x%08x", bad, W * H, px[0]] : @"PASS";
	}
	return [NSString stringWithFormat:@"%@ (plain texture clear: %@)", why, plain];
}

/* The open + self-test run on their own thread; the caller waits at most this long (Metal's caller must never hang). */
@interface NMTLOpen : NSObject
@property(atomic, strong) id device;
@property(atomic, copy) NSString *why;
@property(atomic) BOOL abandoned;
@end
@implementation NMTLOpen
@end

/* backboardd: the frontend's counters every 10 s into NMTL_DIR/metal.log while NMTL_DIR/telemetry exists */
static void telemetry_loop(void)
{
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		for (;;) {
			sleep(10);
			if (access(NMTL_DIR "/telemetry", F_OK) != 0)
				continue;
			static char text[8192];
			native_bridge_metal_telemetry(text, sizeof(text));
			int fd = open(NMTL_DIR "/metal.log", O_WRONLY | O_APPEND);
			if (fd >= 0) {
				dprintf(fd, "NMTL[%d %s]: telemetry\n%s", getpid(), getprogname(), text);
				close(fd);
			}
		}
	});
}

/*
 * GPU-lost watchdog (backboardd; the design follows Chlorophyll inject/bgmtl_inject.m and docs/FIXES.md, MIT): once a second it
 * reads the frontend's progress. When command buffers are pending and none completed for limit_s seconds (and the oldest pending
 * one is that old), the GPU is taken as lost: one log line, the marker NMTL_DIR/strikes/gpu-lost (no device for new processes:
 * off_reason), and this process hands out no device from now on. The clock runs only while something is pending, so a display
 * that is off (no commits) never trips it (Chlorophyll's first version counted from launch and switched Metal off for good).
 */
static volatile bool g_gpu_lost;
static void *watchdog_main(void *arg)
{
	const long limit_s = (long)(intptr_t)arg;
	const bool exit_on_loss = env_num("NEGRONIMETAL_WATCHDOG_EXIT", 0) != 0;
	uint64_t last_completed = UINT64_MAX;
	long stalled = 0;
	for (;;) {
		sleep(1);
		uint64_t p[4] = { 0 };
		native_bridge_metal_progress(p);
		if (p[1] != last_completed || p[2] == 0) {
			if (p[1] > 0 && g_active_strike[0]) {
				unlink(g_active_strike);
				g_active_strike[0] = 0;
			}
			last_completed = p[1];
			stalled = 0;
			continue;
		}
		if (++stalled < limit_s || p[3] < (uint64_t)limit_s * 1000000)
			continue;
		g_gpu_lost = true;
		nlog("GPU watchdog: %llu command buffers pending, none completed for %ld s (oldest %llu ms; %llu committed, %llu completed): "
		     "GPU lost, no Metal device for new processes (rm %s to re-arm)%s",
		     (unsigned long long)p[2], stalled, (unsigned long long)(p[3] / 1000), (unsigned long long)p[0],
		     (unsigned long long)p[1], NMTL_DIR "/strikes/gpu-lost", exit_on_loss ? "; exit(0) now" : "");
		if (FILE *f = fopen(NMTL_DIR "/strikes/gpu-lost", "w")) {
			fprintf(f, "%s[%d] pending=%llu stalled=%lds committed=%llu completed=%llu boot=%s\n", getprogname(), getpid(),
				(unsigned long long)p[2], stalled, (unsigned long long)p[0], (unsigned long long)p[1], boot_id());
			fclose(f);
		} else {
			nlog("GPU watchdog: cannot write %s: %s", NMTL_DIR "/strikes/gpu-lost", strerror(errno));
		}
		if (exit_on_loss)
			_exit(0);
		return NULL;
	}
}

static void watchdog_start(void)
{
	const long default_s = (!strcmp(getprogname(), "backboardd")) ? 60 : 30;
	const long limit_s = env_num("NEGRONIMETAL_WATCHDOG_S", default_s);
	if (limit_s <= 0) {
		nlog("GPU watchdog off (NEGRONIMETAL_WATCHDOG_S=%ld)", limit_s);
		return;
	}
	pthread_attr_t attr;
	pthread_attr_init(&attr);
	pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	pthread_t th;
	int e = pthread_create(&th, &attr, watchdog_main, (void *)(intptr_t)limit_s);
	pthread_attr_destroy(&attr);
	if (e)
		nlog("GPU watchdog: pthread_create: %d", e);
	else
		nlog("GPU watchdog on: %ld s without a completion while command buffers are pending", limit_s);
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
		NSString *bundlePath = [[NSBundle bundleForClass:[NMTL_CLASS class]] bundlePath];
#ifdef NMTL_HOST_TEST
		if (const char *b = getenv("NMTL_HOST_BUNDLE")) /* the host test's stand-in for the bundle directory */
			bundlePath = @(b);
#endif
		strlcpy(g_bundle, bundlePath.UTF8String ?: "/nonexistent", sizeof(g_bundle));
		char why[700];
		if (const char *off = off_reason(why, sizeof(why))) {
			nlog("%s: no Metal device", off);
			return;
		}
		if (!listed()) {
			nlog("not listed in %s/clients, %s/clients.local or %s: no Metal device", g_bundle, g_bundle, NMTL_DIR "/clients");
			return;
		}
		if (bootarg_off()) {
			nlog("boot-arg negronimetal=0: no Metal device");
			return;
		}
		if (!gpu_service_present()) {
			nlog("no RedwoodGPU service (boot-args negroniadreno=22 negroniadreno_keep=1): no Metal device");
			return;
		}
		NSString *turnip = [bundlePath stringByAppendingPathComponent:@"libvulkan_freedreno.dylib"];
		if (const char *t = getenv("NEGRONI_TURNIP"))
			turnip = @(t);
		if (access(turnip.UTF8String, R_OK) != 0) {
			nlog("no Turnip at %s: no Metal device", turnip.UTF8String);
			return;
		}
		char strike[256];
		if (!deadman_arm(strike, sizeof(strike)))
			return;
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
		setenv("CA_USE_CGTEXTUREDATA", "0", 0);
		setenv("CI_USE_MTL_DAG_FOR_CIKL_SRC", "0", 0);
		CFPreferencesSetAppValue(CFSTR("CAEnableFramebufferCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		CFPreferencesSetAppValue(CFSTR("CAEnableIOSurfaceCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		CFPreferencesSetAppValue(CFSTR("CAEnableDeepFramebuffer"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		setenv("METAL2VULKAN_LOG_PIPELINES", "1", 0);
		load_env();
		const long timeout_ms = env_num("NEGRONIMETAL_OPEN_MS", 20000);
		const bool test = env_num("NEGRONIMETAL_SELFTEST", 1) != 0;

		uint64_t registryID = 0;
		if (port)
			IORegistryEntryGetRegistryEntryID(port, &registryID);
		double t0 = CFAbsoluteTimeGetCurrent();
		NMTLOpen *job = [NMTLOpen new];
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		const char *tpath = strdup(turnip.UTF8String);
		const char *cpath = strdup(cache);
		/* its own thread with a big stack (Turnip and the translator recurse); the job object outlives a timeout */
		pthread_attr_t attr;
		pthread_attr_init(&attr);
		pthread_attr_setstacksize(&attr, 8 << 20);
		pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
		struct Ctx {
			void *job, *done;
			const char *turnip, *cache;
			uint64_t registryID;
			bool test;
		};
		Ctx *ctx = new Ctx{ (__bridge_retained void *)job, (__bridge_retained void *)done, tpath, cpath, registryID, test };
		pthread_t th;
		int e = pthread_create(&th, &attr, [](void *arg) -> void * {
			Ctx *c = (Ctx *)arg;
			@autoreleasepool {
				NMTLOpen *job = (__bridge_transfer NMTLOpen *)c->job;
				dispatch_semaphore_t done = (__bridge_transfer dispatch_semaphore_t)c->done;
				id dev = nil;
				NSString *why = nil;
				@try {
					dev = native_bridge_metal_open(c->turnip, c->cache, c->registryID, missing);
					if (!dev)
						why = [NSString stringWithFormat:@"open refused: %s", nmb_last_error()];
					if (dev)
						hook_surfaces(c->turnip);
					if (dev && c->test && !job.abandoned) {
						why = selftest(dev);
						if (why)
							why = [@"self-test: " stringByAppendingString:why];
					}
				} @catch (NSException *ex) {
					why = [NSString stringWithFormat:@"exception %@", ex.reason];
				}
				job.why = why;
				job.device = why ? nil : dev;
				dispatch_semaphore_signal(done);
			}
			free((void *)c->turnip);
			free((void *)c->cache);
			delete c;
			return NULL;
		}, ctx);
		pthread_attr_destroy(&attr);
		bool timed_out = false;
		if (e != 0) {
			/* no thread: undo the transfers and open on this one, without a deadline */
			job = (__bridge_transfer NMTLOpen *)ctx->job;
			(void)(__bridge_transfer dispatch_semaphore_t)ctx->done;
			free((void *)tpath);
			free((void *)cpath);
			delete ctx;
			nlog("pthread_create: %d: no Metal device", e);
		} else if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, timeout_ms * NSEC_PER_MSEC)) != 0) {
			job.abandoned = YES;
			timed_out = true;
		}
		device = timed_out ? nil : job.device;
		double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
		if (timed_out)
			nlog("device open/self-test still running after %ld ms: no Metal device (the strike stays; "
			     "NEGRONIMETAL_OPEN_MS in %s/env changes the limit)", timeout_ms, NMTL_DIR);
		else
			nlog("device %s in %.0f ms (turnip %s, cache %s, self-test %s)%s%s",
			     device ? [[device name] UTF8String] : "refused", ms, turnip.UTF8String, cache,
			     test ? "on" : "off", job.why ? ": " : "", job.why ? job.why.UTF8String : "");
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
		if (device) {
			/*
			 * QuartzCore uploads asset-catalog images straight from CGImageTextureData, in Apple's GPU tiled layout of the
			 * compressed data: CoreGraphics read past the mapped file (Chlorophyll plugin/chlorophyll_plugin.m, MIT: SpringBoard
			 * crash loop), and an Adreno cannot sample that layout anyway. Off: CA decodes those images into plain textures.
			 * 20H392: CA::Render::create_image reads getenv("CA_USE_CGTEXTUREDATA") once, at its first image, atoi != 0 = on,
			 * unset = on (QuartzCore 0x188316d38) [V]. Set before the device is returned; an earlier image keeps CA's value [I].
			 * An NMTL_DIR/env line wins (overwrite 0). CI_USE_MTL_DAG_FOR_CIKL_SRC is not in the 20H392 cache [V]: not set.
			 */
			setenv("CA_USE_CGTEXTUREDATA", "0", 0);
			setenv("CI_USE_MTL_DAG_FOR_CIKL_SRC", "0", 0);
			deadman_clear_later(strike);
			const long wd = env_num("NEGRONIMETAL_WATCHDOG", -1); /* 1 / 0 force it on / off; default: backboardd only */
			if (!strcmp(getprogname(), "backboardd"))
				telemetry_loop();
			if (wd == 1 || (wd < 0 && !strcmp(getprogname(), "backboardd")))
				watchdog_start();
		} else if (!timed_out) {
			unlink(strike); /* a clean refusal is not a crash; a hang keeps its strike */
		}
	});
	if (g_gpu_lost) {
		nlog("the GPU watchdog marked the GPU lost: no Metal device");
		return nil;
	}
	return device;
}
@end
