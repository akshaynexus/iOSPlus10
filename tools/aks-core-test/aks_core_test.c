/*
 * Host unit test of the NEGRONI software keybag core (NegroniKeyStoreCore.h,
 * added to the kernel by patches/xnu/0221-negroni-aks-passcode.patch).
 * Run: scripts/kernel/test-aks-core.sh (extracts the header from the patch).
 *
 * The core uses SHA256_CTX / SHA256_Init / SHA256_Update / SHA256_Final.
 * macOS: CommonCrypto (CC_SHA256_*), reference PBKDF2 = CCKeyDerivationPBKDF.
 * Linux: OpenSSL (SHA256_*), reference PBKDF2 = PKCS5_PBKDF2_HMAC.
 */
#define _GNU_SOURCE 1
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <CommonCrypto/CommonHMAC.h>
#define SHA256_CTX    CC_SHA256_CTX
#define SHA256_Init   CC_SHA256_Init
#define SHA256_Update(c, d, l) CC_SHA256_Update((c), (d), (CC_LONG)(l))
#define SHA256_Final  CC_SHA256_Final
static void
ref_pbkdf2(const uint8_t *pw, size_t pwlen, const uint8_t *salt, size_t saltlen, uint32_t it,
    uint8_t *out, size_t outlen)
{
	CCKeyDerivationPBKDF(kCCPBKDF2, (const char *)pw, pwlen, salt, saltlen, kCCPRFHmacAlgSHA256, it,
	    out, outlen);
}
static void
ref_hmac(const uint8_t *k, size_t kl, const uint8_t *m, size_t ml, uint8_t *out)
{
	CCHmac(kCCHmacAlgSHA256, k, kl, m, ml, out);
}
#else
#define OPENSSL_SUPPRESS_DEPRECATED 1
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/sha.h>
static void
ref_pbkdf2(const uint8_t *pw, size_t pwlen, const uint8_t *salt, size_t saltlen, uint32_t it,
    uint8_t *out, size_t outlen)
{
	PKCS5_PBKDF2_HMAC((const char *)pw, (int)pwlen, salt, (int)saltlen, (int)it, EVP_sha256(),
	    (int)outlen, out);
}
static void
ref_hmac(const uint8_t *k, size_t kl, const uint8_t *m, size_t ml, uint8_t *out)
{
	unsigned int n = 32;
	HMAC(EVP_sha256(), k, (int)kl, m, ml, out, &n);
}
#endif

#include "NegroniKeyStoreCore.h"

static int failures;
#define CHECK(cond, ...) do { \
	if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } \
} while (0)

static void
hex(const char *what, const uint8_t *p, size_t n)
{
	printf("  %s ", what);
	for (size_t i = 0; i < n; i++) {
		printf("%02x", p[i]);
	}
	printf("\n");
}

static void
test_hmac(void)
{
	/* RFC 4231 test case 2 */
	static const uint8_t exp2[32] = {
		0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e, 0x6a, 0x04, 0x24, 0x26, 0x08, 0x95, 0x75, 0xc7,
		0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83, 0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
	};
	uint8_t out[32], ref[32], key[200], msg[300];

	nks_hmac_sha256((const uint8_t *)"Jefe", 4, (const uint8_t *)"what do ya want for nothing?", 28, out);
	CHECK(memcmp(out, exp2, 32) == 0, "HMAC RFC 4231 case 2");
	/* long keys (hashed first) and random lengths against the reference */
	srand(7);
	for (int t = 0; t < 200; t++) {
		size_t kl = (size_t)(rand() % 200), ml = (size_t)(rand() % 300);
		for (size_t i = 0; i < kl; i++) {
			key[i] = (uint8_t)rand();
		}
		for (size_t i = 0; i < ml; i++) {
			msg[i] = (uint8_t)rand();
		}
		nks_hmac_sha256(key, kl, msg, ml, out);
		ref_hmac(key, kl, msg, ml, ref);
		CHECK(memcmp(out, ref, 32) == 0, "HMAC random case %d (key %zu, msg %zu)", t, kl, ml);
	}
	printf("hmac-sha256: RFC 4231 + 200 random cases\n");
}

