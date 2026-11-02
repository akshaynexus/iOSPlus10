/*
 * Host test of the iOS 16 EL0 LSE emulation: the kernel's own asm text (asm_frag.inc, out of machine_routines_asm.s, see extract.py) with the macros
 * of that file. The table has the kernel's layout and the kernel's end symbol: a range after the end is not in the table, as in the kernel.
 * The entries here are absolute addresses, not offsets: the static ELF has no such relocation between sections.
 */
#define EXT(x) x
#define LEXT(x) x:
#define EFAULT 14
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

.macro COPYIO_RECOVER_TABLE_SYM sym_name
	.align 3
	.pushsection copyio_vectors, "a"
	.globl \sym_name
\sym_name:
	.popsection
.endm

.macro COPYIO_RECOVER_RANGE end_addr, recovery_addr = copyio_error
	.align	3
	.pushsection copyio_vectors, "a"
	.quad	.Lcre_start_\@
	.quad	\end_addr
	.quad	\recovery_addr
	.popsection
.Lcre_start_\@:
.endm

	COPYIO_RECOVER_TABLE_SYM copyio_recover_table

	.text
	.align 2
	.globl	lse0081_text_start
lse0081_text_start:
	.globl	lse0081_copyio_error
lse0081_copyio_error:
copyio_error:
	mov	x0, #EFAULT
	POP_FRAME
	ARM64_STACK_EPILOG

#include "asm_frag.inc"

	.text
	.globl	lse0081_text_end
lse0081_text_end:

/* the way out of exception_triage(), which does not return in the kernel. x19-x30, sp */
	.globl	lse0081_setjmp
lse0081_setjmp:
	stp	x19, x20, [x0, #0]
	stp	x21, x22, [x0, #16]
	stp	x23, x24, [x0, #32]
	stp	x25, x26, [x0, #48]
	stp	x27, x28, [x0, #64]
	stp	x29, x30, [x0, #80]
	mov	x9, sp
	str	x9, [x0, #96]
	mov	x0, #0
	ret

	.globl	lse0081_longjmp
lse0081_longjmp:
	ldp	x19, x20, [x0, #0]
	ldp	x21, x22, [x0, #16]
	ldp	x23, x24, [x0, #32]
	ldp	x25, x26, [x0, #48]
	ldp	x27, x28, [x0, #64]
	ldp	x29, x30, [x0, #80]
	ldr	x9, [x0, #96]
	mov	sp, x9
	mov	x0, #1
	ret
