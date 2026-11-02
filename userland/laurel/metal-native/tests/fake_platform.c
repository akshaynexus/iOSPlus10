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

const struct nw_ops *nmn_platform_ops(void **ctx, char *why, size_t why_size)
{
	(void)why; (void)why_size;
	the_kernel = fake_kernel_new(getenv("NMN_RD"), 512ull << 20);
	*ctx = the_kernel;
	atexit(report);
	return &fake_kernel_ops;
}
