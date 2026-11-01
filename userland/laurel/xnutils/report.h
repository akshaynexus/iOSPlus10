/*
 * The report of XNUtils (docs/laurel_sprout/xnutils.md): from one text (key=value lines of collect_ios.c + kern.laurel_stats, kernel
 * patch 2911) to sections with rows. Plain C, no iOS call: scripts/laurel/xnutils-test.sh runs the same code on the host.
 *
 * Output for the app (tab separated, one line each; "%" ends one report):
 *   #  TITLE  STATE  REASON          STATE: on | off | part | info | none
 *   =  KEY  VALUE  AGE               AGE: seconds since the kernel saw the line, -1 = read now
 * Plain mode: the same content as text (`powermenu-helper report`, the app's Copy and Share build theirs from the rows).
 * A value nobody has is the text "not available". The report never makes up a number.
 */
#ifndef XNUTILS_REPORT_H
#define XNUTILS_REPORT_H
#include <stdio.h>

#define RP_KV_MAX  256
#define RP_REC_MAX 400
#define NA "not available"

struct rp_rec {
	char type;              /* S, R, C, D */
	long age, n;
	const char *key;        /* S, R: slot key. C: name. D: name */
	const char *a;          /* S: on|off. C: signal number. D: M (Metal) | G (GPU) */
	const char *text;       /* S: text after on:/off:. R: the whole line. C: reason. D: note */
};

struct rp {
	FILE *out;
	int plain;
	int nkv, nrec;
	struct { const char *k, *v; } kv[RP_KV_MAX];
	struct rp_rec rec[RP_REC_MAX];
};

/* report_core.c */
void rp_parse(struct rp *r, char *text);        /* text is cut in place and must stay */
const char *rp_kv(const struct rp *r, const char *key);
long rp_kvn(const struct rp *r, const char *key, long missing);
const struct rp_rec *rp_s(const struct rp *r, const char *key);    /* state slot, exact key */
const struct rp_rec *rp_r(const struct rp *r, const char *prefix); /* line slot, key prefix, the newest */
void rp_section(struct rp *r, const char *title, const char *state, const char *reason);
void rp_state(struct rp *r, const char *title, const struct rp_rec *s, const char *none); /* header from a state slot */
void rp_row(struct rp *r, const char *key, const char *value, long age); /* value NULL: not available */
void rp_rowf(struct rp *r, const char *key, long age, const char *fmt, ...) __attribute__((format(printf, 4, 5)));
void rp_line(struct rp *r, const char *key, const struct rp_rec *line);  /* the line's text after its tag, or not available */
void rp_srow(struct rp *r, const char *key, const struct rp_rec *s);     /* "on: text" / "off: text" of a state slot */
int rp_after(const char *text, const char *label, char *out, size_t cap); /* the words after label, up to , ; | ( or the end */
int rp_before(const char *text, const char *label, char *out, size_t cap); /* the word before label */
void rp_cut_row(struct rp *r, const char *key, const struct rp_rec *line, const char *label); /* rp_after on a line; age of the line */
long rp_count(const struct rp *r, const char *prefix, long *age); /* the lines of all slots with this key prefix */
void rp_sysctl_section(struct rp *r, const char *title, const char *text); /* header from "on: x" / "off: x" */
int rp_running(const struct rp *r, const char *name);   /* 1 running, 0 not, -1 unknown */

/* the sections: report_gfx.c, report_sys.c, report_io.c */
void rp_sec_gpu(struct rp *r);
void rp_sec_metal(struct rp *r);
void rp_sec_gl(struct rp *r);
void rp_sec_display(struct rp *r);
void rp_sec_cpu(struct rp *r);
void rp_sec_thermal(struct rp *r);
void rp_sec_memory(struct rp *r);
void rp_sec_battery(struct rp *r);
void rp_sec_wifi(struct rp *r);
void rp_sec_bt(struct rp *r);
void rp_sec_cell(struct rp *r);
void rp_sec_camera(struct rp *r);
void rp_sec_audio(struct rp *r);
void rp_sec_clock(struct rp *r);
void rp_sec_storage(struct rp *r);
void rp_sec_kernel(struct rp *r);
void rp_sec_features(struct rp *r);
void rp_sec_crashes(struct rp *r);
void rp_all(struct rp *r);                      /* every section, in order, then "%" */
#endif