static void
test_pbkdf2(void)
{
	/* RFC 7914 section 11: PBKDF2-HMAC-SHA256("passwd", "salt", 1, 64) */
	static const uint8_t exp[64] = {
		0x55, 0xac, 0x04, 0x6e, 0x56, 0xe3, 0x08, 0x9f, 0xec, 0x16, 0x91, 0xc2, 0x25, 0x44, 0xb6, 0x05,
		0xf9, 0x41, 0x85, 0x21, 0x6d, 0xde, 0x04, 0x65, 0xe6, 0x8b, 0x9d, 0x57, 0xc2, 0x0d, 0xac, 0xbc,
		0x49, 0xca, 0x9c, 0xcc, 0xf1, 0x79, 0xb6, 0x45, 0x99, 0x16, 0x64, 0xb3, 0x9d, 0x77, 0xef, 0x31,
		0x7c, 0x71, 0xb8, 0x45, 0xb1, 0xe3, 0x0b, 0xd5, 0x09, 0x11, 0x20, 0x41, 0xd3, 0xa1, 0x97, 0x83,
	};
	uint8_t out[80], ref[80];
	struct { const char *pw, *salt; uint32_t it; size_t len; } v[] = {
		{ "passwd", "salt", 1, 64 },
		{ "password", "salt", 2, 32 },
		{ "123456", "0123456789abcdef", 1000, 32 },
		{ "", "0123456789abcdef", 10, 32 },
		{ "a long alphanumeric passcode with spaces, 0123456789!", "s", 4096, 80 },
		{ "000000", "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10", NKS_ITERATIONS, 32 },
	};

	nks_pbkdf2_sha256((const uint8_t *)"passwd", 6, (const uint8_t *)"salt", 4, 1, out, 64);
	CHECK(memcmp(out, exp, 64) == 0, "PBKDF2 RFC 7914 vector");
	for (size_t i = 0; i < sizeof(v) / sizeof(v[0]); i++) {
		size_t pl = strlen(v[i].pw), sl = strlen(v[i].salt);
		nks_pbkdf2_sha256((const uint8_t *)v[i].pw, pl, (const uint8_t *)v[i].salt, sl, v[i].it, out, v[i].len);
		ref_pbkdf2((const uint8_t *)v[i].pw, pl, (const uint8_t *)v[i].salt, sl, v[i].it, ref, v[i].len);
		CHECK(memcmp(out, ref, v[i].len) == 0, "PBKDF2 case %zu (it %u, len %zu)", i, v[i].it, v[i].len);
	}
	printf("pbkdf2-hmac-sha256: RFC 7914 + %zu cases against the system library\n", sizeof(v) / sizeof(v[0]));
}

