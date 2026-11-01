/* Host mock (cam5_mock.c) */
#ifndef MOCK_CM_H
#define MOCK_CM_H
#include <CoreFoundation/CoreFoundation.h>
typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } CMTime;
typedef struct mock_obj *CMSampleBufferRef, *CMVideoFormatDescriptionRef, *CMClockRef;
enum { kCMAttachmentMode_ShouldPropagate = 1 };
CMClockRef CMClockGetHostTimeClock(void);
CMTime CMClockMakeHostTimeFromSystemUnits(uint64_t t);
CFDictionaryRef CMTimeCopyAsDictionary(CMTime t, CFAllocatorRef a);
OSStatus CMVideoFormatDescriptionCreate(CFAllocatorRef a, uint32_t f, int w, int h, CFDictionaryRef e, CMVideoFormatDescriptionRef *o);
struct mock_obj *CMSampleBufferGetImageBuffer(CMSampleBufferRef s);
CFTypeRef CMGetAttachment(CFTypeRef o, CFStringRef k, uint32_t *m);
void CMSetAttachment(CFTypeRef o, CFStringRef k, CFTypeRef v, uint32_t m);
#endif
