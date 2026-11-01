/*
 * laurel_a64emu_asm.h: LL/SC and single-copy load/store on a user address, fault-safe. Included by an assembler file:
 *   kernel: osfmk/arm64/machine_routines_asm.s, before copyio_recover_table_end (a range after that symbol is not in the table
 *           that find_copyio_recovery_entry() walks: a fault there is a panic).
 *   test:   tools/laurel-a64emu/test/harness_asm.S
 * The includer defines A64S(name) (the symbol of a C name), PUSH_FRAME, POP_FRAME, ARM64_STACK_PROLOG, ARM64_STACK_EPILOG and the macro
 * A64EMU_RECOVER_RANGE end, recovery.
 *
 * Between LDXR and STXR there is no memory access and no call: the code is a short loop, as the architecture wants for forward
 * progress. No lock. An interrupt, a migration or a fault clears the monitor (ERET): the store-exclusive fails and the loop reads again.
 * The recovery point gets x0 = EFAULT from the fault path. The loop stops after A64EMU_SPINS failed stores (a memory type with no
 * exclusive monitor would loop for ever): the caller returns to EL0 at the same PC, so the thread can take signals and be preempted.
 *
 * Ordering: A = LDAXR, L = STLXR. A and L together: also DMB ISH after the store, because an LSE word with A and L orders every earlier
 * access before every later access (ARM ARM, Barrier-ordered-before), and LDAXR + STLXR alone do not order a later plain load.
 */
#define A64EMU_SPINS 4096

.macro A64EMU_RMW name, ldx, stx, r, sxa, sxb, post
	.text
	.align	2
	.globl	\name
\name:
	ARM64_STACK_PROLOG
	PUSH_FRAME
	mov	w14, #A64EMU_SPINS
	A64EMU_RECOVER_RANGE 9f, 9f
1:	\ldx	\r\()10, [x0]
	cmp	w1, #9
	b.ne	20f
	cmp	\r\()10, \r\()3
	b.ne	7f
	mov	\r\()11, \r\()2
	b	5f
20:	cmp	w1, #8
	b.ne	21f
	mov	\r\()11, \r\()2
	b	5f
21:	cmp	w1, #0
	b.ne	22f
	add	\r\()11, \r\()10, \r\()2
	b	5f
22:	cmp	w1, #1
	b.ne	23f
	bic	\r\()11, \r\()10, \r\()2
	b	5f
23:	cmp	w1, #2
	b.ne	24f
	eor	\r\()11, \r\()10, \r\()2
	b	5f
24:	cmp	w1, #3
	b.ne	25f
	orr	\r\()11, \r\()10, \r\()2
	b	5f
25:	\sxa
	\sxb
	cmp	w1, #4
	b.ne	26f
	cmp	\r\()12, \r\()13
	csel	\r\()11, \r\()10, \r\()2, gt
	b	5f
26:	cmp	w1, #5
	b.ne	27f
	cmp	\r\()12, \r\()13
	csel	\r\()11, \r\()10, \r\()2, lt
	b	5f
27:	cmp	\r\()10, \r\()2
	csel	\r\()11, \r\()10, \r\()2, hi
	cmp	w1, #6
	b.eq	5f
	cmp	\r\()10, \r\()2
	csel	\r\()11, \r\()10, \r\()2, lo
5:	\stx	w9, \r\()11, [x0]
	cbz	w9, 8f
	subs	w14, w14, #1
	b.ne	1b
	mov	x0, #A64EMU_ERR_RETRY
	b	9f
7:	clrex
8:	\post
	str	x10, [x4]
	mov	x0, #0
9:
	POP_FRAME
	ARM64_STACK_EPILOG
.endmacro

.macro A64EMU_RMW4 s, ldx, ldax, stx, stlx, r, sxa, sxb
	A64EMU_RMW A64S(a64emu_rmw_\s),    \ldx,  \stx,  \r, "\sxa", "\sxb", "nop"
	A64EMU_RMW A64S(a64emu_rmw_\s\()_a),  \ldax, \stx,  \r, "\sxa", "\sxb", "nop"
	A64EMU_RMW A64S(a64emu_rmw_\s\()_l),  \ldx,  \stlx, \r, "\sxa", "\sxb", "nop"
	A64EMU_RMW A64S(a64emu_rmw_\s\()_al), \ldax, \stlx, \r, "\sxa", "\sxb", "dmb ish"
