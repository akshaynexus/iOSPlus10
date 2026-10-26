/*
 * Host unit test of the Bluetooth HCI shim (bsd/dev/negroni_bt_shim.c, patches 0333-0338): the 0338 legacy LE ->
 * extended LE translation and the 0337 vendor answers. Run by scripts/kernel/test-bt-shim.sh TREE.
 * Stubs: the H4 transport (inject = toward bluetoothd, send_cmd = toward the chip) and the boot-args (defaults).
 * Expected bytes: Bluetooth Core 5.3 Vol 4 Part E 7.8.5-7.8.12, 7.8.53-7.8.66, 7.7.65.2, 7.7.65.13.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include "negroni_bt.h"

static uint8_t sent[8][64], inj[8][300];
static uint32_t sentn[8], injn[8];
static int nsent, ninj, fails;

static uint64_t now;
uint32_t negroni_bt_arg(const char *n, uint32_t d) { (void)n; return d; }
uint64_t negroni_bt_us(void) { return now; }
void negroni_bt_h4_inject(const uint8_t *p, uint32_t n) { memcpy(inj[ninj], p, n); injn[ninj++] = n; }
int negroni_bt_h4_send_cmd(const uint8_t *p, uint32_t n, bool rx) { (void)rx; memcpy(sent[nsent], p, n); sentn[nsent++] = n; return 0; }

static void
check(const char *what, const uint8_t *got, uint32_t gn, const uint8_t *exp, uint32_t en)
{
	if (gn != en || memcmp(got, exp, en) != 0) {
		fails++;
		printf("FAIL %s: got", what);
		for (uint32_t i = 0; i < gn; i++) printf(" %02x", got[i]);
		printf("\n     expected");
		for (uint32_t i = 0; i < en; i++) printf(" %02x", exp[i]);
		printf("\n");
	} else {
		printf("ok   %s\n", what);
	}
}

#define B(...) (const uint8_t[]){ __VA_ARGS__ }, sizeof((const uint8_t[]){ __VA_ARGS__ })

/* host command; expect: shim result, and the one packet to the chip (or NULL) */
static void
tx(const char *what, const uint8_t *p, uint32_t n, int r_exp, const uint8_t *chip, uint32_t cn)
{
	uint8_t b[300];
	memcpy(b, p, n);
	nsent = ninj = 0;
	int r = negroni_bt_shim_tx(b, n);
	if (r != r_exp) { fails++; printf("FAIL %s: shim result %d, expected %d\n", what, r, r_exp); }
	if (chip) {
		if (nsent != 1) { fails++; printf("FAIL %s: %d packets to the chip\n", what, nsent); return; }
		check(what, sent[0], sentn[0], chip, cn);
	} else if (r == NEGRONI_BT_SHIM_PASS) {
		check(what, b, n, p, n);
	}
}

/* controller event; expect: delivered (rewritten in place) packet, or a chip packet + nothing / an injected one */
static void
rx(const char *what, const uint8_t *p, uint32_t n, const uint8_t *host, uint32_t hn, const uint8_t *chip, uint32_t cn)
{
	uint8_t b[300];
	memcpy(b, p, n);
	nsent = ninj = 0;
	int r = negroni_bt_shim_rx(b, n);
	const uint8_t *got = r == NEGRONI_BT_SHIM_PASS ? b : ninj ? inj[0] : NULL;
	uint32_t gn = r == NEGRONI_BT_SHIM_PASS ? n : ninj ? injn[0] : 0;
	if (host) {
		check(what, got ? got : (const uint8_t *)"", gn, host, hn);
	} else if (got) {
		fails++;
		printf("FAIL %s: delivered to the host, expected nothing\n", what);
	}
	if (chip) {
		if (nsent != 1) { fails++; printf("FAIL %s: %d packets to the chip\n", what, nsent); return; }
		check(what, sent[0], sentn[0], chip, cn);
	}
}

