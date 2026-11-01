/*
 * Host test of laurel_ipa*.c (2780 + 2782) and laurel_cell.c (2760 + 2780 + 2786) as one system, kernel files taken from the patches: laurel_cell.c
 * asks the real laurel_ipa_state(). A simulated modem answers UIM, DMS, NAS, WDS and the QMI 0x31 handshake. Run by scripts/laurel/test-ipa.sh.
 * Scenarios: boot 20:02's mode 5 at the first read, then ONLINE after "LAUREL IPA: on"; the modem asserts after INIT_MODEM_DRIVER (boot 17:01); ipa=0.
 */
#define GATE_NO_MAIN
#include "gate_test.c"

extern void laurel_cell_server(uint32_t svc, uint32_t inst, uint32_t node, uint32_t port, bool up);
extern bool laurel_cell_rx(uint32_t dst_port, const uint8_t *d, uint32_t len);
extern void laurel_cell_poll(bool ready, bool glink);
extern void laurel_cell_off(const char *why);
uint32_t topaz_qrtr_services(void);
uint32_t topaz_qrtr_services(void) { return 9; }
/* laurel 2932: the data client is real; no AP pipes in this test */
int laurel_ipa_data_state(const char **why);
int laurel_ipa_data_state(const char **why) { if (why != NULL) { *why = "no AP GSI data pipes yet"; } return -1; }
void laurel_pdp_set4(bool up, uint32_t ip, uint32_t mask, uint32_t gw, uint32_t dns1, uint32_t dns2, uint32_t mtu);
void laurel_pdp_set4(bool up, uint32_t ip, uint32_t mask, uint32_t gw, uint32_t dns1, uint32_t dns2, uint32_t mtu) { (void)up; (void)ip; (void)mask; (void)gw; (void)dns1; (void)dns2; (void)mtu; }
void laurel_pdp_set6(bool up, const uint8_t *ip, uint8_t plen, const uint8_t *gw, const uint8_t *dns1, const uint8_t *dns2, uint32_t mtu);
void laurel_pdp_set6(bool up, const uint8_t *ip, uint8_t plen, const uint8_t *gw, const uint8_t *dns1, const uint8_t *dns2, uint32_t mtu) { (void)up; (void)ip; (void)plen; (void)gw; (void)dns1; (void)dns2; (void)mtu; }

static int opmode = 5, reads, set_online;
static uint64_t online_at, ipa_on_at;
static uint32_t q_port[16], q_len[16];
static uint8_t q_msg[16][300];
static int q_n;

static void
tlv_put(uint8_t *m, uint32_t *n, uint8_t t, const void *v, uint16_t l)
{
	m[*n] = t;
	memcpy(m + *n + 1, &l, 2);
	memcpy(m + *n + 3, v, l);
	*n += 3u + l;
}

static bool
modem(uint32_t src, const void *data, uint32_t len)
{
	const uint8_t *d = data;
	uint16_t txn, msg, r[2] = { 0, 0 }, l;
	uint8_t *m = q_msg[q_n];
	uint32_t n = 7;

	if (src < 0x4010 || src > 0x4014 || len < 7 || q_n >= 16) {
		return false;
	}
	memcpy(&txn, d + 1, 2);
	memcpy(&msg, d + 3, 2);
	m[0] = 2;
	memcpy(m + 1, &txn, 2);
	memcpy(m + 3, &msg, 2);
	tlv_put(m, &n, 0x02, r, 4);
	if (src == 0x4010 && msg == 0x2F) {             /* card status: SIM1 USIM ready, session already there */
		static const uint8_t cs[] = { 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 1, 1, 0, 3, 10, 0, 1, 2, 7, 0, 0, 0, 0, 1, 0xA0, 0, 1, 3, 10, 0, 3, 10, 0 };
		tlv_put(m, &n, 0x10, cs, sizeof(cs));
	} else if (src == 0x4013 && msg == 0x2D) {
		uint8_t v = (uint8_t)(++reads > 2 && opmode == 5 ? (opmode = 1) : opmode);
		tlv_put(m, &n, 0x01, &v, 1);
	} else if (src == 0x4013 && msg == 0x2E) {
		set_online++;
		online_at = kt_now_ns;
		opmode = 0;
	} else if (src == 0x4011 && msg == 0x24) {
		const uint8_t ss[6] = { 1, 1, 1, 2, 1, 8 }, plmn[] = { 0x94, 0x01, 45, 0, 1, 'A' };
		tlv_put(m, &n, 0x01, ss, 6);
		tlv_put(m, &n, 0x12, plmn, sizeof(plmn));
	} else if (src == 0x4011 && msg == 0x4F) {
		const uint8_t lte[6] = { (uint8_t)(int8_t)-71, 0, (uint8_t)(int16_t)-90, 0xFF, 0, 0 };
		tlv_put(m, &n, 0x14, lte, 6);
	}
	l = (uint16_t)(n - 7);
	memcpy(m + 5, &l, 2);
	q_port[q_n] = src;
	q_len[q_n++] = n;
	return true;
}

