// Host test of laurel_gpu_opp.h, the text of patches/laurel/xnu/2961 (scripts/laurel/test-gpu-opp.sh cuts it out). A fake GPU clock block checks at
// each write what must hold on the phone: no rate above its rails, no RCG on a dead or wrong PLL, no change of a running PLL. Every pair of levels
// runs, with a failure at each step.
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static int scnprintf(char *s, size_t n, const char *f, ...) {
	va_list a;
	va_start(a, f);
	int r = vsnprintf(s, n, f, a);
	va_end(a);
	if (r < 0) return 0;
	return (size_t)r >= n ? (int)n - 1 : r;
}
#include "laurel_gpu_opp.h"

static int errors;
static void bad(const std::string &m) { if (errors++ < 20) printf("FAIL %s\n", m.c_str()); }
static void eq(uint32_t got, uint32_t want, const char *what) { if (got != want) bad(std::string(what) + ": got " + std::to_string(got) + ", want " + std::to_string(want)); }

static struct HW {
	uint32_t cx = CX_NOM, ddr = 0, rate = 0;
	bool ipeak = false;
	struct { bool on = false; uint32_t vco = 0; } pll[2];
	int src = OPP_NO_PLL;
	const struct laurel_opp *rcg = nullptr;
	std::vector<std::string> log;
	int n = 0, fail_at = -1;        // the fail_at-th fallible step fails
	bool fail_after = false;        // and all after it
	bool cx_low_refused = false;
	bool cx_lost_ack = false;       // the RPM takes the vote, the ack does not come: false, but the rail moved
	bool fail() { int k = n++; if (k == fail_at || (fail_after && fail_at >= 0 && k > fail_at)) { return true; } return false; }
} hw;

static bool f_ipeak(bool on) {
	if (on && hw.fail()) { hw.log.push_back("ipeak+ refused"); return false; }
	if (on && hw.ipeak) bad("iPeak voted twice");
	hw.ipeak = on;
	hw.log.push_back(on ? "ipeak+" : "ipeak-");
	return true;
}
static bool f_ddr(uint32_t m) {
	if (hw.fail()) { hw.log.push_back("ddr refused"); return false; }
	hw.ddr = m;
	hw.log.push_back("ddr " + std::to_string(m));
	return true;
}
static bool f_cx(uint32_t c) {
	if (hw.cx_lost_ack) { hw.cx = c; hw.log.push_back("cx lost ack " + std::to_string(c)); return false; }
	if (hw.fail()) { hw.log.push_back("cx refused"); if (c < hw.cx) hw.cx_low_refused = true; return false; }
	hw.cx = c;
	hw.log.push_back("cx " + std::to_string(c));
	return true;
}
static bool f_pll_on(const struct laurel_opp *o) {
	if (o->pll == OPP_NO_PLL) { bad("pll_on with no PLL"); return true; }
	if (hw.pll[o->pll].on) bad("a running PLL programmed: " + std::to_string(o->mhz));
	if (hw.src == o->pll) bad("the RCG's PLL programmed: " + std::to_string(o->mhz));
	if (hw.fail()) { hw.log.push_back("lock failed"); return false; }
	hw.pll[o->pll].on = true;
	// 19.2 MHz x (L + alpha / 2^40), in kHz
	uint64_t khz = (uint64_t)o->l * 19200 + (((uint64_t)o->alpha_u << 32 | o->alpha) * 19200 >> 40);
	hw.pll[o->pll].vco = (uint32_t)((khz + 500) / 1000);
	hw.log.push_back("pll" + std::to_string(o->pll) + " " + std::to_string(hw.pll[o->pll].vco));
	return true;
}
static void f_pll_off(int p) {
	if (hw.src == p) bad("the RCG's PLL stopped");
	hw.pll[p].on = false;
	hw.log.push_back("pll" + std::to_string(p) + " off");
}
static bool f_rcg(const struct laurel_opp *o) {
	if (hw.fail()) { hw.log.push_back("rcg refused"); return false; }
	if (o->pll != OPP_NO_PLL) {
		if (!hw.pll[o->pll].on) bad("RCG on a stopped PLL: " + std::to_string(o->mhz));
		if (hw.pll[o->pll].vco != 2u * o->mhz) bad("RCG on a PLL at " + std::to_string(hw.pll[o->pll].vco) + " for " + std::to_string(o->mhz));
	}
	if (o->mhz > hw.rate) {
		if (hw.cx < o->cx) bad("rate " + std::to_string(o->mhz) + " above its CX corner: " + std::to_string(hw.cx));
		if (o->ipeak && !hw.ipeak) bad("rate " + std::to_string(o->mhz) + " with no iPeak vote");
	}
	if (o->bus_mhz > hw.ddr && o->mhz > hw.rate && o->ipeak) bad("rate " + std::to_string(o->mhz) + " before its DDR vote");
	hw.rate = o->mhz;
	hw.src = o->pll;
	hw.rcg = o;
	hw.log.push_back("rcg " + std::to_string(o->mhz));
	return true;
}
static bool f_check(uint32_t) {
	if (hw.fail()) { hw.log.push_back("read wrong"); return false; }
	hw.log.push_back("read");
	return true;
}
static const struct opp_ops ops = { f_ipeak, f_ddr, f_cx, f_pll_on, f_pll_off, f_rcg, f_check };

