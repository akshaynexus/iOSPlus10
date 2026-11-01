/*
 * NegroniCamera (iOSPlus10, Mi A3 camera quality): the memory of a running camera. [V boots 2026-11-01 18:40, 19:34] the kernel killed mediaserverd at about 2.6 GB of
 * compressed memory, each time 4 s after its filter strip's prewarm (20 "heap texture refused"), and no line named the allocator (docs/laurel_sprout/metal.md section 12).
 * - The line at frame 60 and each 300 frames: footprint, malloc zones, VM tags (vm_statistics.h: 1-11 malloc, 21 IOKit, 73 IOSurface, ...), Metal's live objects.
 * - The guard (camera_mem_guard.h), a feature on by default, 4 samples a second: one line at each +256 MB with the same facts and the busiest thread's stack; at 768 MB this
 *   session's filter strip goes to the CPU copy (media_hooks.c) and this process makes no new Metal pipelines, with one line. The process stays: a kill stops audio too.
 *   Kill switch: the file /var/db/negronicam/memguard-off.
 */
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "camera_mem_guard.h"

#define METAL_BUNDLE_IMAGE "/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal"
#define MEMGUARD_OFF_FILE  "/var/db/negronicam/memguard-off"

void negronicam_say(const char *format, ...) __attribute__((format(printf, 1, 2)));
void negronicam_memory_line(uint64_t frame);
void negronicam_memory_guard_session(void);
volatile bool negronicam_filter_strip_off;      /* media_hooks.c reads it */

/* Metal's entries (flame/0020), in the plug-in's image when this process has a device. A bundle's symbols are not global: dlopen without loading. */
static void
metal_entries(void (**objects)(int64_t *), void (**stop)(bool))
{
	void *image = dlopen(METAL_BUNDLE_IMAGE, RTLD_NOLOAD | RTLD_LAZY);

	*objects = image != NULL ? (void (*)(int64_t *))dlsym(image, "native_bridge_metal_objects") : NULL;
	if (stop != NULL) {
		*stop = image != NULL ? (void (*)(bool))dlsym(image, "native_bridge_metal_stop_new_pipelines") : NULL;
	}
}

static void
metal_text(char *out, size_t size)
{
	void (*objects)(int64_t *) = NULL;
	int64_t n[9];

	metal_entries(&objects, NULL);
	if (objects == NULL) {
		snprintf(out, size, "Metal: no device in this process");
		return;
	}
	objects(n);
	snprintf(out, size, "Metal: %lld textures (%lld over surfaces), %lld buffers %lld MB, %lld heaps %lld MB, %lld command buffers (%lld in flight), %lld pipelines",
	    (long long)n[0], (long long)n[1], (long long)n[2], (long long)(n[3] >> 20), (long long)n[4], (long long)(n[5] >> 20), (long long)n[6], (long long)n[7], (long long)n[8]);
}

