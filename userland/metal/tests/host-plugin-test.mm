/*
 * Host test of the NegroniMetal plugin logic on a Mac (scripts/metal/host-plugin-test.sh builds and runs it):
 * the plugin + frontend + the bridge built for aarch64-apple-darwin, MoltenVK in place of Turnip, the gate directory in
 * a scratch folder (NMTL_DIR) and the bundle's control files in another (NMTL_HOST_BUNDLE). One case per process, because
 * the plugin opens its device once (dispatch_once):
 *   host-plugin-test CASE      CASE = device | msl | mps | unlisted | off | bundleoff | blocked | nogpu | timeout | deadman | watchdog | lost
 * mps (flame/0012): the frontend's objects conform to the public Metal protocols (MetalPerformanceShaders checks the command
 * buffer and dereferences nil otherwise); then an MPSImageGaussianBlur through the device.
 * msl (flame/0011): MSL source through Apple's front end in this process (GPUCompiler.framework on macOS), a kernel that reads and writes
 * through an argument buffer (newArgumentEncoderWithBufferIndex:, useResource:), newArgumentEncoderWithArguments:, an indirect dispatch,
 * and a compile error that answers nil + the compiler's text.
 * Prints "PASS CASE" or "FAIL CASE: why". It checks the gate (clients files, kill switches, fail closed), the fast refusals,
 * the open thread with its deadline, the dead-man counter, the self-test (GPU clear into an IOSurface-backed texture through
 * the frontend), the GPU watchdog, and the frontend's CoreAnimation fixes of flame/0002 (device SPI answers, DontCare clear,
 * IOSurface seed bump, skipped draws); not Metal's own registration (MTLAddDevice is iOS only) and not Turnip or the kernel.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <mach/mach_time.h>
#include <sys/stat.h>
#include <unistd.h>

extern "C" size_t native_bridge_metal_telemetry(char *out, size_t size);

@interface NSObject (NMTLHostTest)
- (id)initWithAcceleratorPort:(mach_port_t)port;
@end

static int fail(const char *c, NSString *why)
{
	printf("FAIL %s: %s\n", c, why.UTF8String);
	fflush(stdout);
	_exit(1); /* no teardown: an abandoned open may still run on its thread */
}

