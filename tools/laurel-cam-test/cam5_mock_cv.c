/* Host mock of CoreMedia and CoreVideo for cam5_test.c, see cam5_mock.c */
#include <stdlib.h>
#include <CoreVideo/CoreVideo.h>
#include "cam5_mock.h"
#include "cam5_mock_int.h"

/* ---- CoreMedia, CoreVideo ---- */
volatile int mock_pool_refuse;
CFStringRef kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
    kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2;

void
mock_cv_init(void)
{
	kCVImageBufferYCbCrMatrixKey = kCVImageBufferYCbCrMatrix_ITU_R_601_4 = mock_cfstr("ycbcr");
	kCVImageBufferColorPrimariesKey = kCVImageBufferColorPrimaries_ITU_R_709_2 = mock_cfstr("primaries");
	kCVImageBufferTransferFunctionKey = kCVImageBufferTransferFunction_ITU_R_709_2 = mock_cfstr("transfer");
}

CMClockRef CMClockGetHostTimeClock(void) { static struct mock_obj c = { 1, T_MISC, 1 << 30 }; return &c; }
CMTime CMClockMakeHostTimeFromSystemUnits(uint64_t t) { CMTime x = { (int64_t)t, 1000000000, 1, 0 }; return x; }
CFDictionaryRef CMTimeCopyAsDictionary(CMTime t, CFAllocatorRef a) { return mock_make(T_DICT); }
OSStatus CMVideoFormatDescriptionCreate(CFAllocatorRef a, uint32_t f, int w, int h, CFDictionaryRef e, CMVideoFormatDescriptionRef *o) { *o = mock_make(T_MISC); return 0; }
CFDictionaryRef mock_pool(uint32_t w, uint32_t h, uint32_t pf) { struct mock_obj *o = mock_make(T_POOL); o->w = w; o->h = h; o->pf = pf; return o; }

int
CVPixelBufferPoolCreatePixelBuffer(CFAllocatorRef a, CVPixelBufferPoolRef p, CVPixelBufferRef *out)
{
	struct mock_obj *o;

	/* (the 4032-wide pool only: a photograph that finds no buffer) */
	if (p->w > 3000 && mock_pool_refuse > 0) {
		mock_pool_refuse--;
		*out = NULL;
		return -1;
	}
	o = mock_make(T_PB);
	o->w = p->w;
	o->h = p->h;
	o->pf = p->pf;
	o->mem = malloc((size_t)p->w * p->h * 2);
	__atomic_add_fetch(&mock_live_buffers, 1, __ATOMIC_SEQ_CST);
	__atomic_add_fetch(&mock_buffers_made, 1, __ATOMIC_SEQ_CST);
	*out = o;
	return 0;
}

void CVPixelBufferRelease(CVPixelBufferRef b) { CFRelease(b); }
CVPixelBufferRef mock_pb_retain(CVPixelBufferRef b) { return (CVPixelBufferRef)CFRetain(b); }
uint32_t CVPixelBufferGetPixelFormatType(CVPixelBufferRef b) { return b->pf; }
size_t CVPixelBufferGetWidth(CVPixelBufferRef b) { return b->w; }
size_t CVPixelBufferGetHeight(CVPixelBufferRef b) { return b->h; }
size_t CVPixelBufferGetBytesPerRow(CVPixelBufferRef b) { return (size_t)b->w * 4; }
size_t CVPixelBufferGetBytesPerRowOfPlane(CVPixelBufferRef b, size_t p) { return b->w; }
void *CVPixelBufferGetBaseAddress(CVPixelBufferRef b) { return b->mem; }
void *CVPixelBufferGetBaseAddressOfPlane(CVPixelBufferRef b, size_t p) { return p ? b->mem + (size_t)b->w * b->h : b->mem; }
int CVPixelBufferLockBaseAddress(CVPixelBufferRef b, int f) { return 0; }
int CVPixelBufferUnlockBaseAddress(CVPixelBufferRef b, int f) { return 0; }
void CVBufferSetAttachment(CVPixelBufferRef b, CFStringRef k, CFTypeRef v, int m) { CFDictionarySetValue(b, k, v); }
CFTypeRef CVBufferGetAttachment(CVPixelBufferRef b, CFStringRef k, int *m) { return CFDictionaryGetValue(b, k); }
struct mock_obj *CMSampleBufferGetImageBuffer(CMSampleBufferRef s) { return (struct mock_obj *)CFDictionaryGetValue(s, CFSTR("image")); }
CFTypeRef CMGetAttachment(CFTypeRef o, CFStringRef k, uint32_t *m) { return CFDictionaryGetValue(o, k); }
void CMSetAttachment(CFTypeRef o, CFStringRef k, CFTypeRef v, uint32_t m) { CFDictionarySetValue((struct mock_obj *)o, k, v); }

/* the derived objects of camera_device.c: storage + its vtable's finalize */
struct mock_obj *
mock_derived_make(void *vt, size_t storage)
{
	struct mock_obj *o = mock_make(T_DERIVED);

	o->vt = vt;
	o->storage = calloc(1, storage);
	return o;
}
void *mock_derived_storage(struct mock_obj *o) { return o->storage; }
void *mock_derived_vt(struct mock_obj *o) { return o->vt; }
