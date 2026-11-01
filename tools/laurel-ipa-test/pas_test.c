/*
 * Host test of the laurel 2775 shared PAS loader (bsd/dev/topaz_pas.c) and the laurel 2780 IPA firmware loader
 * (laurel_ipa_fw.c + the ext4 reader), all taken from the patches, linked with a simulated TrustZone:
 *   pas_test [IMAGE REFDIR]
 * Part 1 (always): a synthetic image with the stock ipa_fws layout: call order, mem_setup span, region bytes,
 * metadata bytes, and the error paths (shutdown only after init_image passed). Part 2 (with IMAGE = a raw
 * vendor ext4 image, served as vendor_b; REFDIR = ipa_fws.mdt/.bNN dumped by debugfs): lipa_fw_load() end to end.
 */
#include "kstub_ipa.h"
#include <stdlib.h>
#include "topaz_pas.h"
#include "laurel_ipa_regs.h"

int kt_printf(const char *fmt, ...) { va_list ap; va_start(ap, fmt); int n = vprintf(fmt, ap); va_end(ap); return n; }
void IOLog(const char *fmt, ...) { va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); }
uint64_t kt_now_ns;
int PE_parse_boot_argn(const char *n, void *v, int s) { (void)n; (void)v; (void)s; return 0; }
void IOSleep(unsigned int ms) { kt_now_ns += ms * 1000000ull; }
void sweet_dcache_clean(vm_offset_t a, unsigned l) { (void)a; (void)l; }

static int bad;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); bad++; } } while (0)

/* ---- simulated SoC: modem pool, carve-out, TrustZone */
#define POOL_PA 0xE0000000ull
static uint8_t pool[0x20000], region[0x10000];
static uint32_t pool_used, region_pa;
static bool soc_ok = true;
static struct { char calls[16]; int n; uint64_t meta_pa, setup_pa, setup_len; int fail; uint8_t meta[0x10000]; } tz;

bool topaz_soc_map(void) { return soc_ok; }
void *
topaz_pool_alloc(uint64_t size, uint64_t *pa)
{
	if (pool_used + size > sizeof(pool)) {
		return NULL;
	}
	*pa = POOL_PA + pool_used;
	void *v = pool + pool_used;
	pool_used += (uint32_t)((size + 0xfff) & ~0xfffull);
	return v;
}
vm_offset_t ml_io_map(vm_offset_t pa, vm_size_t len) { return pa == region_pa && len <= sizeof(region) ? (vm_offset_t)region : 0; }
uint64_t
topaz_scm(uint32_t fn, uint64_t arginfo, uint64_t a, uint64_t b, uint64_t c, uint64_t *res1)
{
	uint32_t cmd = fn & 0xff;
	(void)arginfo; (void)a;
	*res1 = 0;
	if (tz.n < 15) {
		tz.calls[tz.n++] = (char)('0' + cmd);
	}
	if (cmd == 1) {                         /* init_image: TrustZone reads the metadata at b */
		tz.meta_pa = b;
		if (b >= POOL_PA && b < POOL_PA + sizeof(pool)) {
			memcpy(tz.meta, pool + (b - POOL_PA), sizeof(pool) - (b - POOL_PA) < sizeof(tz.meta) ? sizeof(pool) - (b - POOL_PA) : sizeof(tz.meta));
		}
	}
	if (cmd == 2) {
		tz.setup_pa = b;
		tz.setup_len = c;
	}
	return tz.fail == (int)cmd ? 0xffffffffffffffeaull : 0;
}

/* ---- UFS: IMAGE as vendor_b, boot_b active, no vendor_a */
static FILE *img;
static uint64_t img_len;
int
sweet_ufs_part_info(const char *want, uint64_t *attr, uint64_t *bytes)
{
	if (attr != NULL) {
		*attr = strcmp(want, "boot_b") == 0 ? 1ull << 50 : 0;
	}
	if (strncmp(want, "boot_", 5) == 0) {
		return 0;
	}
	if (strcmp(want, "vendor_b") == 0 && img != NULL) {
		if (bytes != NULL) {
			*bytes = img_len;
		}
		return 0;
	}
	return ENOENT;
}
int
sweet_ufs_read_part(const char *want, uint64_t off, void *dst, uint64_t len)
{
	if (strcmp(want, "vendor_b") != 0 || img == NULL || fseeko(img, (off_t)off, SEEK_SET) != 0 ||
	    fread(dst, 1, len, img) != len) {
		return EIO;
	}
	return 0;
}

