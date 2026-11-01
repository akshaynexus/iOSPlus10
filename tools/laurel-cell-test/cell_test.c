/*
 * Host test of bsd/dev/laurel_cell.c (patch 2760, the cellular QMI client). Run: scripts/laurel/test-cell.sh
 * The kernel file is included as is; a simulated modem answers its QMI requests (UIM, DMS, NAS, WDS) with
 * the TLV layouts of libqmi. Each scenario runs in its own process (fresh static state).
 */
#include "kstub.h"
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

uint64_t kt_now_ns;
static char said[16][600];                      /* LAUREL CELL lines */
static int nsaid;
static char logbuf[16384];
static uint32_t boot_cell = 1, boot_cell_data = 1;

int
kt_printf(const char *fmt, ...)
{
	char b[800];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(b, sizeof(b), fmt, ap);
	va_end(ap);
	if (strncmp(b, "LAUREL CELL: ", 13) == 0 && nsaid < 16) {
		snprintf(said[nsaid++], sizeof(said[0]), "%s", b);
	}
	strncat(logbuf, b, sizeof(logbuf) - strlen(logbuf) - 1);
	return 0;
}

int
PE_parse_boot_argn(const char *name, void *val, int size)
{
	if (strcmp(name, "cell") == 0 && size == 4) {
		memcpy(val, &boot_cell, 4);
		return 1;
	}
	if (strcmp(name, "cell_data") == 0 && size == 4) {
		memcpy(val, &boot_cell_data, 4);
		return 1;
	}
	return 0;
}

/* ---------------------------------------------------------------- simulated modem */

static struct {
	struct { int card; uint8_t type, state; } sim[2];   /* card 0 absent 1 present */
	uint16_t idx[2];                                    /* GW primary/secondary (0xFFFF none) */
	int opmode;
	bool wide_bind_only, uim_silent, register_ok;
	int prov_reqs, prov_session[4], prov_slot[4], set_online, binds[2];
	int opmode_reads, opmode_err_left, opmode_later, opmode_after;   /* GET_OPERATING_MODE: errors first; the mode changes after opmode_after reads */
	int set_refuse_left, bind_err_left[2], rsrp, rssi_only;          /* SET refused; BIND error 3; signal */
	bool no_signal, mode_sticky;
	int set_lpm, lpm_refuse, event_reports;                          /* laurel 2940: SET low power; its error; SET_EVENT_REPORT with mode reporting */
	uint32_t dpm_pipes[2];                                           /* laurel 2942: the data session */
	int wda_sets, wda_err, wds_bind[2], wds_family[2], wds_start[2], start_family[2], start_err[2], wds_mux;
	bool online_after_format;
} M;
static int m_fails;
#define CHECK_M(c) do { if (!(c)) { fprintf(stderr, "FAIL modem check line %d: %s\n", __LINE__, #c); m_fails++; } } while (0)
static uint32_t q_port[32], q_len[32];
static uint8_t q_msg[32][512];
static int q_n;

static void
put_tlv(uint8_t *m, uint32_t *n, uint8_t t, const void *v, uint16_t l)
{
	m[*n] = t;
	memcpy(m + *n + 1, &l, 2);
	memcpy(m + *n + 3, v, l);
	*n += 3u + l;
}

static void
answer(uint32_t port, uint8_t type, uint16_t txn, uint16_t msg, uint16_t err, const uint8_t *tl, uint32_t tlen)
{
	uint8_t *m = q_msg[q_n];
	uint32_t n = 7;
	uint16_t r[2] = { (uint16_t)(err ? 1 : 0), err };

	m[0] = type;
	memcpy(m + 1, &txn, 2);
	memcpy(m + 3, &msg, 2);
	if (type == 2) {
		put_tlv(m, &n, 0x02, r, 4);
	}
	memcpy(m + n, tl, tlen);
	n += tlen;
	uint16_t l = (uint16_t)(n - 7);
	memcpy(m + 5, &l, 2);
	q_port[q_n] = port;
	q_len[q_n] = n;
	q_n++;
}