static void put_on(uint32_t i, struct opp_state *st) {
	const struct laurel_opp *o = &opp_table[i];
	hw = HW();
	hw.cx = opp_cx_vote(i);
	hw.ipeak = o->ipeak;
	hw.ddr = o->bus_mhz;
	if (o->pll != OPP_NO_PLL) { hw.pll[o->pll].on = true; hw.pll[o->pll].vco = 2u * o->mhz; }
	hw.src = o->pll;
	hw.rate = o->mhz;
	hw.rcg = o;
	*st = { i, hw.cx, o->ipeak != 0, false };
}

// what must hold when opp_go has come back, whatever failed
static void after(const struct opp_state *st, const std::string &ctx) {
	const struct laurel_opp *o = &opp_table[st->cur];
	if (st->broken) return;
	if (hw.rcg != o) bad(ctx + ": st.cur " + std::to_string(o->mhz) + " is not the RCG's level " + std::to_string(hw.rate));
	if (hw.cx < opp_cx_vote(st->cur)) bad(ctx + ": rail below the stock corner");
	if (hw.cx > opp_cx_vote(st->cur) && !hw.cx_low_refused) bad(ctx + ": rail above the stock corner of " + std::to_string(o->mhz));
	if (hw.ipeak != (o->ipeak != 0)) bad(ctx + ": iPeak vote left wrong at " + std::to_string(o->mhz));
	for (int p = 0; p < 2; p++) if (hw.pll[p].on && hw.src != p) bad(ctx + ": PLL" + std::to_string(p) + " left running");
}

static void exact(uint32_t from, uint32_t to, const char *want) {
	struct opp_state st;
	const char *why = "";
	put_on(from, &st);
	hw.log.clear();
	if (!opp_go(&ops, &st, to, &why)) bad(std::string("change failed: ") + why);
	std::string got;
	for (auto &l : hw.log) got += (got.empty() ? "" : ", ") + l;
	if (got != want) bad(std::to_string(opp_table[from].mhz) + "->" + std::to_string(opp_table[to].mhz) + ": " + got + " | want: " + want);
	else printf("ok    %u -> %u: %s\n", opp_table[from].mhz, opp_table[to].mhz, got.c_str());
}

