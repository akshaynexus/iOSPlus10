/*
 * metalprobe: stages 1-3 of the Metal path (docs/metal-plan.md), run over SSH on the phone.
 *
 *   metalprobe [--bundle PATH [--class NAME]] [--registry] [--clear] [--iosurface] [--compute] [--render]
 *              [--metallib FILE] [--all]
 *
 *   (no test option)  print the IOAcceleratorES services and their Metal properties, MTLCopyAllDevices,
 *                     MTLCreateSystemDefaultDevice and the device's name, class chain, families, limits
 *   --bundle PATH     load a Metal plugin bundle in this process and register its device with Metal's own
 *                     MTLAddDevice (stage 1 without a kernel MetalPluginName; only this process sees it)
 *   --class NAME      the plugin class (default: the bundle's principal class)
 *   --registry        dump every property of each IOAcceleratorES service
 *   --clear           render pass that clears a 64x64 BGRA8 texture, read back and checked (stage 2)
 *   --iosurface       the same clear into an IOSurface-backed texture, checked through the IOSurface (stage 2)
 *   --compute         MSL source -> library (Apple's MTLCompilerService frontend) -> compute pipeline, run, checked
 *   --render          MSL source -> render pipeline, one triangle, centre and corner pixels checked (stage 3)
 *   --metallib FILE   load a metallib, make a compute pipeline for every kernel and a render pipeline for every
 *                     vertex+fragment pair with matching name stems (e.g. QuartzCore's default.metallib)
 *   --all             --clear --iosurface --compute --render
 * Exit code: 0 = all requested tests passed, 1 = a test failed, 2 = no Metal device.
 * Output lines start with "metalprobe:"; PASS / FAIL are stable words for scripts (scripts/metal/phone-test.sh).
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define R(...) printf("metalprobe: " __VA_ARGS__)

static int failures;
static void result(BOOL ok, const char *name, NSString *detail)
{
	R("%s %s%s%s\n", ok ? "PASS" : "FAIL", name, detail.length ? ": " : "", detail.UTF8String ?: "");
	if (!ok)
		failures++;
}

/* ---- IORegistry: what Metal.framework's _MTLRegisterDevices sees (IOServiceMatching("IOAcceleratorES")) ---- */
static void dump_services(BOOL all_props)
{
	io_iterator_t it = 0;
	kern_return_t kr = IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching("IOAcceleratorES"), &it);
	if (kr != KERN_SUCCESS) {
		R("IOAcceleratorES lookup failed 0x%x\n", kr);
		return;
	}
	int n = 0;
	for (io_service_t s; (s = IOIteratorNext(it)); IOObjectRelease(s)) {
		io_name_t cls = "";
		IOObjectGetClass(s, cls);
		uint64_t rid = 0;
		IORegistryEntryGetRegistryEntryID(s, &rid);
		NSString *(^prop)(const char *) = ^NSString *(const char *k) {
			CFTypeRef v = IORegistryEntryCreateCFProperty(s, (__bridge CFStringRef)@(k), kCFAllocatorDefault, 0);
			NSString *d = v ? [(__bridge id)v description] : @"-";
			if (v)
				CFRelease(v);
			return d;
		};
		R("service %d: class %s id 0x%llx MetalPluginName %s MetalPluginClassName %s IOUserClientClass %s\n", n, cls,
		  rid, prop("MetalPluginName").UTF8String, prop("MetalPluginClassName").UTF8String, prop("IOUserClientClass").UTF8String);
		if (all_props) {
			CFMutableDictionaryRef d = NULL;
			if (IORegistryEntryCreateCFProperties(s, &d, kCFAllocatorDefault, 0) == KERN_SUCCESS && d) {
				R("  %s\n", [[(__bridge NSDictionary *)d description] UTF8String]);
				CFRelease(d);
			}
		}
		n++;
	}
	IOObjectRelease(it);
	R("IOAcceleratorES services: %d\n", n);
}

