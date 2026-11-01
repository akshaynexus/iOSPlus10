/*
 * The real bsd/dev/redwood_apple80211.c of the 12377 tree on the host, with a fake station side. Requests and answers are raw bytes at
 * the offsets read in IO80211.framework of N104AP 23F84 (this table is not made of the driver's structs: a wrong struct shows here).
 * What it can not show: that wifid is content on a phone. Run: scripts/laurel/test-apple80211.sh.
 */
#define KERNEL 1
#include "stub.h"

int stub_fault;
char stub_log[1 << 16];
size_t stub_log_at;

#include "redwood_apple80211.c"

#undef printf

/* ---- offsets as the disassembly has them: not the driver's ---- */
enum {
	REQ_SIZE = 5528, REQ_SSIDLEN = 0x10, REQ_SSID = 0x14, REQ_TYPE = 0x34, REQ_DWELL = 0x3c, REQ_COUNT = 0x44, REQ_CHANNELS = 0x48, REQ_UUID = 0x154c,
	RES_SIZE = 2272, RES_CHANNEL = 8, RES_CHFLAGS = 12, RES_RSSI = 22, RES_BEACON = 24, RES_CAP = 26, RES_BSSID = 28, RES_RATECOUNT = 34, RES_RATES = 36,
	RES_SSIDLEN = 96, RES_SSID = 97, RES_AGE = 132, RES_ELEMLEN = 138, RES_ELEMENTS = 140, RES_UUID = 2188,
	ASC_SIZE = 908, ASC_MODE = 4, ASC_AUTHL = 8, ASC_AUTHU = 0xc, ASC_SSIDLEN = 0x10, ASC_SSID = 0x14, ASC_BSSID = 0x34, ASC_KEYLEN = 0x40, ASC_CIPHER = 0x44, ASC_KEY = 0x4c,
	LINK_SIZE = 32, LINK_DOWN = 0, LINK_RSSI = 4, LINK_INVOLUNTARY = 16, LINK_REASON = 20,
};

static unsigned checks, failures;
static unsigned group_checks;
#define CHECK(cond, ...) do { checks++; group_checks++; if (!(cond)) { failures++; printf("  FAIL %s:%d: ", __func__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)
static void
group(const char *name)
{
	printf("%-26s %u checks\n", name, group_checks);
	group_checks = 0;
}

static uint32_t rd32(const uint8_t *b, size_t at) { uint32_t v; memcpy(&v, b + at, 4); return v; }
static uint16_t rd16(const uint8_t *b, size_t at) { uint16_t v; memcpy(&v, b + at, 2); return v; }
static void wr32(uint8_t *b, size_t at, uint32_t v) { memcpy(b + at, &v, 4); }
static void wr16(uint8_t *b, size_t at, uint16_t v) { memcpy(b + at, &v, 2); }

/* ---- the fake station ---- */
static struct redwood_sta_bss heard_list[8];
static unsigned heard_n;
static struct redwood_sta_state fake_state;
static struct redwood_sta_scan last_scan;
static unsigned scans_asked;
static struct redwood_sta_join last_join;
static unsigned joins_asked;

bool redwood_sta_present(void) { return true; }
bool redwood_sta_powered(void) { return true; }
int redwood_sta_ask_power(bool on) { (void)on; return 0; }
int redwood_sta_ask_scan(const struct redwood_sta_scan *what) { last_scan = *what; scans_asked++; return 0; }
int redwood_sta_ask_join(const struct redwood_sta_join *what) { last_join = *what; joins_asked++; return 0; }
int redwood_sta_ask_leave(void) { return 0; }
bool redwood_sta_heard(unsigned index, struct redwood_sta_bss *bss) { if (index >= heard_n) { return false; } *bss = heard_list[index]; return true; }
void redwood_sta_state(struct redwood_sta_state *state) { *state = fake_state; }
unsigned redwood_sta_channels(struct redwood_sta_channel *c, unsigned most) { (void)most; c[0] = (struct redwood_sta_channel){ 2412, 0 }; return 1; }

static uint32_t event_code[32], event_len[32];
static uint8_t event_data[32][64];
static unsigned events;
int
kev_post_msg(struct kev_msg *m)
{
	if (events < 32) {
		event_code[events] = m->event_code;
		event_len[events] = m->dv[1].data_length;
		if (m->dv[1].data_length != 0 && m->dv[1].data_length <= 64) {
			memcpy(event_data[events], m->dv[1].data_ptr, m->dv[1].data_length);
		}
		events++;
	}
	return 0;
}