.endm

	A64EMU_RMW4 b, ldxrb, ldaxrb, stxrb, stlxrb, w, "sxtb w12, w10", "sxtb w13, w2"
	A64EMU_RMW4 h, ldxrh, ldaxrh, stxrh, stlxrh, w, "sxth w12, w10", "sxth w13, w2"
	A64EMU_RMW4 w, ldxr,  ldaxr,  stxr,  stlxr,  w, "mov w12, w10",  "mov w13, w2"
	A64EMU_RMW4 x, ldxr,  ldaxr,  stxr,  stlxr,  x, "mov x12, x10",  "mov x13, x2"

/*
 * int a64emu_casp*(addr, s0, s1, t0, t1, uint64_t old[2]): CASP on two doublewords. The pair is single-copy atomic only together with a
 * store, so a failed compare writes the old pair back. A read-only page faults here, also on a failed compare; the architecture allows it.
 */
.macro A64EMU_CASP name, ldxp, stxp, post
	.text
	.align	2
	.globl	\name
\name:
	ARM64_STACK_PROLOG
	PUSH_FRAME
	mov	w14, #A64EMU_SPINS
	A64EMU_RECOVER_RANGE 9f, 9f
1:	\ldxp	x10, x11, [x0]
	cmp	x10, x1
	b.ne	6f
	cmp	x11, x2
	b.ne	6f
	\stxp	w9, x3, x4, [x0]
	b	5f
6:	\stxp	w9, x10, x11, [x0]
5:	cbz	w9, 8f
	subs	w14, w14, #1
	b.ne	1b
	mov	x0, #A64EMU_ERR_RETRY
	b	9f
8:	\post
	stp	x10, x11, [x5]
	mov	x0, #0
9:
	POP_FRAME
	ARM64_STACK_EPILOG
.endmacro

	A64EMU_CASP A64S(a64emu_casp), ldxp,  stxp,  "nop"
	A64EMU_CASP A64S(a64emu_casp_a), ldaxp, stxp,  "nop"
	A64EMU_CASP A64S(a64emu_casp_l), ldxp,  stlxp, "nop"
	A64EMU_CASP A64S(a64emu_casp_al), ldaxp, stlxp, "dmb ish"

/* int a64emu_load*(addr, size_log2, uint64_t *out), int a64emu_store*(addr, size_log2, val): one access, single-copy atomic when aligned */
.macro A64EMU_LOAD name, b, h, w, x
	.text
	.align	2
	.globl	\name
\name:
	ARM64_STACK_PROLOG
	PUSH_FRAME
	A64EMU_RECOVER_RANGE 9f, 9f
	cmp	w1, #1
	b.lo	1f
	b.eq	2f
	cmp	w1, #3
	b.eq	4f
	\w	w10, [x0]
	b	8f
1:	\b	w10, [x0]
	b	8f
2:	\h	w10, [x0]
	b	8f
4:	\x	x10, [x0]
8:	str	x10, [x2]
	mov	x0, #0
9:
	POP_FRAME
	ARM64_STACK_EPILOG
.endmacro

.macro A64EMU_STORE name, b, h, w, x
	.text
	.align	2
	.globl	\name
\name:
	ARM64_STACK_PROLOG
	PUSH_FRAME
	A64EMU_RECOVER_RANGE 9f, 9f
	cmp	w1, #1
	b.lo	1f
	b.eq	2f
	cmp	w1, #3
	b.eq	4f
	\w	w2, [x0]
	b	8f
1:	\b	w2, [x0]
	b	8f
2:	\h	w2, [x0]
	b	8f
4:	\x	x2, [x0]
8:	mov	x0, #0
9:
	POP_FRAME
	ARM64_STACK_EPILOG
.endmacro

	A64EMU_LOAD  A64S(a64emu_load), ldrb, ldrh, ldr,  ldr
	A64EMU_LOAD  A64S(a64emu_load_acq), ldarb, ldarh, ldar, ldar
	A64EMU_STORE A64S(a64emu_store), strb, strh, str,  str
	A64EMU_STORE A64S(a64emu_store_rel), stlrb, stlrh, stlr, stlr
