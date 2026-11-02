/* Included by tools/laurel-a64emu/test/harness.c with -DLSE0081: what no real word can show. */
extern volatile uint64_t g_lse_calls, g_lse_addr, g_vmf_calls, g_vmf_addr, g_far, g_resets, g_ro_page;
extern volatile int g_vmf_prot, g_vmf_force, g_exc;
extern volatile long long g_code0, g_code1;
extern const u64 __start_copyio_vectors[], __stop_copyio_vectors[];
int _sweet_lse_b(u64, u32, u64, u64, u64 *);
int _sweet_lse_h(u64, u32, u64, u64, u64 *);
int _sweet_lse_w(u64, u32, u64, u64, u64 *);
int _sweet_lse_x(u64, u32, u64, u64, u64 *);

#define W_LDADDAL 0xF8E10002u   /* ldaddal x1, x2, [x0] */
#define W_SWPAL   0xF8E18002u
#define W_CASAL   0xC8E1FC02u   /* casal x1, x2, [x0]: compare and old value x1, new value x2 */
#define W_LDAPR   0xF8BFC001u   /* ldapr x1, [x0] */
#define W_STADD   0xF821001Fu   /* stadd x1, [x0] */
#define W_LDADDZR 0xF83F0002u   /* ldadd xzr, x2, [x0] */
#define W_CASPAL  0x4862FC04u
#define KR_INVALID 1
#define KR_PROT 2
#define KR_ABORTED 14
#define EXC_BAD_ACCESS_ 1
#define DA_ALIGN 0x101

static int
in_table(const void *fn)
{
	u64 pc = (u64)fn + 16;  /* in the LL/SC loop */
	for (const u64 *t = copyio_recover_table; t < copyio_recover_table_end; t += 3) {
		if (pc >= t[0] && pc < t[1]) {
			return 1;
		}
	}
	return 0;
}