static void
run(unsigned ms)
{
	for (unsigned i = 0; i < ms; i++) {
		kt_now_ns += 1000000ull;
		for (int k = 0, c = q_n; k < c; k++) {
			static uint8_t b[300];
			memcpy(b, q_msg[k], q_len[k]);
			uint32_t p = q_port[k], l = q_len[k];
			if (k == c - 1) {
				q_n = 0;
			}
			(void)laurel_cell_rx(p, b, l);
		}
		laurel_cell_poll(true, true);
		laurel_ipa_poll(true, true);
		if (ipa_on_at == 0 && laurel_ipa_state(NULL)) {
			ipa_on_at = kt_now_ns;
		}
	}
}

static void
services(void)
{
	static const uint32_t s[][2] = { { 0x0B, 0x30 }, { 0x03, 0x31 }, { 0x02, 0x32 }, { 0x01, 0x33 } };

	for (unsigned i = 0; i < 4; i++) {
		laurel_cell_server(s[i][0], 0x101, 0, s[i][1], true);
	}
	laurel_ipa_server(LIPA_QMI_SVC, LIPA_QMI_INST_MODEM, 0, 0x19, true);
}

int
main(void)
{
	int bad = 0;

	gate_qrtr_more = modem;
	for (int i = 0; i < 3; i++) {
		pid_t p = fork();
		if (p == 0) {
			uint8_t b[32];
			kt_now_ns = 5000000000ull;
			if (i == 0) {
				scen = "IPA on, then ONLINE";
				services();
				run(30000);
				CHECK(reads >= 3 && set_online == 0);   /* mode read again (5, then low power); no ONLINE: the IPA is not on */
				CHECK(sent_init == 1);
				CHECK(strstr(log_text, "LAUREL CELL: part: SIM1 present (USIM ready), SIM2 absent; modem low power; radio off: AP IPA side still starting") != NULL);
				(void)laurel_ipa_rx(0, 0x19, LIPA_PORT_CLIENT, b, resp(b, 2, 0x21));
				(void)laurel_ipa_rx(0, 0x34, LIPA_PORT_SERVER, b, resp(b, 0, 0x35));
				run(45000);
				CHECK(strstr(log_text, "LAUREL IPA: on: v4.2") != NULL);
				CHECK(set_online == 1 && online_at >= ipa_on_at);
				CHECK(strstr(log_text, "LAUREL CELL: on: SIM1 present (USIM ready), SIM2 absent; modem online; SIM1 registered 404-45 A LTE") != NULL);
			} else if (i == 1) {
				scen = "modem assert after INIT_MODEM_DRIVER";
				services();
				run(5000);
				CHECK(sent_init == 1 && set_online == 0);
				laurel_cell_off("modem crashed: ipa_hal.c:6001");
				laurel_ipa_off("modem crashed: ipa_hal.c:6001");
				run(30000);
				CHECK(set_online == 0 && !laurel_ipa_state(NULL));
				CHECK(strstr(log_text, "LAUREL CELL: off: modem crashed: ipa_hal.c:6001") != NULL);
				CHECK(strstr(log_text, "LAUREL IPA: off: modem crashed: ipa_hal.c:6001") != NULL);
			} else {
				scen = "ipa=0";
				boot_ipa = 0;
				services();
				run(40000);
				CHECK(sent_init == 0 && sent_server == 0 && set_online == 0);
				CHECK(strstr(log_text, "radio off: AP IPA side off: boot-arg ipa=0") != NULL);
				CHECK(strstr(log_text, "LAUREL IPA: off: boot-arg ipa=0") != NULL);
			}
			exit(0);
		}
		int st = 0;
		waitpid(p, &st, 0);
		bad += !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
	}
	fprintf(stdout, bad == 0 ? "ok: IPA + cell: 3 scenarios: ONLINE only after LAUREL IPA: on; assert and ipa=0 leave the radio off\n" : "ipa_cell_test: %d failed\n", bad);
	return bad != 0;
}
