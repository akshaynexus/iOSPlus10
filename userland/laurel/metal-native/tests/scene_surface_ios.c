/* SPDX-License-Identifier: MIT */
/* tests/scene.c on the phone: a real IOSurface, as CA asks for one (IOSurfaceCreate, 'BGRA'). The caller keeps it for the tool's life. */
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef struct __IOSurface *IOSurfaceRef;
extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef);
extern size_t IOSurfaceGetAllocSize(IOSurfaceRef);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef);
extern uint32_t IOSurfaceGetID(IOSurfaceRef);
extern const CFStringRef kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat;

static CFNumberRef number(int32_t v) { return CFNumberCreate(NULL, kCFNumberSInt32Type, &v); }

uint32_t scene_make_surface(uint32_t width, uint32_t height, void **base, uint64_t *bytes, uint32_t *row)
{
	const void *keys[] = {kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat};
	const void *values[] = {number((int32_t)width), number((int32_t)height), number(4), number(0x42475241)};
	CFDictionaryRef d = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	IOSurfaceRef s = IOSurfaceCreate(d);
	CFRelease(d);
	if (s == NULL)
		return 0;
	*base = IOSurfaceGetBaseAddress(s);
	*bytes = (IOSurfaceGetAllocSize(s) + 4095) & ~4095ull;
	*row = (uint32_t)IOSurfaceGetBytesPerRow(s);
	return IOSurfaceGetID(s);
}
