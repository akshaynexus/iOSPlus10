/*
 * The host test of laurel_a64emu: the same asm as the kernel, plus the code that runs one case. See scripts/laurel/test-a64emu.sh.
 */
#define LEXT(x) x:
#define EXT(x) x
.macro PUSH_FRAME
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
.endm
.macro POP_FRAME
	ldp	x29, x30, [sp], #16
.endm
.macro ARM64_STACK_PROLOG
.endm
.macro ARM64_STACK_EPILOG
	ret
.endm
/* the fault path of the test: harness.c walks this table, as the kernel walks copyio_recover_table */
.macro A64EMU_RECOVER_RANGE end, rec
	.pushsection a64emu_recover, "a"
	.quad	.Lcre\@, \end, \rec
	.popsection
.Lcre\@:
.endm
#define A64EMU_ERR_RETRY 35
#include "laurel_a64emu_asm.h"


	.text
	.align	2
/* struct st: x[31] @0, sp @248, nzcv @256, v[32] @264 (16 each), fpsr @776, fpcr @784 */
	.globl	run_case
run_case:
	adrp	x9, host_save
	add	x9, x9, :lo12:host_save
	stp	x19, x20, [x9, #0]
	stp	x21, x22, [x9, #16]
	stp	x23, x24, [x9, #32]
	stp	x25, x26, [x9, #48]
	stp	x27, x28, [x9, #64]
	stp	x29, x30, [x9, #80]
	mov	x10, sp
	str	x10, [x9, #96]
	str	x0, [x9, #104]
	ldr	x10, [x0, #256]
	msr	nzcv, x10
	ldr	x10, [x0, #776]
	msr	fpsr, x10
	ldr	x10, [x0, #784]
	msr	fpcr, x10
	add	x9, x0, #264
	ldp	q0, q1, [x9, #0]
	ldp	q2, q3, [x9, #32]
	ldp	q4, q5, [x9, #64]
	ldp	q6, q7, [x9, #96]
	ldp	q8, q9, [x9, #128]
	ldp	q10, q11, [x9, #160]
	ldp	q12, q13, [x9, #192]
	ldp	q14, q15, [x9, #224]
	ldp	q16, q17, [x9, #256]
	ldp	q18, q19, [x9, #288]
	ldp	q20, q21, [x9, #320]
	ldp	q22, q23, [x9, #352]
	ldp	q24, q25, [x9, #384]
	ldp	q26, q27, [x9, #416]
	ldp	q28, q29, [x9, #448]
	ldp	q30, q31, [x9, #480]
	ldr	x10, [x0, #248]
	mov	sp, x10
	ldp	x2, x3, [x0, #16]
	ldp	x4, x5, [x0, #32]
	ldp	x6, x7, [x0, #48]
	ldp	x8, x9, [x0, #64]
	ldp	x10, x11, [x0, #80]
	ldp	x12, x13, [x0, #96]
	ldp	x14, x15, [x0, #112]
	ldp	x16, x17, [x0, #128]
	ldp	x18, x19, [x0, #144]
	ldp	x20, x21, [x0, #160]
	ldp	x22, x23, [x0, #176]
	ldp	x24, x25, [x0, #192]
	ldp	x26, x27, [x0, #208]
	ldp	x28, x29, [x0, #224]
	ldr	x30, [x0, #240]
	ldp	x0, x1, [x0, #0]
	b	code_buf

	.globl	case_exit
case_exit:
	msr	tpidr_el0, x0
	adrp	x0, host_save
	add	x0, x0, :lo12:host_save
	ldr	x0, [x0, #104]
	stp	x2, x3, [x0, #16]
	stp	x4, x5, [x0, #32]
	stp	x6, x7, [x0, #48]
	stp	x8, x9, [x0, #64]
	stp	x10, x11, [x0, #80]
	stp	x12, x13, [x0, #96]
	stp	x14, x15, [x0, #112]
	stp	x16, x17, [x0, #128]
	stp	x18, x19, [x0, #144]
	stp	x20, x21, [x0, #160]
	stp	x22, x23, [x0, #176]
	stp	x24, x25, [x0, #192]
	stp	x26, x27, [x0, #208]
	stp	x28, x29, [x0, #224]
	str	x30, [x0, #240]
	str	x1, [x0, #8]
	mrs	x1, tpidr_el0
	str	x1, [x0, #0]
	mov	x1, sp
	str	x1, [x0, #248]
	mrs	x1, nzcv
	str	x1, [x0, #256]
	mrs	x1, fpsr
	str	x1, [x0, #776]
	add	x9, x0, #264
	stp	q0, q1, [x9, #0]
	stp	q2, q3, [x9, #32]
	stp	q4, q5, [x9, #64]
	stp	q6, q7, [x9, #96]
	stp	q8, q9, [x9, #128]
	stp	q10, q11, [x9, #160]
	stp	q12, q13, [x9, #192]
	stp	q14, q15, [x9, #224]
	stp	q16, q17, [x9, #256]
	stp	q18, q19, [x9, #288]
	stp	q20, q21, [x9, #320]
	stp	q22, q23, [x9, #352]
	stp	q24, q25, [x9, #384]
	stp	q26, q27, [x9, #416]
	stp	q28, q29, [x9, #448]
	stp	q30, q31, [x9, #480]
	adrp	x9, host_save
	add	x9, x9, :lo12:host_save
	msr	fpcr, xzr
	ldp	x19, x20, [x9, #0]
	ldp	x21, x22, [x9, #16]
	ldp	x23, x24, [x9, #32]
	ldp	x25, x26, [x9, #48]
	ldp	x27, x28, [x9, #64]
	ldp	x29, x30, [x9, #80]
	ldr	x10, [x9, #96]
	mov	sp, x10
	ret

/* five words, written per case: [0] pre-sign or NOP, [1] the word, [2] a second word or NOP, [3] b case_exit, [4] the landing point: b case_exit */
	.section .code_rwx, "awx"
	.align	12
	.globl	code_buf
code_buf:
	.space	4096
	.previous

	.bss
	.align	4
host_save:
	.space	128
	.previous

/* syscall(nr, a, b, c, d, e, f) */
	.text
	.globl	sys6
sys6:
	mov	x8, x0
	mov	x0, x1
	mov	x1, x2
	mov	x2, x3
	mov	x3, x4
	mov	x4, x5
	mov	x5, x6
	svc	#0
	ret

	.globl	sigret_tramp
sigret_tramp:
	mov	x8, #139
	svc	#0

/* a new thread: clone with a stack; the child calls fn(arg) and exits */
	.globl	thread_start
thread_start:   /* thread_start(flags, stack, fn, arg, tidptr) */
	mov	x9, x2
	mov	x10, x3
	mov	x2, xzr         /* parent_tid */
	mov	x3, xzr         /* tls */
	/* x4 = child_tid */
	mov	x8, #220        /* clone */
	svc	#0
	cbnz	x0, 1f
	mov	x0, x10
	blr	x9
	mov	x0, #0
	mov	x8, #93         /* exit */
	svc	#0
1:	ret

/* user-side LL/SC, on another thread: what the emulated words must be atomic against */
	.globl	llsc_add
llsc_add:
1:	ldaxr	x2, [x0]
	add	x2, x2, x1
	stlxr	w3, x2, [x0]
	cbnz	w3, 1b
	ret

	.globl	llsc_pair
llsc_pair:      /* both words of the pair get +x1: a torn read shows as a difference */
1:	ldaxp	x2, x3, [x0]
	add	x2, x2, x1
	add	x3, x3, x1
	stlxp	w4, x2, x3, [x0]
	cbnz	w4, 1b
	ret

/* the words that trap in the threads */
	.globl	lse_ldaddal
lse_ldaddal:
	.long	0xF8E10002      /* ldaddal x1, x2, [x0] */
	ret
	.globl	lse_casal
lse_casal:      /* casal x1, x2, [x0], x0 = addr: returns the old value in x0 */
	.long	0xC8E1FC02
	mov	x0, x1
	ret
	.globl	lse_swpal
lse_swpal:      /* swpal x1, x2, [x0] : returns old */
	.long	0xF8E18002
	mov	x0, x2
	ret
	.globl	lse_casp
lse_casp:       /* caspal x2, x3, x4, x5, [x0] : in: x1 -> uint64 s[2], t[2] ; out: s[] = old */
	mov	x9, x1
	ldp	x2, x3, [x9]
	ldp	x4, x5, [x9, #16]
	.long	0x4862FC04
	stp	x2, x3, [x9]
	ret