/* ---- as the framework calls ---- */
static int
ask(bool is_set, int32_t type, void *data, uint32_t len, int32_t *value)
{
	struct apple80211req r;
	int e;

	memset(&r, 0, sizeof(r));
	memcpy(r.req_if_name, "en0", 4);
	r.req_type = type;
	r.req_len = len;
	r.req_data = (user_addr_t)(uintptr_t)data;
	e = redwood_apple80211_ioctl(is_set ? SIOCSA80211 : SIOCGA80211, &r);
	if (value != NULL) {
		*value = r.req_val;
	}
	return e;
}

static struct redwood_sta_bss
bss_at(unsigned freq, int rssi, const char *name, const uint8_t *elements, unsigned n)
{
	struct redwood_sta_bss b;

	memset(&b, 0, sizeof(b));
	b.bssid[0] = 0x02;
	b.bssid[5] = (uint8_t)freq;
	b.ssid_length = (uint8_t)strlen(name);
	memcpy(b.ssid, name, strlen(name));
	b.frequency = (uint16_t)freq;
	b.rssi = (int16_t)rssi;
	b.beacon_interval = 100;
	b.capability = 0x431;
	b.age_ms = 77;
	b.elements_length = (uint16_t)n;
	memcpy(b.elements, elements, n);
	return b;
}

static void
put_channel(uint8_t *req, unsigned i, unsigned number, unsigned flags)
{
	wr32(req, REQ_CHANNELS + 12 * i, 1);
	wr32(req, REQ_CHANNELS + 12 * i + 4, number);
	wr32(req, REQ_CHANNELS + 12 * i + 8, flags);
}

/* one SCAN_RESULT; returns the error */
static int
result(uint8_t *res, const char *uuid, uint16_t room)
{
	memset(res, 0, RES_SIZE);
	wr16(res, RES_ELEMLEN, room);
	if (uuid != NULL) {
		strncpy((char *)res + RES_UUID, uuid, 64);
	}
	return ask(false, 11, res, RES_SIZE, NULL);
}

