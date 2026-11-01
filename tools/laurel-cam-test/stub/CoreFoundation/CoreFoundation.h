/* Host mock of what userland/camera/camera_device.c uses of CoreFoundation (tools/laurel-cam-test/cam5_mock.c): counted objects, not Apple's code. */
#ifndef MOCK_CF_H
#define MOCK_CF_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef const void *CFTypeRef;
typedef const struct mock_obj *CFStringRef, *CFDictionaryRef, *CFArrayRef, *CFNumberRef, *CFBooleanRef, *CFSetRef, *CFAllocatorRef;
typedef struct mock_obj *CFMutableDictionaryRef, *CFMutableSetRef;
typedef long CFIndex;
typedef unsigned long CFTypeID;
typedef unsigned char Boolean;
typedef int32_t OSStatus;
enum { kCFStringEncodingUTF8 = 1, kCFNumberSInt32Type = 3, kCFNumberSInt64Type = 4, kCFNumberFloatType = 12, kCFNumberDoubleType = 13 };
typedef int CFNumberType;
extern const int kCFTypeArrayCallBacks, kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks, kCFTypeSetCallBacks;
extern CFBooleanRef kCFBooleanTrue, kCFBooleanFalse;
CFStringRef mock_cfstr(const char *s);
#define CFSTR(s) mock_cfstr(s)
CFTypeRef CFRetain(CFTypeRef o);
void CFRelease(CFTypeRef o);
CFTypeID CFGetTypeID(CFTypeRef o);
CFTypeID CFStringGetTypeID(void), CFNumberGetTypeID(void), CFDictionaryGetTypeID(void), CFArrayGetTypeID(void), CFBooleanGetTypeID(void);
Boolean CFBooleanGetValue(CFBooleanRef b);
CFStringRef CFStringCreateWithCString(CFAllocatorRef a, const char *s, int enc);
CFStringRef CFStringCreateWithFormat(CFAllocatorRef a, CFDictionaryRef o, CFStringRef f, ...);
Boolean CFStringGetCString(CFStringRef s, char *b, CFIndex n, int enc);
CFStringRef CFCopyDescription(CFTypeRef o);
CFNumberRef CFNumberCreate(CFAllocatorRef a, CFNumberType t, const void *v);
Boolean CFNumberGetValue(CFNumberRef n, CFNumberType t, void *v);
CFArrayRef CFArrayCreate(CFAllocatorRef a, const void **v, CFIndex n, const void *cb);
CFIndex CFArrayGetCount(CFArrayRef x);
const void *CFArrayGetValueAtIndex(CFArrayRef x, CFIndex i);
CFMutableDictionaryRef CFDictionaryCreateMutable(CFAllocatorRef a, CFIndex c, const void *k, const void *v);
CFMutableDictionaryRef CFDictionaryCreateMutableCopy(CFAllocatorRef a, CFIndex c, CFDictionaryRef d);
void CFDictionarySetValue(CFMutableDictionaryRef d, const void *k, const void *v);
const void *CFDictionaryGetValue(CFDictionaryRef d, const void *k);
Boolean CFDictionaryContainsKey(CFDictionaryRef d, const void *k);
CFIndex CFDictionaryGetCount(CFDictionaryRef d);
void CFDictionaryGetKeysAndValues(CFDictionaryRef d, const void **k, const void **v);
void CFDictionaryApplyFunction(CFDictionaryRef d, void (*f)(const void *, const void *, void *), void *c);
CFMutableSetRef CFSetCreateMutable(CFAllocatorRef a, CFIndex c, const void *cb);
Boolean CFSetContainsValue(CFSetRef s, const void *v);
void CFSetAddValue(CFMutableSetRef s, const void *v);
#endif