static void
test_bag(void)
{
	struct nks_bag bag, back;
	uint8_t salt[NKS_SALT_LEN], blob[NKS_BLOB_LEN], blob2[NKS_BLOB_LEN];
	const uint8_t *pc = (const uint8_t *)"123456";
	clock_t t0;
	double ms;

	memset(&bag, 0, sizeof(bag));
	for (int i = 0; i < NKS_SALT_LEN; i++) {
		salt[i] = (uint8_t)(0xa0 + i);
	}
	memcpy(bag.uuid, "negroni\0keybag\0\1", NKS_UUID_LEN);

	/* no passcode: anything opens it */
	CHECK(nks_bag_verify(&bag, (const uint8_t *)"", 0), "no passcode, empty");
	CHECK(nks_bag_verify(&bag, pc, 6), "no passcode, any input");

	/* set: right, wrong, empty, prefix, longer */
	t0 = clock();
	nks_bag_set_secret(&bag, pc, 6, salt, NKS_ITERATIONS);
	ms = (double)(clock() - t0) * 1000.0 / CLOCKS_PER_SEC;
	CHECK(bag.has_secret && bag.iterations == NKS_ITERATIONS, "set state");
	CHECK(memcmp(bag.salt, salt, NKS_SALT_LEN) == 0, "salt kept");
	{
		uint8_t ref[32];
		ref_pbkdf2(pc, 6, salt, NKS_SALT_LEN, NKS_ITERATIONS, ref, 32);
		CHECK(memcmp(bag.hash, ref, 32) == 0, "stored hash = PBKDF2(passcode, salt)");
		CHECK(memmem(&bag, sizeof(bag), "123456", 6) == NULL, "passcode not in the bag");
	}
	CHECK(nks_bag_verify(&bag, pc, 6), "right passcode");
	CHECK(!nks_bag_verify(&bag, (const uint8_t *)"123457", 6), "wrong passcode");
	CHECK(!nks_bag_verify(&bag, (const uint8_t *)"", 0), "empty passcode with a passcode set");
	CHECK(!nks_bag_verify(&bag, pc, 5), "prefix");
	CHECK(!nks_bag_verify(&bag, (const uint8_t *)"1234567", 7), "longer");
	printf("bag: set/verify ok; one PBKDF2 at %u iterations: %.1f ms on this host\n", NKS_ITERATIONS, ms);

	/* blob round trip */
	bag.grace = 300;
	CHECK(nks_bag_serialize(&bag, blob) == NKS_BLOB_LEN, "serialize length");
	CHECK(memmem(blob, sizeof(blob), "123456", 6) == NULL, "passcode not in the blob");
	memset(&back, 0x55, sizeof(back));
	CHECK(nks_bag_parse(blob, sizeof(blob), &back), "parse own blob");
	CHECK(back.has_secret == 1 && back.iterations == NKS_ITERATIONS && back.grace == 300 &&
	    memcmp(back.salt, bag.salt, NKS_SALT_LEN) == 0 && memcmp(back.hash, bag.hash, NKS_HASH_LEN) == 0 &&
	    memcmp(back.uuid, bag.uuid, NKS_UUID_LEN) == 0, "parsed fields");
	CHECK(nks_bag_verify(&back, pc, 6) && !nks_bag_verify(&back, (const uint8_t *)"000000", 6),
	    "verify after round trip");
	nks_bag_serialize(&back, blob2);
	CHECK(memcmp(blob, blob2, NKS_BLOB_LEN) == 0, "serialize(parse(blob)) == blob");
	hex("blob", blob, 32);

	/* damaged / foreign blobs are refused and leave the bag alone */
	for (size_t i = 0; i < NKS_BLOB_LEN; i++) {
		memcpy(blob2, blob, NKS_BLOB_LEN);
		blob2[i] ^= 0x01;
		back = bag;
		CHECK(!nks_bag_parse(blob2, NKS_BLOB_LEN, &back), "flip byte %zu accepted", i);
		CHECK(memcmp(&back, &bag, sizeof(bag)) == 0, "bag changed by refused parse %zu", i);
	}
	CHECK(!nks_bag_parse(blob, NKS_BLOB_LEN - 1, &back), "short blob");
	CHECK(!nks_bag_parse((const uint8_t *)"SWEET", 5, &back), "slop's SWEET bag");
	CHECK(!nks_bag_parse(NULL, 0, &back), "NULL");

	/* clear the passcode: blob says no passcode, anything opens it */
	nks_bag_set_secret(&bag, NULL, 0, NULL, 0);
	CHECK(!bag.has_secret, "cleared");
	nks_bag_serialize(&bag, blob);
	CHECK(nks_bag_parse(blob, NKS_BLOB_LEN, &back) && !back.has_secret && back.grace == 300 &&
	    nks_bag_verify(&back, pc, 6), "cleared round trip");
	printf("blob: round trip, %d one-bit corruptions refused, foreign blobs refused\n", NKS_BLOB_LEN);
}

