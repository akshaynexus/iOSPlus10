/* SPDX-License-Identifier: MIT */
/* A host test's kernel for the bridge: the fake RedwoodGPU; NMN_RD=FILE writes what it gets for cffdump. Only linked in host tests. */
#include <stdio.h>
#include <stdlib.h>
#include "fake_kernel.h"
#include "nw.h"
static struct fake_kernel *the_kernel;

/* one line for the test: what the kernel got, and whether every packet was well formed */
static void report(void)
{
	const struct fake_stats *s = fake_kernel_stats(the_kernel);
	printf("kernel: %llu submissions, %llu IBs, %llu names, %llu dwords, %llu GEM_NEW; bad parity %llu, bad IB %llu, unknown opcode %llu\n", (unsigned long long)s->submissions, (unsigned long long)s->ibs, (unsigned long long)s->names, (unsigned long long)s->dwords, (unsigned long long)s->gem_new, (unsigned long long)s->bad_parity, (unsigned long long)s->bad_ib, (unsigned long long)s->unknown_opcode);
}

/* tests/scene.c: a surface of the fake kernel */
uint32_t scene_make_surface(uint32_t width, uint32_t height, void **base, uint64_t *bytes, uint32_t *row)
{
	*row = (width * 4 + 63) & ~63u;
	/* whole pages, as the kernel's IOSurface: a 32 x 32 surface is one page */
	*bytes = ((uint64_t)*row * height + 4095) & ~4095ull;
	const uint32_t id = fake_kernel_add_surface(the_kernel, *bytes, width, height, *row, 0x42475241);
	*base = fake_kernel_surface_memory(the_kernel, id);
	return id;
}

const struct nw_ops *nmn_platform_ops(void **ctx, char *why, size_t why_size)
{
	(void)why; (void)why_size;
	the_kernel = fake_kernel_new(getenv("NMN_RD"), 512ull << 20);
	*ctx = the_kernel;
	atexit(report);
	return &fake_kernel_ops;
}
