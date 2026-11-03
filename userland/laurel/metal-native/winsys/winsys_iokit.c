/* SPDX-License-Identifier: MIT */
/* The winsys's kernel on the phone: RedwoodGPU's msm requests through IOKit (docs/gpu-abi.md section 4). As userland/negronigl/drm/negroni_drm.c, with no libdrm stand-in around it. */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <mach/mach.h>
#include <stdio.h>
#include "nw.h"

#ifndef kIOReturnNotPermitted
#include <IOKit/IOReturn.h>
#endif

static int kr_errno(kern_return_t kr)
{
	switch (kr) {
	case KERN_SUCCESS: return 0;
	case kIOReturnNoMemory:
	case kIOReturnNoResources: return ENOMEM;
	case kIOReturnBadArgument: return EINVAL;
	case kIOReturnTimeout: return ETIMEDOUT;
	case kIOReturnBusy: return EBUSY;
	case kIOReturnNotFound: return ENOENT;
	case kIOReturnUnsupported: return ENOSYS;
	case kIOReturnNotReady:
	case kIOReturnOffline: return ENODEV;
	case kIOReturnNotPermitted:
	case kIOReturnNotPrivileged: return EPERM;
	default: return EIO;
	}
}

static int rw_call(void *ctx, uint32_t selector, void *data, size_t size)
{
	size_t out = size;
	return kr_errno(IOConnectCallStructMethod((io_connect_t)(uintptr_t)ctx, selector, data, size, data, &out));
}

static void *rw_map(void *ctx, uint32_t handle, uint64_t size)
{
	mach_vm_address_t addr = 0;
	mach_vm_size_t len = 0;
	kern_return_t kr = IOConnectMapMemory64((io_connect_t)(uintptr_t)ctx, handle, mach_task_self(), &addr, &len, kIOMapAnywhere);
	if (kr != KERN_SUCCESS)
		return NULL;
	if (len < size) {
		IOConnectUnmapMemory64((io_connect_t)(uintptr_t)ctx, handle, mach_task_self(), addr);
		return NULL;
	}
	return (void *)(uintptr_t)addr;
}

static void rw_unmap(void *ctx, uint32_t handle, void *address, uint64_t size)
{
	(void)size;
	IOConnectUnmapMemory64((io_connect_t)(uintptr_t)ctx, handle, mach_task_self(), (mach_vm_address_t)(uintptr_t)address);
}

static const struct nw_ops rw_ops = {rw_call, rw_map, rw_unmap};

const struct nw_ops *nmn_platform_ops(void **ctx, char *why, size_t why_size)
{
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("RedwoodGPU"));
	if (svc == IO_OBJECT_NULL) {
		snprintf(why, why_size, "no RedwoodGPU service");
		return NULL;
	}
	io_connect_t conn = IO_OBJECT_NULL;
	kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
	IOObjectRelease(svc);
	if (kr != KERN_SUCCESS) {
		snprintf(why, why_size, "IOServiceOpen RedwoodGPU: %#x", kr);
		return NULL;
	}
	*ctx = (void *)(uintptr_t)conn;
	return &rw_ops;
}
