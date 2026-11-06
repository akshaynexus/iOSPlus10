/*
 * Host test of DarwinWindowTop (laurel mu 0104, DarwinBootPkg/Driver/WindowTop.h): fake UEFI memory maps as EFI_MEMORY_DESCRIPTOR bytes.
 * HOST ONLY: it says what the walk does with a map, not what the phone's firmware puts above the window.
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "WindowTop.h"

#define MIB 0x100000ULL
#define STRIDE 48ULL    /* EDK2 reports a stride above sizeof(EFI_MEMORY_DESCRIPTOR) (40): the walk must use it */
static unsigned char map[64 * 48];
static unsigned n;

static void
put64(unsigned char *p, unsigned long long v)
{
	for (unsigned i = 0; i < 8; i++) { p[i] = (unsigned char)(v >> (8 * i)); }
}

static void
desc(unsigned type, unsigned long long start, unsigned long long bytes, unsigned long long attr)
{
	unsigned char *d = map + n++ * STRIDE;
	memset(d, 0, STRIDE);
	put64(d, type);
	put64(d + 8, start);
	put64(d + 24, bytes / 0x1000);
	put64(d + 32, attr);
}

static unsigned long long
top(unsigned long long end, unsigned long long max)
{
	return DarwinWindowTop(map, n * STRIDE, STRIDE, end, max);
}

int
main(void)
{
	const unsigned long long W0 = 0xC1004000ULL, WS = 3904 * MIB, WE = W0 + WS, BANK = 0x1C0000000ULL;

	/* the Mi A3 map as mu 0101 makes it: the window, then UEFI's allocations top-down to the bank end, in map order (not sorted) */
	n = 0;
	desc(2, W0, WS, 0);                                     /* the window itself: EfiLoaderData (AllocatePages) */
	desc(4, BANK - 40 * MIB, 40 * MIB, 0);                  /* BsData at the top */
	desc(7, WE, 100 * MIB, 0);                              /* free right above the window */
	desc(3, BANK - 60 * MIB, 20 * MIB, 0);                  /* BsCode */
	desc(1, WE + 100 * MIB, BANK - 60 * MIB - (WE + 100 * MIB), 0);  /* LoaderCode: DarwinBoot's own image */
	desc(7, 0x62100000ULL, 60 * MIB, 0);                    /* the DXE heap, bank A: not contiguous */
	unsigned long long t = top(WE, ~0ULL);
	printf("darwinboot-top-test (host only): Mi A3 map: +%llu MiB above the window (0x%llx of 0x%llx)\n", t / MIB, t, BANK - WE);
	assert(t == ((BANK - WE) & ~(2 * MIB - 1)));            /* 174 MiB: the 2 MiB multiple of 0xAFFC000 */
	assert(WE + t <= BANK);
	assert(((WS + t) & (2 * MIB - 1)) == 0);                /* the sum stays a 2 MiB multiple */

	/* a runtime-services page in the middle stops the run before it */
	n = 0;
	desc(7, WE, 100 * MIB, 0);
	desc(6, WE + 100 * MIB, 4 * MIB, 0);                    /* EfiRuntimeServicesData */
	desc(7, WE + 104 * MIB, 50 * MIB, 0);
	assert(top(WE, ~0ULL) == 100 * MIB);
	/* ... and so does EFI_MEMORY_RUNTIME on a free type, reserved (0), ACPI (9, 10), MMIO (11), persistent (14) */
	n = 0; desc(7, WE, 100 * MIB, 1ULL << 63); assert(top(WE, ~0ULL) == 0);
	n = 0; desc(0, WE, 100 * MIB, 0); assert(top(WE, ~0ULL) == 0);
	n = 0; desc(9, WE, 100 * MIB, 0); assert(top(WE, ~0ULL) == 0);
	n = 0; desc(11, WE, 100 * MIB, 0); assert(top(WE, ~0ULL) == 0);
	n = 0; desc(14, WE, 100 * MIB, 0); assert(top(WE, ~0ULL) == 0);
	/* a gap stops it; a descriptor that starts before the end does not count */
	n = 0; desc(7, WE + 0x1000, 100 * MIB, 0); assert(top(WE, ~0ULL) == 0);
	n = 0; desc(7, WE - 0x1000, 100 * MIB, 0); assert(top(WE, ~0ULL) == 0);
	/* the cap: DARWINBOOT_MAX_WINDOW - window, a 2 MiB multiple */
	n = 0; desc(7, WE, 100 * MIB, 0);
	assert(top(WE, 10 * MIB) == 10 * MIB);
	assert(top(WE, 10 * MIB + 0x1000) == 10 * MIB);
	assert(top(WE, 0) == 0);
	/* 2 MiB rounding of the run */
	n = 0; desc(7, WE, 3 * MIB + 0x1000, 0); assert(top(WE, ~0ULL) == 2 * MIB);
	n = 0; desc(7, WE, 0x1000, 0); assert(top(WE, ~0ULL) == 0);
	/* an end that is not a page: nothing; an empty or odd map: nothing; a huge page count: skipped */
	n = 0; desc(7, WE + 1, 100 * MIB, 0); assert(top(WE + 1, ~0ULL) == 0);
	assert(DarwinWindowTop(map, 0, STRIDE, WE, ~0ULL) == 0);
	assert(DarwinWindowTop(map, STRIDE, 8, WE, ~0ULL) == 0);
	assert(DarwinWindowTop(0, STRIDE, STRIDE, WE, ~0ULL) == 0);
	n = 0; memset(map, 0, STRIDE); put64(map, 7); put64(map + 8, WE); put64(map + 24, ~0ULL); n = 1; assert(top(WE, ~0ULL) == 0);
	/* two descriptors that both start at the end: the first free one wins (EDK2 never reports two; the walk still ends) */
	n = 0; desc(7, WE, 2 * MIB, 0); desc(7, WE, 2 * MIB, 0); assert(top(WE, ~0ULL) == 2 * MIB);
	printf("darwinboot-top-test: all checks passed\n");
	return 0;
}