static uint32_t
card_status_tlv(uint8_t *o)
{
	uint8_t v[256];
	uint32_t n = 0, t = 0;
	static const uint8_t aid[] = { 0xA0, 0x00, 0x00, 0x00, 0x87, 0x10, 0x02 };

	memcpy(v + n, &M.idx[0], 2); n += 2;
	v[n++] = 0xFF; v[n++] = 0xFF;                       /* 1x primary */
	memcpy(v + n, &M.idx[1], 2); n += 2;
	v[n++] = 0xFF; v[n++] = 0xFF;                       /* 1x secondary */
	v[n++] = 2;                                         /* cards */
	for (int s = 0; s < 2; s++) {
		v[n++] = (uint8_t)M.sim[s].card;
		v[n++] = 0; v[n++] = 3; v[n++] = 10; v[n++] = 0;  /* upin state, retries, error */
		v[n++] = M.sim[s].card == 1 ? 1 : 0;            /* apps */
		if (M.sim[s].card == 1) {
			v[n++] = M.sim[s].type; v[n++] = M.sim[s].state;
			v[n++] = 0; v[n++] = 0; v[n++] = 0; v[n++] = 0;
			v[n++] = sizeof(aid);
			memcpy(v + n, aid, sizeof(aid)); n += sizeof(aid);
			v[n++] = 0; v[n++] = 1; v[n++] = 3; v[n++] = 10; v[n++] = 0; v[n++] = 3; v[n++] = 10;
		}
	}
	put_tlv(o, &t, 0x10, v, (uint16_t)n);
	return t;
}