/* ---- part 1: synthetic image with the stock layout (seg 2 @0 filesz 0x2f08 memsz 0x4000, 3 @0x4000, 4 @0x4080) */
static uint8_t mdt[0xd4 + 0x200], segd[5][0x3000];
static const uint32_t S_PA[5] = { 0, 0x5000, 0, 0x4000, 0x4080 }, S_FS[5] = { 0xd4, 0x1a98, 0x2f08, 0x80, 0x140 };
static const uint32_t S_MS[5] = { 0, 0x2000, 0x4000, 0x80, 0x140 }, S_TY[5] = { 0, 0, 1, 1, 1 };
static const uint32_t S_FL[5] = { 0x7000000, 0x2200000, 0x8000007, 0x8000007, 0x8000007 };

static void
put32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

static void
make_image(void)
{
	memset(mdt, 0xA5, sizeof(mdt));
	memcpy(mdt, "\177ELF\001\001\001", 7);
	put32(mdt + 28, 52);                    /* e_phoff */
	mdt[44] = 5; mdt[45] = 0;               /* e_phnum */
	for (int i = 0; i < 5; i++) {
		uint8_t *ph = mdt + 52 + 32 * i;
		put32(ph, S_TY[i]); put32(ph + 12, S_PA[i]); put32(ph + 16, S_FS[i]); put32(ph + 20, S_MS[i]);
		put32(ph + 24, S_FL[i]);
		for (uint32_t k = 0; k < sizeof(segd[i]); k++) {
			segd[i][k] = (uint8_t)(i * 37 + k * 7 + 1);
		}
	}
}

static int
seg_cb(void *ctx, uint32_t idx, volatile uint8_t *dst, uint32_t room, char *why, size_t wl)
{
	(void)ctx;
	if (idx >= 5 || S_FS[idx] > room) {
		snprintf(why, wl, "bad segment %u", idx);
		return 1;
	}
	for (uint32_t i = 0; i < S_FS[idx]; i++) {
		dst[i] = segd[idx][i];
	}
	return 0;
}

static int
run(int fail, uint32_t rsize, bool soc)
{
	char why[200] = "";
	struct topaz_pas p = { "test: pas", "test image", 15, mdt, sizeof(mdt), 0x57500000, rsize, NULL, seg_cb, NULL };
	memset(&tz, 0, sizeof(tz));
	memset(region, 0xEE, sizeof(region));
	pool_used = 0;
	region_pa = 0x57500000;
	tz.fail = fail;
	soc_ok = soc;
	int rc = topaz_pas_load(&p, why, sizeof(why));
	printf("  pas: fail=%d region=%#x soc=%d -> %d calls '%s' %s\n", fail, rsize, soc, rc, tz.calls, why);
	return rc;
}

static bool
region_ok(void)
{
	static uint8_t want[0x10000];
	memset(want, 0, sizeof(want));
	for (int i = 2; i < 5; i++) {
		memcpy(want + S_PA[i], segd[i], S_FS[i]);
	}
	return memcmp(region, want, 0x10000) == 0;
}

static void
part1(void)
{
	make_image();
	CHECK(run(0, 0x10000, true) == 0 && strcmp(tz.calls, "7125") == 0);
	CHECK(tz.setup_pa == 0x57500000 && tz.setup_len == 0x5000);     /* page end of 0x4080 + 0x140 */
	CHECK(tz.meta_pa == POOL_PA && memcmp(tz.meta, mdt, sizeof(mdt)) == 0);
	CHECK(region_ok());
	CHECK(run(7, 0x10000, true) == TOPAZ_PAS_ENOSUPPORT && strcmp(tz.calls, "7") == 0);
	CHECK(run(1, 0x10000, true) == TOPAZ_PAS_EINIT && strcmp(tz.calls, "71") == 0);     /* no shutdown */
	CHECK(run(2, 0x10000, true) == TOPAZ_PAS_ESETUP && strcmp(tz.calls, "7126") == 0);
	CHECK(run(5, 0x10000, true) == TOPAZ_PAS_EAUTH && strcmp(tz.calls, "71256") == 0);
	CHECK(run(0, 0x4000, true) == TOPAZ_PAS_ELAYOUT && tz.n == 0);                     /* 0x5000 > 0x4000 */
	CHECK(run(0, 0x10000, false) == TOPAZ_PAS_EMETA && tz.n == 0);                     /* no pool, no meta_alt */
	region_pa = 0;                                                                       /* map fails */
	{
		char why[200] = "";
		struct topaz_pas p = { "test: pas", "test image", 15, mdt, sizeof(mdt), 0x57500000, 0x10000, NULL, seg_cb, NULL };
		memset(&tz, 0, sizeof(tz));
		soc_ok = true;
		CHECK(topaz_pas_load(&p, why, sizeof(why)) == TOPAZ_PAS_ECOPY && strcmp(tz.calls, "7126") == 0);
	}
	printf("ok: shared PAS loader: order 7-1-2-5, span 0x5000, region and metadata bytes, 6 error paths\n");
}