static void
tags_text(char *out, size_t size)
{
	uint64_t pages[256] = { 0 }, page = (uint64_t)getpagesize();
	mach_vm_address_t at = 0;
	int top[3] = { -1, -1, -1 };

	for (;;) {
		vm_address_t address = (vm_address_t)at;
		vm_size_t length = 0;
		natural_t depth = 0;
		struct vm_region_submap_info_64 info;
		mach_msg_type_number_t n = VM_REGION_SUBMAP_INFO_COUNT_64;

		if (vm_region_recurse_64(mach_task_self(), &address, &length, &depth, (vm_region_recurse_info_t)&info, &n) != KERN_SUCCESS) {
			break;
		}
		if (!info.is_submap) {
			pages[(uint8_t)info.user_tag] += (uint64_t)info.pages_dirtied + info.pages_swapped_out;
		}
		at = (mach_vm_address_t)address + length;
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
	snprintf(out, size, "by VM tag: %d %llu MB, %d %llu MB, %d %llu MB", top[0], (unsigned long long)(pages[top[0]] * page >> 20), top[1],
	    (unsigned long long)(pages[top[1]] * page >> 20), top[2], (unsigned long long)(pages[top[2]] * page >> 20));
}

static void
append_place(char *out, size_t size, uintptr_t pc)
{
	Dl_info info;
	size_t used = strlen(out);

	if (dladdr((const void *)pc, &info) != 0 && info.dli_fname != NULL) {
		const char *name = strrchr(info.dli_fname, '/');

		snprintf(out + used, size - used, " %s+0x%lx", name != NULL ? name + 1 : info.dli_fname, (unsigned long)(pc - (uintptr_t)info.dli_fbase));
	} else {
		snprintf(out + used, size - used, " 0x%lx", (unsigned long)pc);
	}
}

/* The thread with the most CPU now and where it is: what allocates at 600 MB/s is on the CPU. Frames are read with vm_read, so a stack that moves costs a short list, no fault. */
static void
busiest_thread_text(char *out, size_t size)
{
	thread_act_array_t threads = NULL;
	mach_msg_type_number_t count = 0;
	thread_act_t self = mach_thread_self(), best = MACH_PORT_NULL;
	integer_t best_cpu = -1;
	struct thread_extended_info extended;
	mach_msg_type_number_t n;

	snprintf(out, size, "no thread");
	if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
		mach_port_deallocate(mach_task_self(), self);
		return;
	}
	for (mach_msg_type_number_t i = 0; i < count; i++) {
		struct thread_basic_info basic;

		n = THREAD_BASIC_INFO_COUNT;
		if (threads[i] != self && thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &n) == KERN_SUCCESS && basic.cpu_usage > best_cpu) {
			best_cpu = basic.cpu_usage;
			best = threads[i];
		}
	}
	if (best != MACH_PORT_NULL) {
		arm_thread_state64_t state;
		char name[64] = "";

		n = THREAD_EXTENDED_INFO_COUNT;
		if (thread_info(best, THREAD_EXTENDED_INFO, (thread_info_t)&extended, &n) == KERN_SUCCESS) {
			snprintf(name, sizeof(name), "%s", extended.pth_name);
		}
		snprintf(out, size, "busiest thread \"%s\" %d%%:", name, best_cpu * 100 / TH_USAGE_SCALE);
		n = ARM_THREAD_STATE64_COUNT;
		if (thread_get_state(best, ARM_THREAD_STATE64, (thread_state_t)&state, &n) == KERN_SUCCESS) {
			uint64_t frame = arm_thread_state64_get_fp(state);

			append_place(out, size, (uintptr_t)arm_thread_state64_get_pc(state));
			append_place(out, size, (uintptr_t)arm_thread_state64_get_lr(state));
			for (int depth = 0; depth < 8 && frame != 0; depth++) {
				uint64_t pair[2];
				vm_size_t got = 0;

				if (vm_read_overwrite(mach_task_self(), (vm_address_t)frame, sizeof(pair), (vm_address_t)pair, &got) != KERN_SUCCESS || got != sizeof(pair) ||
				    pair[1] == 0 || pair[0] <= frame) {
					break;
				}
				append_place(out, size, (uintptr_t)pair[1]);
				frame = pair[0];
			}
		}
	}
	for (mach_msg_type_number_t i = 0; i < count; i++) {
		mach_port_deallocate(mach_task_self(), threads[i]);
	}
	vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(threads[0]));
	mach_port_deallocate(mach_task_self(), self);
}

static bool
footprint_now(uint64_t *footprint, uint64_t *compressed)
{
	task_vm_info_data_t vm;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) != KERN_SUCCESS) {
		return false;
	}
	*footprint = vm.phys_footprint;
	*compressed = vm.compressed;
	return true;
}

