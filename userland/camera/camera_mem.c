/*
 * NegroniCamera (iOSPlus10, Mi A3 camera quality): the memory line of a running camera: this process's footprint and which kind of memory it is.
 * [V boot 2026-11-01 18:40] the kernel killed mediaserverd twice at 2.5 GB of compressed memory in about 6 s of pictures. The line tells a next
 * such case by its allocator: the malloc zones, and the VM tags (vm_statistics.h: 1-11 malloc, 21 IOKit, 73 IOSurface, ...). A read-only self-check.
 */
#include <malloc/malloc.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

void negronicam_say(const char *format, ...) __attribute__((format(printf, 1, 2)));
void negronicam_memory_line(uint64_t frame);

void
negronicam_memory_line(uint64_t frame)
{
	task_vm_info_data_t vm;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	malloc_statistics_t ms = { 0 };
	uint64_t pages[256] = { 0 }, page = (uint64_t)getpagesize();
	mach_vm_address_t at = 0;
	int top[3] = { -1, -1, -1 };

	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) != KERN_SUCCESS) {
		return;
	}
	malloc_zone_statistics(NULL, &ms);
	for (;;) {
		vm_address_t address = (vm_address_t)at;
		vm_size_t size = 0;
		natural_t depth = 0;
		struct vm_region_submap_info_64 info;
		mach_msg_type_number_t n = VM_REGION_SUBMAP_INFO_COUNT_64;

		if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth, (vm_region_recurse_info_t)&info, &n) != KERN_SUCCESS) {
			break;
		}
		if (!info.is_submap) {
			pages[(uint8_t)info.user_tag] += (uint64_t)info.pages_dirtied + info.pages_swapped_out;
		}
		at = (mach_vm_address_t)address + size;
	}
	for (int i = 0; i < 256; i++) {
		for (int t = 0; t < 3; t++) {
			if (top[t] < 0 || pages[i] > pages[top[t]]) {
				for (int m = 2; m > t; m--) {
					top[m] = top[m - 1];
				}
				top[t] = i;
				break;
			}
		}
	}
	negronicam_say("memory at frame %llu: footprint %llu MB, malloc %llu MB; by VM tag: %d %llu MB, %d %llu MB, %d %llu MB",
	    (unsigned long long)frame, (unsigned long long)(vm.phys_footprint >> 20), (unsigned long long)(ms.size_in_use >> 20), top[0],
	    (unsigned long long)(pages[top[0]] * page >> 20), top[1], (unsigned long long)(pages[top[1]] * page >> 20), top[2],
	    (unsigned long long)(pages[top[2]] * page >> 20));
}