static void
test_scan(void)
{
	static uint8_t req[REQ_SIZE], res[RES_SIZE];
	const char *uuid = "6B29FC40-CA47-1067-B31D-00DD010662DA";

	/* a size that is not 23F84's */
	CHECK(ask(true, 10, req, 5456, NULL) == EINVAL, "5456 bytes must be refused");
	/* passive kept: type 2 listens, type 1 does not; name, dwell, channels from the raw offsets */
	memset(req, 0, sizeof(req));
	wr32(req, REQ_SSIDLEN, 4);
	memcpy(req + REQ_SSID, "home", 4);
	wr32(req, REQ_TYPE, 2);
	wr16(req, REQ_DWELL, 33);
	wr32(req, REQ_COUNT, 2);
	put_channel(req, 0, 1, 0x8 | 0x2);
	put_channel(req, 1, 36, 0x10 | 0x2);
	strcpy((char *)req + REQ_UUID, uuid);
	CHECK(ask(true, 10, req, REQ_SIZE, NULL) == 0, "5528 bytes accepted");
	CHECK(last_scan.passive, "scan type 2 stays passive");
	CHECK(!last_scan.no_radio, "real channels use the radio");
	CHECK(last_scan.ssid_length == 4 && !memcmp(last_scan.ssid, "home", 4), "name at +0x14");
	CHECK(last_scan.dwell_ms == 33, "dwell at +0x3c");
	CHECK(last_scan.frequency_count == 2 && last_scan.frequencies[0] == 2412 && last_scan.frequencies[1] == 5180, "channels at +0x48");
	wr32(req, REQ_TYPE, 1);
	CHECK(ask(true, 10, req, REQ_SIZE, NULL) == 0 && !last_scan.passive, "scan type 1 is not passive");
	group("scan request");

	/* the result, every field at the offset of __addScanResultToList */
	static const uint8_t elements[] = { 0, 4, 'h', 'o', 'm', 'e', 1, 2, 0x82, 0x0c, 7, 6, 'D', 'E', ' ', 1, 13, 20 };
	heard_list[0] = bss_at(2412, -40, "home", elements, sizeof(elements));
	heard_list[1] = bss_at(5180, -60, "five", elements, sizeof(elements));
	heard_list[2] = bss_at(2437, -70, "six", elements, sizeof(elements));
	heard_n = 3;
	wr32(req, REQ_COUNT, 0);
	CHECK(ask(true, 10, req, REQ_SIZE, NULL) == 0, "scan of every channel");
	CHECK(result(res, uuid, 2048) == 0, "a result");
	CHECK(rd32(res, RES_CHANNEL) == 1, "channel at +8: %u", rd32(res, RES_CHANNEL));
	CHECK(rd32(res, RES_CHFLAGS) & 0x8, "channel flags at +12");
	CHECK((int16_t)rd16(res, RES_RSSI) == -40, "rssi at +22");
	CHECK(rd16(res, RES_BEACON) == 100, "beacon at +24");
	CHECK(rd16(res, RES_CAP) == 0x431, "capability at +26");
	CHECK(res[RES_BSSID] == 2, "bssid at +28");
	CHECK(res[RES_RATECOUNT] == 2 && rd32(res, RES_RATES) == 1 && rd32(res, RES_RATES + 4) == 6, "rates at +34 and +36");
	CHECK(res[RES_SSIDLEN] == 4 && !memcmp(res + RES_SSID, "home", 4), "name at +96 and +97");
	CHECK(rd32(res, RES_AGE) == 77, "age at +132");
	CHECK(rd16(res, RES_ELEMLEN) == sizeof(elements) && !memcmp(res + RES_ELEMENTS, elements, sizeof(elements)), "elements at +138 and +140");
	CHECK(!strcmp((char *)res + RES_UUID, uuid), "the UUID of the request at +2188");
	CHECK(result(res, NULL, 2048) == 0 && !strcmp((char *)res + RES_UUID, uuid), "no UUID in the request: the one of the last scan");
	CHECK(result(res, "OTHER", 2048) == 0 && !strcmp((char *)res + RES_UUID, "OTHER"), "the UUID the caller gave stays");
	CHECK(result(res, uuid, 2048) == EIO, "EIO after the last result");
	/* a UUID with no end cannot run past its field */
	wr32(req, REQ_COUNT, 0);
	memset(req + REQ_UUID, 'A', 64);
	CHECK(ask(true, 10, req, REQ_SIZE, NULL) == 0, "scan");
	CHECK(result(res, NULL, 2048) == 0 && strlen((char *)res + RES_UUID) == 63, "the UUID is cut at 63");
	strcpy((char *)req + REQ_UUID, uuid);
	/* room for elements */
	CHECK(ask(true, 10, req, REQ_SIZE, NULL) == 0, "scan");
	CHECK(result(res, uuid, 4) == 0 && rd16(res, RES_ELEMLEN) == 0, "room of 4: no elements rather than a cut element");
	/* the short caller gets only what it has */
	{
		static uint8_t small[1164 + 8];

		memset(small, 0xee, sizeof(small));
		CHECK(ask(true, 10, req, REQ_SIZE, NULL) == 0, "scan");
		CHECK(ask(false, 11, small, 1164, NULL) == 0, "short buffer");
		CHECK(small[1164] == 0xee && small[1171] == 0xee, "nothing past the caller's length");
	}
	group("scan result");

	/* the split scan: a stage of 6 GHz alone (the case of redwood_apple80211.c:544, EINVAL before) */
	wr32(req, REQ_COUNT, 2);
	put_channel(req, 0, 37, 0x2000 | 0x2);
	put_channel(req, 1, 69, 0x2000 | 0x2);
	events = 0;
	unsigned before = scans_asked;
	CHECK(ask(true, 10, req, REQ_SIZE, NULL) == 0, "the 6 GHz stage is accepted");
	CHECK(scans_asked == before + 1 && last_scan.no_radio, "it goes to the station thread with no_radio");
	redwood_apple80211_event(REDWOOD_STA_SCAN_DONE, 0);
	CHECK(events == 1 && event_code[0] == EVENT_SCAN_DONE, "the stage ends with the scan event");
	CHECK(result(res, uuid, 2048) == EIO, "the 6 GHz stage has no results");
	/* then a stage of 2.4 GHz: the older 5 GHz entry of the list is not its result */
	wr32(req, REQ_COUNT, 2);
	put_channel(req, 0, 1, 0x8 | 0x2);
	put_channel(req, 1, 6, 0x8 | 0x2);
	CHECK(ask(true, 10, req, REQ_SIZE, NULL) == 0 && !last_scan.no_radio && last_scan.frequency_count == 2, "the 2.4 GHz stage");
	redwood_apple80211_event(REDWOOD_STA_SCAN_DONE, 0);
	CHECK(result(res, uuid, 2048) == 0 && rd32(res, RES_CHANNEL) == 1, "first of its channels");
	CHECK(result(res, uuid, 2048) == 0 && rd32(res, RES_CHANNEL) == 6, "second of its channels: 5 GHz skipped");
	CHECK(result(res, uuid, 2048) == EIO, "end of the stage");
	/* a stage of both: only the one this radio has */
	wr32(req, REQ_COUNT, 2);
	put_channel(req, 0, 36, 0x10 | 0x2);
	put_channel(req, 1, 37, 0x2000 | 0x2);
	CHECK(ask(true, 10, req, REQ_SIZE, NULL) == 0 && !last_scan.no_radio && last_scan.frequency_count == 1 && last_scan.frequencies[0] == 5180, "a mixed stage");
	CHECK(result(res, uuid, 2048) == 0 && rd32(res, RES_CHANNEL) == 36 && result(res, uuid, 2048) == EIO, "its one result");
	/* more than 64 channels: every channel, as before */
	wr32(req, REQ_COUNT, 65);
	for (unsigned i = 0; i < 65; i++) {
		put_channel(req, i, 1, 0x8 | 0x2);
	}
	CHECK(ask(true, 10, req, REQ_SIZE, NULL) == 0 && !last_scan.no_radio && last_scan.frequency_count == 0, "more than 64 channels");
	CHECK(result(res, uuid, 2048) == 0 && result(res, uuid, 2048) == 0 && result(res, uuid, 2048) == 0 && result(res, uuid, 2048) == EIO, "all three results, no filter");
	heard_n = 0;
	group("split scan");
}

