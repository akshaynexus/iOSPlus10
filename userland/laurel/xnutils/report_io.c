/* Report sections: Wi-Fi, Bluetooth, cellular, camera, audio, the LAUREL feature list, crashes (report.h). */
#include <stdlib.h>
#include <string.h>
#include "report.h"

void
rp_sec_wifi(struct rp *r)
{
	const struct rp_rec *s = rp_s(r, "LAUREL WIFI");
	long up = rp_kvn(r, "wifi.up", -1);

	if (s == NULL) {
		rp_section(r, "Wi-Fi", "none", "no LAUREL WIFI line");
	} else if (strcmp(s->a, "off") == 0) {
		rp_section(r, "Wi-Fi", "off", s->text);
	} else {
		rp_section(r, "Wi-Fi", up == 1 ? "on" : up == 0 ? "part" : "on", up == 0 ? "firmware up, not joined" : s->text);
	}
	if (up == 1) {
		long freq = rp_kvn(r, "wifi.freq", 0), mbps10 = rp_kvn(r, "wifi.rx_mbps10", 0);

		rp_rowf(r, "Band and channel", -1, "%s GHz, channel %s, %ld MHz", freq >= 4900 ? "5" : "2.4", rp_kv(r, "wifi.channel"), freq);
		rp_rowf(r, "Width and mode", -1, "%s MHz %s%s, %sx%s", rp_kv(r, "wifi.width"), rp_kv(r, "wifi.mode"), rp_kvn(r, "wifi.qos", 0) ? " QoS" : "",
		    rp_kv(r, "wifi.nss"), rp_kv(r, "wifi.nss"));
		rp_rowf(r, "Rx rate", -1, "%s MCS %s, %s MHz, %ld.%ld Mbit/s", rp_kv(r, "wifi.rx_kind"), rp_kv(r, "wifi.rx_mcs"), rp_kv(r, "wifi.rx_width"), mbps10 / 10, mbps10 % 10);
		if (rp_kvn(r, "wifi.tx_kbps", 0) != 0) {
			rp_rowf(r, "Tx rate", -1, "%ld Mbit/s", rp_kvn(r, "wifi.tx_kbps", 0) / 1000);
		} else {
			rp_row(r, "Tx rate", "no firmware answer yet", -1);
		}
		rp_rowf(r, "Signal", -1, "%s dBm, %s bars", rp_kv(r, "wifi.rssi"), rp_kv(r, "wifi.bars"));
	} else if (up == 0) {
		rp_row(r, "Link", "not joined", -1);
	} else {
		rp_line(r, "Last link line", rp_r(r, "LAUREL WIFI: link"));
	}
	if (rp_kv(r, "net.en0_rx_kbps") != NULL) {
		rp_rowf(r, "Throughput now", -1, "down %s kbit/s, up %s kbit/s", rp_kv(r, "net.en0_rx_kbps"), rp_kv(r, "net.en0_tx_kbps"));
	} else {
		rp_row(r, "Throughput now", NULL, -1);
	}
	if (rp_kv(r, "wifi.drop_full") != NULL) {
		rp_rowf(r, "Frames", -1, "rx %s, tx %s, tx failed %s", rp_kv(r, "wifi.rx_frames"), rp_kv(r, "wifi.tx_frames"), rp_kv(r, "wifi.tx_fail"));
		rp_rowf(r, "Drops by reason", -1, "full %s, link down %s, too big %s, no memory %s, queue %s, left at link loss %s; in %s", rp_kv(r, "wifi.drop_full"),
		    rp_kv(r, "wifi.drop_down"), rp_kv(r, "wifi.drop_big"), rp_kv(r, "wifi.drop_nomem"), rp_kv(r, "wifi.drop_queue"), rp_kv(r, "wifi.drop_left"), rp_kv(r, "wifi.drop_in"));
		rp_rowf(r, "Scans", -1, "%s real, %s deferred", rp_kv(r, "wifi.scans"), rp_kv(r, "wifi.scans_deferred"));
	} else {
		rp_row(r, "Drops by reason", NULL, -1);
		rp_row(r, "Scans", NULL, -1);
	}
	rp_srow(r, "Scan limit", rp_s(r, "LAUREL WIFI/scan limit"));
	rp_srow(r, "Band choice", rp_s(r, "LAUREL WIFI/band choice"));
	rp_srow(r, "HT/VHT", rp_s(r, "LAUREL WIFI/HT/VHT"));
	rp_srow(r, "Tx queue", rp_s(r, "LAUREL WIFI/tx queue"));
	rp_line(r, "Traffic path", rp_r(r, "LAUREL WIFI: path"));
}

