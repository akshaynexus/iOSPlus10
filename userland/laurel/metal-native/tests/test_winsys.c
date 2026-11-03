/* SPDX-License-Identifier: MIT */
/* Host test of the winsys against the fake kernel: buffers, slices, command streams, submission lists, and the kernel's rules. PASS/FAIL lines, exit 0 only if all pass. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fake_kernel.h"
#include "nw.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __func__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void test_open(void)
{
	char why[128] = "";
	struct fake_kernel *k = fake_kernel_new(NULL, 64 << 20);
	struct nw_device *d = nw_device_open(&fake_kernel_ops, k, why, sizeof(why));
	CHECK(d != NULL, "open: %s", why);
	const struct nw_info *i = nw_device_info(d);
	CHECK(i->chip_id == 0x06010000 && i->gmem_size == 132 * 1024 && i->highest_bank_bit == 14, "info %#x %u %u", i->chip_id, i->gmem_size, i->highest_bank_bit);
	nw_device_close(d);
	fake_kernel_free(k);
}

static void test_slices(void)
{
	char why[128];
	struct fake_kernel *k = fake_kernel_new(NULL, 256 << 20);
	struct nw_device *d = nw_device_open(&fake_kernel_ops, k, why, sizeof(why));
	enum { N = 4000 };
	static struct nw_slice s[N];
	/* many small objects: few kernel buffers */
	for (int i = 0; i < N; i++) {
		CHECK(nw_slice_new(d, 256 + (i % 16) * 64, 64, &s[i]), "slice %d", i);
		CHECK((s[i].iova & 63) == 0, "align %d", i);
		memset(s[i].map, i & 0xff, s[i].size);
	}
	uint64_t st[5];
	nw_memory_stats(d, st);
	CHECK(st[0] <= 2, "%llu kernel buffers for %d small objects", (unsigned long long)st[0], N);
	/* no two slices overlap, each kept its bytes */
	for (int i = 0; i < N; i++) {
		const unsigned char *m = s[i].map;
		CHECK(m[0] == (i & 0xff) && m[s[i].size - 1] == (i & 0xff), "overlap at %d", i);
	}
	/* free every second one, then the rest: gaps must join, so one large slice fits again with no new kernel buffer */
	for (int i = 0; i < N; i += 2)
		nw_slice_free(d, &s[i]);
	for (int i = 1; i < N; i += 2)
		nw_slice_free(d, &s[i]);
	nw_memory_stats(d, st);
	CHECK(st[3] == 0 && st[2] == 0, "slices left %llu, bytes %llu", (unsigned long long)st[3], (unsigned long long)st[2]);
	uint64_t before = st[0];
	struct nw_slice big;
	CHECK(nw_slice_new(d, NW_SLICE_MAX, 4096, &big), "1 MiB slice");
	CHECK((big.iova & 4095) == 0, "4 KiB alignment");
	nw_memory_stats(d, st);
	CHECK(st[0] == before, "the joined gaps took it: %llu kernel buffers, was %llu", (unsigned long long)st[0], (unsigned long long)before);
	nw_slice_free(d, &big);
	/* large: own buffer, and the list takes it back */
	struct nw_slice l1, l2;
	CHECK(nw_slice_new(d, 9 << 20, 4096, &l1), "9 MiB");
	uint64_t iova = l1.iova;
	nw_slice_free(d, &l1);
	CHECK(nw_slice_new(d, 9 << 20, 4096, &l2), "9 MiB again");
	nw_memory_stats(d, st);
	CHECK(l2.iova == iova && st[4] == 1, "no reuse: %#llx %#llx, hits %llu", (unsigned long long)l2.iova, (unsigned long long)iova, (unsigned long long)st[4]);
	nw_slice_free(d, &l2);
	nw_device_close(d);
	fake_kernel_free(k);
}

