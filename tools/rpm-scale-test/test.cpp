// Host test of laurel_rpm_scale.h, the text of patches/laurel/xnu/2985 (scripts/laurel/test-rpm-scale.sh cuts it out). The fake RPM holds the rules read in the stock rpm.mbn
// (docs/laurel_sprout/gpu.md "RPM scaling"): a gated node keeps its state while /clk/dcvs.ena is 0; at 1 it takes the highest vote of its masters, and no vote is the lowest level.
#include <cstdint>
#include <cstdio>
#include <map>
#include <string>
#include <tuple>
#include <vector>
#include "laurel_rpm_scale.h"

static int errors;
static void bad(const std::string &m) { if (errors++ < 20) printf("FAIL %s\n", m.c_str()); }

using Res = std::pair<uint32_t, uint32_t>;
static struct RPM {
	std::map<Res, uint32_t> act, slp;       // KHz votes of the AP
	bool scaling = false, scaling_sleep = false;
	int writes = 0, fail_at = -1;
	uint32_t ddr_khz = 1353600;
	std::vector<std::tuple<uint32_t, Res, uint32_t, uint32_t>> log;
	bool ignores = false;                   // the "read does not rise" case
	uint32_t ddr_read() const { return ddr_khz / 1000; }
} *r;

// the DDR table of the firmware [V rpm.mbn: 0x9516c], rows from 200000 to 1804800 kHz; a vote takes the first row at or above it
static uint32_t level(uint32_t khz) {
	static const uint32_t t[] = { 200000, 300000, 451200, 547200, 681600, 768000, 1017600, 1353600, 1555200, 1804800 };
	for (uint32_t v : t) if (v >= khz) return v;
	return 1804800;
}

static void apply() {
	if (r->scaling && !r->ignores) {
		auto it = r->act.find({ RS_CLK2, 0 });
		r->ddr_khz = level(it == r->act.end() ? 0 : it->second);
	}
}

static bool w(uint32_t set, uint32_t type, uint32_t id, uint32_t key, uint32_t value) {
	if (r->writes++ == r->fail_at) return false;
	r->log.push_back({ set, { type, id }, key, value });
	if (type == RS_CLK0 && id == RS_SCALING_ID && key == RS_KEY_ENAB) {
		(set == RS_SET_ACTIVE ? r->scaling : r->scaling_sleep) = value != 0;
	} else if (key == RS_KEY_KHZ) {
		(set == RS_SET_ACTIVE ? r->act : r->slp)[{ type, id }] = value;
	} else {
		bad("a key that stock does not send here");
	}
	apply();
	return true;
}
static uint32_t ddr() { return r->ddr_read(); }
static uint32_t waited;
static void wait_ms(uint32_t ms) { waited += ms; }
static const rs_ops ops = { w, ddr, wait_ms };

// what must hold at the moment the active Enab goes out: every clock has its votes in both sets; else the firmware takes that node to its lowest level
static void check_order(const RPM &x) {
	size_t en = 0;
	for (size_t i = 0; i < x.log.size(); i++) {
		if (std::get<1>(x.log[i]) == Res(RS_CLK0, RS_SCALING_ID)) { en = i; break; }
	}
	if (en == 0) { bad("no Enab"); return; }
	if (std::get<0>(x.log[en]) != RS_SET_SLEEP) bad("Enab: the sleep set must come first");
	if (en + 2 != x.log.size() || std::get<0>(x.log[en + 1]) != RS_SET_ACTIVE) bad("Enab: active set last, nothing after it");
	if (std::get<3>(x.log[0]) != RS_BIMC_FIRST || std::get<1>(x.log[0]) != Res(RS_CLK2, 0) || std::get<0>(x.log[0]) != RS_SET_ACTIVE) bad("first message: BIMC INT_MAX active");
	for (uint32_t i = 0; i < RS_N; i++) {
		size_t at = 1 + i * 2;
		if (at + 1 >= en) { bad(std::string(rs_clocks[i].name) + ": no vote before Enab"); continue; }
		Res res{ rs_clocks[i].type, rs_clocks[i].id };
		if (std::get<1>(x.log[at]) != res || std::get<1>(x.log[at + 1]) != res) bad(std::string(rs_clocks[i].name) + ": out of the stock order");
		if (std::get<0>(x.log[at]) != RS_SET_ACTIVE || std::get<0>(x.log[at + 1]) != RS_SET_SLEEP) bad(std::string(rs_clocks[i].name) + ": active set first, then sleep");
		if (std::get<3>(x.log[at]) != RS_TOP_KHZ || std::get<3>(x.log[at + 1]) != RS_TOP_KHZ) bad(std::string(rs_clocks[i].name) + ": not the top vote");
	}
}

