/* Host test of LaurelWifiPhy.h + LaurelWifiLink.h: see scripts/laurel/wifi-phy-test.sh. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "LaurelWifiPhy.h"
#include "LaurelWifiLink.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

/* WCN3990 as the firmware may say it: 1 chain, 11a + 11g, HT with SGI, VHT with SGI80, beamformee bit set */
static const struct lw_fw fw = { .valid = true, .phy = 3, .rf_chains = 1, .ht = 0x0803 | 0x10 | 0x40, .vht = 0x00001021 | 0x10 | 0x80 };

static uint32_t
put(uint8_t *p, uint8_t id, const uint8_t *v, uint8_t n)
{
	p[0] = id;
	p[1] = n;
	memcpy(p + 2, v, n);
	return 2u + n;
}

/* a beacon's elements; sec: HT secondary (0 none, 1 above, 3 below); vw/seg0: VHT operation, vw 255: no VHT */
static uint32_t
beacon(uint8_t *b, bool ht, uint8_t sec, uint8_t vw, uint8_t seg0)
{
	uint8_t c[26] = { 0x6F, 0x09, 0x17 }, o[22] = { 44 }, vc[12] = { 0x20, 0, 0, 0x03, 0xFA, 0xFF, 0, 0, 0xFA, 0xFF, 0, 0 }, vo[5] = { vw, seg0 };
	static const uint8_t wmm[24] = { 0, 0x50, 0xF2, 2, 1, 1, 0, 0, 0x03, 0xA4, 0, 0, 0x27, 0xA4, 0, 0, 0x42, 0x43, 0x5E, 0, 0x62, 0x32, 0x2F, 0 };
	uint32_t n = 0;

	c[3] = 0xFF;
	c[4] = 0xFF;                                /* 2 streams */
	o[1] = (uint8_t)(sec | (sec != 0 ? 4 : 0));
	if (ht) {
		n += put(b + n, 45, c, sizeof(c));
		n += put(b + n, 61, o, sizeof(o));
		n += put(b + n, 221, wmm, sizeof(wmm));
		if (vw != 255) {
			n += put(b + n, 191, vc, sizeof(vc));
			n += put(b + n, 192, vo, sizeof(vo));
		}
	}
	return n;
}

