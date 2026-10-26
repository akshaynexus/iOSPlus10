/*
 * Host test for the Wi-Fi patches 0320-0323: the QMI WLAN_CFG / WLAN_MODE / HOST_CAP(gpios) encodings
 * (negroni_wlfw_tables.h + the 0266 coder), the HTC READY parser (negroni_wlan_ce.c), the HTC header and
 * trailer parsers, the WMI TLV walk and the 802.11 beacon parser (negroni_wlan_wmi.c). Run it with
 *   scripts/wifi/wmi-host-test.sh TREE          (TREE = a patched tree, scripts/kernel/patched-tree.sh)
 * Checks exact sizes / bytes, refusal of every truncated or over-long input, then random and mutated input
 * under ASan/UBSan (every length field the chip sends is bounds-checked).
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include "negroni_wlfw_tables.h"
#include "negroni_wlan_ce.h"
#include "negroni_wlan_wmi.h"
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(1);} } while (0)
static uint8_t buf[16384];

static void
put32(uint8_t *p, uint32_t v)
{
	memcpy(p, &v, 4);
}

int
main(void)
{
	uint32_t len;

	/* WLAN_CFG: 7 + host_version (3+3) + tgt (3+1+9*20) + svc (3+1+14*12) + shadow v2 (3+1+30*4) = 493 */
	static struct wlfw_wlan_cfg_req c;
	memset(&c, 0, sizeof c);
	c.host_version_valid = 1; strcpy(c.host_version, WLFW_HOST_VERSION);
	c.tgt_cfg_valid = 1; c.tgt_cfg_len = WLAN_CE_TGT_N;
	for (uint32_t i = 0; i < WLAN_CE_TGT_N; i++) {
		c.tgt_cfg[i].pipe_num = wlan_ce_tgt_cfg[i].pipe; c.tgt_cfg[i].pipe_dir = wlan_ce_tgt_cfg[i].dir;
		c.tgt_cfg[i].nentries = wlan_ce_tgt_cfg[i].nentries; c.tgt_cfg[i].nbytes_max = wlan_ce_tgt_cfg[i].nbytes_max;
		c.tgt_cfg[i].flags = wlan_ce_tgt_cfg[i].flags;
	}
	c.svc_cfg_valid = 1; c.svc_cfg_len = WLAN_CE_SVC_N;
	for (uint32_t i = 0; i < WLAN_CE_SVC_N; i++) {
		c.svc_cfg[i].service_id = wlan_ce_svc_map[i].service; c.svc_cfg[i].pipe_dir = wlan_ce_svc_map[i].dir;
		c.svc_cfg[i].pipe_num = wlan_ce_svc_map[i].pipe;
	}
	c.shadow_reg_v2_valid = 1; c.shadow_reg_v2_len = WLAN_SHADOW_N;
	memcpy(c.shadow_reg_v2, wlan_shadow_v2, sizeof wlan_shadow_v2);
	CHECK(!negroni_qmi_encode(&wlfw_wlan_cfg_req_d, QMI_REQUEST, 3, &c, buf, sizeof buf, &len));
	printf("WLAN_CFG %u bytes (v01 max 803 + 7)\n", len);
	CHECK(len == 493 && len - 7 <= 803);
	CHECK(buf[3] == 0x23 && buf[7] == 0x10 && buf[8] == 3 && !memcmp(buf + 10, "WIN", 3));
	CHECK(buf[13] == 0x11 && buf[16] == 9);                         /* tgt_cfg: 9 entries */
	uint32_t pd; memcpy(&pd, buf + 17 + 20 * 4 + 4, 4); CHECK(pd == WLAN_PIPEDIR_OUT);   /* CE4 dir */
	CHECK(buf[17 + 180] == 0x12 && buf[17 + 183] == 14);           /* svc_cfg: 14 entries */
	uint32_t o = 17 + 180 + 4 + 168;
	CHECK(buf[o] == 0x14 && buf[o + 3] == 30);
	uint32_t sh; memcpy(&sh, buf + o + 4 + 4 * WLAN_SHADOW_CE0_SRC, 4); CHECK(sh == 0x01b80400u);
	memcpy(&sh, buf + o + 4 + 4 * WLAN_SHADOW_CE2_STS, 4); CHECK(sh == 0x01b8540cu);
	c.shadow_reg_v2_len = 37; CHECK(negroni_qmi_encode(&wlfw_wlan_cfg_req_d, 0, 3, &c, buf, sizeof buf, &len) == EINVAL);
	/* WLAN_MODE mission: 01 04 00 00000000, 10 01 00 00 */
	struct wlfw_wlan_mode_req m = { .mode = 0, .hw_debug_valid = 1 };
	CHECK(!negroni_qmi_encode(&wlfw_wlan_mode_req_d, 0, 4, &m, buf, sizeof buf, &len));
	static const uint8_t exp_m[] = { 0, 4, 0, 0x22, 0, 11, 0, 1, 4, 0, 0, 0, 0, 0, 0x10, 1, 0, 0 };
	CHECK(len == sizeof exp_m && !memcmp(buf, exp_m, len));
	/* HOST_CAP Android: gpios TLV 0x12 = u8 count 1 + u32 0x38242f00, feature_list 7 */
	struct wlfw_host_cap_req hc; memset(&hc, 0, sizeof hc);
	hc.gpios_valid = 1; hc.gpios_len = 1; hc.gpios[0] = WLFW_GPIO_WSA_20847; hc.feature_list_valid = 1; hc.feature_list = 7;
	CHECK(!negroni_qmi_encode(&wlfw_host_cap_req_d, 0, 5, &hc, buf, sizeof buf, &len));
	static const uint8_t exp_h[] = { 0, 5, 0, 0x34, 0, 19, 0, 0x12, 5, 0, 1, 0x00, 0x2f, 0x24, 0x38, 0x27, 8, 0, 7, 0, 0, 0, 0, 0, 0, 0 };
	CHECK(len == sizeof exp_h && !memcmp(buf, exp_h, len));

	/* HTC READY: eid 0, payload 12: READY | 1 credit << 16, size 2048 | 3 endpoints << 16, version 1 */
	uint8_t r[20] = { 0 };
	put32(r, 0 | (12u << 16)); put32(r + 8, 1 | (1u << 16)); put32(r + 12, 2048 | (3u << 16)); put32(r + 16, 1 | (8u << 8));
	struct negroni_wlan_htc_ready rd;
	CHECK(!negroni_wlan_htc_parse_ready(r, 20, 2, &rd) && rd.credits == 1 && rd.credit_size == 2048 && rd.max_endpoints == 3 &&
	    rd.extended && rd.version == 1 && rd.max_bundle == 8 && rd.pipe == 2);
	CHECK(negroni_wlan_htc_parse_ready(r, 19, 2, &rd) == EBADMSG);  /* payload past the buffer */
	r[0] = 1; CHECK(negroni_wlan_htc_parse_ready(r, 20, 2, &rd) == EBADMSG); r[0] = 0;
	r[8] = 2; CHECK(negroni_wlan_htc_parse_ready(r, 20, 2, &rd) == EBADMSG); r[8] = 1;

	/* HTC frame with a credit trailer: payload 4 + trailer 8 (record 1, len 4: eid 2 +1 credit) */
	uint8_t h[20] = { 0 };
	put32(h, 2 | (HTC_FLAG_TRAILER << 8) | (12u << 16)); put32(h + 4, 8);
	put32(h + 8, 0xdeadbeef); h[12] = HTC_RECORD_CREDITS; h[13] = 4; h[16] = 2; h[17] = 1;
	struct htc_frame f;
	CHECK(!negroni_htc_parse(h, 20, &f) && f.eid == 2 && f.payload_len == 4 && f.trailer_len == 8);
	uint32_t cr[HTC_EP_COUNT] = { 0 };
	CHECK(!negroni_htc_trailer_credits(f.trailer, f.trailer_len, cr) && cr[2] == 1);
	h[13] = 5; CHECK(negroni_htc_trailer_credits(h + 12, 8, cr) == EBADMSG); h[13] = 4;
	put32(h + 4, 13); CHECK(negroni_htc_parse(h, 20, &f) == EBADMSG); put32(h + 4, 8);       /* trailer > payload */
	put32(h, 9 | (12u << 16)); CHECK(negroni_htc_parse(h, 20, &f) == EBADMSG);               /* eid 9 */
	put32(h, 2 | (13u << 16)); CHECK(negroni_htc_parse(h, 20, &f) == EBADMSG);               /* payload past the end */

	/* WMI TLV walk */
	uint8_t w[24] = { 0 };
	put32(w, (0x23u << 16) | 4); put32(w + 8, (0x11u << 16) | 8); put32(w + 20, (0x10u << 16) | 4);
	struct wmi_tlv_it it = { w, w + 24 };
	uint32_t tag, l; const uint8_t *v; int n = 0, rr;
	while ((rr = negroni_wmi_tlv_next(&it, &tag, &v, &l)) == 1) n++;
	CHECK(n == 2 && rr == -1);              /* the third TLV runs past the end */

	/* beacon: SSID "HomeNet", DS channel 6, RSN */
	uint8_t bc[128] = { 0x80, 0 };
	memcpy(bc + 16, "\x11\x22\x33\x44\x55\x66", 6); bc[32] = 100; bc[34] = 0x11;
	uint32_t p = 36;
	bc[p++] = 0; bc[p++] = 7; memcpy(bc + p, "HomeNet", 7); p += 7;
	bc[p++] = 3; bc[p++] = 1; bc[p++] = 6;
	bc[p++] = 48; bc[p++] = 2; bc[p++] = 1; bc[p++] = 0;
	struct wlan_bss b;
	CHECK(!negroni_wlan_beacon_parse(bc, p, &b) && !strcmp(b.ssid, "HomeNet") && b.channel == 6 && b.rsn && !b.hidden &&
	    b.beacon_int == 100 && b.bssid[5] == 0x66);
	CHECK(negroni_wlan_beacon_parse(bc, p - 1, &b) == EBADMSG);     /* the last element cut */
	bc[37] = 33; CHECK(negroni_wlan_beacon_parse(bc, 128, &b) == EBADMSG); bc[37] = 7;
	bc[0] = 0x08; CHECK(negroni_wlan_beacon_parse(bc, p, &b) == ENOENT); bc[0] = 0x50;
	CHECK(!negroni_wlan_beacon_parse(bc, p, &b));                    /* probe response */

	/* fuzz: every parser over random and mutated input */
	static uint8_t fz[4096]; srand(7);
	for (int i = 0; i < 400000; i++) {
		uint32_t nlen = rand() % 300;
		for (uint32_t k = 0; k < nlen; k++) fz[k] = rand() % (i & 1 ? 256 : 16);
		uint8_t *in = malloc(nlen ? nlen : 1); memcpy(in, fz, nlen);
		if (!negroni_htc_parse(in, nlen, &f)) {
			CHECK(f.payload + f.payload_len <= in + nlen);
			if (f.trailer) { CHECK(f.trailer + f.trailer_len <= in + nlen); (void)negroni_htc_trailer_credits(f.trailer, f.trailer_len, cr); }
		}
		(void)negroni_wlan_htc_parse_ready(in, nlen, 1, &rd);
		struct wmi_tlv_it t2 = { in, in + nlen };
		while (negroni_wmi_tlv_next(&t2, &tag, &v, &l) == 1) CHECK(v + l <= in + nlen);
		(void)negroni_wlan_beacon_parse(in, nlen, &b);
		free(in);
	}
	for (int i = 0; i < 300000; i++) {
		uint8_t t[128]; memcpy(t, bc, sizeof t); t[rand() % p] = rand();
		uint32_t nlen = rand() % (p + 1); uint8_t *in = malloc(nlen ? nlen : 1); memcpy(in, t, nlen);
		if (!negroni_wlan_beacon_parse(in, nlen, &b)) CHECK(strlen(b.ssid) <= 32);
		free(in);
	}
	printf("ALL PASS\n");
	return 0;
}
