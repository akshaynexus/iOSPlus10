/*
 * Included by tools/laurel-a64emu/test/harness.c with -DLSE0081. Faults on top of the case stream of that file. Same random numbers in both runs.
 *   A bad address: both runs. A read-only page: both runs.
 *   A lazy page (zero fill, or COW: read-only until the first write): only the emulator's run takes the fault; the page was a normal page for the real word,
 *   because the kernel handles a page fault from EL0 and the program does not see it. The emulator must give the same result.
 */
extern volatile uint64_t g_ro_page;
static int g_prot_changed;

static u64
lse0081_read(u64 a, u32 size)
{
	u64 v = 0;
	for (u32 k = 0; k < (1u << size); k++) {
		v |= (u64)((const volatile u8 *)a)[k] << (8 * k);
	}
	return v;
}

static void
lse0081_prepare(struct st *s, const struct plan *p, int native)
{
	u32 w = p->w1, size = w >> 30;
	u32 rn = (w >> 5) & 31, rs = (w >> 16) & 31;
	u64 r = rnd();
	u32 kind = r & 31;
	static const u64 bad[] = {
		(1ULL << 47), (1ULL << 48), 0xfffffff007004000ULL, 1ULL << 55,
	};

	if (kind == 0) {
		if (rn != 31) {
			u32 b = (r >> 8) & 7;
			s->x[rn] = b < 4 ? bad[b] : ((u64)mem | (1ULL << 55) | ((r >> 16) & 0x7fULL) << 56);
		}
		return;
	}
	u64 a = (rn == 31 ? s->sp : s->x[rn]) & 0x00FFFFFFFFFFFFFFULL;
	if (a < (u64)mem || a + 8 > (u64)mem + 4096) {
		return;
	}
	if (kind <= 4) {                /* zero fill or paged out */
		if (!native) {
			g_lazy_addr = (u64)mem;
			sys6(SYS_mprotect, (long)mem, 4096, 0, 0, 0, 0);
			g_prot_changed = 1;
		}
	} else if (kind <= 8) {         /* COW: the first write to the page */
		if (!native) {
			g_lazy_addr = (u64)mem;
			sys6(SYS_mprotect, (long)mem, 4096, 1, 0, 0, 0);
			g_prot_changed = 1;
		}
	} else if (kind <= 10) {        /* read-only in both runs */
		/* a CAS whose compare fails: qemu faults, the emulator gives the old value (the rules show it, doc docs/laurel_sprout/ios16-lse.md): not in the stream */
		if ((w & 0x3FA07C00) == 0x08A07C00) {
			u64 mask = size == 3 ? ~0ULL : (1ULL << (8 << size)) - 1;
			u64 cmp = rs == 31 ? 0 : s->x[rs] & mask;
			if (cmp != lse0081_read(a, size)) {
				return;
			}
		}
		g_ro_page = (u64)mem;
		sys6(SYS_mprotect, (long)mem, 4096, 1, 0, 0, 0);
		g_prot_changed = 1;
	}
}

static void
lse0081_restore(void)
{
	if (g_prot_changed) {
		sys6(SYS_mprotect, (long)mem, 4096, 3, 0, 0, 0);
		g_prot_changed = 0;
	}
	g_lazy_addr = 0;
	g_ro_page = 0;
}
