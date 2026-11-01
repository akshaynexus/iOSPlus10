/* Report sections: GPU, Metal, GL, display (report.h). Each value comes from a driver's own line or file, or it is "not available". */
#include <stdlib.h>
#include <string.h>
#include "report.h"

void
rp_sec_gpu(struct rp *r)
{
	const char *st = rp_kv(r, "gpu.state");
	const struct rp_rec *line = rp_s(r, "LAUREL GPU");

	if (st != NULL && strncmp(st, "off", 3) == 0) {
		rp_section(r, "GPU", "off", st[3] == ':' ? st + 5 : st);
	} else if (st != NULL && st[0] != 0) {
		rp_section(r, "GPU", "on", line != NULL ? line->text : "");
	} else if (st != NULL) {
		rp_section(r, "GPU", "none", "the GPU is starting");
	} else {
		rp_state(r, "GPU", line, "no kern.laurel_gpu and no line");
	}
	const struct rp_rec *sub = rp_r(r, "RedwoodGPU: submissions in");
	const struct rp_rec *clk = rp_r(r, "LAUREL GPU CLOCK: on: last");
	const struct rp_rec *pool = rp_r(r, "RedwoodGPU: buffers:");
	const struct rp_rec *worked = rp_r(r, "RedwoodGPU: the GPU");
	const struct rp_rec *fault = rp_r(r, "LAUREL GPU SMMU: fault");
	char a[64];

	if (rp_after(sub != NULL ? sub->text : NULL, "GPU busy", a, sizeof(a))) {
		rp_row(r, "Busy", a, sub->age);
	} else {
		rp_row(r, "Busy", sub != NULL ? "no number in the last 5 s line" : NULL, sub != NULL ? sub->age : -1);
	}
	/* laurel 2913: "clock N MHz over the window"; older kernels: "core N MHz while busy, M MHz over the window" (the first number was wrong) */
	rp_cut_row(r, "Clock over the 5 s window", sub, sub != NULL && strstr(sub->text, "while busy,") != NULL ? "while busy," : "clock ");
	if (rp_kv(r, "gpu.level_mhz") != NULL) {
		rp_rowf(r, "Clock level now", -1, "%s MHz", rp_kv(r, "gpu.level_mhz"));
	} else {
		rp_row(r, "Clock level now", NULL, -1);
	}
	rp_line(r, "Level time, last minute", clk);
	if (rp_before(sub != NULL ? sub->text : NULL, " submissions", a, sizeof(a))) {
		char ms[32];

		rp_after(sub->text, "submissions in", ms, sizeof(ms));
		ms[strcspn(ms, ":")] = 0;
		rp_rowf(r, "Submissions", sub->age, "%s in %s", a, ms);
	} else {
		rp_row(r, "Submissions", NULL, -1);
	}
	rp_line(r, "GPU work per submission", worked);
	rp_cut_row(r, "Pool free", pool, "GPU pool");
	const struct rp_rec *smmu = rp_s(r, "LAUREL GPU SMMU");

	rp_srow(r, "SMMU", smmu);
	if (fault != NULL) {
		rp_rowf(r, "SMMU faults", fault->age, "%ld, last: %s", fault->n, strstr(fault->text, "fault ") ? strstr(fault->text, "fault ") + 6 : fault->text);
	} else {
		rp_row(r, "SMMU faults", smmu != NULL ? "0 seen in the log" : NULL, -1);
	}
	rp_srow(r, "Host pages", rp_s(r, "LAUREL GPU HOST PAGES"));
	rp_srow(r, "Clock control", rp_s(r, "LAUREL GPU CLOCK"));
	rp_srow(r, "DDR", rp_s(r, "LAUREL DDR"));
	rp_srow(r, "Watchdog", rp_s(r, "LAUREL GPU WATCHDOG"));
}

/* the "device" records of one kind: name, opens, running or not */
static void
device_rows(struct rp *r, const char *kind, const char *title, int with_note)
{
	int shown = 0;

	for (int i = 0; i < r->nrec; i++) {
		const struct rp_rec *d = &r->rec[i];

		if (d->type != 'D' || strcmp(d->a, kind) != 0) {
			continue;
		}
		int run = rp_running(r, d->key);
		char left[96];

		snprintf(left, sizeof(left), "%s %s", title, d->key);
		if (with_note && d->text[0] != 0) {
			rp_rowf(r, left, d->age, "%s, %ld opens; %s", run > 0 ? "running" : run == 0 ? "exited" : "?", d->n, d->text);
		} else {
			rp_rowf(r, left, d->age, "%s, %ld opens", run > 0 ? "running" : run == 0 ? "exited" : "?", d->n);
		}
		shown++;
	}
	if (shown == 0) {
		rp_row(r, title, "none in the log", -1);
	}
}