/* laurel_cell.c -> modem */
void
topaz_qrtr_data(uint32_t src_port, uint32_t node, uint32_t port, const void *data, uint32_t len)
{
	const uint8_t *d = data;
	uint16_t txn, msg, l;
	uint8_t tl[400] = { 0 };
	uint32_t tn = 0;

	(void)node; (void)port;
	if (len < 7 || d[0] != 0) {
		return;
	}
	memcpy(&txn, d + 1, 2);
	memcpy(&msg, d + 3, 2);
	memcpy(&l, d + 8, 2);                               /* length of the first TLV */
	switch (src_port) {
	case 0x4010:                                        /* UIM */
		if (M.uim_silent) {
			return;
		}
		if (msg == 0x002F) {
			tn = card_status_tlv(tl);
		} else if (msg == 0x0038) {
			uint8_t session = d[10], slot = d[15];
			M.prov_session[M.prov_reqs & 3] = session;
			M.prov_slot[M.prov_reqs & 3] = slot;
			M.prov_reqs++;
			M.idx[session == 0 ? 0 : 1] = (uint16_t)((slot - 1) << 8);
		}
		answer(src_port, 2, txn, msg, 0, tl, tn);
		break;
	case 0x4013:                                        /* DMS */
		if (msg == 0x0001) {
			M.event_reports += d[7] == 0x14 && d[10] == 1;
		} else if (msg == 0x0020) {
			static const uint8_t cap[14] = { 0x00, 0x75, 0x12, 0x03, 0x00, 0x10, 0x5E, 0x5F, 1, 1, 3, 4, 5, 8 };
			put_tlv(tl, &tn, 0x01, cap, sizeof(cap));
		} else if (msg == 0x0023) {
			put_tlv(tl, &tn, 0x01, "MPSS.AT.4.3.1.c1-00047", 22);
		} else if (msg == 0x002D) {
			uint8_t m;
			M.opmode_reads++;
			if (M.opmode_err_left > 0) {
				M.opmode_err_left--;
				answer(src_port, 2, txn, msg, 0x4A, tl, 0);
				return;
			}
			if (M.opmode_after != 0 && M.opmode_reads > M.opmode_after) {
				M.opmode = M.opmode_later;
				M.opmode_after = 0;
			}
			m = (uint8_t)M.opmode;
			put_tlv(tl, &tn, 0x01, &m, 1);
			{
				uint16_t why = 0;
				put_tlv(tl, &tn, 0x10, &why, 2);
				put_tlv(tl, &tn, 0x11, &m, 1);
			}
		} else if (msg == 0x002E && d[10] == 1) {
			M.set_lpm++;
			if (M.lpm_refuse != 0) {
				answer(src_port, 2, txn, msg, (uint16_t)M.lpm_refuse, tl, 0);
				return;
			}
			if (!M.mode_sticky) {
				M.opmode = 1;
			}
		} else if (msg == 0x002E) {
			M.set_online++;
			if (M.set_refuse_left != 0) {
				M.set_refuse_left--;
				answer(src_port, 2, txn, msg, 0x34, tl, 0);
				return;
			}
			if (!M.mode_sticky) {
				M.opmode = 0;
			}
			M.online_after_format = M.wda_sets > 0;
		}
		answer(src_port, 2, txn, msg, 0, tl, tn);
		break;
	case 0x4011:
	case 0x4012: {                                      /* NAS */
		int sub = src_port == 0x4011 ? 0 : 1;
		if (msg == 0x0045) {
			if (M.wide_bind_only && l != 4) {
				answer(src_port, 2, txn, msg, 0x0001, tl, 0);
				return;
			}
			if (M.bind_err_left[sub] > 0) {
				M.bind_err_left[sub]--;
				answer(src_port, 2, txn, msg, 0x0003, tl, 0);
				return;
			}
			M.binds[sub]++;
		} else if (msg == 0x0024) {
			uint8_t ss[6] = { (uint8_t)(M.register_ok ? 1 : 2), 1, 1, 2, 1, 8 };
			uint8_t plmn[5 + 6] = { 0x94, 0x01, 45, 0, 6, 'A', 'i', 'r', 't', 'e', 'l' };   /* 404 */
			put_tlv(tl, &tn, 0x01, ss, 6);
			put_tlv(tl, &tn, 0x12, plmn, sizeof(plmn));
		} else if (msg == 0x004F) {
			int16_t rsrp = (int16_t)M.rsrp, snr = 50;
			uint8_t lte[6] = { (uint8_t)(int8_t)-71, (uint8_t)(int8_t)-10 };
			memcpy(lte + 2, &rsrp, 2);
			memcpy(lte + 4, &snr, 2);
			if (!M.no_signal) {
				put_tlv(tl, &tn, 0x14, lte, 6);
			}
		}
		answer(src_port, 2, txn, msg, 0, tl, tn);
		break;
	}
	case 0x4014:                                        /* WDS */
		put_tlv(tl, &tn, 0x14, "airtelgprs.com", 14);
		answer(src_port, 2, txn, msg, 0, tl, tn);
		break;
	case 0x4017:                                        /* laurel 2942: DPM */
		if (d[7] == 0x11 && d[10] == 1) {
			uint32_t w[4];
			memcpy(w, d + 11, 16);
			CHECK_M(w[0] == 4 && w[1] == 1);
			M.dpm_pipes[0] = w[2];
			M.dpm_pipes[1] = w[3];
		}
		answer(src_port, 2, txn, msg, 0, tl, 0);
		break;
	case 0x4018: {                                      /* WDA */
		uint32_t link = 2, ul = 5;
		M.wda_sets++;
		put_tlv(tl, &tn, 0x11, &link, 4);
		put_tlv(tl, &tn, 0x12, &ul, 4);
		put_tlv(tl, &tn, 0x13, &ul, 4);
		answer(src_port, 2, txn, msg, (uint16_t)M.wda_err, tl, tn);
		break;
	}
	case 0x4019:
	case 0x401A: {                                      /* WDS, one client per family */
		int f = src_port == 0x4019 ? 0 : 1;
		if (msg == 0x00A2) {
			M.wds_bind[f]++;
			M.wds_mux = d[21];                  /* TLV 0x10 (3 + 8 bytes), then TLV 0x11 */
		} else if (msg == 0x004D) {
			M.wds_family[f] = d[10];
		} else if (msg == 0x0020) {
			uint32_t h = 0x1000u + (uint32_t)f;
			uint16_t reason = 12;
			M.wds_start[f]++;
			M.start_family[f] = d[10];
			if (M.start_err[f] != 0) {
				put_tlv(tl, &tn, 0x10, &reason, 2);
				answer(src_port, 2, txn, msg, (uint16_t)M.start_err[f], tl, tn);
				return;
			}
			put_tlv(tl, &tn, 0x01, &h, 4);
		} else if (msg == 0x002D && f == 0) {
			uint32_t v;
			v = 0x0A000002; put_tlv(tl, &tn, 0x1E, &v, 4);
			v = 0xFFFFFFFC; put_tlv(tl, &tn, 0x21, &v, 4);
			v = 0x0A000001; put_tlv(tl, &tn, 0x20, &v, 4);
			v = 0x08080808; put_tlv(tl, &tn, 0x15, &v, 4);
			v = 1430;       put_tlv(tl, &tn, 0x29, &v, 4);
		} else if (msg == 0x002D) {
			uint8_t a[17] = { 0x24, 0x01 }, g[17] = { 0xFE, 0x80 }, n1[16] = { 0x20, 0x01 };
			uint32_t v = 1430;
			a[15] = 2; a[16] = 64; g[15] = 1; g[16] = 64; n1[15] = 0x88;
			put_tlv(tl, &tn, 0x25, a, 17);
			put_tlv(tl, &tn, 0x26, g, 17);
			put_tlv(tl, &tn, 0x27, n1, 16);
			put_tlv(tl, &tn, 0x29, &v, 4);
		}
		answer(src_port, 2, txn, msg, 0, tl, tn);
		break;
	}
	default:
		break;
	}
}