static void test_submit_names(void)
{
	char why[128];
	struct fake_kernel *k = fake_kernel_new(NULL, 256 << 20);
	struct nw_device *d = nw_device_open(&fake_kernel_ops, k, why, sizeof(why));
	struct nw_cs cs;
	nw_cs_init(&cs, d);
	/* CP_NOP packets across more than one chunk: every IB stays inside its chunk and every chunk is named */
	for (int i = 0; i < 200000; i++) {
		nw_cs_reserve(&cs, 2);
		nw_cs_emit(&cs, nw_pkt7(0x10 /* CP_NOP */, 1));
		nw_cs_emit(&cs, (uint32_t)i);
	}
	nw_cs_end_ib(&cs);
	CHECK(cs.ib_count >= 2 && cs.ib_count == cs.chunk_count, "%u IBs of %u chunks", cs.ib_count, cs.chunk_count);
	struct nw_submit s;
	nw_submit_begin(&s, d);
	nw_submit_stream(&s, &cs);
	struct nw_bo *surface = nw_bo_new(d, 4096, 0);
	/* the same buffer named many times: one name */
	for (int i = 0; i < 1000; i++)
		nw_submit_name(&s, surface);
	uint32_t fence = 0;
	int e = nw_submit_go(&s, &fence);
	CHECK(e == 0 && fence == 1, "submit errno %d fence %u", e, fence);
	const struct fake_stats *st = fake_kernel_stats(k);
	CHECK(st->names == cs.chunk_count + 1, "%llu names for %u chunks + 1", (unsigned long long)st->names, cs.chunk_count);
	CHECK(st->bad_parity == 0 && st->bad_ib == 0 && st->unknown_opcode == 0, "packets: parity %llu ib %llu op %llu", (unsigned long long)st->bad_parity, (unsigned long long)st->bad_ib, (unsigned long long)st->unknown_opcode);
	CHECK(st->dwords == 400000, "%llu dwords", (unsigned long long)st->dwords);
	CHECK(surface->fence == fence, "named buffer has the fence");
	CHECK(nw_fence_wait(d, fence, 1000000) == 0, "wait");
	nw_submit_end(&s);
	/* a second submission of a fresh list, with no stale stamp */
	nw_submit_begin(&s, d);
	nw_submit_name(&s, surface);
	CHECK(s.name_count == 1, "a new submission lists the buffer again");
	nw_submit_end(&s);
	/* more IBs than the kernel takes: refused here, not by the kernel */
	nw_submit_begin(&s, d);
	nw_cs_reset(&cs);
	for (int i = 0; i < NW_SUBMIT_MAX_IBS + 1; i++) {
		nw_cs_reserve(&cs, 2);
		nw_cs_emit(&cs, nw_pkt7(0x10, 1));
		nw_cs_emit(&cs, 0);
		nw_cs_end_ib(&cs);
	}
	nw_submit_stream(&s, &cs);
	CHECK(nw_submit_go(&s, &fence) == EINVAL, "%d IBs must be refused", NW_SUBMIT_MAX_IBS + 1);
	nw_submit_end(&s);
	nw_cs_finish(&cs);
	nw_bo_free(d, surface);
	nw_device_close(d);
	fake_kernel_free(k);
}

static void test_kinds(void)
{
	char why[128];
	/* a pool of 1 MiB: the second buffer goes to scattered pages, below the kernel's kSamePlaceBase */
	struct fake_kernel *k = fake_kernel_new(NULL, 1 << 20);
	struct nw_device *d = nw_device_open(&fake_kernel_ops, k, why, sizeof(why));
	struct nw_bo *a = nw_bo_new(d, 512 * 1024, 0), *b = nw_bo_new(d, 1024 * 1024, 0);
	CHECK(a && a->kind == NW_BO_POOL, "pool");
	CHECK(b && b->kind == NW_BO_SCATTERED, "scattered");
	uint32_t id = fake_kernel_add_surface(k, 720 * 1560 * 4, 720, 1560, 2880, 0x42475241);
	uint32_t offset = 99, row = 0;
	struct nw_bo *s = nw_bo_import_surface(d, id, &offset, &row);
	CHECK(s && s->kind == NW_BO_SURFACE && offset == 0 && row == 2880, "surface");
	/* the CPU address of a surface is its owner's: nw_bo_free must not unmap it (the fake kernel's unmap counts) */
	s->map = (void *)0x1000;
	CHECK(nw_bo_import_surface(d, 77, NULL, NULL) == NULL, "no such surface");
	void *pages = aligned_alloc(4096, 8192);
	struct nw_bo *h = nw_bo_import_host(d, pages, 8192, false);
	CHECK(h && h->kind == NW_BO_HOST && h->map == pages, "host pages");
	nw_bo_free(d, a); nw_bo_free(d, b);
	uint64_t unmaps = fake_kernel_stats(k)->unmaps;
	nw_bo_free(d, s); nw_bo_free(d, h);
	CHECK(fake_kernel_stats(k)->unmaps == unmaps, "a surface or host buffer was unmapped");
	free(pages);
	nw_device_close(d);
	fake_kernel_free(k);
}

/* The stream check. The first case is the stream of the first hang on the phone, word for word (FAR 0x1970460000). */
static int check_one(struct nw_device *d, struct nw_bo *b, const uint32_t *w, uint32_t n, char *why, size_t why_size)
{
	memcpy(b->map, w, n * 4);
	return nw_stream_check(d, b->map, n, b->iova, 1, why, why_size);
}

