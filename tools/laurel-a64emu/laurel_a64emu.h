/*
 * laurel_a64emu: EL0 instructions newer than ARMv8.0, run in software for the Mi A3 (Kryo 260, ARMv8.0, no PAC) iOS 26 kernel.
 *
 * Same file in the kernel (osfmk/arm64/, stage script patches/laurel/xnu-12377/stage/) and in the host test
 * (scripts/laurel/test-a64emu.sh: this C code on qemu-aarch64 -cpu cortex-a53, truth = the real word on -cpu max).
 * No kernel header here: the kernel glue is osfmk/arm64/laurel_abi.c.
 *
 * Rules of the code:
 *   - All integer. No FP or NEON register is touched: the user's registers are in memory (struct a64emu_cpu).
 *   - An instruction changes state only after its memory access worked. A fault leaves every register and the PC as they were.
 *   - No lock and no global state: preemption and migration can happen at any point.
 */
#ifndef LAUREL_A64EMU_H
#define LAUREL_A64EMU_H

#include <stdint.h>
#include <stdbool.h>

/* the classes: one count each, one kill bit each */
enum a64emu_class {
	A64E_PAC = 0,    /* RETAA/B BRAA/B(Z) BLRAA/B(Z) LDRAA/B PACx AUTx XPAC PACGA */
	A64E_LSE,        /* CAS SWP LD<op> ST<op>, all sizes */
	A64E_CASP,       /* CASP, word and double pairs */
	A64E_RCPC,       /* LDAPR LDAPUR STLUR, LDLAR STLLR */
	A64E_FP16,       /* FEAT_FP16 scalar and vector */
	A64E_FCMA,       /* FCADD FCMLA */
	A64E_DOTPROD,    /* SDOT UDOT */
	A64E_JSCVT,      /* FJCVTZS */
	A64E_FHM,        /* FMLAL FMLSL */
	A64E_SHA3,       /* EOR3 BCAX RAX1 XAR SHA512* */
	A64E_RDM,        /* SQRDMLAH SQRDMLSH */
	A64E_SYSREG,     /* MSR/MRS DIT, SB, reads of the Apple registers of section 4 */
	A64E_NCLASS
};

enum a64emu_result {
	A64EMU_OK = 0,      /* done, PC moved */
	A64EMU_UNKNOWN,     /* not ours, or its class is off: nothing changed, SIGILL as before */
	A64EMU_FAULT,       /* a bad user address: nothing changed, out.addr is the address */
	A64EMU_ALIGN,       /* an unaligned atomic: nothing changed, out.addr is the address */
	A64EMU_SP_ALIGN,    /* SP as base, not 16-byte aligned: nothing changed */
	A64EMU_RETRY        /* the LL/SC loop did not finish in A64EMU_SPINS tries: nothing changed, return to EL0 and trap again */
};

/* Same layout as the first fields of arm_saved_state64_t (x0-x28, fp, lr, sp, pc, cpsr) and of the Linux sigcontext regs[31], sp, pc, pstate. */
struct a64emu_regs {
	uint64_t x[31];
	uint64_t sp;
	uint64_t pc;
	uint32_t pstate;
};

struct a64emu_cpu {
	struct a64emu_regs *r;
	uint64_t (*v)[2];       /* 32 x 128 bits, little endian */
	uint32_t *fpsr;
	uint32_t *fpcr;
	uint64_t limit;         /* first address above user memory: an access at or above it is a fault, never a kernel access */
	uint32_t off;           /* bit per class: off */
	bool kernel_va;         /* self-check only: the address is a kernel address, no tag strip and no limit */
};

struct a64emu_out {
	int cls;                /* class, -1 for none */
	uint64_t addr;          /* with A64EMU_FAULT or A64EMU_ALIGN */
	bool write;             /* the access needs write permission */
};

/* The class of a word, or -1. A pure function of the word: unallocated field values give -1, as on a CPU that has the feature. */
int a64emu_classify(uint32_t word);

/* Run one word. On A64EMU_OK the PC is the next instruction (or the branch target) and PSTATE.SS is clear, so a debugger's step ends here. */
enum a64emu_result a64emu_run(struct a64emu_cpu *c, uint32_t word, struct a64emu_out *out);

/* Known answers for a class: 0 = good, else the number of the check that failed. Uses no user memory. */
int a64emu_selfcheck(int cls);

/*
 * The LL/SC and load/store code, in laurel_a64emu_asm.h. Each returns 0, or EFAULT through the fault recovery (kernel:
 * copyio recovery table), or 35 (A64EMU_RETRY: the store-exclusive failed A64EMU_SPINS times).
 * op: 0 ADD, 1 CLR, 2 EOR, 3 SET, 4 SMAX, 5 SMIN, 6 UMAX, 7 UMIN, 8 SWP, 9 CAS. val and cmp are zero-extended to the size.
 */
#define A64EMU_ERR_RETRY 35
typedef int (*a64emu_rmw_fn)(uint64_t addr, uint32_t op, uint64_t val, uint64_t cmp, uint64_t *old);
#define A64EMU_RMW_DECL(s) \
	int a64emu_rmw_ ## s(uint64_t, uint32_t, uint64_t, uint64_t, uint64_t *); \
	int a64emu_rmw_ ## s ## _a(uint64_t, uint32_t, uint64_t, uint64_t, uint64_t *); \
	int a64emu_rmw_ ## s ## _l(uint64_t, uint32_t, uint64_t, uint64_t, uint64_t *); \
	int a64emu_rmw_ ## s ## _al(uint64_t, uint32_t, uint64_t, uint64_t, uint64_t *);
A64EMU_RMW_DECL(b)
A64EMU_RMW_DECL(h)
A64EMU_RMW_DECL(w)
A64EMU_RMW_DECL(x)
int a64emu_casp(uint64_t addr, uint64_t s0, uint64_t s1, uint64_t t0, uint64_t t1, uint64_t *old);
int a64emu_casp_a(uint64_t addr, uint64_t s0, uint64_t s1, uint64_t t0, uint64_t t1, uint64_t *old);
int a64emu_casp_l(uint64_t addr, uint64_t s0, uint64_t s1, uint64_t t0, uint64_t t1, uint64_t *old);
int a64emu_casp_al(uint64_t addr, uint64_t s0, uint64_t s1, uint64_t t0, uint64_t t1, uint64_t *old);
int a64emu_load(uint64_t addr, uint32_t size_log2, uint64_t *out);
int a64emu_load_acq(uint64_t addr, uint32_t size_log2, uint64_t *out);
int a64emu_store(uint64_t addr, uint32_t size_log2, uint64_t val);
int a64emu_store_rel(uint64_t addr, uint32_t size_log2, uint64_t val);

#endif /* LAUREL_A64EMU_H */
