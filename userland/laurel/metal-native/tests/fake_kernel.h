/* SPDX-License-Identifier: MIT */
/* A fake RedwoodGPU for host tests: the kernel's rules of submission (iokit/Kernel/arm/RedwoodGPU.cpp) in one process, with no GPU. It walks every packet it gets and writes a .rd file for Mesa's cffdump. */
#ifndef FAKE_KERNEL_H
#define FAKE_KERNEL_H
#include "nw.h"
struct fake_stats {
	uint64_t submissions, ibs, names, dwords, bad_parity, bad_ib, unknown_opcode, gem_new, gem_close, surfaces, unmaps;
};
struct fake_kernel;
struct fake_kernel *fake_kernel_new(const char *rd_path /* NULL: none */, uint64_t pool_bytes);
void fake_kernel_free(struct fake_kernel *);
extern const struct nw_ops fake_kernel_ops;
const struct fake_stats *fake_kernel_stats(const struct fake_kernel *);
/* a surface the kernel can import: returns its id */
uint32_t fake_kernel_add_surface(struct fake_kernel *, uint64_t size, uint32_t width, uint32_t height, uint32_t row_bytes, uint32_t fourcc);
#endif