uint32_t
topaz_qrtr_services(void)
{
	return 7;
}

/* laurel 2780: the IPA state (laurel_ipa.c in the kernel); a scenario sets test_ipa_on */
static bool test_ipa_on;
bool laurel_ipa_state(const char **why);
bool
laurel_ipa_state(const char **why)
{
	*why = test_ipa_on ? "" : "AP IPA side still starting (QMI 0x31 INIT_MODEM_DRIVER not done): ONLINE without it "
	    "can crash the modem and with it Wi-Fi";
	return test_ipa_on;
}

/* laurel 2942: the AP pipes and the interface are stand-ins here; data_test.c tests the pipes. Default: no pipes, as an image without them */
static int test_data_state = -1;
int
laurel_ipa_data_state(const char **why)
{
	if (why != NULL) {
		*why = "no AP GSI data pipes yet";
	}
	return test_data_state;
}
static struct { bool up; uint32_t ip, mask, gw, dns1, dns2, mtu; } P4;
static struct { bool up; uint8_t ip[16], plen, gw[16], dns1[16], dns2[16]; uint32_t mtu; } P6;
void
laurel_pdp_set4(bool up, uint32_t ip, uint32_t mask, uint32_t gw, uint32_t dns1, uint32_t dns2, uint32_t mtu)
{
	P4.up = up; P4.ip = ip; P4.mask = mask; P4.gw = gw; P4.dns1 = dns1; P4.dns2 = dns2; P4.mtu = mtu;
}
void
laurel_pdp_set6(bool up, const uint8_t *ip, uint8_t plen, const uint8_t *gw, const uint8_t *dns1, const uint8_t *dns2, uint32_t mtu)
{
	P6.up = up;
	if (up) {
		memcpy(P6.ip, ip, 16); P6.plen = plen; memcpy(P6.gw, gw, 16); memcpy(P6.dns1, dns1, 16); memcpy(P6.dns2, dns2, 16); P6.mtu = mtu;
	}
}