void
rp_sec_metal(struct rp *r)
{
	const struct rp_rec *m = rp_s(r, "LAUREL METAL"), *g = rp_s(r, "LAUREL METAL CLIENTS");
	const char *off = rp_kv(r, "metal.off");

	if (off != NULL && atoi(off) != 0) {
		rp_section(r, "Metal", "off", "the off file exists (/var/db/negronimetal/off)");
	} else if (m != NULL && strcmp(m->a, "off") == 0) {
		rp_section(r, "Metal", "off", m->text);
	} else if (g != NULL && strcmp(g->a, "off") == 0) {
		rp_section(r, "Metal", "part", g->text);
	} else if (m != NULL) {
		rp_section(r, "Metal", "on", g != NULL ? g->text : m->text);
	} else {
		rp_section(r, "Metal", "none", "no LAUREL METAL line");
	}
	rp_srow(r, "Plug-in (kernel)", m);
	rp_srow(r, "Gate", g);
	rp_row(r, "Mode", rp_kv(r, "metal.mode"), -1);
	rp_row(r, "Clients file", rp_kv(r, "metal.clients"), -1);
	rp_row(r, "clients.local", rp_kv(r, "metal.local"), -1);
	rp_row(r, "Gate record", rp_kv(r, "metal.gate"), -1);
	rp_row(r, "Strikes", rp_kv(r, "metal.strikes"), -1);
	if (rp_kv(r, "metal.cache_files") != NULL) {
		rp_rowf(r, "Shader cache", -1, "%s files, %ld KiB", rp_kv(r, "metal.cache_files"), rp_kvn(r, "metal.cache_bytes", 0) / 1024);
	} else {
		rp_row(r, "Shader cache", NULL, -1);
	}
	device_rows(r, "M", "Device", 1);
}

void
rp_sec_gl(struct rp *r)
{
	const struct rp_rec *b = rp_s(r, "LAUREL BBD");
	const char *off = rp_kv(r, "gl.off");

	if (off != NULL && atoi(off) != 0) {
		rp_section(r, "GL", "off", "the off file exists (/var/db/laurelgl/off); applies after Restart UI");
	} else {
		rp_state(r, "GL", b, "no LAUREL BBD line");
	}
	rp_row(r, "Switch file", off == NULL ? NULL : atoi(off) ? "off" : "on (no off file)", -1);
	rp_srow(r, "backboardd loader", b);
	rp_srow(r, "Surfaces drawn by the GPU", rp_s(r, "LAUREL GL DRAWN"));
	const struct rp_rec *fps = rp_r(r, "SWEET FPS: frames"), *frame = rp_r(r, "redwood-gl: frame");
	char f[32], ms[32];

	if (fps != NULL && rp_before(fps->text, " frames in", f, sizeof(f)) && rp_after(fps->text, "frames in", ms, sizeof(ms))) {
		long frames = atol(f), span = atol(ms);

		if (span > 0) {
			rp_rowf(r, "FPS (panel swaps)", fps->age, "%ld.%ld", frames * 1000 / span, frames * 10000 / span % 10);
		} else {
			rp_row(r, "FPS (panel swaps)", NULL, -1);
		}
	} else {
		rp_row(r, "FPS (panel swaps)", NULL, -1);
	}
	rp_line(r, "Last FPS line", fps);
	char us[24];

	if (frame != NULL && rp_before(frame->text, " us (", us, sizeof(us))) {
		long v = atol(us);

		rp_rowf(r, "Frame time (last logged)", frame->age, "%ld.%ld ms", v / 1000, v / 100 % 10);
	} else {
		rp_row(r, "Frame time (last logged)", NULL, -1);
	}
	rp_line(r, "redwood-gl frame", frame);
	rp_row(r, "GL for apps", "no: the GL loader goes only into backboardd on this port", -1);
}

void
rp_sec_display(struct rp *r)
{
	const struct rp_rec *bl = rp_s(r, "LAUREL BACKLIGHT"), *panel = rp_s(r, "LAUREL PANEL");

	rp_state(r, "Display", panel != NULL ? panel : bl, "no LAUREL PANEL line");
	const struct rp_rec *lvl = rp_r(r, "LAUREL BACKLIGHT: brightness");

	rp_cut_row(r, "Panel level", lvl, "brightness");
	rp_srow(r, "Backlight", bl);
	rp_srow(r, "Power mode", panel);
	const struct rp_rec *wake = rp_r(r, "LAUREL PANEL: wake");
	char n[16];

	if (wake != NULL && rp_after(wake->text, "wake", n, sizeof(n))) {
		n[strcspn(n, ":")] = 0;
		rp_rowf(r, "Wake count", wake->age, "%s; last: %s", n, strchr(wake->text, ':') ? strchr(wake->text, ':') + 2 : "");
	} else {
		rp_row(r, "Wake count", panel != NULL ? "0 in the log" : NULL, -1);
	}
	long ref_age = -1, ref = rp_count(r, "LAUREL FB OWNER: refused", &ref_age);

	if (ref != 0) {
		rp_rowf(r, "FB owner refusals", ref_age, "%ld", ref);
	} else {
		rp_row(r, "FB owner refusals", rp_s(r, "LAUREL FB OWNER") != NULL ? "0 in the log" : NULL, -1);
	}
	rp_srow(r, "FB owner", rp_s(r, "LAUREL FB OWNER"));
	rp_srow(r, "Canvas", rp_s(r, "LAUREL FB CANVAS"));
	rp_srow(r, "Handoff", rp_s(r, "LAUREL FB HANDOFF"));
}
