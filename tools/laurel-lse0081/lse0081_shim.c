/*
 * Host test of the iOS 16 EL0 LSE emulation: the kernel's own C text (sleh_frag.inc, out of sleh.c, see extract.py) on the names it uses from the kernel.
 * a64emu_run() here is the start of handle_uncategorized(): emulate, or the word stays undefined. See scripts/laurel/test-lse0081.sh.
 */
#include "laurel_a64emu.h"
#include <stddef.h>

typedef struct a64emu_regs arm_saved_state_t;
typedef uint64_t user_addr_t;
typedef long register_t;
typedef long long mach_exception_data_type_t;
typedef int kern_return_t;
typedef void *vm_map_t;
typedef void *thread_t;

#define FALSE 0
#define NULL_MAP ((vm_map_t)0)
#define MACH_VM_MAX_ADDRESS (1ULL << 47)
#define PAGE_MASK 0xfffULL
#define vm_map_trunc_page(x, m) ((uint64_t)(x) & ~(uint64_t)(m))
#define VM_PROT_READ 1
#define VM_PROT_WRITE 2
#define VM_KERN_MEMORY_NONE 0
#define THREAD_ABORTSAFE 1
#define KERN_SUCCESS 0
#define KERN_INVALID_ADDRESS 1
#define KERN_PROTECTION_FAILURE 2
#define KERN_ABORTED 14
#define EXC_BAD_ACCESS 1
#define EXC_ARM_DA_ALIGN 0x101
#define get_saved_state_reg(s, n) ((s)->x[n])
#define set_saved_state_reg(s, n, v) ((s)->x[n] = (uint64_t)(v))
#define get_saved_state_sp(s) ((s)->sp)
#define add_saved_state_pc(s, n) ((s)->pc += (n))
#define current_map() NULL_MAP
#define current_thread() ((thread_t)0)
#define __dead2 __attribute__((noreturn))

/* what the rules look at */
volatile uint64_t g_lse_calls, g_lse_addr, g_vmf_calls, g_vmf_addr, g_far, g_resets;
volatile int g_vmf_prot, g_vmf_force = -1, g_exc;
volatile long long g_code0, g_code1;
volatile uint64_t g_ro_page;

static inline void set_saved_state_far(arm_saved_state_t *s, uint64_t far)
{
	(void)s;
	g_far = far;
}
static inline void thread_reset_pcs_will_fault(thread_t t)
{
	(void)t;
	g_resets++;
}

/* the second vm_fault of the path. The first one runs in the fault path (harness.c, segv_handler) */
static kern_return_t
vm_fault(vm_map_t map, uint64_t addr, int prot, int wiring, int tag, int interruptible, void *pmap, uint64_t paddr)
{
	(void)map; (void)wiring; (void)tag; (void)pmap; (void)paddr;
	g_vmf_calls++;
	g_vmf_addr = addr;
	g_vmf_prot = prot;
	if (interruptible != THREAD_ABORTSAFE) {
		return KERN_INVALID_ADDRESS;
	}
	if (g_vmf_force >= 0) {
		return g_vmf_force;
	}
	return g_ro_page && (addr & ~0xfffULL) == g_ro_page ? KERN_PROTECTION_FAILURE : KERN_INVALID_ADDRESS;
}

int lse0081_setjmp(uint64_t *jb) __attribute__((returns_twice));
void lse0081_longjmp(uint64_t *jb) __attribute__((noreturn));
static uint64_t *volatile g_jb;

static __dead2 void
exception_triage(int exc, mach_exception_data_type_t *codes, int n)
{
	(void)n;
	g_exc = exc;
	g_code0 = codes[0];
	g_code1 = codes[1];
	lse0081_longjmp(g_jb);
}

/* each access of the kernel text is counted: the rules show which bad address never reached it */
#define _sweet_lse_b counted_b
#define _sweet_lse_h counted_h
#define _sweet_lse_w counted_w
#define _sweet_lse_x counted_x
#include "sleh_frag.inc"
#undef _sweet_lse_b
#undef _sweet_lse_h
#undef _sweet_lse_w
#undef _sweet_lse_x

#define COUNTED(s) \
	extern int _sweet_lse_ ## s(user_addr_t, uint32_t, uint64_t, uint64_t, uint64_t *); \
	int counted_ ## s(user_addr_t a, uint32_t op, uint64_t v, uint64_t c, uint64_t *o) { g_lse_calls++; g_lse_addr = a; return _sweet_lse_ ## s(a, op, v, c, o); }
COUNTED(b)
COUNTED(h)
COUNTED(w)
COUNTED(x)

enum a64emu_result
a64emu_run(struct a64emu_cpu *c, uint32_t word, struct a64emu_out *o)
{
	uint64_t jb[13];

	o->cls = -1;
	o->addr = 0;
	o->write = false;
	g_jb = jb;
	if (lse0081_setjmp(jb)) {
		o->cls = A64E_LSE;
		o->addr = (uint64_t)g_code1;
		return g_code0 == EXC_ARM_DA_ALIGN ? A64EMU_ALIGN : A64EMU_FAULT;
	}
	if (!sweet_emulate_lse(c->r, word)) {
		return A64EMU_UNKNOWN;
	}
	o->cls = A64E_LSE;
	return A64EMU_OK;
}