int main() {
	// the whole path
	{
		RPM x; r = &x; const char *why = "";
		if (!rs_enable(&ops, &why)) bad("the normal path failed");
		check_order(x);
		if (!x.scaling || !x.scaling_sleep) bad("scaling not on in both sets");
		if (x.ddr_read() != 1804) bad("the top vote does not give 1804");
		uint32_t got = rs_read_rise(&ops, 1355);
		if (got != 1804) bad("the read after the enable");
		printf("ok    normal path: %zu messages, DDR 1353 -> %u MHz\n", x.log.size(), got);
	}
	// each message refused or with no ack: nothing after it, and no active Enab unless it was that one
	int n = 2 + 2 * (int)RS_N + 1;
	for (int i = 0; i < n + 1; i++) {
		RPM x; r = &x; x.fail_at = i; const char *why = "";
		bool ok = rs_enable(&ops, &why);
		if (ok != (i >= n)) bad("a failed message at " + std::to_string(i) + " gave the wrong result");
		if (!ok && x.log.size() != (size_t)i) bad("messages after a failure at " + std::to_string(i));
		if (!ok && (x.scaling)) bad("scaling on after a failure at " + std::to_string(i));
		if (!ok && x.ddr_read() != 1353) bad("DDR moved with no enable");
		if (!ok && why[0] == 0) bad("no reason");
	}
	printf("ok    %d failure points: no later message, no active Enab, DDR stays\n", n);
	// the votes before the enable move nothing
	{
		RPM x; r = &x; x.ignores = true; const char *why = "";
		(void)rs_enable(&ops, &why);
		waited = 0;
		uint32_t got = rs_read_rise(&ops, 1355);
		if (got >= 1355 * 11 / 10) bad("a read with no rise counts as a rise");
		if (waited < RS_READ_MS) bad("the read gave up early");
		printf("ok    no rise: read %u MHz after %u ms: off\n", got, waited);
	}
	// the Gold table: laurel_rpm_scale.h against cpu4_cpu_ddr_latmon, ddr4-map; levels of the firmware
	struct { uint32_t g, d; } g[] = { { 300, 451 }, { 902, 451 }, { 1056, 1017 }, { 1401, 1017 }, { 1420, 1555 }, { 1804, 1555 }, { 1805, 1804 }, { 2016, 1804 } };
	for (auto &e : g) {
		if (rs_gold_bus(e.g) != e.d) bad("gold " + std::to_string(e.g) + " MHz: " + std::to_string(rs_gold_bus(e.g)));
	}
	// votes in MHz x 1000 come to the row they mean
	struct { uint32_t mhz, row; } l[] = { { 1353, 1353600 }, { 1555, 1555200 }, { 1804, 1804800 }, { 1017, 1017600 }, { 451, 451200 } };
	for (auto &e : l) {
		if (level(e.mhz * 1000) != e.row) bad("the vote of " + std::to_string(e.mhz));
	}
	printf("ok    Gold table and vote rounding\n");
	if (errors) { printf("FAIL %d\n", errors); return 1; }
	printf("PASS\n");
	return 0;
}
