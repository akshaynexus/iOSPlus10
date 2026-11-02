/*
 * Host build of Apple's IOHIDEvent.cpp and of SweetHIDTouch::touch (scripts/laurel/test-ios26-hid.sh): the few kernel types they use, with the same meaning.
 * Nothing here goes into a kernel.
 */
#ifndef HOSTKERN_H
#define HOSTKERN_H
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <vector>
typedef uint8_t UInt8; typedef uint16_t UInt16; typedef uint32_t UInt32; typedef uint64_t UInt64; typedef int32_t SInt32; typedef int16_t SInt16; typedef int64_t SInt64;
typedef int32_t IOFixed; typedef uint32_t IOOptionBits; typedef uint64_t IOByteCount; typedef int IOReturn; typedef uint32_t OSBoolean_t;
typedef unsigned char Boolean; typedef uint64_t AbsoluteTime; typedef struct { unsigned int val[8]; } audit_token_t; typedef uint32_t boolean_t_host; typedef uint32_t IOReturn_host;
#define kIOReturnSuccess 0
#define kIOReturnNoMemory 1
#define TRUE 1
#define __unused __attribute__((unused))
#define FALSE 0
#define bcopy(a, b, n) memmove((b), (a), (n))
#define bzero(a, n) memset((a), 0, (n))
#define COMPILER_BARRIER() __asm__ volatile("" : : : "memory")
#define APPLE_KEXT_OVERRIDE override
class OSMetaClass {};
#define OSDeclareDefaultStructors(c) public: c() {} virtual ~c() {} private:
#define OSDeclareAbstractStructors(c) public: c() {} virtual ~c() {} private:
#define OSDefineMetaClassAndStructors(c, s)
#define OSSafeReleaseNULL(p) do { if (p) { (p)->release(); (p) = NULL; } } while (0)
class OSObject {
	int refs = 1;
public:
	virtual ~OSObject() {}
	virtual bool init() { return true; }
	virtual void free() { delete this; }
	void retain() { refs++; }
	void release() { if (--refs == 0) free(); }
};
class OSArray : public OSObject {
	std::vector<const OSObject *> v;
public:
	static OSArray *withCapacity(unsigned) { return new OSArray; }
	static OSArray *withObjects(const OSObject *o[], unsigned n) { OSArray *a = new OSArray; for (unsigned i = 0; i < n; i++) a->setObject(o[i]); return a; }
	bool setObject(const OSObject *o) { const_cast<OSObject *>(o)->retain(); v.push_back(o); return true; }
	unsigned getCount() const { return (unsigned)v.size(); }
	OSObject *getObject(unsigned i) const { return i < v.size() ? const_cast<OSObject *>(v[i]) : NULL; }
	void free() override { for (auto o : v) const_cast<OSObject *>(o)->release(); delete this; }
};
class OSData : public OSObject {
public:
	static OSData *withCapacity(unsigned) { return new OSData; }
	bool appendBytes(const void *, unsigned) { return true; }
	bool appendByte(unsigned char, unsigned) { return true; }
	unsigned getLength() const { return 0; }
	const void *getBytesNoCopy() const { return NULL; }
	void *getBytesNoCopy(unsigned, unsigned) { return NULL; }
};
static inline void *IOMallocZeroData(size_t n) { return calloc(1, n); }
static inline void *IOMallocData(size_t n) { return malloc(n); }
static inline void IOFreeData(void *p, size_t) { ::free(p); }
#define IOLog(...) fprintf(stderr, __VA_ARGS__)
static inline uint64_t continuoustime_to_absolutetime(uint64_t v) { return v; }
static inline uint64_t absolutetime_to_continuoustime(uint64_t v) { return v; }
static inline void absolutetime_to_nanoseconds(uint64_t a, uint64_t *n) { *n = a; }
static inline void clock_get_uptime(uint64_t *v) { *v = 1000; }
static inline void clock_absolutetime_interval_to_deadline(uint64_t a, uint64_t *d) { *d = a; }
static inline uint64_t mach_absolute_time(void) { return 0x1122334455ull; }
#define SUB_ABSOLUTETIME(a, b) (*(a) -= *(b))
#endif