int
main(void)
{
	negroni_bt_shim_init();
	negroni_bt_shim_session();
	printf("---- 0338 translation\n");
	tx("0x200b -> 0x2041", B(1, 0x0b, 0x20, 7, 0x00, 0xe0, 0x01, 0x30, 0x00, 0x01, 0x00), NEGRONI_BT_SHIM_DONE,
	    B(1, 0x41, 0x20, 8, 0x01, 0x00, 0x01, 0x00, 0xe0, 0x01, 0x30, 0x00));
	rx("0x2041 CC -> 0x200b CC", B(4, 0x0e, 4, 1, 0x41, 0x20, 0), B(4, 0x0e, 4, 1, 0x0b, 0x20, 0), NULL, 0);
	tx("0x200c -> 0x2042", B(1, 0x0c, 0x20, 2, 1, 1), NEGRONI_BT_SHIM_DONE, B(1, 0x42, 0x20, 6, 1, 1, 0, 0, 0, 0));
	rx("0x2042 CC -> 0x200c CC", B(4, 0x0e, 4, 1, 0x42, 0x20, 0x0c), B(4, 0x0e, 4, 1, 0x0c, 0x20, 0x0c), NULL, 0);
	tx("0x2005 passes (no set yet)", B(1, 0x05, 0x20, 6, 1, 2, 3, 4, 5, 0xc6), NEGRONI_BT_SHIM_PASS, NULL, 0);
	rx("0x2005 CC passes", B(4, 0x0e, 4, 1, 0x05, 0x20, 0), B(4, 0x0e, 4, 1, 0x05, 0x20, 0), NULL, 0);
	tx("0x2006 ADV_IND random -> 0x2036", B(1, 0x06, 0x20, 15, 0xa0, 0, 0xa0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 7, 0),
	    NEGRONI_BT_SHIM_DONE, B(1, 0x36, 0x20, 25, 0, 0x13, 0, 0xa0, 0, 0, 0xa0, 0, 0, 7, 1, 0, 0, 0, 0, 0, 0, 0, 0,
	    0x7f, 1, 0, 1, 0, 0));
	rx("0x2036 CC -> 0x2035 to the chip", B(4, 0x0e, 5, 1, 0x36, 0x20, 0, 5), NULL, 0,
	    B(1, 0x35, 0x20, 7, 0, 1, 2, 3, 4, 5, 0xc6));
	rx("0x2035 CC -> 0x2006 CC", B(4, 0x0e, 4, 1, 0x35, 0x20, 0), B(4, 0x0e, 4, 1, 0x06, 0x20, 0), NULL, 0);
	tx("0x2008 -> 0x2037", B(1, 0x08, 0x20, 32, 3, 2, 1, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	    0, 0, 0, 0, 0, 0, 0, 0), NEGRONI_BT_SHIM_DONE, B(1, 0x37, 0x20, 7, 0, 3, 1, 3, 2, 1, 6));
	rx("0x2037 CC -> 0x2008 CC", B(4, 0x0e, 4, 1, 0x37, 0x20, 0), B(4, 0x0e, 4, 1, 0x08, 0x20, 0), NULL, 0);
	tx("0x200a -> 0x2039", B(1, 0x0a, 0x20, 1, 1), NEGRONI_BT_SHIM_DONE, B(1, 0x39, 0x20, 6, 1, 1, 0, 0, 0, 0));
	rx("0x2039 error -> 0x200a CC with it", B(4, 0x0e, 4, 1, 0x39, 0x20, 0x12), B(4, 0x0e, 4, 1, 0x0a, 0x20, 0x12),
	    NULL, 0);
	tx("0x2005 with set 0 -> 0x2005 first", B(1, 0x05, 0x20, 6, 9, 8, 7, 6, 5, 0xc4), NEGRONI_BT_SHIM_DONE,
	    B(1, 0x05, 0x20, 6, 9, 8, 7, 6, 5, 0xc4));
	rx("0x2005 CC -> 0x2035 to the chip", B(4, 0x0e, 4, 1, 0x05, 0x20, 0), NULL, 0,
	    B(1, 0x35, 0x20, 7, 0, 9, 8, 7, 6, 5, 0xc4));
	rx("0x2035 error only logged -> 0x2005 CC 0", B(4, 0x0e, 4, 1, 0x35, 0x20, 0x0c), B(4, 0x0e, 4, 1, 0x05, 0x20, 0),
	    NULL, 0);
	rx("ext report ADV_IND -> legacy report", B(4, 0x3e, 29, 0x0d, 1, 0x13, 0x00, 0x01, 1, 2, 3, 4, 5, 6, 1, 0, 0xff,
	    0x7f, 0xc0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 2, 1, 6),
	    B(4, 0x3e, 15, 0x02, 1, 0x00, 0x01, 1, 2, 3, 4, 5, 6, 3, 2, 1, 6, 0xc0), NULL, 0);
	rx("ext report SCAN_RSP to ADV_IND -> type 4", B(4, 0x3e, 26, 0x0d, 1, 0x1b, 0x00, 0x00, 1, 2, 3, 4, 5, 6, 1, 0,
	    0xff, 0x7f, 0xb0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
	    B(4, 0x3e, 12, 0x02, 1, 0x04, 0x00, 1, 2, 3, 4, 5, 6, 0, 0xb0), NULL, 0);
	rx("ext report extended PDU -> dropped", B(4, 0x3e, 26, 0x0d, 1, 0x01, 0x00, 0x00, 1, 2, 3, 4, 5, 6, 1, 2,
	    0x01, 0x7f, 0xb0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), NULL, 0, NULL, 0);
	rx("Advertising Set Terminated -> dropped", B(4, 0x3e, 6, 0x12, 0, 0, 0x40, 0, 0), NULL, 0, NULL, 0);
	tx("0x200d -> 0x2043", B(1, 0x0d, 0x20, 25, 0x60, 0, 0x30, 0, 0, 1, 1, 2, 3, 4, 5, 6, 1, 0x18, 0, 0x28, 0, 0, 0,
	    0x48, 0, 0, 0, 0, 0), NEGRONI_BT_SHIM_DONE, B(1, 0x43, 0x20, 26, 0, 1, 1, 1, 2, 3, 4, 5, 6, 1, 0x60, 0, 0x30,
	    0, 0x18, 0, 0x28, 0, 0, 0, 0x48, 0, 0, 0, 0, 0));
	rx("0x2043 CS -> 0x200d CS", B(4, 0x0f, 4, 0, 1, 0x43, 0x20), B(4, 0x0f, 4, 0, 1, 0x0d, 0x20), NULL, 0);
	{
		uint8_t b[] = { 1, 0x01, 0x20, 8, 0x7f, 0x0a, 0x86, 0x3f, 7, 0, 0, 0 };
		(void)negroni_bt_shim_tx(b, sizeof(b));
		check("0x2001 byte 1 0x0a -> 0x1a", b + 5, 1, (const uint8_t[]){ 0x1a }, 1);
	}
	tx("0x0c03 resets the set state", B(1, 0x03, 0x0c, 0), NEGRONI_BT_SHIM_PASS, NULL, 0);
	tx("0x200a disable with no set -> local 0", B(1, 0x0a, 0x20, 1, 0), NEGRONI_BT_SHIM_DONE, NULL, 0);
	check("  its answer", ninj ? inj[0] : (const uint8_t *)"", ninj ? injn[0] : 0, B(4, 0x0e, 4, 1, 0x0a, 0x20, 0));
	tx("0x2009 with no set -> 0x2036 defaults first", B(1, 0x09, 0x20, 32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), NEGRONI_BT_SHIM_DONE, B(1, 0x36, 0x20, 25, 0, 0x13, 0,
	    0, 8, 0, 0, 8, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x7f, 1, 0, 1, 0, 0));
	rx("0x2036 CC -> 0x2038 to the chip", B(4, 0x0e, 5, 1, 0x36, 0x20, 0, 5), NULL, 0, B(1, 0x38, 0x20, 4, 0, 3, 1, 0));
	rx("0x2038 CC -> 0x2009 CC", B(4, 0x0e, 4, 1, 0x38, 0x20, 0), B(4, 0x0e, 4, 1, 0x09, 0x20, 0), NULL, 0);
	printf("---- 0338 review fixes\n");
	tx("reset", B(1, 0x03, 0x0c, 0), NEGRONI_BT_SHIM_PASS, NULL, 0);
	tx("0x2006 NONCONN -> 0x2036 props 0x10", B(1, 0x06, 0x20, 15, 0xa0, 0, 0xa0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0),
	    NEGRONI_BT_SHIM_DONE, B(1, 0x36, 0x20, 25, 0, 0x10, 0, 0xa0, 0, 0, 0xa0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	    0x7f, 1, 0, 1, 0, 0));
	rx("F2: 0x2036 error -> 0x2006 CC with it", B(4, 0x0e, 5, 1, 0x36, 0x20, 0x12, 0),
	    B(4, 0x0e, 4, 1, 0x06, 0x20, 0x12), NULL, 0);
	tx("F2: then 0x200a disable -> local 0 (no set)", B(1, 0x0a, 0x20, 1, 0), NEGRONI_BT_SHIM_DONE, NULL, 0);
	check("  its answer", ninj ? inj[0] : (const uint8_t *)"", ninj ? injn[0] : 0, B(4, 0x0e, 4, 1, 0x0a, 0x20, 0));
	tx("0x2006 high duty directed public -> props 0x1d", B(1, 0x06, 0x20, 15, 0, 0, 0, 0, 1, 0, 0, 1, 2, 3, 4, 5, 6,
	    7, 0), NEGRONI_BT_SHIM_DONE, B(1, 0x36, 0x20, 25, 0, 0x1d, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 1, 2, 3, 4, 5, 6, 0,
	    0x7f, 1, 0, 1, 0, 0));
	rx("0x2036 CC (public: no 0x2035) -> 0x2006 CC", B(4, 0x0e, 5, 1, 0x36, 0x20, 0, 0),
	    B(4, 0x0e, 4, 1, 0x06, 0x20, 0), NULL, 0);
	tx("F4: 0x2008 on directed -> local 0", B(1, 0x08, 0x20, 32, 3, 2, 1, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), NEGRONI_BT_SHIM_DONE, NULL, 0);
	check("  its answer", ninj ? inj[0] : (const uint8_t *)"", ninj ? injn[0] : 0, B(4, 0x0e, 4, 1, 0x08, 0x20, 0));
	tx("F3: 0x200a enable high duty -> duration 0x0080", B(1, 0x0a, 0x20, 1, 1), NEGRONI_BT_SHIM_DONE,
	    B(1, 0x39, 0x20, 6, 1, 1, 0, 0x80, 0, 0));
	now += 3000000u;
	tx("F6: answer lost, 3 s later 0x200a disable -> stale chain dropped, sent", B(1, 0x0a, 0x20, 1, 0),
	    NEGRONI_BT_SHIM_DONE, B(1, 0x39, 0x20, 6, 0, 1, 0, 0, 0, 0));
	rx("0x2039 CC -> 0x200a CC", B(4, 0x0e, 4, 1, 0x39, 0x20, 0), B(4, 0x0e, 4, 1, 0x0a, 0x20, 0), NULL, 0);
	printf("---- 0337 vendor answers\n");
	tx("0xfce2 sub 0x15 local", B(1, 0xe2, 0xfc, 10, 0x15, 0, 0, 0, 0xff, 0x0f, 2, 0, 0, 0), NEGRONI_BT_SHIM_DONE,
	    NULL, 0);
	check("  its answer: status 0 + 8 bytes, byte 0 = sub-opcode", ninj ? inj[0] : (const uint8_t *)"",
	    ninj ? injn[0] : 0, B(4, 0x0e, 12, 1, 0xe2, 0xfc, 0, 0x15, 0, 0, 0, 0, 0, 0, 0));
	tx("0xfd4e (not in the table) local", B(1, 0x4e, 0xfd, 2, 1, 1), NEGRONI_BT_SHIM_DONE, NULL, 0);
	check("  its answer: status 1 + 8 bytes", ninj ? inj[0] : (const uint8_t *)"", ninj ? injn[0] : 0,
	    B(4, 0x0e, 12, 1, 0x4e, 0xfd, 1, 1, 0, 0, 0, 0, 0, 0, 0));
	printf(fails ? "bt shim test: %d FAILED\n" : "bt shim test: all ok\n", fails);
	return fails ? 1 : 0;
}
