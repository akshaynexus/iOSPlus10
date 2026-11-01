/*
 * Host test of the 16 KiB slide pages: the kernel's own vm_shared_region_slide_page_v5 (extracted from the kernel tree by scripts/laurel/test-slide.sh) on every
 * slide page of a real cache, with this file's own reading of the chain as the check. slide-test FILE...
 * For each page: the slid copy must differ from the original only at the chain's locations, each with the expected value; an auth entry (original cache) must become
 * a plain pointer, not stay raw. It also counts what a 4 KiB-at-a-time slide would miss. The VM part of the pager (faults, UPL) is not in this test.
 */
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int kern_return_t;
typedef unsigned long vm_offset_t;
typedef uint64_t mach_vm_offset_t;
#define KERN_SUCCESS 0
#define KERN_FAILURE 5
#define __unused __attribute__((unused))
#define DYLD_CACHE_SLIDE_V5_PAGE_ATTR_NO_REBASE 0xFFFF
struct vm_shared_region_slide_info_entry_v5 {
	uint32_t version, page_size, page_starts_count;
	uint64_t value_add;
	uint16_t page_starts[];
};
typedef struct vm_shared_region_slide_info_entry_v5 *vm_shared_region_slide_info_entry_v5_t;
struct si_entry { struct vm_shared_region_slide_info_entry_v5 v5; };
struct vm_shared_region_slide_info {
	uint32_t si_slide;
	int si_ptrauth;
	struct si_entry *si_slide_info_entry;
};
typedef struct vm_shared_region_slide_info *vm_shared_region_slide_info_t;
#include "slide-v5-from-kernel.inc"

#define SLIDE 0x1234000u
int main(int argc, char **argv)
{
	uint64_t pages = 0, rebases = 0, auth = 0, past4k = 0, straddle = 0, bad = 0, mappings = 0, norebase = 0;
	for (int a = 1; a < argc; a++) {
		int fd = open(argv[a], O_RDONLY);
		struct stat st;
		if (fd < 0 || fstat(fd, &st)) {
			perror(argv[a]);
			return 2;
		}
		const uint8_t *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
		uint32_t off = *(const uint32_t *)(m + 0x138), cnt = *(const uint32_t *)(m + 0x13c);
		for (uint32_t i = 0; i < cnt; i++) {
			const uint64_t *e = (const uint64_t *)(m + off + i * 56);
			uint64_t addr = e[0], size = e[1], foff = e[2], sioff = e[3], sisize = e[4];
			if (!sisize) {
				continue;
			}
			struct si_entry *se = (struct si_entry *)(void *)(m + sioff);
			if (se->v5.version != 5 || se->v5.page_size != 16384) {
				printf("%s: slide info version %u page %u\n", argv[a], se->v5.version, se->v5.page_size);
				bad++;
				continue;
			}
			mappings++;
			if (se->v5.page_starts_count * 16384ull < size - 16383) {
				printf("%s: %u slide pages for %llu bytes\n", argv[a], se->v5.page_starts_count, (unsigned long long)size);
				bad++;
			}
			struct vm_shared_region_slide_info si = { SLIDE, 0, se };
			for (uint32_t p = 0; p < se->v5.page_starts_count; p++) {
				uint8_t buf[16384];
				const uint8_t *src = m + foff + p * 16384ull;
				memcpy(buf, src, sizeof(buf));
				if (se->v5.page_starts[p] == DYLD_CACHE_SLIDE_V5_PAGE_ATTR_NO_REBASE) {
					norebase++;
				}
				if (vm_shared_region_slide_page_v5(&si, (vm_offset_t)buf, addr + p * 16384ull + SLIDE, p, 0) != KERN_SUCCESS) {
					bad++;
					continue;
				}
				pages++;
				uint8_t want[16384];
				memcpy(want, src, sizeof(want));
				if (se->v5.page_starts[p] != DYLD_CACHE_SLIDE_V5_PAGE_ATTR_NO_REBASE) {
					uint32_t o = se->v5.page_starts[p];
					for (;;) {
						uint64_t v;
						if (o + 8 > 16384) {
							printf("%s: page %u: chain leaves the slide page at %u\n", argv[a], p, o);
							bad++;
							break;
						}
						memcpy(&v, src + o, 8);
						uint64_t delta = ((v >> 52) & 0x7ff) * 8;
						uint64_t t = (v & 0x3FFFFFFFFULL) + se->v5.value_add + SLIDE;
						if (v >> 63) {
							auth++;
						} else {
							t += (v << 22) & 0xFF00000000000000ULL;
						}
						memcpy(want + o, &t, 8);
						rebases++;
						if (o >= 4096) {
							past4k++;
						}
						if ((o & 4095) > 4088) {
							straddle++;
						}
						if (!delta) {
							break;
						}
						o += (uint32_t)delta;
					}
				}
				if (memcmp(want, buf, sizeof(buf))) {
					bad++;
					if (bad < 10) {
						printf("%s: page %u: the kernel's result differs\n", argv[a], p);
					}
				}
			}
		}
		munmap((void *)m, (size_t)st.st_size);
		close(fd);
	}
	printf("slide test: %llu mappings, %llu slide pages (%llu with no rebase), %llu rebases, %llu auth entries made plain, %llu rebases past the first 4 KiB of their page, %llu across a 4 KiB boundary; %llu differences\n",
	    (unsigned long long)mappings, (unsigned long long)pages, (unsigned long long)norebase, (unsigned long long)rebases, (unsigned long long)auth, (unsigned long long)past4k,
	    (unsigned long long)straddle, (unsigned long long)bad);
	return bad != 0;
}
