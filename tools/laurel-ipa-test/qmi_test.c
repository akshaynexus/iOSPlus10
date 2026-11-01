/*
 * Host test of the laurel 2780 QMI 0x31 messages (bsd/dev/laurel_ipa_qmi.c, taken from the patch). Expected bytes:
 * the 4.14 driver (ipa_qmi_service.c ipa3_qmi_init_modem_send_sync_msg, ipa_qmi_service_v01.c TLV types 0x10-0x22,
 * ipa_utils.c ipa_4_2_mem_part). Run by scripts/laurel/test-ipa.sh. Exit 0 = all pass.
 */
#include "kstub_ipa.h"
#include <stdlib.h>

int kt_printf(const char *fmt, ...) { va_list ap; va_start(ap, fmt); int n = vprintf(fmt, ap); va_end(ap); return n; }
uint64_t kt_now_ns;
int PE_parse_boot_argn(const char *n, void *v, int s) { (void)n; (void)v; (void)s; return 0; }

#include "laurel_ipa_qmi.c"

static int bad;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); bad++; } } while (0)

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

/* walk the TLVs: type list and values; returns the TLV count */
static int
tlvs(const uint8_t *d, uint32_t n, uint8_t *types, const uint8_t **vals, uint16_t *lens)
{
	int k = 0;
	for (uint32_t o = 7; o + 3 <= n && k < 32; k++) {
		uint16_t l = (uint16_t)(d[o + 1] | d[o + 2] << 8);
		types[k] = d[o];
		lens[k] = l;
		vals[k] = d + o + 3;
		o += 3u + l;
	}
	return k;
}

static void
test_init_req(uint32_t r)
{
	uint8_t b[256], ty[32];
	const uint8_t *v[32];
	uint16_t l[32];
	uint32_t n = lipa_qmi_init_modem_req(b, sizeof(b), 0x1234, r);
	static const uint8_t want_ty[] = { 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x19, 0x1F, 0x20, 0x21, 0x22 };
	const uint32_t want_v[][2] = {
		{ 3, 0 }, { 0x4A8 + r, 0x4A8 + r + 0x140 - 1 }, { 0x3A0 + r, 7 }, { 0x428 + r, 7 }, { 0x290 + r, 0 },
		{ 0x318 + r, 0 }, { 0xBF0 + r, 0x140C }, { 9, 0 }, { 0x5F0 + r, 0x5F0 + 0x200 + r - 1 }, { 0xA50 + r, 0 },
		{ 0x60, 0 }, { 0xBF0 + r, 0 }, { 0, 0 },
	};

	CHECK(n > 7);
	CHECK(b[0] == 0 && b[1] == 0x34 && b[2] == 0x12 && b[3] == 0x21 && b[4] == 0);
	CHECK((uint32_t)(b[5] | b[6] << 8) == n - 7);
	int k = tlvs(b, n, ty, v, l);
	CHECK(k == (int)sizeof(want_ty));
	for (int i = 0; i < k && i < (int)sizeof(want_ty); i++) {
		CHECK(ty[i] == want_ty[i]);
		CHECK(l[i] == 4 || l[i] == 8);
		CHECK(le32(v[i]) == want_v[i][0]);
		if (l[i] == 8) {
			CHECK(le32(v[i] + 4) == want_v[i][1]);
		}
	}
	CHECK(lipa_qmi_init_modem_req(b, 40, 1, r) == 0);   /* too small: no half message */
	printf("ok: INIT_MODEM_DRIVER restricted 0x%x: %u bytes, %d TLVs\n", r, n, k);
}

static void
test_init_resp(void)
{
	uint16_t err = 0;
	const uint8_t ok[] = { 2, 1, 0, 0x21, 0, 7, 0, 0x02, 4, 0, 0, 0, 0, 0 };
	const uint8_t no[] = { 2, 1, 0, 0x21, 0, 7, 0, 0x02, 4, 0, 1, 0, 0x2A, 0 };
	const uint8_t other[] = { 2, 1, 0, 0x22, 0, 7, 0, 0x02, 4, 0, 0, 0, 0, 0 };
	const uint8_t cut[] = { 2, 1, 0, 0x21, 0, 7, 0, 0x02, 9, 0, 0, 0 };
	CHECK(lipa_qmi_init_modem_resp(ok, sizeof(ok), &err) == 0);
	CHECK(lipa_qmi_init_modem_resp(no, sizeof(no), &err) == 1 && err == 0x2A);
	CHECK(lipa_qmi_init_modem_resp(other, sizeof(other), &err) == -1);
	CHECK(lipa_qmi_init_modem_resp(cut, sizeof(cut), &err) == -1);
	printf("ok: INIT_MODEM_DRIVER answer: success, error 0x2a, other message, cut TLV\n");
}

