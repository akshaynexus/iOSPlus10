/*
 * Host test of the window self-check (osfmk/arm64/laurel_ram.c from patches 2100 + 2974): the map of 2974 and each fallback.
 * Run: scripts/laurel/ram-map-test.sh. Not the phone: no start.s, no arm_vm_init, no pmap.
 */
#include "laurel_ram_stubs.h"
#include "laurel_ram.c"

struct vm_page vm_pages[1];
unsigned int vm_pages_count;
int vm_himemory_mode = 1;

static const uint64_t banks[4] = { 0x80000000, 0x40000000, 0xC0000000, 0x100000000 };
static uint64_t reserved[4];
static uint32_t arg_grow = 1, arg_ram = 1;
static bool have_banks;
static int fails;

int SecureDTLookupEntry(void *parent, const char *path, DTEntry *out) { (void)parent; (void)path; *out = banks; return kSuccess; }
int
SecureDTGetProperty(DTEntry e, const char *name, void const **prop, unsigned int *len)
{
	(void)e;
	if (strcmp(name, "laurel-ram-banks") == 0 && have_banks) { *prop = banks; *len = sizeof(banks); return kSuccess; }
	if (strcmp(name, "laurel-ram-reserved") == 0) { *prop = reserved; *len = sizeof(reserved); return kSuccess; }
	return 1;
}
bool
PE_parse_boot_argn(const char *name, void *value, int size)
{
	(void)size;
	if (strcmp(name, "laurelramgrow") == 0) { *(uint32_t *)value = arg_grow; return true; }
	if (strcmp(name, "laurelram") == 0) { *(uint32_t *)value = arg_ram; return true; }
	return false;
}

/* limit is what arm_vm_init applies: 0 means the whole window */
static void
check(const char *what, uint64_t base, uint64_t size, uint64_t want_managed, const char *want_line)
{
	boot_args a = { base, size };
	uint64_t limit = laurel_ram_limit(&a, 0), managed = (limit != 0 && limit < size) ? limit : size;
	bool ok = managed == want_managed && strstr(laurel_ram_summary(), want_line) != NULL;

	printf("%-44s %5llu MiB  %s  %s\n", what, (unsigned long long)(managed >> 20), ok ? "ok" : "BAD", laurel_ram_summary());
	fails += !ok;
}

int
main(void)
{
	const uint64_t M = 1ull << 20;

	have_banks = true;
	reserved[0] = 0x80000000; reserved[1] = 0x40000000; reserved[2] = 0xC0000000; reserved[3] = 0x01000000;
	check("the map of 2974", 0xC1004000, 3904 * M, 3904 * M, "LAUREL RAM: on: 3904 MiB at 0xc1004000..0x1b5004000 (banks 0x80000000..0x1c0000000; 1007 MiB below 4 GiB, used last)");
	check("UEFI took more: DarwinBoot gave 3700 MiB", 0xC1004000, 3700 * M, 3700 * M, "LAUREL RAM: on: 3700 MiB");
	check("window past the banks: size of before", 0xC1004000, 4096 * M, 3264 * M, "window end 0x1c1004000 is past the banks: 3264 MiB");
	arg_grow = 0;
	check("laurelramgrow=0", 0xC1004000, 3904 * M, 3264 * M, "kill switch laurelramgrow=0: 3264 MiB");
	arg_grow = 1;
	check("an FD of before 2974, new ADT", 0xE1004000, 3392 * M, 3392 * M, "LAUREL RAM: on: 3392 MiB at 0xe1004000");
	check("the window of before, new ADT", 0xE1004000, 3264 * M, 3264 * M, "LAUREL RAM: on: 3264 MiB at 0xe1004000..0x1ad004000");
	check("window base inside the modem pool", 0xC0004000, 3904 * M, 768 * M, "is inside the pool 0xc0000000..0xc1000000");
	arg_ram = 0;
	check("laurelram=0", 0xC1004000, 3904 * M, 768 * M, "kill switch laurelram=0");
	arg_ram = 1;
	have_banks = false;
	check("no laurel-ram-banks", 0xC1004000, 3904 * M, 768 * M, "no /chosen laurel-ram-banks");
	printf("%s\n", fails ? "laurel-ram-test: FAILED" : "laurel-ram-test: ok");
	return fails != 0;
}