static void
test_associate(void)
{
	static uint8_t a[ASC_SIZE];
	char *log_from;

	memset(a, 0, sizeof(a));
	wr16(a, ASC_MODE, 1);
	wr32(a, ASC_AUTHL, 1);
	wr32(a, ASC_AUTHU, 8);
	wr32(a, ASC_SSIDLEN, 7);
	memcpy(a + ASC_SSID, "SECRET1", 7);
	memcpy(a + ASC_BSSID, "\x02\x11\x22\x33\x44\x55", 6);
	wr32(a, ASC_KEYLEN, 10);
	wr32(a, ASC_CIPHER, 10);
	memcpy(a + ASC_KEY, "PASSPHRASE", 10);
	joins_asked = 0;
	log_from = stub_log + stub_log_at;
	CHECK(ask(true, 20, a, ASC_SIZE, NULL) == 0 && joins_asked == 1, "908 bytes accepted");
	CHECK(last_join.ssid_length == 7 && !memcmp(last_join.ssid, "SECRET1", 7), "name at +0x14, length at +0x10");
	CHECK(!memcmp(last_join.bssid, "\x02\x11\x22\x33\x44\x55", 6), "bssid at +0x34");
	CHECK(last_join.security == REDWOOD_STA_WPA2_PSK && last_join.passphrase_length == 10 && !memcmp(last_join.passphrase, "PASSPHRASE", 10), "the passphrase at +0x4c, kind +0x44, length +0x40");
	CHECK(strstr(log_from, "PASSPHRASE") == NULL && strstr(log_from, "SECRET1") == NULL, "name and key stay out of the log");
	CHECK(strstr(log_from, "authentication 0x1/0x8") != NULL, "auth at +8 and +0xc: %s", log_from);
	/* the key as bytes */
	static const uint8_t pmk[32] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 };
	wr32(a, ASC_KEYLEN, 32);
	wr32(a, ASC_CIPHER, 6);
	memcpy(a + ASC_KEY, pmk, 32);
	CHECK(ask(true, 20, a, ASC_SIZE, NULL) == 0 && !memcmp(last_join.pmk, pmk, 32), "the key at +0x4c");
	/* open */
	wr32(a, ASC_KEYLEN, 0);
	wr32(a, ASC_CIPHER, 0);
	CHECK(ask(true, 20, a, ASC_SIZE, NULL) == 0 && last_join.security == REDWOOD_STA_OPEN, "no key: open");
	/* refusals */
	wr32(a, ASC_SSIDLEN, 33);
	CHECK(ask(true, 20, a, ASC_SIZE, NULL) == EINVAL, "a name too long");
	wr32(a, ASC_SSIDLEN, 7);
	wr32(a, ASC_KEYLEN, 64);
	wr32(a, ASC_CIPHER, 10);
	CHECK(ask(true, 20, a, ASC_SIZE, NULL) == EINVAL, "a passphrase too long");
	CHECK(ask(true, 20, a, 0x88, NULL) == EINVAL, "shorter than up to the key's end");
	group("associate");
}

