// negroni-shot: write what the render server shows on the main display to a PNG.
// The render server (backboardd) draws the display into our own IOSurface (CARenderServerRenderDisplay),
// so the picture is the composited UI before the framebuffer copy. Dev tool, run over SSH:
//   negroni-shot [OUT.png]        default /private/var/tmp/negroni-shot.png
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurfaceRef.h>
#import <dlfcn.h>
#import <objc/message.h>

typedef void (*render_display_fn)(mach_port_t, CFStringRef, IOSurfaceRef, int, int);

static int fail(const char *what) { fprintf(stderr, "negroni-shot: %s\n", what); return 1; }

int main(int argc, char **argv)
{
	@autoreleasepool {
		const char *out = argc > 1 ? argv[1] : "/private/var/tmp/negroni-shot.png";
		void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
		render_display_fn render = qc ? (render_display_fn)dlsym(qc, "CARenderServerRenderDisplay") : NULL;
		if (!render)
			return fail("no CARenderServerRenderDisplay in QuartzCore");

		// display size in pixels from CADisplay.mainDisplay.bounds (the mode CA composites at)
		size_t w = 1125, h = 2436;
		Class cad = NSClassFromString(@"CADisplay");
		id main = cad ? ((id (*)(id, SEL))objc_msgSend)(cad, sel_registerName("mainDisplay")) : nil;
		if (main) {
			CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(main, sel_registerName("bounds"));
			if (b.size.width >= 1 && b.size.height >= 1) {
				w = (size_t)b.size.width;
				h = (size_t)b.size.height;
			}
		}

		NSDictionary *props = @{
			(id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h),
			(id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(((w * 4) + 63) & ~(size_t)63),
			(id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
		};
		IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
		if (!s)
			return fail("IOSurfaceCreate failed");
		render(MACH_PORT_NULL, CFSTR("LCD"), s, 0, 0);

		IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
		size_t bpr = IOSurfaceGetBytesPerRow(s);
		CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
		CGContextRef cg = CGBitmapContextCreate(IOSurfaceGetBaseAddress(s), w, h, 8, bpr, cs,
		    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
		CGImageRef img = cg ? CGBitmapContextCreateImage(cg) : NULL;
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
		if (!img)
			return fail("no image from the surface");

		NSURL *url = [NSURL fileURLWithPath:@(out)];
		CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
		if (!d)
			return fail("cannot create the PNG file");
		CGImageDestinationAddImage(d, img, NULL);
		bool ok = CGImageDestinationFinalize(d);
		CFRelease(d);
		CGImageRelease(img);
		CGContextRelease(cg);
		CGColorSpaceRelease(cs);
		CFRelease(s);
		if (!ok)
			return fail("PNG write failed");
		printf("%s %zux%zu\n", out, w, h);
	}
	return 0;
}