static void
test_der(void)
{
	uint32_t vals[] = { 0, 1, 0x7f, 0x80, 0xff, 0x100, 300, 3600, 14400, 0x7fffffff, 0x80000000, 0xffffffff };
	uint8_t buf[512];

	for (size_t i = 0; i < sizeof(vals) / sizeof(vals[0]); i++) {
		size_t n = 2;
		uint32_t got = 12345;
		n += nks_der_pair(buf + n, "bd", 7);
		n += nks_der_pair(buf + n, "gp", vals[i]);
		n += nks_der_pair(buf + n, "mua", 10);
		buf[0] = 0x31;
		buf[1] = (uint8_t)(n - 2);
		CHECK(nks_der_find_int(buf, n, "gp", &got) && got == vals[i], "der gp %u -> %u", vals[i], got);
		CHECK(nks_der_find_int(buf, n, "mua", &got) && got == 10, "der mua");
		CHECK(!nks_der_find_int(buf, n, "g", &got), "der prefix key");
		CHECK(!nks_der_find_int(buf, n - 1, "mua", &got), "der truncated");
	}
	/* encoding of 0x80 is 02 02 00 80; of 0 is 02 01 00 */
	{
		size_t n = nks_der_pair(buf, "gp", 0x80);
		CHECK(n == 2 + 2 + 2 + 2 + 2 && buf[6] == 0x02 && buf[7] == 2 && buf[8] == 0 && buf[9] == 0x80,
		    "der 0x80 bytes");
		n = nks_der_pair(buf, "gp", 0);
		CHECK(n == 9 && buf[7] == 1 && buf[8] == 0, "der 0 bytes");
	}
	/* long-form SET length */
	{
		size_t n = 4;
		uint32_t got;
		for (int i = 0; i < 20; i++) {
			n += nks_der_pair(buf + n, "xxxxxxxx", (uint32_t)i);
		}
		n += nks_der_pair(buf + n, "gp", 60);
		buf[0] = 0x31;
		buf[1] = 0x82;
		buf[2] = (uint8_t)((n - 4) >> 8);
		buf[3] = (uint8_t)(n - 4);
		CHECK(nks_der_find_int(buf, n, "gp", &got) && got == 60, "der long form");
	}
	printf("der: INTEGER encode/decode for %zu values, long form, truncation\n", sizeof(vals) / sizeof(vals[0]));
}