static void
test_link(void)
{
	events = 0;
	fake_state.bss.rssi = -55;
	redwood_apple80211_event(REDWOOD_STA_LINK, 1);
	CHECK(events == 3 && event_code[2] == EVENT_LINK_CHANGED, "SSID, BSSID, link");
	CHECK(event_len[2] == LINK_SIZE, "32 bytes, not 44: %u", event_len[2]);
	CHECK(event_data[2][LINK_DOWN] == 0 && (int32_t)rd32(event_data[2], LINK_RSSI) == -55, "up: rssi at +4");
	events = 0;
	redwood_apple80211_event(REDWOOD_STA_LINK, ETIMEDOUT);
	CHECK(event_data[2][LINK_DOWN] == 1 && event_data[2][LINK_INVOLUNTARY] == 1 && rd32(event_data[2], LINK_REASON) == 4, "lost: down +0, involuntary +16, reason +20");
	group("link event");
}

static void
test_small(void)
{
	static uint8_t b[64];
	int32_t v;

	/* capabilities: 21 bytes; the old bits */
	memset(b, 0xee, sizeof(b));
	CHECK(ask(false, 12, b, 21, NULL) == 0, "capabilities");
	CHECK(b[20] == 0 && b[21] == 0xee, "21 bytes");
	CHECK((b[10 / 8] >> (10 % 8)) & 1, "WPA2 bit");
	CHECK((b[2 / 8] >> 2) & 1 && (b[3 / 8] >> 3) & 1, "AES bits");
	group("capabilities");

	/* the no-op sets */
	static const int32_t quiet[] = { 365, 383, 473, 481, 483, 485, 512, 560, 564, 582 };
	for (unsigned i = 0; i < sizeof(quiet) / sizeof(quiet[0]); i++) {
		CHECK(ask(true, quiet[i], b, 4, NULL) == 0, "set %d", quiet[i]);
		CHECK(strcmp(type_name(quiet[i]), "?") != 0, "name of %d", quiet[i]);
	}
	CHECK(ask(true, 9999, b, 4, NULL) == EOPNOTSUPP, "others still refused");
	group("no-op sets");

	/* the country: never without a source */
	static const uint8_t de[] = { 0, 1, 'x', 7, 6, 'D', 'E', ' ', 1, 13, 20 };
	static const uint8_t us[] = { 7, 6, 'U', 'S', ' ', 1, 11, 30 };
	static const uint8_t lower[] = { 7, 6, 'd', 'e', ' ', 1, 13, 20 };
	static const uint8_t cut[] = { 7, 40, 'F', 'R', ' ' };
	static const uint8_t none[] = { 0, 1, 'x' };

	fake_state.phase = REDWOOD_STA_IDLE;
	heard_n = 0;
	CHECK(ask(false, 51, b, 3, NULL) == EOPNOTSUPP, "nothing heard: refused, no made-up country");
	heard_list[0] = bss_at(2412, -40, "a", none, sizeof(none));
	heard_list[1] = bss_at(2437, -50, "b", lower, sizeof(lower));
	heard_list[2] = bss_at(2437, -50, "c", cut, sizeof(cut));
	heard_n = 3;
	CHECK(ask(false, 51, b, 3, NULL) == EOPNOTSUPP, "no element, lower case, a cut element: refused");
	heard_list[1] = bss_at(2437, -70, "b", us, sizeof(us));
	heard_list[2] = bss_at(2462, -50, "c", de, sizeof(de));
	memset(b, 0xee, 8);
	CHECK(ask(false, 51, b, 3, NULL) == 0 && !memcmp(b, "DE", 3) && b[3] == 0xee, "the strongest that says one, 3 bytes");
	fake_state.phase = REDWOOD_STA_JOINED;
	fake_state.bss = bss_at(2412, -80, "joined", us, sizeof(us));
	CHECK(ask(false, 51, b, 3, NULL) == 0 && !memcmp(b, "US", 3), "the network joined goes first");
	fake_state.bss = bss_at(2412, -80, "joined", none, sizeof(none));
	CHECK(ask(false, 51, b, 3, NULL) == 0 && !memcmp(b, "DE", 3), "joined without one: the heard");
	fake_state.phase = REDWOOD_STA_IDLE;
	heard_n = 0;
	group("country");

	/* no second line */
	(void)v;
	const char *first = strstr(stub_log, "LAUREL A80211: on:");
	CHECK(first != NULL && strstr(first + 1, "LAUREL A80211:") == NULL, "one LAUREL line");
	CHECK(first != NULL && strstr(first, "SCAN_REQ 5528, SCAN_RESULT 2272, ASSOCIATE 908, CARD_CAPABILITIES 21, link 32") != NULL, "its text");
	group("line");
}