/* ---- stage 1 without the kernel: load a plugin bundle and register it in this process ---- */
static BOOL register_bundle(NSString *path, NSString *clsName)
{
	NSBundle *b = [NSBundle bundleWithPath:path];
	NSError *err = nil;
	if (!b || ![b loadAndReturnError:&err]) {
		result(NO, "bundle-load", [NSString stringWithFormat:@"%@: %@", path, err]);
		return NO;
	}
	Class cls = clsName ? NSClassFromString(clsName) : b.principalClass;
	Class base = NSClassFromString(@"_MTLDevice");
	if (!cls || !base || ![cls isSubclassOfClass:base]) {
		result(NO, "bundle-class", [NSString stringWithFormat:@"%@ is not a _MTLDevice subclass", cls]);
		return NO;
	}
	/* the service Metal itself would pass (any IOAcceleratorES; 0 when the kernel has none yet) */
	io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("IOAcceleratorES"));
	/* MTLCreateSystemDefaultDevice runs Metal's own discovery once (MTLDeviceArrayInitialize): it creates the device
	 * array that MTLAddDevice asserts on. iOS 16 has no MTLCopyAllDevices (20H392 Metal exports only MTLAddDevice). */
	id<MTLDevice> before = MTLCreateSystemDefaultDevice();
	void (*add)(id) = (void (*)(id))dlsym(RTLD_DEFAULT, "MTLAddDevice");
	if (!add) {
		result(NO, "bundle-register", @"MTLAddDevice not found");
		return NO;
	}
	/* -[_MTLDevice initWithAcceleratorPort:(mach_port_t)]: an init method (consumes self, returns +1) */
	typedef id (*init_fn)(__attribute__((ns_consumed)) id, SEL, mach_port_t) __attribute__((ns_returns_retained));
	id dev = ((init_fn)objc_msgSend)([cls alloc], @selector(initWithAcceleratorPort:), svc);
	if (!dev) {
		result(NO, "bundle-init", @"initWithAcceleratorPort: returned nil (plugin refused: see its log)");
		return NO;
	}
	add(dev);
	result(YES, "bundle-register", [NSString stringWithFormat:@"%@ (default device before: %@)", NSStringFromClass([dev class]),
						  before ? before.name : @"none"]);
	return YES;
}

static void print_device(id<MTLDevice> d)
{
	NSMutableString *chain = [NSMutableString string];
	for (Class c = object_getClass(d); c; c = class_getSuperclass(c))
		[chain appendFormat:@"%s%@", chain.length ? " : " : "", NSStringFromClass(c)];
	R("device: %s (%s), registryID 0x%llx\n", d.name.UTF8String, chain.UTF8String, d.registryID);
	R("  maxThreadsPerThreadgroup %lux%lux%lu, maxBufferLength %lu MiB, maxThreadgroupMemoryLength %lu, "
	  "recommendedMaxWorkingSetSize %llu MiB, hasUnifiedMemory %d, lowPower %d, headless %d\n",
	  (unsigned long)d.maxThreadsPerThreadgroup.width, (unsigned long)d.maxThreadsPerThreadgroup.height,
	  (unsigned long)d.maxThreadsPerThreadgroup.depth, (unsigned long)(d.maxBufferLength >> 20),
	  (unsigned long)d.maxThreadgroupMemoryLength, (unsigned long long)(d.recommendedMaxWorkingSetSize >> 20),
	  d.hasUnifiedMemory, d.isLowPower, d.isHeadless);
	NSMutableString *fam = [NSMutableString string];
	struct { MTLGPUFamily f; const char *n; } fams[] = {
		{ MTLGPUFamilyApple1, "Apple1" }, { MTLGPUFamilyApple2, "Apple2" }, { MTLGPUFamilyApple3, "Apple3" },
		{ MTLGPUFamilyApple4, "Apple4" }, { MTLGPUFamilyApple5, "Apple5" }, { MTLGPUFamilyApple6, "Apple6" },
		{ MTLGPUFamilyApple7, "Apple7" }, { MTLGPUFamilyApple8, "Apple8" }, { MTLGPUFamilyCommon1, "Common1" },
		{ MTLGPUFamilyCommon2, "Common2" }, { MTLGPUFamilyCommon3, "Common3" }, { MTLGPUFamilyMetal3, "Metal3" },
	};
	for (size_t i = 0; i < sizeof(fams) / sizeof(fams[0]); i++)
		if ([d supportsFamily:fams[i].f])
			[fam appendFormat:@" %s", fams[i].n];
	R("  families:%s\n", fam.length ? fam.UTF8String : " none");
	R("  argumentBuffersSupport %lu, readWriteTextureSupport %lu, supports32BitFloatFiltering %d, "
	  "supportsBCTextureCompression %d, programmableSamplePositions %d, rasterOrderGroups %d\n",
	  (unsigned long)d.argumentBuffersSupport, (unsigned long)d.readWriteTextureSupport,
	  [d respondsToSelector:@selector(supports32BitFloatFiltering)] ? (int)d.supports32BitFloatFiltering : -1,
	  [d respondsToSelector:@selector(supportsBCTextureCompression)] ? (int)((BOOL (*)(id, SEL))objc_msgSend)(d, @selector(supportsBCTextureCompression)) : -1,
	  d.areProgrammableSamplePositionsSupported, d.areRasterOrderGroupsSupported);
}