void
rp_sec_bt(struct rp *r)
{
	const struct rp_rec *s = rp_s(r, "LAUREL BT");
	char a[96];

	rp_state(r, "Bluetooth", s, "no LAUREL BT line");
	const char *t = s != NULL ? s->text : NULL;

	if (rp_after(t, "product", a, sizeof(a))) {
		char chip[32] = "";

		rp_before(t, " product", chip, sizeof(chip));
		rp_rowf(r, "Chip", s->age, "%s product %s", chip, a);
	} else {
		rp_row(r, "Chip", NULL, -1);
	}
	if (t != NULL && strchr(t, ',') != NULL && strstr(t, ".tlv") != NULL) {
		const char *c = strchr(t, ',') + 1;

		while (*c == ' ') {
			c++;
		}
		size_t n = strcspn(c, ",");

		rp_rowf(r, "Firmware", s->age, "%.*s", (int)n, c);
	} else {
		rp_row(r, "Firmware", NULL, -1);
	}
	rp_cut_row(r, "Address", s != NULL ? rp_r(r, "LAUREL BT: on:") : NULL, "BD_ADDR");
	rp_line(r, "iOS side", rp_r(r, "LAUREL BT: ios:"));
}

void
rp_sec_cell(struct rp *r)
{
	const char *c = rp_kv(r, "cell.state"), *ipa = rp_kv(r, "ipa.state");
	const struct rp_rec *s = rp_s(r, "LAUREL CELL");

	if (c != NULL && strncmp(c, "part: ", 6) == 0) {
		rp_section(r, "Cellular", "part", c + 6);       /* laurel 2786: the client reads the SIMs, the radio is not online */
	} else if (c != NULL && strncmp(c, "on: ", 4) == 0 && strstr(c, "modem online") == NULL) {
		rp_section(r, "Cellular", "part", c + 4);       /* (a kernel before 2786 says "on" for SIM facts only) */
	} else if (c != NULL && c[0] != 0) {
		rp_sysctl_section(r, "Cellular", c);
	} else {
		rp_state(r, "Cellular", s, "no kern.laurel_cell and no line");
	}
	rp_cut_row(r, "SIM 1", s, "SIM1 ");
	rp_cut_row(r, "SIM 2", s, "SIM2 ");
	rp_cut_row(r, "Modem mode", s, "modem mode");
	rp_cut_row(r, "Radio", s, "radio ");
	rp_cut_row(r, "Data", s, "data ");
	rp_cut_row(r, "SMS, voice", s, "SMS, voice ");
	rp_row(r, "IPA", ipa, -1);
	rp_srow(r, "IPA line", rp_s(r, "LAUREL IPA"));
	rp_row(r, "ICCID, IMSI, IMEI", "never shown here", -1);
}

