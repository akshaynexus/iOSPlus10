/* Host test only: the little of CoreFoundation that audio_plugin.c uses (scripts/laurel/mic-host-test.sh). */
#ifndef MIC_TEST_CF_H
#define MIC_TEST_CF_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#ifndef __unused
#define __unused __attribute__((unused))
#endif
typedef uint8_t Boolean;
typedef uint32_t UInt32;
typedef uint64_t UInt64;
typedef float Float32;
typedef double Float64;
typedef int32_t OSStatus;
typedef int32_t HRESULT;
typedef uint32_t ULONG;
typedef void *LPVOID;
typedef const char *CFStringRef;        /* a C string stands for a CFString */
typedef const void *CFUUIDRef;
typedef const void *CFDictionaryRef;
typedef const void *CFPropertyListRef;
typedef const void *CFAllocatorRef;
typedef struct { uint8_t b[16]; } CFUUIDBytes;
typedef CFUUIDBytes REFIID;
#define CFSTR(s) (s)
#define kCFStringEncodingUTF8 0
#define S_OK 0
#define E_NOINTERFACE ((HRESULT)0x80000004)
static inline CFStringRef CFStringGetCStringPtr(CFStringRef s, int e) { (void)e; return s; }
static inline void CFRetain(const void *o) { (void)o; }
static inline void CFRelease(const void *o) { (void)o; }
#define IUnknownUUID ((CFUUIDRef)"iunknown")
static inline bool CFEqual(const void *a, const void *b) { return strcmp((const char *)a, (const char *)b) == 0; }
static inline CFUUIDRef CFUUIDCreateFromUUIDBytes(const void *a, CFUUIDBytes b) { (void)a; (void)b; return "uuid"; }
#define CFUUIDGetConstantUUIDWithBytes(a, ...) ((CFUUIDRef)#__VA_ARGS__)
#endif