/* BGRA8 (0.25, 0.5, 0.75, 1) = B 0xbf, G 0x80, R 0x40, A 0xff -> little-endian word 0xff4080bf (+-1 for rounding) */
static BOOL pixel_ok(uint32_t v)
{
	int b = v & 0xff, g = (v >> 8) & 0xff, r = (v >> 16) & 0xff, a = v >> 24;
	return b >= 0xbe && b <= 0xc0 && g >= 0x7f && g <= 0x81 && r >= 0x3f && r <= 0x41 && a == 0xff;
}

static BOOL clear_into(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLTexture> t, NSString **why)
{
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = t;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1.0);
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
	[e endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	if (cb.status != MTLCommandBufferStatusCompleted) {
		*why = [NSString stringWithFormat:@"command buffer status %ld error %@", (long)cb.status, cb.error];
		return NO;
	}
	return YES;
}

static void test_clear(id<MTLDevice> d, id<MTLCommandQueue> q)
{
	const NSUInteger W = 64, H = 64;
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
											 width:W height:H mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModeShared;
	id<MTLTexture> t = [d newTextureWithDescriptor:td];
	if (!t) {
		result(NO, "clear", @"newTextureWithDescriptor: nil");
		return;
	}
	NSString *why = nil;
	if (!clear_into(d, q, t, &why)) {
		result(NO, "clear", why);
		return;
	}
	uint32_t *px = calloc(W * H, 4);
	[t getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
	NSUInteger bad = 0;
	for (NSUInteger i = 0; i < W * H; i++)
		bad += !pixel_ok(px[i]);
	result(bad == 0, "clear", [NSString stringWithFormat:@"%lu of %lu pixels wrong, first 0x%08x", (unsigned long)bad,
							      (unsigned long)(W * H), px[0]]);
	free(px);
}

static void test_iosurface(id<MTLDevice> d, id<MTLCommandQueue> q)
{
	const int W = 64, H = 64;
	NSDictionary *props = @{
		(id)kIOSurfaceWidth : @(W), (id)kIOSurfaceHeight : @(H), (id)kIOSurfaceBytesPerElement : @4,
		(id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
	};
	IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
	if (!s) {
		result(NO, "iosurface", @"IOSurfaceCreate failed");
		return;
	}
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
											 width:W height:H mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	id<MTLTexture> t = [d newTextureWithDescriptor:td iosurface:s plane:0];
	if (!t) {
		result(NO, "iosurface", @"newTextureWithDescriptor:iosurface:plane: nil");
		CFRelease(s);
		return;
	}
	NSString *why = nil;
	if (!clear_into(d, q, t, &why)) {
		result(NO, "iosurface", why);
		CFRelease(s);
		return;
	}
	IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
	uint8_t *base = IOSurfaceGetBaseAddress(s);
	size_t bpr = IOSurfaceGetBytesPerRow(s);
	int bad = 0;
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++)
			bad += !pixel_ok(((uint32_t *)(base + y * bpr))[x]);
	uint32_t first = *(uint32_t *)base;
	IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
	result(bad == 0, "iosurface", [NSString stringWithFormat:@"surface %u, %d of %d pixels wrong, first 0x%08x",
								  IOSurfaceGetID(s), bad, W * H, first]);
	CFRelease(s);
}

static NSString *const kCompute = @"#include <metal_stdlib>\n"
				   "using namespace metal;\n"
				   "kernel void add2(device const float *a [[buffer(0)]], device const float *b [[buffer(1)]],\n"
				   "                 device float *o [[buffer(2)]], uint i [[thread_position_in_grid]]) {\n"
				   "  o[i] = a[i] + 2.0f * b[i];\n"
				   "}\n";

static void test_compute(id<MTLDevice> d, id<MTLCommandQueue> q)
{
	NSError *err = nil;
	id<MTLLibrary> lib = [d newLibraryWithSource:kCompute options:nil error:&err];
	if (!lib) {
		result(NO, "compute", [NSString stringWithFormat:@"newLibraryWithSource: %@", err]);
		return;
	}
	id<MTLFunction> f = [lib newFunctionWithName:@"add2"];
	id<MTLComputePipelineState> ps = f ? [d newComputePipelineStateWithFunction:f error:&err] : nil;
	if (!ps) {
		result(NO, "compute", [NSString stringWithFormat:@"pipeline: %@", err]);
		return;
	}
	const NSUInteger N = 4096;
	id<MTLBuffer> a = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> b = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> o = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
	float *pa = a.contents, *pb = b.contents, *po = o.contents;
	for (NSUInteger i = 0; i < N; i++) {
		pa[i] = (float)i;
		pb[i] = (float)(N - i) * 0.5f;
		po[i] = -1;
	}
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
	[e setComputePipelineState:ps];
	[e setBuffer:a offset:0 atIndex:0];
	[e setBuffer:b offset:0 atIndex:1];
	[e setBuffer:o offset:0 atIndex:2];
	[e dispatchThreadgroups:MTLSizeMake(N / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[e endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	NSUInteger bad = 0;
	for (NSUInteger i = 0; i < N; i++)
		bad += po[i] != (float)i + (float)(N - i);
	result(cb.status == MTLCommandBufferStatusCompleted && bad == 0, "compute",
	       [NSString stringWithFormat:@"status %ld, %lu of %lu wrong", (long)cb.status, (unsigned long)bad, (unsigned long)N]);
}

static NSString *const kRender = @"#include <metal_stdlib>\n"
				  "using namespace metal;\n"
				  "struct V { float4 p [[position]]; float4 c; };\n"
				  "vertex V tri_v(uint id [[vertex_id]], constant float2 *pos [[buffer(0)]]) {\n"
				  "  V o; o.p = float4(pos[id], 0, 1); o.c = float4(0.25, 0.5, 0.75, 1); return o;\n"
				  "}\n"
				  "fragment float4 tri_f(V in [[stage_in]]) { return in.c; }\n";

static void test_render(id<MTLDevice> d, id<MTLCommandQueue> q)
{
	NSError *err = nil;
	id<MTLLibrary> lib = [d newLibraryWithSource:kRender options:nil error:&err];
	if (!lib) {
		result(NO, "render", [NSString stringWithFormat:@"newLibraryWithSource: %@", err]);
		return;
	}
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"tri_v"];
	pd.fragmentFunction = [lib newFunctionWithName:@"tri_f"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:pd error:&err];
	if (!ps) {
		result(NO, "render", [NSString stringWithFormat:@"pipeline: %@", err]);
		return;
	}
	const NSUInteger W = 64, H = 64;
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
											 width:W height:H mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget;
	td.storageMode = MTLStorageModeShared;
	id<MTLTexture> t = [d newTextureWithDescriptor:td];
	/* a triangle over the lower-left half: (-1,-1) (1,-1) (-1,1) */
	float pos[] = { -1, -1, 1, -1, -1, 1 };
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = t;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
	[e setRenderPipelineState:ps];
	[e setVertexBytes:pos length:sizeof(pos) atIndex:0];
	[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[e endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	uint32_t *px = calloc(W * H, 4);
	[t getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
	/* Metal: texture row 0 is the top; NDC y = -1 is the bottom. Lower-left pixel inside, upper-right outside. */
	uint32_t in = px[(H - 4) * W + 4], out = px[4 * W + (W - 4)];
	BOOL ok = cb.status == MTLCommandBufferStatusCompleted && pixel_ok(in) && out == 0;
	result(ok, "render", [NSString stringWithFormat:@"status %ld, inside 0x%08x, outside 0x%08x", (long)cb.status, in, out]);
	free(px);
}

/* Every kernel -> compute pipeline; every vertex+fragment pair with the same stem (the first vertex function is paired with each fragment) -> render pipeline */
static void test_metallib(id<MTLDevice> d, NSString *path)
{
	NSError *err = nil;
	id<MTLLibrary> lib = [d newLibraryWithURL:[NSURL fileURLWithPath:path] error:&err];
	if (!lib) {
		result(NO, "metallib", [NSString stringWithFormat:@"%@: %@", path, err]);
		return;
	}
	NSArray<NSString *> *names = lib.functionNames;
	int kern = 0, kern_ok = 0, frag = 0, frag_ok = 0;
	NSMutableArray *verts = [NSMutableArray array];
	for (NSString *n in names) {
		id<MTLFunction> f = [lib newFunctionWithName:n];
		if (f.functionType == MTLFunctionTypeVertex)
			[verts addObject:f];
	}
	for (NSString *n in names) {
		id<MTLFunction> f = [lib newFunctionWithName:n];
		if (!f)
			continue;
		if (f.functionType == MTLFunctionTypeKernel) {
			kern++;
			id ps = [d newComputePipelineStateWithFunction:f error:&err];
			kern_ok += ps != nil;
			if (!ps)
				R("  kernel %s: %s\n", n.UTF8String, err.localizedDescription.UTF8String);
		} else if (f.functionType == MTLFunctionTypeFragment && verts.count) {
			frag++;
			MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
			pd.vertexFunction = verts[0];
			pd.fragmentFunction = f;
			pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
			id ps = [d newRenderPipelineStateWithDescriptor:pd error:&err];
			frag_ok += ps != nil;
			if (!ps)
				R("  fragment %s: %s\n", n.UTF8String, err.localizedDescription.UTF8String);
		}
	}
	result(kern_ok == kern && frag_ok == frag, "metallib",
	       [NSString stringWithFormat:@"%@: %lu functions, kernels %d/%d, fragment pipelines %d/%d (function constants unset)",
					  path.lastPathComponent, (unsigned long)names.count, kern_ok, kern, frag_ok, frag]);
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		NSString *bundle = nil, *cls = nil, *metallib = nil;
		BOOL reg = NO, clear = NO, ios = NO, comp = NO, rend = NO;
		for (int i = 1; i < argc; i++) {
			const char *a = argv[i];
			if (!strcmp(a, "--bundle") && i + 1 < argc)
				bundle = @(argv[++i]);
			else if (!strcmp(a, "--class") && i + 1 < argc)
				cls = @(argv[++i]);
			else if (!strcmp(a, "--metallib") && i + 1 < argc)
				metallib = @(argv[++i]);
			else if (!strcmp(a, "--registry"))
				reg = YES;
			else if (!strcmp(a, "--clear"))
				clear = YES;
			else if (!strcmp(a, "--iosurface"))
				ios = YES;
			else if (!strcmp(a, "--compute"))
				comp = YES;
			else if (!strcmp(a, "--render"))
				rend = YES;
			else if (!strcmp(a, "--all"))
				clear = ios = comp = rend = YES;
			else {
				fprintf(stderr, "usage: %s [--bundle PATH [--class NAME]] [--registry] [--clear] [--iosurface] "
						"[--compute] [--render] [--metallib FILE] [--all]\n", argv[0]);
				return 2;
			}
		}
		dump_services(reg);
		if (bundle && !register_bundle(bundle, cls))
			return 2;
		id<MTLDevice> d = MTLCreateSystemDefaultDevice();
		result(d != nil, "device", d ? d.name : @"MTLCreateSystemDefaultDevice returned nil");
		if (!d)
			return 2;
		print_device(d);
		id<MTLCommandQueue> q = [d newCommandQueue];
		if ((clear || ios || comp || rend) && !q) {
			result(NO, "queue", @"newCommandQueue nil");
			return 1;
		}
		if (clear)
			test_clear(d, q);
		if (ios)
			test_iosurface(d, q);
		if (comp)
			test_compute(d, q);
		if (rend)
			test_render(d, q);
		if (metallib)
			test_metallib(d, metallib);
		R("%s (%d failed)\n", failures ? "FAIL" : "PASS", failures);
		return failures ? 1 : 0;
	}
}