static void test_stream_check(void)
{
	char why[256];
	struct fake_kernel *k = fake_kernel_new(NULL, 64 << 20);
	struct nw_device *d = nw_device_open(&fake_kernel_ops, k, why, sizeof(why));
	struct nw_bo *b = nw_bo_new(d, 65536, 0), *other = nw_bo_new(d, 65536, 0);
	const uint32_t hi = (uint32_t)(other->iova >> 32), lo = (uint32_t)other->iova;
	const uint32_t ev = nw_pkt7(0x46, 1), ev4 = nw_pkt7(0x46, 4);
	/* PC_CCU_FLUSH_COLOR_TS with no address, then the next event: the CP's address is the next two words */
	const uint32_t hang[] = {ev, 0x1d, ev, 0x19};
	CHECK(!check_one(d, b, hang, 4, why, sizeof(why)) && strstr(why, "0x1970460001") != NULL, "the first hang's stream: %s", why);
	/* each time stamp event */
	static const uint32_t ts[] = {4, 8, 22, 26, 28, 29};
	for (unsigned i = 0; i < 6; i++) {
		const uint32_t w[] = {ev, ts[i], nw_pkt7(0x26, 0), nw_pkt7(0x26, 0)};
		CHECK(!check_one(d, b, w, 4, why, sizeof(why)), "event %u with no address passed", ts[i]);
		const uint32_t good[] = {ev4, ts[i], lo, hi, 0};
		CHECK(check_one(d, b, good, 5, why, sizeof(why)), "event %u with an address: %s", ts[i], why);
		const uint32_t bad[] = {ev4, ts[i], 0x70460001, 0x19, 0};
		CHECK(!check_one(d, b, bad, 5, why, sizeof(why)), "event %u with a wild address passed", ts[i]);
	}
	const uint32_t plain[] = {ev, 0x19, ev, 0x31, nw_pkt7(0x26, 0)};
	CHECK(check_one(d, b, plain, 5, why, sizeof(why)), "events with no time stamp: %s", why);
	/* an address register: inside a buffer, outside, zero, half a pair. 0x8c18 RB_2D_DST, 0xab10 SP_BINDLESS_BASE[0] (low bits are a size) */
	const uint32_t r1[] = {nw_pkt4(0x8c18, 2), lo + 64, hi};
	CHECK(check_one(d, b, r1, 3, why, sizeof(why)), "RB_2D_DST inside: %s", why);
	const uint32_t r2[] = {nw_pkt4(0x8c18, 2), 0x70460000, 0x19};
	CHECK(!check_one(d, b, r2, 3, why, sizeof(why)), "RB_2D_DST outside passed");
	const uint32_t r3[] = {nw_pkt4(0x8c18, 2), 0, 0};
	CHECK(check_one(d, b, r3, 3, why, sizeof(why)), "RB_2D_DST zero: %s", why);
	const uint32_t r4[] = {nw_pkt4(0x8c18, 1), lo};
	CHECK(!check_one(d, b, r4, 2, why, sizeof(why)), "half an address passed");
	const uint32_t r5[] = {nw_pkt4(0xab10, 2), lo | 3, hi};
	CHECK(check_one(d, b, r5, 3, why, sizeof(why)), "bindless base: %s", why);
	const uint32_t r6[] = {nw_pkt4(0x8c17, 4), 0, lo, hi, 0};
	CHECK(check_one(d, b, r6, 5, why, sizeof(why)), "a run over an address register: %s", why);
	const uint32_t r7[] = {nw_pkt4(0x8c17, 4), 0, 0x70460000, 0x19, 0};
	CHECK(!check_one(d, b, r7, 5, why, sizeof(why)), "a run over a wild address register passed");
	/* a word that is no packet, a count past the IB, bad parity, an opcode with no rule */
	const uint32_t p1[] = {0x12345678};
	CHECK(!check_one(d, b, p1, 1, why, sizeof(why)), "no header passed");
	const uint32_t p2[] = {nw_pkt7(0x10, 5), 0};
	CHECK(!check_one(d, b, p2, 2, why, sizeof(why)), "a count past the IB passed");
	const uint32_t p3[] = {nw_pkt7(0x26, 0) ^ (1u << 15)};
	CHECK(!check_one(d, b, p3, 1, why, sizeof(why)), "bad parity passed");
	const uint32_t p4[] = {nw_pkt7(0x7e, 0)};
	CHECK(!check_one(d, b, p4, 1, why, sizeof(why)), "an opcode with no rule passed");
	/* calls: IB1 -> IB2 yes, IB2 -> IB3 no, outside a buffer no */
	uint32_t *o = other->map;
	o[0] = nw_pkt7(0x26, 0);
	const uint32_t c1[] = {nw_pkt7(0x3f, 3), lo, hi, 1};
	CHECK(check_one(d, b, c1, 4, why, sizeof(why)), "IB1 -> IB2: %s", why);
	o[0] = nw_pkt7(0x3f, 3); o[1] = lo + 64; o[2] = hi; o[3] = 1; o[16] = nw_pkt7(0x26, 0);
	const uint32_t c2[] = {nw_pkt7(0x3f, 3), lo, hi, 4};
	CHECK(!check_one(d, b, c2, 4, why, sizeof(why)) && strstr(why, "third level") != NULL, "IB1 -> IB2 -> IB3 passed: %s", why);
	const uint32_t c3[] = {nw_pkt7(0x3f, 3), 0x70460000, 0x19, 1};
	CHECK(!check_one(d, b, c3, 4, why, sizeof(why)), "a call outside passed");
	/* the bad word in an IB2 is found too; a known IB2 is not read again; a forgotten one is */
	o[0] = ev; o[1] = 0x1d; o[2] = ev; o[3] = 0x19;
	const uint32_t c4[] = {nw_pkt7(0x3f, 3), lo, hi, 4};
	CHECK(!check_one(d, b, c4, 4, why, sizeof(why)), "a bad IB2 passed");
	o[0] = nw_pkt7(0x26, 0);
	CHECK(nw_ib2_check(d, o, 1, other->iova, why, sizeof(why)) && nw_ib2_known(d, other->iova, 1), "a good IB2: %s", why);
	nw_ib2_forget(d, other->iova);
	CHECK(!nw_ib2_known(d, other->iova, 1), "a forgotten IB2 stays known");
	/* a freed buffer's address is refused */
	uint64_t gone_iova = other->iova;
	nw_bo_free(d, other);
	const uint32_t f1[] = {nw_pkt4(0x8c18, 2), (uint32_t)gone_iova, (uint32_t)(gone_iova >> 32)};
	CHECK(!check_one(d, b, f1, 3, why, sizeof(why)), "a freed buffer's address passed");
	/* the submit refuses, the kernel sees nothing */
	struct nw_cs cs;
	nw_cs_init(&cs, d);
	nw_cs_reserve(&cs, 4);
	for (int i = 0; i < 4; i++)
		nw_cs_emit(&cs, hang[i]);
	nw_cs_end_ib(&cs);
	struct nw_submit s;
	nw_submit_begin(&s, d);
	nw_submit_stream(&s, &cs);
	uint32_t fence = 0;
	uint64_t before = fake_kernel_stats(k)->submissions;
	CHECK(nw_submit_go(&s, &fence) == EFAULT, "the submit took the first hang's stream");
	CHECK(fake_kernel_stats(k)->submissions == before, "the kernel saw it");
	CHECK(strstr(nw_last_refusal(d), "time stamp") != NULL, "refusal: %s", nw_last_refusal(d));
	nw_submit_end(&s);
	nw_cs_finish(&cs);
	/* append: the other stream's IBs run between this stream's, in order, and its chunks are named */
	struct nw_cs a, c;
	nw_cs_init(&a, d);
	nw_cs_init(&c, d);
	nw_cs_reserve(&a, 1); nw_cs_emit(&a, nw_pkt7(0x26, 0));
	nw_cs_reserve(&c, 1); nw_cs_emit(&c, nw_pkt7(0x12, 0));
	nw_cs_end_ib(&c);
	nw_cs_append_ibs(&a, &c);
	nw_cs_reserve(&a, 1); nw_cs_emit(&a, nw_pkt7(0x13, 0));
	nw_cs_end_ib(&a);
	CHECK(a.ib_count == 3 && a.ibs[1].bo == c.ibs[0].bo && a.ibs[1].iova == c.ibs[0].iova && a.ibs[2].iova == a.ibs[0].iova + 4, "append: %u IBs", a.ib_count);
	nw_submit_begin(&s, d);
	nw_submit_stream(&s, &a);
	before = fake_kernel_stats(k)->ibs;
	CHECK(nw_submit_go(&s, &fence) == 0, "the submit of an appended stream: %s", nw_last_refusal(d));
	CHECK(fake_kernel_stats(k)->ibs == before + 3, "3 IBs at the kernel");
	nw_submit_end(&s);
	nw_cs_finish(&a);
	nw_cs_finish(&c);
	nw_bo_free(d, b);
	nw_device_close(d);
	fake_kernel_free(k);
}

int main(void)
{
	test_open();
	test_slices();
	test_submit_names();
	test_kinds();
	test_stream_check();
	printf(fails ? "winsys: FAIL, %d checks\n" : "winsys: PASS\n", fails);
	return fails != 0;
}