static uint8_t *
slurp(const char *dir, const char *name, size_t *len)
{
	char p[512];
	snprintf(p, sizeof(p), "%s/%s", dir, name);
	FILE *f = fopen(p, "rb");
	if (f == NULL) {
		return NULL;
	}
	uint8_t *b = malloc(0x40000);
	*len = fread(b, 1, 0x40000, f);
	fclose(f);
	return b;
}

static void
part2(const char *image, const char *ref)
{
	char why[200] = "";
	size_t ml = 0;
	img = fopen(image, "rb");
	if (img == NULL || fseeko(img, 0, SEEK_END) != 0) {
		printf("FAIL: cannot open %s\n", image);
		bad++;
		return;
	}
	img_len = (uint64_t)ftello(img);
	memset(&tz, 0, sizeof(tz));
	memset(region, 0xEE, sizeof(region));
	pool_used = 0;
	region_pa = LIPA_FW_PA;
	soc_ok = true;
	bool ok = lipa_fw_load(why, sizeof(why));
	printf("  fw: lipa_fw_load -> %d calls '%s' %s\n", ok, tz.calls, why);
	CHECK(ok && strcmp(tz.calls, "7125") == 0 && tz.setup_pa == LIPA_FW_PA && tz.setup_len == 0x5000);
	uint8_t *m = slurp(ref, "ipa_fws.mdt", &ml);
	CHECK(m != NULL && ml == 7020 && memcmp(tz.meta, m, ml) == 0);
	static uint8_t want[0x10000];
	memset(want, 0, sizeof(want));
	for (uint32_t i = 0; m != NULL && i < m[44]; i++) {
		const uint8_t *ph = m + 52 + 32 * i;
		uint32_t ty, pa, fs, ms, fl;
		memcpy(&ty, ph, 4); memcpy(&pa, ph + 12, 4); memcpy(&fs, ph + 16, 4); memcpy(&ms, ph + 20, 4); memcpy(&fl, ph + 24, 4);
		if (ty != 1 || ms == 0 || ((fl >> 24) & 7) == 2) {
			continue;
		}
		char name[16];
		size_t sl = 0;
		snprintf(name, sizeof(name), "ipa_fws.b%02u", i);
		uint8_t *s = slurp(ref, name, &sl);
		CHECK(s != NULL && sl >= fs && pa + fs <= sizeof(want));
		if (s != NULL) {
			memcpy(want + pa, s, fs);
			free(s);
		}
	}
	CHECK(memcmp(region, want, sizeof(want)) == 0);
	free(m);
	fclose(img);
	img = NULL;
	/* no image at all: the reason names both slots */
	ok = lipa_fw_load(why, sizeof(why));
	CHECK(!ok && strstr(why, "no IPA firmware in vendor_a/_b") != NULL);
	printf("ok: lipa_fw_load from %s: PAS 15 order 7-1-2-5, mem_setup 0x57500000+0x5000, metadata = ipa_fws.mdt, "
	    "region = .b02/.b03/.b04 at 0/0x4000/0x4080 (debugfs files)\n", image);
}

int
main(int argc, char **argv)
{
	part1();
	if (argc >= 3) {
		part2(argv[1], argv[2]);
	} else {
		printf("note: no vendor image: lipa_fw_load end-to-end part skipped\n");
	}
	printf("%s: pas_test (%d failures)\n", bad ? "FAIL" : "PASS", bad);
	return bad != 0;
}