static int
rules_main(void)
{
	u64 v[32][2];
	static struct a64emu_regs r, before;
	u32 fpsr, fpcr;
	struct a64emu_cpu c = { &r, v, &fpsr, &fpcr, 1ULL << 47, 0, false };
	struct a64emu_out o;
	u64 pnone, pro, prw, pcow, pzero;

	set_handlers();
	mapa(&pnone, 0);
	mapa(&pro, 1);
	mapa(&prw, 3);
	mapa(&pcow, 3);
	mapa(&pzero, 3);
#define RESET0() do { memset(&r, 0x55, sizeof(r)); r.pc = 0x4000; r.pstate = 0; g_exc = 0; g_code0 = g_code1 = 0; g_lse_calls = 0; g_vmf_calls = 0; g_far = 0; g_lazy_fixes = 0; g_vmf_force = -1; } while (0)

	/* bug 1: the table holds the four ranges, and its end is the end of the section */
	ck(in_table((void *)_sweet_lse_b), "_sweet_lse_b in the recovery table");
	ck(in_table((void *)_sweet_lse_h), "_sweet_lse_h in the recovery table");
	ck(in_table((void *)_sweet_lse_w), "_sweet_lse_w in the recovery table");
	ck(in_table((void *)_sweet_lse_x), "_sweet_lse_x in the recovery table");
	ck((u64)copyio_recover_table_end == (u64)__stop_copyio_vectors, "table end is the end of the section");
	ck((u64)copyio_recover_table == (u64)__start_copyio_vectors, "table start is the start of the section");

	/* bug 2: LDUMIN, each size. Old value below the operand: memory keeps it. Above: the operand goes in */
	static const struct { u32 w; u64 lo, hi; } umin[] = {
		{ 0x38E17002, 0x7F, 0x80 }, { 0x78E17002, 0x7FFF, 0x8000 }, { 0xB8E17002, 0x7FFFFFFF, 0x80000000 }, { 0xF8E17002, 0x7FFFFFFFFFFFFFFFULL, 0x8000000000000000ULL },
	};
	for (unsigned k = 0; k < 4; k++) {
		RESET0();
		*(volatile u64 *)prw = umin[k].lo;
		r.x[0] = prw;
		r.x[1] = umin[k].hi;
		ck(a64emu_run(&c, umin[k].w, &o) == A64EMU_OK && r.x[2] == umin[k].lo && *(volatile u64 *)prw == umin[k].lo, "ldumin: old below the operand stays");
		ck(r.pc == 0x4004, "PC after ldumin");
		RESET0();
		*(volatile u64 *)prw = umin[k].hi;
		r.x[0] = prw;
		r.x[1] = umin[k].lo;
		ck(a64emu_run(&c, umin[k].w, &o) == A64EMU_OK && r.x[2] == umin[k].hi && *(volatile u64 *)prw == umin[k].lo, "ldumin: old above the operand goes");
	}

	/* the case that panicked: the first write to a COW page. The load works, the store faults, vm_fault fixes the page, the word finishes */
	RESET0();
	*(volatile u64 *)pcow = 7;
	sys6(SYS_mprotect, (long)pcow, 4096, 1, 0, 0, 0);
	g_lazy_addr = pcow;
	r.x[0] = pcow;
	r.x[1] = 3;
	ck(a64emu_run(&c, W_LDADDAL, &o) == A64EMU_OK, "ldaddal on a COW page: done");
	ck(g_lazy_fixes == 1 && *(volatile u64 *)pcow == 10 && r.x[2] == 7 && r.pc == 0x4004, "ldaddal on a COW page: one fault, value, old value, PC");
	g_lazy_addr = 0;
	/* a page not there yet */
	RESET0();
	sys6(SYS_mprotect, (long)pzero, 4096, 0, 0, 0, 0);
	g_lazy_addr = pzero;
	r.x[0] = pzero;
	r.x[1] = 3;
	ck(a64emu_run(&c, W_LDADDAL, &o) == A64EMU_OK && g_lazy_fixes == 1 && *(volatile u64 *)pzero == 3 && r.x[2] == 0, "ldaddal on a page not there yet");
	g_lazy_addr = 0;

	/* a bad address: EXC_BAD_ACCESS with the real code and address, registers and PC as they were; a word above user memory never reaches an access */
	static const struct { u64 tag; int low; const char *n; } kinds[] = {
		{ 0, 1, "no tag" }, { 0x7BULL << 56, 1, "top byte" }, { 1ULL << 55, 0, "bit 55" },
	};
	static const u32 onbad[] = { W_LDADDAL, W_SWPAL, W_CASAL, W_LDAPR };
	for (unsigned w = 0; w < 4; w++) {
		for (unsigned k = 0; k < 3; k++) {
			RESET0();
			r.x[0] = pnone | kinds[k].tag;
			before = r;
			ck(a64emu_run(&c, onbad[w], &o) == A64EMU_FAULT, "bad address: fault");
			ck(g_exc == EXC_BAD_ACCESS_ && g_code0 == KR_INVALID && (u64)g_code1 == (pnone | kinds[k].tag) && g_far == (pnone | kinds[k].tag), "bad address: exception, code, address");
			ck(memcmp_regs(&r, &before), "bad address: registers and PC as they were");
			ck(g_lse_calls == (u64)kinds[k].low, kinds[k].n);
			if (kinds[k].low) {
				ck(g_lse_addr == pnone, "the access has no tag");
				ck(g_vmf_calls == 1 && g_vmf_addr == pnone && g_vmf_prot == (w == 3 ? 1 : 3), "second vm_fault: address, read or write");
			}
		}
		static const u64 high[] = { 1ULL << 47, 1ULL << 48, 0xfffffff007004000ULL, 0x8000000000000000ULL | 0x1000 };
		for (unsigned k = 0; k < 4; k++) {
			RESET0();
			r.x[0] = high[k];
			before = r;
			u64 want = high[k];
			enum a64emu_result e = a64emu_run(&c, onbad[w], &o);
			/* 0x80...1000: bit 55 clear, top byte ignored: a normal low address, not mapped */
			ck(e == A64EMU_FAULT && (u64)g_code1 == want && memcmp_regs(&r, &before), "high address: fault");
			ck(g_lse_calls == (k == 3 ? 1u : 0u), "high address: no access");
		}
	}
	/* a read-only page: a load works; a word that writes faults, code KERN_PROTECTION_FAILURE, memory as it was */
	RESET0();
	g_ro_page = pro;
	r.x[0] = pro;
	r.x[1] = 1;
	before = r;
	ck(a64emu_run(&c, W_LDADDAL, &o) == A64EMU_FAULT && g_code0 == KR_PROT && memcmp_regs(&r, &before) && *(volatile u64 *)pro == 0, "ldaddal on a read-only page");
	ck(g_vmf_prot == 3, "ldaddal: write access");
	RESET0();
	r.x[0] = pro;
	ck(a64emu_run(&c, W_LDAPR, &o) == A64EMU_OK && r.x[1] == 0 && r.pc == 0x4004, "ldapr on a read-only page");
	RESET0();
	r.x[0] = pro;
	r.x[1] = 0;
	r.x[2] = 5;
	before = r;
	ck(a64emu_run(&c, W_CASAL, &o) == A64EMU_FAULT && g_code0 == KR_PROT && memcmp_regs(&r, &before), "cas on a read-only page, compare matches");
	/* known difference from qemu: compare fails on a read-only page: no write, no fault. 0081 did this and the emulator of the iOS 26 kernel does this */
	RESET0();
	r.x[0] = pro;
	r.x[1] = 9;
	r.x[2] = 5;
	ck(a64emu_run(&c, W_CASAL, &o) == A64EMU_OK && r.x[1] == 0 && r.pc == 0x4004 && *(volatile u64 *)pro == 0, "cas on a read-only page, compare fails: old value, no fault");
	g_ro_page = 0;
	/* the map changed between the two faults, or a signal is pending: back to EL0 on the same word, nothing changed */
	static const int again[] = { 0, KR_ABORTED };
	for (unsigned k = 0; k < 2; k++) {
		RESET0();
		g_vmf_force = again[k];
		r.x[0] = pnone;
		before = r;
		ck(a64emu_run(&c, W_LDADDAL, &o) == A64EMU_OK && g_exc == 0 && memcmp_regs(&r, &before), "second vm_fault gives success or aborted: same word again");
	}
	g_vmf_force = -1;
	/* an unaligned word: EXC_ARM_DA_ALIGN before any access, also on a page that is not there */
	RESET0();
	r.x[0] = prw + 1;
	before = r;
	ck(a64emu_run(&c, W_LDADDAL, &o) == A64EMU_ALIGN && g_code0 == DA_ALIGN && (u64)g_code1 == prw + 1 && g_far == prw + 1 && g_lse_calls == 0 && memcmp_regs(&r, &before), "unaligned: EXC_ARM_DA_ALIGN");
	RESET0();
	r.x[0] = pnone + 2;
	ck(a64emu_run(&c, W_LDAPR, &o) == A64EMU_ALIGN && g_lse_calls == 0, "unaligned on a bad page: alignment first");
	/* top byte: the access works, on the address with no tag */
	RESET0();
	*(volatile u64 *)prw = 9;
	r.x[0] = prw | (0x7BULL << 56);
	r.x[1] = 1;
	ck(a64emu_run(&c, W_LDADDAL, &o) == A64EMU_OK && r.x[2] == 9 && *(volatile u64 *)prw == 10 && g_lse_addr == prw && r.x[0] == (prw | (0x7BULL << 56)), "tagged pointer");
	/* Rt = 31: nothing is written back. Rs = 31: operand 0 */
	RESET0();
	*(volatile u64 *)prw = 20;
	r.x[0] = prw;
	r.x[1] = 2;
	before = r;
	before.pc += 4;
	ck(a64emu_run(&c, W_STADD, &o) == A64EMU_OK && *(volatile u64 *)prw == 22 && memcmp_regs(&r, &before), "stadd: only memory and PC");
	RESET0();
	*(volatile u64 *)prw = 20;
	r.x[0] = prw;
	ck(a64emu_run(&c, W_LDADDZR, &o) == A64EMU_OK && *(volatile u64 *)prw == 20 && r.x[2] == 20, "ldadd xzr");
	/* SP as the base */
	RESET0();
	*(volatile u64 *)prw = 4;
	r.sp = prw;
	r.x[1] = 1;
	ck(a64emu_run(&c, 0xF8E103E2u, &o) == A64EMU_OK && r.x[2] == 4 && *(volatile u64 *)prw == 5, "ldaddal x1, x2, [sp]");
	/* words that stay undefined: CASP (not in 0081), LDAPR with other A, R, o3:opc with no word, CAS with Rt2 not 31 */
	static const u32 unk[] = { W_CASPAL, 0xF83FC001u, 0xF8FFC001u, 0xF87FC001u, 0xF8BEC001u, 0xF8A19002u, 0xC8E1F802u, 0x00201000u };
	for (unsigned k = 0; k < sizeof(unk) / sizeof(unk[0]); k++) {
		RESET0();
		r.x[0] = prw;
		before = r;
		ck(a64emu_run(&c, unk[k], &o) == A64EMU_UNKNOWN && memcmp_regs(&r, &before) && g_lse_calls == 0, "stays undefined");
	}
	wr(1, "rules: checks ");
	out_u((u64)g_checks);
	wr(1, " failures ");
	out_u((u64)g_fail);
	wr(1, " panics ");
	out_u(g_panics);
	wr(1, "\n");
	return g_fail != 0;
}
