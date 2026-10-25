/*
 * The Metal device of a NegroniMetal probe process (carenderprobe, layerprobe), the way metalprobe --bundle gets it:
 *   - Metal's own discovery first (MTLCreateSystemDefaultDevice; with the kernel's MetalPluginName that is our plugin);
 *   - else, with --bundle PATH, the plugin bundle is loaded in this process, its principal class makes the device
 *     (-initWithAcceleratorPort:, the plugin's gate decides) and Metal's MTLAddDevice registers it for this process only.
 * The plugin's gate applies: the probe must be listed in a clients file (BUNDLE/clients lists the probes).
 * Plain C + Objective-C without ARC (the probes are built with -fno-objc-arc, as Chlorophyll builds them).
 */
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

/* "--bundle PATH" in argv: PATH, and the two arguments are removed from argv (argc updated) */
static const char *nmtl_probe_bundle_arg(int *argc, char **argv)
{
	for (int i = 1; i + 1 < *argc; i++)
		if (!strcmp(argv[i], "--bundle")) {
			const char *path = argv[i + 1];
			for (int k = i; k + 2 <= *argc; k++)
				argv[k] = argv[k + 2];
			*argc -= 2;
			return path;
		}
	return NULL;
}

static id<MTLDevice> nmtl_probe_device(const char *bundle)
{
	id<MTLDevice> d = MTLCreateSystemDefaultDevice(); /* also makes Metal's device array, which MTLAddDevice asserts on */
	if (d || !bundle) {
		printf("device: %s (Metal's discovery)\n", d ? d.name.UTF8String : "none");
		return d;
	}
	NSBundle *b = [NSBundle bundleWithPath:@(bundle)];
	NSError *err = nil;
	if (!b || ![b loadAndReturnError:&err]) {
		printf("FAIL bundle-load: %s: %s\n", bundle, err ? err.description.UTF8String : "no bundle");
		return nil;
	}
	Class cls = b.principalClass;
	void (*add)(id) = (void (*)(id))dlsym(RTLD_DEFAULT, "MTLAddDevice");
	if (!cls || !add) {
		printf("FAIL bundle-register: %s\n", cls ? "MTLAddDevice not found" : "no principal class");
		return nil;
	}
	io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("IOAcceleratorES"));
	id dev = ((id(*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], @selector(initWithAcceleratorPort:), svc);
	if (!dev) {
		printf("FAIL bundle-init: initWithAcceleratorPort: returned nil (the plugin refused: see its log)\n");
		return nil;
	}
	add(dev);
	d = MTLCreateSystemDefaultDevice();
	printf("device: %s (bundle %s)\n", d ? d.name.UTF8String : "none", bundle);
	return d;
}