/* A keybag file around a blob: binary plist bytes, XML base64, damaged, foreign, random. */
static void
test_find_blob(void)
{
	static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	uint8_t salt[NKS_SALT_LEN], blob[NKS_BLOB_LEN], file[2048];
	const uint8_t pc[] = "246810";
	struct nks_bag bag, got;
	size_t n, i;

	memset(&bag, 0, sizeof(bag));
	for (i = 0; i < sizeof(salt); i++) {
		salt[i] = (uint8_t)(0x30 + i);
	}
	nks_bag_set_secret(&bag, pc, 6, salt, 1000);
	nks_bag_serialize(&bag, blob);

	/* binary plist: bplist00, dict, key, then data marker 0x4f 0x10 0x80 + bytes */
	n = 0;
	memcpy(file, "bplist00\xd1\x01\x02ZKeyBagKeysO\x10\x80", 25);
	n = 25;
	memcpy(file + n, blob, sizeof(blob));
	n += sizeof(blob);
	memcpy(file + n, "\x08\x0b\x16\x00\x00\x00", 6);
	n += 6;
	memset(&got, 0, sizeof(got));
	CHECK(nks_find_blob(file, n, &got) && got.has_secret && nks_bag_verify(&got, pc, 6) &&
	    !nks_bag_verify(&got, (const uint8_t *)"246811", 6), "find: binary");
	file[25 + 40] ^= 1;
	CHECK(!nks_find_blob(file, n, &got), "find: damaged binary refused");
	CHECK(!nks_find_blob(file, 25 + 100, &got), "find: truncated binary refused");

	/* XML: base64 with line breaks and tabs, as plutil writes it */
	n = (size_t)sprintf((char *)file, "<?xml version=\"1.0\"?>\n<plist version=\"1.0\">\n<dict>\n"
	    "\t<key>KeyBagKeys</key>\n\t<data>\n\t");
	for (i = 0; i < sizeof(blob); i += 3) {
		uint32_t v = (uint32_t)blob[i] << 16;
		size_t k = sizeof(blob) - i;
		v |= k > 1 ? (uint32_t)blob[i + 1] << 8 : 0;
		v |= k > 2 ? blob[i + 2] : 0;
		file[n++] = (uint8_t)b64[(v >> 18) & 63];
		file[n++] = (uint8_t)b64[(v >> 12) & 63];
		file[n++] = k > 1 ? (uint8_t)b64[(v >> 6) & 63] : '=';
		file[n++] = k > 2 ? (uint8_t)b64[v & 63] : '=';
		if (i % 36 == 33) {
			memcpy(file + n, "\n\t", 2);
			n += 2;
		}
	}
	n += (size_t)sprintf((char *)file + n, "\n\t</data>\n</dict>\n</plist>\n");
	memset(&got, 0, sizeof(got));
	CHECK(nks_find_blob(file, n, &got) && got.has_secret && nks_bag_verify(&got, pc, 6), "find: xml");

	/* slop's placeholder */
	{
		const char *sweet = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>"
		    "<key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>\n";
		CHECK(!nks_find_blob((const uint8_t *)sweet, strlen(sweet), &got), "find: SWEET refused");
		CHECK(!nks_find_blob((const uint8_t *)"", 0, &got), "find: empty");
		CHECK(!nks_find_blob(NULL, 0, &got), "find: NULL");
		CHECK(!nks_find_blob((const uint8_t *)"<data>", 6, &got), "find: open data");
		CHECK(!nks_find_blob((const uint8_t *)"<data", 5, &got), "find: short");
	}

	/* random files (with fragments of the real ones) must not crash or match */
	srand(7);
	for (int t = 0; t < 3000; t++) {
		size_t len = (size_t)(rand() % (int)sizeof(file));
		for (i = 0; i < len; i++) {
			file[i] = (uint8_t)rand();
		}
		if (len > 200 && (t & 1)) {
			memcpy(file + rand() % (int)(len - 150), "<data>", 6);
			memcpy(file + rand() % (int)(len - 150), blob, 100);
		}
		CHECK(!nks_find_blob(file, len, &got), "find: random %d", t);
	}
	printf("find blob: binary + XML plist found, damaged / truncated / SWEET / 3000 random refused\n");
}

/* --blob OUT: write a passcode blob ("246810") for the plist check in test-aks-core.sh;
 * --find FILE: exit 0 when FILE holds a blob with that passcode. */
static int
tool(const char *cmd, const char *path)
{
	uint8_t salt[NKS_SALT_LEN] = { 1, 2, 3 }, blob[NKS_BLOB_LEN], *buf;
	struct nks_bag bag;
	size_t n;
	FILE *f;

	if (strcmp(cmd, "--blob") == 0) {
		memset(&bag, 0, sizeof(bag));
		nks_bag_set_secret(&bag, (const uint8_t *)"246810", 6, salt, 1000);
		nks_bag_serialize(&bag, blob);
		f = fopen(path, "wb");
		if (f == NULL || fwrite(blob, 1, sizeof(blob), f) != sizeof(blob)) {
			return 2;
		}
		return fclose(f) == 0 ? 0 : 2;
	}
	buf = malloc(65536);
	f = fopen(path, "rb");
	if (buf == NULL || f == NULL) {
		return 2;
	}
	n = fread(buf, 1, 65536, f);
	fclose(f);
	memset(&bag, 0, sizeof(bag));
	n = nks_find_blob(buf, n, &bag) && bag.has_secret && nks_bag_verify(&bag, (const uint8_t *)"246810", 6);
	free(buf);
	return n ? 0 : 1;
}

int
main(int argc, char **argv)
{
	if (argc == 3) {
		return tool(argv[1], argv[2]);
	}
	test_hmac();
	test_pbkdf2();
	test_bag();
	test_der();
	test_find_blob();
	printf(failures ? "RESULT: %d FAILURES\n" : "RESULT: all tests passed\n", failures);
	return failures ? 1 : 0;
}