#include "laurel_cell.c"
#include "laurel_cell_data.c"
#include "laurel_pdp_text.h"
#undef printf
#include "cellbar_state.h"
#include "celld_net.h"

/* ---------------------------------------------------------------- driver */

static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s line %d: %s\n", scen, __LINE__, #c); fails++; } } while (0)
static const char *scen;

static void
run_ms(unsigned ms, bool ready)
{
	for (unsigned i = 0; i < ms; i++) {
		kt_now_ns += 1000000ull;
		int n = q_n;
		q_n = 0;
		uint32_t port[32], len[32];
		static uint8_t msg[32][512];
		memcpy(port, q_port, sizeof(port));
		memcpy(len, q_len, sizeof(len));
		memcpy(msg, q_msg, sizeof(msg));
		for (int k = 0; k < n; k++) {
			CHECK(laurel_cell_rx(port[k], msg[k], len[k]));
		}
		laurel_cell_poll(ready, ready);
	}
}

static void
services(bool uim)
{
	if (uim) {
		laurel_cell_server(0x0B, 0x101, 0, 0x30, true);
	}
	laurel_cell_server(0x03, 0x101, 0, 0x31, true);
	laurel_cell_server(0x02, 0x101, 0, 0x32, true);
	laurel_cell_server(0x01, 0x101, 0, 0x33, true);
	laurel_cell_server(0x45, 0x101, 0, 0x34, true);     /* WLFW: not ours */
}

static void
data_services(void)
{
	laurel_cell_server(0x2F, 0x101, 0, 0x40, true);
	laurel_cell_server(0x1A, 0x101, 0, 0x41, true);
}

static const char *
last(void)
{
	return nsaid ? said[nsaid - 1] : "";
}

static void
modem_defaults(void)
{
	memset(&M, 0, sizeof(M));
	M.idx[0] = M.idx[1] = 0xFFFF;
	M.opmode = 1;                                       /* low power after boot */
	M.register_ok = true;
	M.rsrp = -98;
	kt_now_ns = 5000000000ull;
}

#include "cell_test2.h"
#include "cell_test3.h"