/* flame/0002 checks on an open device; nil = all good, else what failed */
static NSString *check_fixes(id<MTLDevice> d)
{
	/* 1. device SPI answers that _MTLDevice lacks on 20H392 */
	struct Arch {
		uint64_t arch;
		uint32_t subtype;
		const char *name;
	};
	SEL tdi = NSSelectorFromString(@"targetDeviceInfo");
	if (![(id)d respondsToSelector:tdi])
		return @"no targetDeviceInfo";
	const Arch *arch = ((const Arch *(*)(id, SEL))objc_msgSend)(d, tdi);
	if (!arch || !arch->name || !arch->name[0])
		return @"targetDeviceInfo: NULL or no name";
	SEL shared = NSSelectorFromString(@"sharedMemorySize"), dedicated = NSSelectorFromString(@"dedicatedMemorySize");
	if (![(id)d respondsToSelector:shared] || ![(id)d respondsToSelector:dedicated])
		return @"no sharedMemorySize/dedicatedMemorySize";
	if (((uint64_t(*)(id, SEL))objc_msgSend)(d, shared) == 0)
		return @"sharedMemorySize 0";
	printf("targetDeviceInfo {%llu, %u, \"%s\"}, sharedMemorySize %llu MiB, dedicated %llu\n", (unsigned long long)arch->arch,
	       arch->subtype, arch->name, (unsigned long long)(((uint64_t(*)(id, SEL))objc_msgSend)(d, shared) >> 20),
	       (unsigned long long)((uint64_t(*)(id, SEL))objc_msgSend)(d, dedicated));

	id<MTLCommandQueue> q = [d newCommandQueue];
	const int W = 32, H = 32;
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
											 width:W height:H mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModeShared;

	/* 2. DontCare colour attachment of a texture that is no IOSurface starts cleared to zero */
	id<MTLTexture> t = [d newTextureWithDescriptor:td];
	if (!t)
		return @"no texture";
	uint32_t px[32 * 32];
	for (int i = 0; i < W * H; i++)
		px[i] = 0xabcdef12;
	[t replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 4];
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = t;
	rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
	/* 3. a nil render pipeline: its draw is skipped, the command buffer still completes */
	[e setRenderPipelineState:(id<MTLRenderPipelineState>)nil];
	[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[e endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	if (cb.status != MTLCommandBufferStatusCompleted)
		return [NSString stringWithFormat:@"skipped draw: command buffer status %ld error %@", (long)cb.status, cb.error];
	[t getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
	int dirty = 0;
	for (int i = 0; i < W * H; i++)
		dirty += px[i] != 0;
	if (dirty)
		return [NSString stringWithFormat:@"DontCare attachment: %d of %d texels not cleared (first 0x%08x)", dirty, W * H, px[0]];
	char tel[8192];
	native_bridge_metal_telemetry(tel, sizeof(tel));
	const char *n = strstr(tel, "N skipped draws=");
	if (!n || !strncmp(n, "N skipped draws=0 ", 18))
		return @"telemetry N row: no skipped draw counted";
	printf("%.*s\n", (int)strcspn(n, "\n"), n);

	/* 4. a GPU write into an IOSurface moves its seed */
	NSDictionary *props = @{
		(id)kIOSurfaceWidth : @(W), (id)kIOSurfaceHeight : @(H), (id)kIOSurfaceBytesPerElement : @4,
		(id)kIOSurfaceBytesPerRow : @(W * 4), (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
	};
	IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
	if (!s)
		return @"IOSurfaceCreate failed";
	id<MTLTexture> st = [d newTextureWithDescriptor:td iosurface:s plane:0];
	if (!st) {
		CFRelease(s);
		return @"no IOSurface texture";
	}
	uint32_t seed0 = IOSurfaceGetSeed(s);
	rp.colorAttachments[0].texture = st;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
	cb = [q commandBuffer];
	[[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	uint32_t seed1 = IOSurfaceGetSeed(s);
	CFRelease(s);
	if (cb.status != MTLCommandBufferStatusCompleted)
		return [NSString stringWithFormat:@"IOSurface clear: status %ld", (long)cb.status];
	if (seed1 == seed0)
		return [NSString stringWithFormat:@"IOSurface seed did not move after the GPU write (%u)", seed0];
	printf("IOSurface seed %u -> %u\n", seed0, seed1);
	return nil;
}

/* A command buffer that never completes (it waits for an event nobody signals), committed from another thread. */
static void commit_stuck(id<MTLDevice> d)
{
	id<MTLCommandQueue> q = [d newCommandQueue];
	id<MTLEvent> ev = [d newEvent];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
		id<MTLCommandBuffer> cb = [q commandBuffer];
		[cb encodeWaitForEvent:ev value:1];
		[cb commit];
		printf("stuck command buffer committed\n");
	});
}

/* flame/0011: MSL source -> in-process front end -> metallib -> metal2vulkan; argument buffers; indirect dispatch. nil = all good. */
static NSString *check_msl(id<MTLDevice> d)
{
	static NSString *const kSource = @"#include <metal_stdlib>\n"
		"using namespace metal;\n"
		"struct Args { device float *out [[id(0)]]; constant float *in [[id(1)]]; };\n"
		"kernel void viaargs(constant Args &a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a.out[i] = a.in[i] * 2.0f + 1.0f; }\n"
		"kernel void plain(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = float(i) * 3.0f; }\n";
	NSError *err = nil;
	MTLCompileOptions *opts = [MTLCompileOptions new];
	opts.languageVersion = MTLLanguageVersion2_4;
	id<MTLLibrary> lib = [d newLibraryWithSource:kSource options:opts error:&err];
	if (!lib)
		return [NSString stringWithFormat:@"newLibraryWithSource: nil: %@", err.localizedDescription];
	printf("msl: library %s, functions %s\n", class_getName([(id)lib class]), [[lib.functionNames componentsJoinedByString:@","] UTF8String]);
	id<MTLFunction> viaargs = [lib newFunctionWithName:@"viaargs"], plain = [lib newFunctionWithName:@"plain"];
	if (!viaargs || !plain)
		return @"newFunctionWithName: nil";
	id<MTLComputePipelineState> p1 = [d newComputePipelineStateWithFunction:viaargs error:&err];
	if (!p1)
		return [NSString stringWithFormat:@"pipeline viaargs: %@", err.localizedDescription];
	id<MTLComputePipelineState> p2 = [d newComputePipelineStateWithFunction:plain error:&err];
	if (!p2)
		return [NSString stringWithFormat:@"pipeline plain: %@", err.localizedDescription];
	id<MTLArgumentEncoder> enc = [viaargs newArgumentEncoderWithBufferIndex:0];
	if (!enc)
		return @"newArgumentEncoderWithBufferIndex:0 nil";
	printf("msl: argument encoder %s encodedLength %lu alignment %lu, argumentBuffersSupport %lu\n", class_getName([(id)enc class]),
	       (unsigned long)enc.encodedLength, (unsigned long)enc.alignment, (unsigned long)d.argumentBuffersSupport);
	const NSUInteger N = 64;
	id<MTLBuffer> in = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> out = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> out2 = [d newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
	id<MTLBuffer> args = [d newBufferWithLength:MAX(enc.encodedLength, (NSUInteger)16) options:MTLResourceStorageModeShared];
	const uint32_t groups[3] = {N / 32, 1, 1};
	id<MTLBuffer> indirect = [d newBufferWithBytes:groups length:sizeof(groups) options:MTLResourceStorageModeShared];
	for (NSUInteger i = 0; i < N; i++)
		((float *)in.contents)[i] = (float)i;
	[enc setArgumentBuffer:args offset:0];
	[enc setBuffer:out offset:0 atIndex:0];
	[enc setBuffer:in offset:0 atIndex:1];
	id<MTLCommandQueue> q = [d newCommandQueue];
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	[ce setComputePipelineState:p1];
	[ce setBuffer:args offset:0 atIndex:0];
	[ce useResource:out usage:MTLResourceUsageWrite];
	[ce useResource:in usage:MTLResourceUsageRead];
	[ce dispatchThreadgroups:MTLSizeMake(N / 32, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
	[ce setComputePipelineState:p2];
	[ce setBuffer:out2 offset:0 atIndex:0];
	[ce dispatchThreadgroupsWithIndirectBuffer:indirect indirectBufferOffset:0 threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
	[ce endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	if (cb.status != MTLCommandBufferStatusCompleted)
		return [NSString stringWithFormat:@"command buffer status %ld: %@", (long)cb.status, cb.error];
	unsigned bad = 0, bad2 = 0;
	for (NSUInteger i = 0; i < N; i++) {
		if (((float *)out.contents)[i] != (float)i * 2.0f + 1.0f)
			bad++;
		if (((float *)out2.contents)[i] != (float)i * 3.0f)
			bad2++;
	}
	printf("msl: argument-buffer kernel %u/%lu wrong (out[5] = %g), indirect dispatch %u/%lu wrong (out2[5] = %g)\n", bad, (unsigned long)N,
	       ((float *)out.contents)[5], bad2, (unsigned long)N, ((float *)out2.contents)[5]);
	if (bad || bad2)
		return @"wrong results";
	MTLArgumentDescriptor *a0 = [MTLArgumentDescriptor argumentDescriptor], *a1 = [MTLArgumentDescriptor argumentDescriptor];
	a0.dataType = MTLDataTypePointer;
	a0.index = 0;
	a1.dataType = MTLDataTypeTexture;
	a1.index = 1;
	id<MTLArgumentEncoder> enc2 = [d newArgumentEncoderWithArguments:@[ a0, a1 ]];
	if (!enc2)
		return @"newArgumentEncoderWithArguments: nil";
	printf("msl: newArgumentEncoderWithArguments: encodedLength %lu\n", (unsigned long)enc2.encodedLength);
	err = nil;
	id<MTLLibrary> broken = [d newLibraryWithSource:@"#include <metal_stdlib>\nkernel void k(device float *o [[buffer(0)]]) { o[0] = nothing; }\n"
						options:nil error:&err];
	if (broken || !err || [err.localizedDescription rangeOfString:@"nothing"].location == NSNotFound)
		return [NSString stringWithFormat:@"compile error case: library %@, error %@", broken, err];
	printf("msl: compile error answered: %s\n", [[err.localizedDescription stringByReplacingOccurrencesOfString:@"\n" withString:@" | "] UTF8String]);
	return nil;
}

/*
 * flame/0012: the frontend's objects answer conformsToProtocol: for the public Metal protocols. MetalPerformanceShaders
 * (20H392 MPSCore) refuses a command buffer that does not, answers nil and SpringBoard's Siri orb then crashes on the nil.
 * Then an MPSImageGaussianBlur through the device (the host MPS on MoltenVK): a pass is the conformance; the blur's
 * outcome is printed (its kernels are Apple-GPU AIR that metal2vulkan may refuse) and only an exception fails the case.
 */
static NSString *check_mps(id d)
{
	id<MTLCommandQueue> q = [d newCommandQueue];
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
	td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	td.storageMode = MTLStorageModeShared;
	id<MTLTexture> t = [d newTextureWithDescriptor:td];
	id<MTLBuffer> b = [d newBufferWithLength:256 options:MTLResourceStorageModeShared];
	struct { id obj; Protocol *proto; const char *name; } checks[] = {
		{ q, @protocol(MTLCommandQueue), "MTLCommandQueue" }, { cb, @protocol(MTLCommandBuffer), "MTLCommandBuffer" },
		{ ce, @protocol(MTLComputeCommandEncoder), "MTLComputeCommandEncoder" }, { ce, @protocol(MTLCommandEncoder), "MTLCommandEncoder" },
		{ t, @protocol(MTLTexture), "MTLTexture" }, { t, @protocol(MTLResource), "MTLResource" }, { b, @protocol(MTLBuffer), "MTLBuffer" },
	};
	for (auto &c : checks) {
		if (!c.obj)
			return [NSString stringWithFormat:@"no object for %s", c.name];
		if (![c.obj conformsToProtocol:c.proto])
			return [NSString stringWithFormat:@"%s (%s) does not conform to %s", class_getName(object_getClass(c.obj)), c.name, c.name];
	}
	[ce endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	printf("mps: %zu objects conform to their Metal protocols\n", sizeof checks / sizeof checks[0]);
	@try {
		MPSImageGaussianBlur *blur = [[MPSImageGaussianBlur alloc] initWithDevice:d sigma:2.0f];
		id<MTLTexture> dst = [d newTextureWithDescriptor:td];
		id<MTLCommandBuffer> cb2 = [q commandBuffer];
		[blur encodeToCommandBuffer:cb2 sourceTexture:t destinationTexture:dst];
		[cb2 commit];
		[cb2 waitUntilCompleted];
		printf("mps: MPSImageGaussianBlur encoded, command buffer status %ld%s%s\n", (long)cb2.status, cb2.error ? ": " : "",
		       cb2.error ? cb2.error.localizedDescription.UTF8String : "");
	} @catch (NSException *ex) {
		return [NSString stringWithFormat:@"MPSImageGaussianBlur raised %@: %@", ex.name, ex.reason];
	}
	return nil;
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		setvbuf(stdout, NULL, _IONBF, 0);
		if (argc < 2)
			return fail("usage", @"host-plugin-test CASE");
		const char *c = argv[1];
		Class cls = NSClassFromString(@"NegroniMTLDevice");
		if (!cls)
			return fail(c, @"no class NegroniMTLDevice");
		Class base = objc_getClass("_MTLDevice");
		if (!base || ![cls isSubclassOfClass:base])
			return fail(c, @"NegroniMTLDevice is not a subclass of _MTLDevice");
		uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		id d = [[cls alloc] initWithAcceleratorPort:0];
		double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
		printf("case %s: device %s in %.0f ms\n", c, d ? [[d name] UTF8String] : "nil", ms);
		bool wants = !strcmp(c, "device") || !strcmp(c, "msl") || !strcmp(c, "mps") || !strcmp(c, "watchdog");
		if (wants) {
			if (!d)
				return fail(c, @"no device");
			if (![d conformsToProtocol:@protocol(MTLDevice)])
				return fail(c, @"device does not conform to MTLDevice");
			Protocol *spi = objc_getProtocol("MTLDeviceSPI");
			if (spi && ![d conformsToProtocol:spi])
				return fail(c, @"device does not conform to MTLDeviceSPI");
			for (NSString *sel in @[ @"newPipelineLibraryWithFilePath:error:", @"newTextureWithDescriptor:iosurface:plane:",
						  @"supportsFamily:", @"newCommandQueue" ])
				if (![d respondsToSelector:NSSelectorFromString(sel)])
					return fail(c, [@"device lacks " stringByAppendingString:sel]);
			if (!getenv("CA_USE_CGTEXTUREDATA") || strcmp(getenv("CA_USE_CGTEXTUREDATA"), "0"))
				return fail(c, @"CA_USE_CGTEXTUREDATA is not 0 in a process with a device");
		} else if (d) {
			return fail(c, @"a device where none was expected");
		}
		if (!strcmp(c, "device"))
			if (NSString *why = check_fixes(d))
				return fail(c, why);
		if (!strcmp(c, "msl"))
			if (NSString *why = check_msl(d))
				return fail(c, why);
		if (!strcmp(c, "mps"))
			if (NSString *why = check_mps(d))
				return fail(c, why);
		if (!strcmp(c, "watchdog")) {
			/* NEGRONIMETAL_WATCHDOG=1 NEGRONIMETAL_WATCHDOG_S=1 (the script sets them): a stuck command buffer trips it */
			const char *marker = getenv("NMTL_HOST_MARKER");
			if (!marker)
				return fail(c, @"NMTL_HOST_MARKER not set");
			commit_stuck(d);
			struct stat stt;
			for (int i = 0; i < 80 && stat(marker, &stt) != 0; i++)
				usleep(100000);
			if (stat(marker, &stt) != 0)
				return fail(c, [NSString stringWithFormat:@"no %s 8 s after a stuck command buffer", marker]);
			if ([[cls alloc] initWithAcceleratorPort:0])
				return fail(c, @"a device after the watchdog marked the GPU lost");
		}
		if (!strcmp(c, "timeout") && ms > 2000)
			return fail(c, [NSString stringWithFormat:@"waited %.0f ms for a 1 ms deadline", ms]);
		if (!wants && strcmp(c, "timeout") && ms > 200)
			return fail(c, [NSString stringWithFormat:@"refusal took %.0f ms", ms]);
		printf("PASS %s\n", c);
		fflush(stdout);
		_exit(0);
	}
}