int main() {
	const uint32_t ALL = (1u << OPP_N) - 1, STOCK = ALL & ~(1u << OPP_300);
	exact(3, 7, "ipeak+, ddr 1804, cx 416, pll0 1900, rcg 950, read");
	exact(3, 4, "ddr 1353, pll0 1490, rcg 745, read");
	exact(4, 7, "ipeak+, ddr 1804, cx 416, rcg 600, pll0 off, pll0 1900, rcg 950, read");
	exact(7, 4, "rcg 600, pll0 off, pll0 1490, rcg 745, ipeak-, cx 256");
	exact(7, 1, "pll1 640, rcg 320, pll0 off, ipeak-, cx 256");
	exact(1, 2, "ddr 768, rcg 300, pll1 off, pll1 930, rcg 465, read");

	// review 2026-11-03: a lost ack on a lower vote must not leave 950 MHz on the NOM rail
	{
		struct opp_state st;
		const char *why = "";
		put_on(7, &st);
		hw.cx_lost_ack = true;
		if (!opp_go(&ops, &st, 4, &why)) bad("lower with a lost ack failed");
		hw.cx_lost_ack = false;
		if (!opp_go(&ops, &st, 7, &why)) bad(std::string("raise after a lost ack failed: ") + why);
		if (hw.cx < 416) bad("950 MHz on CX " + std::to_string(hw.cx) + " after a lost ack");
		printf("ok    lost ack: 950 MHz back on CX %u\n", hw.cx);
	}
	// review 2026-11-03: no iPeak feature: the levels stock guards with it stay out, the others stay
	for (uint32_t i = 0; i < OPP_N; i++) {
		if (opp_ipeak_refuses(&opp_table[i], true)) bad("refused with the feature");
		if (opp_ipeak_refuses(&opp_table[i], false) != (opp_table[i].mhz >= 900)) bad("iPeak rule at " + std::to_string(opp_table[i].mhz));
	}

	// every pair, every failure, single and from there on
	uint32_t runs = 0;
	for (uint32_t from = 0; from < OPP_N; from++) {
		for (uint32_t to = 0; to < OPP_N; to++) {
			if (from == to) continue;
			for (int k = -1; k < 16; k++) {
				for (int tail = 0; tail < 2; tail++) {
					struct opp_state st;
					const char *why = "";
					put_on(from, &st);
					hw.fail_at = k;
					hw.fail_after = tail;
					std::string ctx = std::to_string(opp_table[from].mhz) + "->" + std::to_string(opp_table[to].mhz) + " fail " + std::to_string(k) + (tail ? "+" : "");
					bool ok = opp_go(&ops, &st, to, &why);
					if (ok && st.cur != to) bad(ctx + ": true but not on the level");
					if (!ok && why[0] == 0) bad(ctx + ": false with no reason");
					if (k < 0 && !ok) bad(ctx + ": no failure, and false");
					if (st.broken && !(k >= 0)) bad(ctx + ": broken with no failure");
					if (!ok && to > from && hw.rate > opp_table[from].mhz && !st.broken) bad(ctx + ": a failed raise is left above the old clock");
					after(&st, ctx);
					runs++;
				}
			}
		}
	}
	printf("ok    %u changes with failures\n", runs);

	// the CX vote never above the stock corner where the GPU sets it above the held NOM
	for (uint32_t i = 0; i < OPP_N; i++) {
		if (opp_table[i].mhz > 745) eq(opp_cx_vote(i), opp_table[i].cx, "CX vote above 745");
		else eq(opp_cx_vote(i), CX_NOM, "CX vote to 745: the NOM held");
	}

	// governor
	uint32_t low = 0;
	eq(opp_table[opp_decide(1, 100, OPP_NONE, STOCK, OPP_N - 1, &low)].mhz, 950, "100 % at 320");
	eq(opp_table[opp_decide(1, 50, OPP_NONE, STOCK, OPP_N - 1, &low)].mhz, 465, "50 % at 320");
	eq(opp_table[opp_decide(3, 50, OPP_NONE, STOCK, OPP_N - 1, &low)].mhz, 745, "50 % at 600");
	eq(opp_table[opp_decide(6, 50, OPP_NONE, STOCK, OPP_N - 1, &low)].mhz, 950, "50 % at 900");
	eq(opp_table[opp_decide(1, 0, OPP_TOUCH, STOCK, OPP_N - 1, &low)].mhz, 745, "touch at 320");
	eq(opp_table[opp_decide(7, 0, OPP_TOUCH, STOCK, OPP_N - 1, &low)].mhz, 950, "touch at 950, 0 %: holds, first tick");
	low = OPP_LOWER_MS;
	eq(opp_table[opp_decide(7, 0, OPP_TOUCH, STOCK, OPP_N - 1, &low)].mhz, 745, "touch, 0 %, after 500 ms: not below 745");
	low = OPP_LOWER_MS;
	eq(opp_table[opp_decide(4, 0, OPP_TOUCH, STOCK, OPP_N - 1, &low)].mhz, 745, "touch at 745, 0 %: stays");
	eq(low, 0, "touch at 745: no count");
	// laurel 3021: a touch or a frame holds the top: 950 from 320 in one decision; the thermal cap still wins; nothing held: the old rule
	low = 0;
	eq(opp_table[opp_decide(1, 0, OPP_HOLD_TOP, STOCK, OPP_N - 1, &low)].mhz, 950, "UI hold at 320, 0 %: the top at once");
	eq(opp_table[opp_decide(3, 0, OPP_HOLD_TOP, STOCK, OPP_N - 1, &low)].mhz, 950, "UI hold at 600: the top");
	eq(opp_table[opp_decide(7, 0, OPP_HOLD_TOP, STOCK, OPP_N - 1, &low)].mhz, 950, "UI hold at 950, 0 %: stays");
	eq(low, 0, "UI hold at 950: no lower count");
	low = OPP_LOWER_MS;
	eq(opp_table[opp_decide(7, 0, OPP_HOLD_TOP, STOCK, OPP_N - 1, &low)].mhz, 950, "UI hold, 0 %, after 500 ms: still the top");
	eq(opp_table[opp_decide(1, 0, OPP_HOLD_TOP, STOCK, 5, &low)].mhz, 820, "UI hold under a thermal cap of 820: 820");
	eq(opp_table[opp_decide(1, 0, OPP_HOLD_TOP, STOCK & ~(1u << 7), OPP_N - 1, &low)].mhz, 900, "950 out: the UI hold takes the highest left");
	eq(opp_table[opp_decide(OPP_300, 0, OPP_HOLD_TOP, OPP_GPLL0_ONLY, OPP_N - 1, &low)].mhz, 600, "fallback: UI hold at 300 gives 600");
	low = 0;
	eq(opp_table[opp_decide(1, 0, OPP_NONE, STOCK, OPP_N - 1, &low)].mhz, 320, "no hold, 0 % at 320: stays");
	eq(OPP_HOLD_TOP, OPP_N - 1, "OPP_HOLD_TOP is the last level");
	eq(OPP_NONE, OPP_N, "OPP_NONE is past the table");
	// lower only after 500 ms without a break
	low = 0;
	for (uint32_t t = 0; t + OPP_TICK_MS < OPP_LOWER_MS; t += OPP_TICK_MS) eq(opp_decide(7, 0, OPP_NONE, STOCK, OPP_N - 1, &low), 7, "no lower before 500 ms");
	eq(opp_table[opp_decide(7, 0, OPP_NONE, STOCK, OPP_N - 1, &low)].mhz, 320, "after 500 ms at 0 %");
	low = 0;
	(void)opp_decide(7, 10, OPP_NONE, STOCK, OPP_N - 1, &low);
	(void)opp_decide(7, 60, OPP_NONE, STOCK, OPP_N - 1, &low);
	eq(low, 0, "a busy tick breaks the count");
	// no ping-pong: a steady amount of work settles on one level from any start
	for (uint32_t work = 1; work <= 950; work += 7) {
		for (uint32_t start = 1; start < OPP_N; start++) {
			uint32_t cur = start, changes = 0, l = 0;
			for (int t = 0; t < 400; t++) {
				uint32_t pct = work * 100 / opp_table[cur].mhz;
				uint32_t n = opp_decide(cur, pct > 100 ? 100 : pct, OPP_NONE, STOCK, OPP_N - 1, &l);
				if (n != cur && t > 100) changes++;
				cur = n;
			}
			if (changes != 0) bad("ping-pong at work " + std::to_string(work) + " from " + std::to_string(opp_table[start].mhz));
		}
	}
	// the fallback path acts as 2892: 300 <-> 600
	low = 0;
	eq(opp_table[opp_decide(OPP_300, 50, OPP_NONE, OPP_GPLL0_ONLY, OPP_N - 1, &low)].mhz, 600, "fallback: 50 % at 300");
	eq(opp_table[opp_decide(OPP_300, 0, OPP_TOUCH, OPP_GPLL0_ONLY, OPP_N - 1, &low)].mhz, 600, "fallback: touch at 300");
	eq(opp_table[opp_decide(7, 100, OPP_NONE, OPP_GPLL0_ONLY, OPP_N - 1, &low)].mhz, 600, "a level taken out: down to the highest left");
	eq(opp_table[opp_decide(5, 100, OPP_NONE, STOCK & ~(1u << 6) & ~(1u << 7), OPP_N - 1, &low)].mhz, 820, "900, 950 out: 820 is the top");

	// thermal: Android's limits
	struct opp_thermal th = { (uint32_t)OPP_N - 1, false };
	if (opp_thermal_tick(&th, 949, 7, STOCK)) bad("94.9 C is not hot");
	eq(th.cap, 7, "cap at 94.9 C");
	if (!opp_thermal_tick(&th, 950, 7, STOCK)) bad("95 C is hot");
	eq(th.cap, 6, "95 C: one level down");
	(void)opp_thermal_tick(&th, 950, 6, STOCK);
	eq(th.cap, 5, "95 C again: one more level");
	if (opp_thermal_tick(&th, 900, 5, STOCK)) bad("90 C after 95 C is not hot");
	eq(th.cap, 6, "below the trip: one level up");
	(void)opp_thermal_tick(&th, 1000, 6, STOCK);
	eq(th.cap, 1, "100 C: the lowest level");
	if (!opp_thermal_tick(&th, 960, 1, STOCK)) bad("96 C after 100 C: still held (hysteresis 5 C)");
	eq(th.cap, 1, "96 C after 100 C");
	(void)opp_thermal_tick(&th, 949, 1, STOCK);
	eq(th.cap, 2, "below 95 C after 100 C: one level up");
	(void)opp_thermal_tick(&th, -1000, 2, STOCK);
	eq(th.cap, 1, "no reading: the lowest level");
	th = { (uint32_t)OPP_N - 1, false };
	(void)opp_thermal_tick(&th, 960, 7, STOCK);
	low = 0;
	eq(opp_table[opp_decide(7, 100, OPP_NONE, STOCK, th.cap, &low)].mhz, 900, "hot: down at once");
	th = { 4, false };
	(void)opp_thermal_tick(&th, 960, 4, STOCK);
	eq(opp_table[opp_decide(1, 100, OPP_NONE, STOCK, th.cap, &low)].mhz, 600, "hot: a raise stays under the cap");

	// the DDR floor
	eq(opp_ddr_snap(1355), 1353, "boot read 1355 is level 1353");
	eq(opp_ddr_snap(1400), 1400, "not a level");

	// reads: 900 and 950 must differ
	if (!opp_read_right(300, 298) || !opp_read_right(600, 598) || !opp_read_right(600, 588)) bad("boot 11's reads must pass");
	if (opp_read_right(950, 900) || opp_read_right(900, 950) || opp_read_right(900, 820)) bad("a read must tell the levels apart");

	// the self-check line: longest case fits one kernel log line (255 bytes)
	{
		uint16_t g[OPP_N], c[OPP_N];
		char s[400];
		for (uint32_t i = 0; i < OPP_N; i++) g[i] = c[i] = 9999;
		const char *why = "0123456789012345678901234567890123456789012345";
		int all = opp_on_line(s, sizeof(s), STOCK, g, c, 99999, true, "");
		int out = opp_on_line(s, sizeof(s), 1u << OPP_300 | 1u << OPP_600, g, c, 99999, false, why);
		printf("ok    self-check line: %d bytes with all levels, %d with levels out\n", all, out);
		if (all > 255 || out > 255) bad("a self-check line above 255 bytes");
		opp_on_line(s, sizeof(s), STOCK, g, c, 99999, true, "");
		printf("      %s\n", s);
	}

	printf(errors ? "gpu-opp: FAIL (%d)\n" : "gpu-opp: PASS\n", errors);
	return errors ? 1 : 0;
}