void
negronicam_memory_line(uint64_t frame)
{
	malloc_statistics_t ms = { 0 };
	uint64_t footprint = 0, compressed = 0;
	char tags[96], metal[160];

	if (!footprint_now(&footprint, &compressed)) {
		return;
	}
	malloc_zone_statistics(NULL, &ms);
	tags_text(tags, sizeof(tags));
	metal_text(metal, sizeof(metal));
	negronicam_say("memory at frame %llu: footprint %llu MB (compressed %llu MB), malloc %llu MB; %s; %s", (unsigned long long)frame, (unsigned long long)(footprint >> 20),
	    (unsigned long long)(compressed >> 20), (unsigned long long)(ms.size_in_use >> 20), tags, metal);
}

static struct memguard guard;
static dispatch_queue_t guard_queue;

static void
guard_stop_pipelines(bool stop)
{
	void (*objects)(int64_t *) = NULL, (*stop_pipelines)(bool) = NULL;

	metal_entries(&objects, &stop_pipelines);
	if (stop_pipelines != NULL) {
		stop_pipelines(stop);
	}
}

static void
guard_line(const char *why, uint64_t footprint, uint64_t compressed)
{
	malloc_statistics_t ms = { 0 };
	char tags[96], metal[160], thread[320];

	malloc_zone_statistics(NULL, &ms);
	tags_text(tags, sizeof(tags));
	metal_text(metal, sizeof(metal));
	busiest_thread_text(thread, sizeof(thread));
	negronicam_say("memory guard: %s: footprint %llu MB (compressed %llu MB), malloc %llu MB; %s; %s; %s", why, (unsigned long long)(footprint >> 20),
	    (unsigned long long)(compressed >> 20), (unsigned long long)(ms.size_in_use >> 20), tags, metal, thread);
}

static void
guard_sample(void *context)
{
	uint64_t footprint = 0, compressed = 0;

	(void)context;
	if (!footprint_now(&footprint, &compressed)) {
		return;
	}
	switch (memguard_sample(&guard, footprint >> 20)) {
	case MEMGUARD_LIMIT:
		negronicam_filter_strip_off = true;
		guard_stop_pipelines(true);
		guard_line("limit: the filter strip goes through the CPU for this session, no new Metal pipelines", footprint, compressed);
		break;
	case MEMGUARD_LINE:
		guard_line(guard.over ? "still growing past the limit" : "growing", footprint, compressed);
		break;
	default:
		break;
	}
}

/* each session's start: starts the guard once, and lifts a limit the footprint is back under */
void
negronicam_memory_guard_session(void)
{
	static dispatch_once_t once;
	static bool on;

	dispatch_once(&once, ^{
		if (access(MEMGUARD_OFF_FILE, F_OK) == 0) {
			negronicam_say("memory guard: off: " MEMGUARD_OFF_FILE);
			return;
		}
		memguard_init(&guard, MEMGUARD_LIMIT_MB);
		guard_queue = dispatch_queue_create("negronicam.memory-guard", DISPATCH_QUEUE_SERIAL);
		dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, guard_queue);

		if (guard_queue == NULL || timer == NULL) {
			negronicam_say("memory guard: off: no queue or timer");
			return;
		}
		dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
		dispatch_source_set_event_handler_f(timer, guard_sample);
		dispatch_resume(timer);
		on = true;
		negronicam_say("memory guard: on: 4 samples a second, a line at each +%u MB, limit %u MB", MEMGUARD_STEP_MB, MEMGUARD_LIMIT_MB);
	});
	if (!on) {
		return;
	}
	dispatch_async(guard_queue, ^{
		uint64_t footprint = 0, compressed = 0;

		if (!footprint_now(&footprint, &compressed)) {
			return;
		}
		switch (memguard_session(&guard, footprint >> 20)) {
		case MEMGUARD_LIFTED:
			negronicam_filter_strip_off = false;
			guard_stop_pipelines(false);
			negronicam_say("memory guard: a new session, footprint %llu MB: the filter strip and new pipelines are back", (unsigned long long)(footprint >> 20));
			break;
		case MEMGUARD_STILL_OVER:
			negronicam_say("memory guard: a new session, footprint %llu MB, still past the limit: the filter strip stays off", (unsigned long long)(footprint >> 20));
			break;
		default:
			break;
		}
	});
}