static void
scenario(char s)
{
	modem_defaults();
	switch (s) {
	case 'A':       /* SIM1 USIM ready, SIM2 empty, no auto provisioning, no IPA: radio stays off */
		scen = "A one SIM, low power";
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		run_ms(10, false);
		services(true);
		run_ms(30000, true);
		CHECK(nsaid == 1);
		CHECK(strstr(last(), "LAUREL CELL: part: SIM1 present (USIM ready), SIM2 absent; modem low power; radio off: AP IPA side still starting") != NULL);
		CHECK(M.prov_reqs == 1 && M.prov_session[0] == 0 && M.prov_slot[0] == 1);
		CHECK(M.set_online == 0);
		CHECK(M.binds[0] == 1 && M.binds[1] == 0);
		CHECK(strstr(last(), "; data off: no AP GSI data pipes yet; SMS, voice off: not built") != NULL);
		CHECK(strstr(logbuf, "modem revision MPSS.AT.4.3.1") != NULL);
		{
			char out[400];
			struct sysctl_req r = { out, sizeof(out), NULL, 0 };
			CHECK(cell_sysctl(NULL, NULL, 0, &r) == 0 && strncmp(out, "part: SIM1 present", 18) == 0);
		}
		break;
	case 'B':       /* both SIMs, NAS bind needs the 4-byte enum: primary slot 1, secondary slot 2 */
		scen = "B dual SIM";
		M.sim[0].card = 1; M.sim[0].type = 2; M.sim[0].state = 7;
		M.sim[1].card = 1; M.sim[1].type = 1; M.sim[1].state = 2;
		M.wide_bind_only = true;
		services(true);
		run_ms(30000, true);
		CHECK(M.prov_reqs == 2);
		CHECK(M.prov_session[0] == 0 && M.prov_slot[0] == 1);
		CHECK(M.prov_session[1] == 2 && M.prov_slot[1] == 2);
		CHECK(M.binds[0] == 1 && M.binds[1] == 1);
		CHECK(strstr(last(), "part: SIM1 present (USIM ready), SIM2 present (SIM PIN required); modem low power") != NULL);
		break;
	case 'C':       /* IPA up (step 2 self-check), SIM only in slot 2: online, registered, signal; then hot swap */
		scen = "C online + hot swap";
		test_ipa_on = true;
		M.sim[1].card = 1; M.sim[1].type = 2; M.sim[1].state = 7;
		services(true);
		run_ms(40000, true);
		CHECK(M.prov_reqs == 1 && M.prov_session[0] == 0 && M.prov_slot[0] == 2);
		CHECK(M.set_online == 1);
		CHECK(strstr(last(), "on: SIM1 absent, SIM2 present (USIM ready); modem online; SIM2 registered 404-45 Airtel LTE rssi -71 rsrp -98 bars 2") != NULL);
		{
			int before = nsaid;
			uint8_t ind[400];
			uint32_t n;
			M.sim[1].card = 0; M.idx[0] = 0xFFFF;
			n = card_status_tlv(ind);
			answer(0x4010, 4, 0, 0x0032, 0, ind, n);
			run_ms(15000, true);
			CHECK(nsaid == before + 1);
			CHECK(strstr(last(), "on: SIM1 absent, SIM2 absent; modem online") != NULL);
		}
		break;
	case 'D':       /* no UIM service */
		scen = "D no UIM";
		services(false);
		run_ms(61000, true);
		CHECK(strstr(last(), "LAUREL CELL: off: modem up, no QMI UIM service in 60 s (7 QRTR services)") != NULL);
		break;
	case 'E':       /* UIM does not answer */
		scen = "E UIM silent";
		M.uim_silent = true;
		services(true);
		run_ms(25000, true);
		CHECK(strstr(last(), "LAUREL CELL: off: UIM service does not answer") != NULL);
		break;
	case 'F':       /* kill switch */
		scen = "F cell=0";
		boot_cell = 0;
		services(true);
		run_ms(1000, true);
		CHECK(nsaid == 1 && strstr(last(), "LAUREL CELL: off: boot-arg cell=0") != NULL);
		CHECK(q_n == 0);
		break;
	case 'G':       /* modem never READY, then a modem failure must not print a second line */
		scen = "G not ready";
		run_ms(91000, false);
		CHECK(strstr(last(), "LAUREL CELL: off: modem not READY") != NULL);
		laurel_cell_off("modem crashed: x");
		CHECK(nsaid == 1);
		break;
	case 'H':       /* no SIM at all: on, no provisioning, radio stays as it is */
		scen = "H no SIM";
		services(true);
		run_ms(20000, true);
		CHECK(strstr(last(), "LAUREL CELL: part: SIM1 absent, SIM2 absent; modem low power") != NULL);
		CHECK(M.prov_reqs == 0 && M.set_online == 0);
		break;
	default:
		scenario2(s);
		scenario3(s);
		break;
	}
	fails += m_fails;
	if (fails) {
		fprintf(stderr, "---- log of %s:\n%s", scen, logbuf);
	} else {
		printf("ok   %s: %s", scen, last());
	}
	exit(fails ? 1 : 0);
}

int
main(void)
{
	const char *all = "ABCDEFGHIJKLMNOPQRSTUVW";
	int bad = 0;

	for (const char *p = all; *p; p++) {
		pid_t pid = fork();
		if (pid == 0) {
			scenario(*p);
		}
		int st = 0;
		waitpid(pid, &st, 0);
		bad += !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
	}
	printf("laurel-cell-test: %d of %zu scenarios failed\n", bad, strlen(all));
	return bad ? 1 : 0;
}