int
main(void)
{
	uint8_t b[256], ie[64];
	struct lw_ap ap;
	struct lw_link l;
	struct lw_rate r;
	uint32_t w[4][4], n;

	/* VHT80 on channel 44 (the owner's router, 5220 MHz): the 80 MHz block 36-48, centre 5210 */
	n = beacon(b, true, 3, 1, 42);
	lw_parse_ap(b, n, &ap);
	CHECK(ap.ht && ap.vht && ap.wmm && ap.wmm_params && ap.ht_40 && ap.ht_below);
	lw_choose(&fw, &ap, 5220, true, &l);
	CHECK(l.mode == LW_VHT80 && l.width == 80 && l.center == 5210 && l.vht && l.ht && l.qos && l.nss == 1);
	CHECK((l.peer_flags & (LW_PEER_QOS | LW_PEER_HT | LW_PEER_40 | LW_PEER_VHT | LW_PEER_80)) ==
	    (LW_PEER_QOS | LW_PEER_HT | LW_PEER_40 | LW_PEER_VHT | LW_PEER_80));
	CHECK(l.ht_rate_count == 8 && l.ht_rates[7] == 7);      /* 1 stream: MCS 0-7 of the AP's 2 streams */
	CHECK(l.vht_rx_mcs == 0xFFFE && l.vht_tx_mcs == 0xFFFE);
	CHECK(l.vht_caps & LW_VHT_SGI80);
	CHECK(l.max_mpdu == 524287 && l.density == 4);      /* the AP: VHT exponent 6, HT density code 5 */
	/* a primary channel outside the VHT block says the element is wrong: 40 MHz stays */
	lw_choose(&fw, &ap, 5300, true, &l);
	CHECK(l.mode == LW_VHT40 && l.width == 40 && l.center == 5290);
	/* the old 160 MHz form */
	n = beacon(b, true, 3, 2, 50);
	lw_parse_ap(b, n, &ap);
	lw_choose(&fw, &ap, 5220, true, &l);
	CHECK(l.mode == LW_VHT80 && l.center == 5210);
	/* HT40 only, secondary above, channel 36 */
	n = beacon(b, true, 1, 255, 0);
	lw_parse_ap(b, n, &ap);
	lw_choose(&fw, &ap, 5180, true, &l);
	CHECK(l.mode == LW_HT40_5G && l.center == 5190 && l.width == 40 && !l.vht);
	/* 2.4 GHz: 20 MHz even if the AP offers 40 */
	lw_choose(&fw, &ap, 2432, true, &l);
	CHECK(l.mode == LW_HT20_2G && l.center == 2432 && l.width == 20 && l.ht && l.qos);
	/* no HT in the beacon, or HT not allowed: legacy, as before these patches */
	n = beacon(b, false, 0, 255, 0);
	lw_parse_ap(b, n, &ap);
	lw_choose(&fw, &ap, 5220, true, &l);
	CHECK(l.mode == LW_11A && !l.ht && !l.qos && l.peer_flags == 0 && l.center == 5220);
	lw_choose(&fw, &ap, 2432, true, &l);
	CHECK(l.mode == LW_11G && !l.ht);
	n = beacon(b, true, 3, 1, 42);
	lw_parse_ap(b, n, &ap);
	lw_choose(&fw, &ap, 5220, false, &l);
	CHECK(l.mode == LW_11A && !l.ht && !l.qos && l.peer_flags == 0);
	/* firmware without HT */
	{
		struct lw_fw nh = fw;

		nh.ht = 0;
		lw_choose(&nh, &ap, 5220, true, &l);
		CHECK(!l.ht && l.mode == LW_11A);
	}
	/* a truncated element is not read past the end (the address sanitizer watches) */
	lw_parse_ap(b, 5, &ap);
	lw_parse_ap(b, 0, &ap);
	/* our elements */
	CHECK(lw_put_ht_cap(ie, &fw, true) == ie + 28);
	CHECK(ie[0] == 45 && ie[1] == 26 && (ie[2] & 0x2) != 0 && (ie[2] & 0x0C) == 0x0C && ie[4] == 27 && ie[5] == 0xFF && ie[6] == 0 && ie[17] == 1);
	CHECK(lw_put_ht_cap(ie, &fw, false) == ie + 28 && (ie[2] & 0x2) == 0 && (ie[2] & 0x40) == 0);
	CHECK(lw_put_vht_cap(ie, &fw) == ie + 14);
	CHECK(ie[0] == 191 && ie[1] == 12 && ie[6] == 0xFE && ie[7] == 0xFF && (ie[3] & 0x10) == 0);    /* no beamformee bit, TX STBC off */
	CHECK((ie[2] & 0x80) == 0);
	CHECK(lw_put_wmm(ie) == ie + 9 && ie[0] == 221 && ie[1] == 7 && ie[8] == 0);
	/* WMM: the AP's record for BE: AIFSN 3, ECW 4/10 */
	lw_wmm_values(&ap, w);
	CHECK(w[0][0] == 15 && w[0][1] == 1023 && w[0][2] == 3 && w[3][3] == 47);
	memset(&ap, 0, sizeof(ap));
	lw_wmm_values(&ap, w);
	CHECK(w[2][0] == 7 && w[2][3] == 94);
	/* rates (ath10k_htt_rx_h_rates fields) */
	lw_rate_decode(0x08u << 24, 7, 1u << 7, &r);
	CHECK(r.kind == 1 && r.mcs == 7 && r.mbps10 == 722 && r.width == 20 && r.sgi);
	lw_rate_decode(0x0Cu << 24, 2, (9u << 4) | 1, &r);
	CHECK(r.kind == 2 && r.mcs == 9 && r.mbps10 == 4333 && r.width == 80);
	lw_rate_decode(0x04u << 24 | 4, 0, 0, &r);
	CHECK(r.kind == 0 && r.mbps10 == 540);
	lw_rate_decode(0x04u << 24 | 1u << 4, 0, 0, &r);
	CHECK(r.kind == 0 && r.mbps10 == 110);
	printf(fails == 0 ? "wifi-phy-test: all checks passed\n" : "wifi-phy-test: %d checks FAILED\n", fails);
	return fails != 0;
}
