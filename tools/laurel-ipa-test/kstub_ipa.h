/*
 * Host stand-ins for the XNU headers of the laurel 2780 IPA files (laurel_ext4*.c, laurel_ipa*.c, topaz_pas.c), on top of
 * the cellular test's stubs (tools/laurel-cell-test/kstub.h). scripts/laurel/test-ipa.sh makes the kernel
 * header names (sys/param.h, kern/kalloc.h, ...) include this file.
 */
#ifndef KSTUB_IPA_H
#define KSTUB_IPA_H
#include "kstub.h"
#include <errno.h>
#include <stdlib.h>

#ifndef ENOTSUP
#define ENOTSUP                 45
#endif
#define Z_WAITOK                1
#define Z_ZERO                  2
static inline void *kalloc_data(size_t n, int f) { (void)f; return calloc(1, n); }
static inline void kfree_data(void *p, size_t n) { (void)n; free(p); }
typedef uintptr_t vm_offset_t;
typedef uintptr_t vm_size_t;
/* kern/thread.h (laurel_ipa.c): gate_test.c runs the thread inside kernel_thread_start */
typedef int kern_return_t;
typedef int wait_result_t;
typedef long thread_t;
typedef void (*thread_continue_t)(void *, wait_result_t);
#define KERN_SUCCESS            0
static inline thread_t current_thread(void) { return 1; }
/* mach/mach_time.h (topaz_pas.c): the test clock */
static inline uint64_t mach_absolute_time(void) { return kt_now_ns; }
#endif
