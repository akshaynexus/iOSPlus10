/*
 * Host test of the NegroniMetal plugin logic on a Mac (scripts/metal/host-plugin-test.sh builds and runs it):
 * the plugin + frontend + the bridge built for aarch64-apple-darwin, MoltenVK in place of Turnip, the gate directory in
 * a scratch folder (NMTL_DIR). One case per process, because the plugin opens its device once (dispatch_once):
 *   host-plugin-test CASE      CASE = device | unlisted | off | nogpu | timeout | deadman
 * Prints "PASS CASE" or "FAIL CASE: why". It checks the gate, the fast refusals, the open thread with its deadline, the
 * dead-man counter and the self-test (GPU clear into an IOSurface-backed texture through the frontend); not Metal's own
 * registration (MTLAddDevice is iOS only) and not Turnip or the kernel.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <mach/mach_time.h>
#include <unistd.h>

@interface NSObject (NMTLHostTest)
- (id)initWithAcceleratorPort:(mach_port_t)port;
@end

static int fail(const char *c, NSString *why)
{
	printf("FAIL %s: %s\n", c, why.UTF8String);
	fflush(stdout);
	_exit(1); /* no teardown: an abandoned open may still run on its thread */
}

int main(int argc, char **argv)
{
	@autoreleasepool {
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
		if (!strcmp(c, "device")) {
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
		} else if (d) {
			return fail(c, @"a device where none was expected");
		}
		if (!strcmp(c, "timeout") && ms > 2000)
			return fail(c, [NSString stringWithFormat:@"waited %.0f ms for a 1 ms deadline", ms]);
		if ((!strcmp(c, "unlisted") || !strcmp(c, "off") || !strcmp(c, "nogpu") || !strcmp(c, "deadman")) && ms > 200)
			return fail(c, [NSString stringWithFormat:@"refusal took %.0f ms", ms]);
		printf("PASS %s\n", c);
		fflush(stdout);
		_exit(0);
	}
}