/* The struct against the table, field by field */
#define F(s, f, at) CHECK(offsetof(struct s, f) == (at), #s "." #f " at %zu, the code says %u", offsetof(struct s, f), (unsigned)(at))
static void
test_layout(void)
{
	CHECK(sizeof(struct apple80211_scan_request) == REQ_SIZE, "SCAN_REQ");
	CHECK(sizeof(struct apple80211_scan_result) == RES_SIZE, "SCAN_RESULT");
	CHECK(sizeof(struct apple80211_assoc) == ASC_SIZE, "ASSOCIATE");
	CHECK(sizeof(struct apple80211_link_changed) == LINK_SIZE, "link");
	F(apple80211_scan_request, bss_type, 4); F(apple80211_scan_request, bssid, 8); F(apple80211_scan_request, ssid_length, 0x10); F(apple80211_scan_request, ssid, 0x14);
	F(apple80211_scan_request, scan_type, 0x34); F(apple80211_scan_request, phy_mode, 0x38); F(apple80211_scan_request, dwell_ms, 0x3c); F(apple80211_scan_request, rest_ms, 0x40);
	F(apple80211_scan_request, channel_count, 0x44); F(apple80211_scan_request, channels, 0x48); F(apple80211_scan_request, flags, 0x1308); F(apple80211_scan_request, name_count, 0x1314);
	F(apple80211_scan_request, names, 0x1318); F(apple80211_scan_request, short_ssid, 0x1548); F(apple80211_scan_request, scan_uuid, 0x154c); F(apple80211_scan_request, unknown_0, 0x1590);
	F(apple80211_scan_result, channel, 4); F(apple80211_scan_result, noise_known, 16); F(apple80211_scan_result, noise, 18); F(apple80211_scan_result, snr, 20); F(apple80211_scan_result, rssi, 22);
	F(apple80211_scan_result, beacon_interval, 24); F(apple80211_scan_result, capability, 26); F(apple80211_scan_result, bssid, 28); F(apple80211_scan_result, rate_count, 34); F(apple80211_scan_result, rates, 36);
	F(apple80211_scan_result, ssid_length, 96); F(apple80211_scan_result, ssid, 97); F(apple80211_scan_result, age_ms, 132); F(apple80211_scan_result, flags, 136); F(apple80211_scan_result, elements_length, 138);
	F(apple80211_scan_result, elements, 140); F(apple80211_scan_result, scan_uuid, 2188); F(apple80211_scan_result, timestamp, 2256); F(apple80211_scan_result, unknown_1, 2264); F(apple80211_scan_result, unknown_2, 2268);
	F(apple80211_assoc, mode, 4); F(apple80211_assoc, auth_lower, 8); F(apple80211_assoc, auth_upper, 0xc); F(apple80211_assoc, ssid_length, 0x10); F(apple80211_assoc, ssid, 0x14); F(apple80211_assoc, bssid, 0x34);
	F(apple80211_assoc, key_version, 0x3c); F(apple80211_assoc, key_length, 0x40); F(apple80211_assoc, key_cipher, 0x44); F(apple80211_assoc, key, 0x4c); F(apple80211_assoc, rest, 0x8c);
	F(apple80211_link_changed, rssi, 4); F(apple80211_link_changed, snr, 8); F(apple80211_link_changed, noise, 10); F(apple80211_link_changed, involuntary, 16); F(apple80211_link_changed, reason, 20); F(apple80211_link_changed, subreason, 24);
	group("sizes and fields");
}

int
main(void)
{
	test_layout();
	test_scan();
	test_associate();
	test_link();
	test_small();
	printf("total %u checks, %u failures\n", checks, failures);
	return failures != 0;
}
