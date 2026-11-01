/* Host mock (cam5_mock.c) */
#ifndef MOCK_CV_H
#define MOCK_CV_H
#include <CoreMedia/CoreMedia.h>
typedef struct mock_obj *CVPixelBufferRef, *CVImageBufferRef, *CVPixelBufferPoolRef;
enum { kCVReturnSuccess = 0, kCVAttachmentMode_ShouldPropagate = 1 };
extern CFStringRef kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
    kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2;
CFTypeID CVPixelBufferPoolGetTypeID(void);
int CVPixelBufferPoolCreatePixelBuffer(CFAllocatorRef a, CVPixelBufferPoolRef p, CVPixelBufferRef *o);
void CVPixelBufferRelease(CVPixelBufferRef b);
uint32_t CVPixelBufferGetPixelFormatType(CVPixelBufferRef b);
size_t CVPixelBufferGetWidth(CVPixelBufferRef b), CVPixelBufferGetHeight(CVPixelBufferRef b), CVPixelBufferGetBytesPerRow(CVPixelBufferRef b);
size_t CVPixelBufferGetBytesPerRowOfPlane(CVPixelBufferRef b, size_t p);
void *CVPixelBufferGetBaseAddress(CVPixelBufferRef b), *CVPixelBufferGetBaseAddressOfPlane(CVPixelBufferRef b, size_t p);
int CVPixelBufferLockBaseAddress(CVPixelBufferRef b, int f), CVPixelBufferUnlockBaseAddress(CVPixelBufferRef b, int f);
void CVBufferSetAttachment(CVPixelBufferRef b, CFStringRef k, CFTypeRef v, int m);
CFTypeRef CVBufferGetAttachment(CVPixelBufferRef b, CFStringRef k, int *m);
#endif