/* a request with one TLV */
static uint32_t
req(uint8_t *b, uint16_t txn, uint16_t msg, uint8_t t, const void *v, uint16_t l)
{
	b[0] = 0; b[1] = (uint8_t)txn; b[2] = (uint8_t)(txn >> 8); b[3] = (uint8_t)msg; b[4] = (uint8_t)(msg >> 8);
	uint32_t n = 7;
	if (v != NULL) {
		b[7] = t; b[8] = (uint8_t)l; b[9] = (uint8_t)(l >> 8);
		memcpy(b + 10, v, l);
		n = 10u + l;
	}
	b[5] = (uint8_t)(n - 7); b[6] = (uint8_t)((n - 7) >> 8);
	return n;
}

static void
test_serve(void)
{
	struct lipa_srv s = { 0 };
	uint8_t in[256], out[256], ex[1 + 2 * 12];
	uint16_t msg;
	uint32_t n;

	n = lipa_qmi_serve(&s, in, req(in, 7, 0x20, 0, NULL, 0), out, sizeof(out), &msg);
	CHECK(n == 14 && msg == 0x20 && s.ind_registered && out[0] == 2 && out[1] == 7 && out[3] == 0x20);
	CHECK(out[7] == 0x02 && le32(out + 10) == 0);       /* result success, error 0 */
	/* INSTALL_FILTER_RULE with 2 ex elements of 12 bytes: rule id = the u32 before the last byte */
	memset(ex, 0, sizeof(ex));
	ex[0] = 2;
	memcpy(ex + 1 + 12 - 5, "\x11\x00\x00\x00", 4);
	memcpy(ex + 1 + 24 - 5, "\x22\x00\x00\x00", 4);
	n = lipa_qmi_serve(&s, in, req(in, 8, 0x23, 0x15, ex, sizeof(ex)), out, sizeof(out), &msg);
	CHECK(n == 14 + 3 + 9 && s.filters && s.rules == 2);
	CHECK(out[14] == 0x11 && out[15] == 9 && out[17] == 2 && le32(out + 18) == 0x11 && le32(out + 22) == 0x22);
	ex[0] = 5;                                          /* 23 bytes do not divide into 5 elements */
	n = lipa_qmi_serve(&s, in, req(in, 9, 0x23, 0x15, ex, sizeof(ex) - 1), out, sizeof(out), &msg);
	CHECK(n == 14 && (out[10] | out[11] << 8) == 1 && (out[12] | out[13] << 8) == 1);
	n = lipa_qmi_serve(&s, in, req(in, 10, 0x24, 0, NULL, 0), out, sizeof(out), &msg);
	CHECK(n == 14 && msg == 0x24);
	n = lipa_qmi_serve(&s, in, req(in, 11, 0x27, 0, NULL, 0), out, sizeof(out), &msg);
	CHECK(n == 14 && s.configs == 1);
	uint8_t st = 1;
	n = lipa_qmi_serve(&s, in, req(in, 12, 0x35, 0x01, &st, 1), out, sizeof(out), &msg);
	CHECK(n == 14 && msg == 0x35 && s.init_cmplt);
	n = lipa_qmi_serve(&s, in, req(in, 13, 0x29, 0, NULL, 0), out, sizeof(out), &msg);
	CHECK(n == 0 && msg == 0x29);                       /* not served (as the stock driver) */
	in[0] = 2;
	CHECK(lipa_qmi_serve(&s, in, 7, out, sizeof(out), &msg) == 0);   /* a response is no request */
	printf("ok: our service: IND_REGISTER, INSTALL_FILTER (2 ids echoed, bad size refused), NOTIF, CONFIG, CMPLT, unknown\n");
}

static void
test_master_ind(void)
{
	uint8_t b[32];
	uint32_t n = lipa_qmi_master_ind(b, sizeof(b), 5);
	CHECK(n == 14 && b[0] == 4 && b[1] == 5 && b[3] == 0x22 && b[5] == 7 && b[7] == 0x02 && le32(b + 10) == 0);
	printf("ok: MASTER_DRIVER_INIT_COMPLETE indication\n");
}

int
main(void)
{
	test_init_req(0);
	test_init_req(0x2000);
	test_init_resp();
	test_serve();
	test_master_ind();
	printf("%s: qmi_test (%d failures)\n", bad ? "FAIL" : "PASS", bad);
	return bad != 0;
}