void
rp_sec_camera(struct rp *r)
{
	const char *c = rp_kv(r, "camera.state"), *st = rp_kv(r, "camera.stream");
	const struct rp_rec *sess = rp_r(r, "LAUREL CAMERA: ios session");

	if (c != NULL && c[0] != 0) {
		rp_sysctl_section(r, "Camera", c);
	} else {
		rp_state(r, "Camera", rp_s(r, "LAUREL CAMERA"), "no kern.laurel_camera and no line");
	}
	rp_row(r, "Last stream", st, -1);
	const struct rp_rec *run = rp_r(r, "LAUREL CAMERA: ios session: frames");
	char f[16], ms[32];

	if (run != NULL && rp_before(run->text, " frames in", f, sizeof(f)) && rp_after(run->text, "frames in", ms, sizeof(ms)) && atol(ms) > 0) {
		rp_rowf(r, "Frames", run->age, "%s in %s; %ld.%ld fps", f, ms, atol(f) * 1000 / atol(ms), atol(f) * 10000 / atol(ms) % 10);
	} else {
		rp_row(r, "Frames", NULL, -1);
	}
	rp_cut_row(r, "Exposure", run, "exposure ");
	rp_cut_row(r, "VFE errors", run, "VFE errors");
	rp_line(r, "Session", sess);
	rp_srow(r, "Focus", rp_s(r, "LAUREL CAMERA/focus"));
	rp_line(r, "Memory", rp_r(r, "LAUREL CAMERA: ios: memory"));
	rp_srow(r, "/dev/negronicam", rp_s(r, "LAUREL CAMERA//dev/negronicam"));
}

void
rp_sec_audio(struct rp *r)
{
	const struct rp_rec *s = rp_s(r, "LAUREL AUDIO"), *st = rp_r(r, "TopazAudio:");
	char a[64];

	rp_state(r, "Audio", s, "no LAUREL AUDIO line");
	rp_srow(r, "Speaker path", s);
	if (st != NULL && rp_after(st->text, "core ", a, sizeof(a))) {
		char f[16] = "?";

		rp_before(st->text, " frames in", f, sizeof(f));
		rp_rowf(r, "ADSP", st->age, "core state %s; %s frames in", a, f);
	} else {
		rp_row(r, "ADSP", NULL, -1);
	}
	rp_row(r, "Microphone", "no driver on this port", -1);
}

/* every "LAUREL X" state line */
void
rp_sec_features(struct rp *r)
{
	int on = 0, off = 0;
	char why[64];

	for (int i = 0; i < r->nrec; i++) {
		if (r->rec[i].type == 'S') {
			strcmp(r->rec[i].a, "on") == 0 ? on++ : off++;
		}
	}
	snprintf(why, sizeof(why), "%d on, %d off", on, off);
	rp_section(r, "All LAUREL features", on + off != 0 ? (off ? "part" : "on") : "none", on + off != 0 ? why : "no state line");
	for (int pass = 0; pass < 2; pass++) {              /* off first: that is what people look for */
		for (int i = 0; i < r->nrec; i++) {
			const struct rp_rec *s = &r->rec[i];

			if (s->type == 'S' && (strcmp(s->a, "off") == 0) == (pass == 0)) {
				char key[64];

				snprintf(key, sizeof(key), "%s", strncmp(s->key, "LAUREL ", 7) == 0 ? s->key + 7 : s->key);
				rp_srow(r, key, s);
			}
		}
	}
}

void
rp_sec_crashes(struct rp *r)
{
	int kinds = 0;
	long all = 0;
	char why[64];

	for (int i = 0; i < r->nrec; i++) {
		if (r->rec[i].type == 'C') {
			kinds++;
			all += r->rec[i].n;
		}
	}
	snprintf(why, sizeof(why), "%ld crashes of %d processes in this boot's log", all, kinds);
	rp_section(r, "Crashes", kinds ? "part" : rp_kv(r, "up_ms") != NULL ? "on" : "none", kinds ? why : rp_kv(r, "up_ms") != NULL ? "none in this boot's log" : "no kern.laurel_stats");
	for (int i = 0; i < r->nrec; i++) {
		const struct rp_rec *c = &r->rec[i];

		if (c->type == 'C') {
			rp_rowf(r, c->key, c->age, "%ld times, last signal %s%s%s", c->n, c->a, c->text[0] ? ", " : "", c->text);
		}
	}
}
