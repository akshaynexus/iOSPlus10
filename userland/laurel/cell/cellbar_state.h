/*
 * The parser of kern.laurel_cell_state (kernel patch 2786, bsd/dev/laurel_cell.c): key=value lines -> struct. Plain C with no iOS header: the kernel's
 * host test (scripts/laurel/test-cell.sh) parses the kernel's own text with this file. Used by laurel_cellbar.c.
 */
#ifndef CELLBAR_STATE_H
#define CELLBAR_STATE_H
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

enum { CB_STARTING, CB_ON, CB_OFF };

struct cellbar_sub {
	int slot;               /* 1, 2; 0 = no card seen for this subscription */
	int reg;                /* 2 registered, 1 searching, 0 not registered: as STTelephonySubscriptionInfo registrationStatus [V 20H392] */
	int bars;               /* 0-4; the kernel gives > 0 only when registered, from its own reading */
	char sim[12];           /* absent ready starting pin puk blocked illegal error noapp unknown */
	char rat[12];
	char op[24];            /* the network's name or MCC-MNC; empty unless registered */
};

struct cellbar_state {
	int state;
	bool radio_online;
	struct cellbar_sub sub[2];
};

static inline void
cellbar_copy(char *d, size_t max, const char *s, size_t n)
{
	if (n >= max) {
		n = max - 1;
	}
	memcpy(d, s, n);
	d[n] = 0;
}

static inline void
cellbar_parse(const char *text, struct cellbar_state *o)
{
	memset(o, 0, sizeof(*o));
	o->state = CB_OFF;
	strcpy(o->sub[0].sim, "absent");
	strcpy(o->sub[1].sim, "absent");
	for (const char *p = text; *p != 0;) {
		const char *nl = strchr(p, '\n'), *eq = strchr(p, '=');
		size_t len = nl != NULL ? (size_t)(nl - p) : strlen(p);

		if (eq != NULL && (size_t)(eq - p) < len) {
			size_t kl = (size_t)(eq - p), vl = len - kl - 1;
			const char *v = eq + 1;
			char num[8];

			cellbar_copy(num, sizeof(num), v, vl);
			if (kl == 5 && memcmp(p, "state", 5) == 0) {
				o->state = vl == 2 && memcmp(v, "on", 2) == 0 ? CB_ON : (vl == 3 && memcmp(v, "off", 3) == 0 ? CB_OFF : CB_STARTING);
			} else if (kl == 5 && memcmp(p, "radio", 5) == 0) {
				o->radio_online = vl == 6 && memcmp(v, "online", 6) == 0;
			} else if (kl > 5 && memcmp(p, "sub", 3) == 0 && (p[3] == '0' || p[3] == '1') && p[4] == '.') {
				struct cellbar_sub *s = &o->sub[p[3] - '0'];
				const char *f = p + 5;
				size_t fl = kl - 5;

				if (fl == 4 && memcmp(f, "slot", 4) == 0) {
					s->slot = atoi(num);
				} else if (fl == 3 && memcmp(f, "reg", 3) == 0) {
					s->reg = atoi(num);
				} else if (fl == 4 && memcmp(f, "bars", 4) == 0) {
					s->bars = atoi(num);
				} else if (fl == 3 && memcmp(f, "sim", 3) == 0) {
					cellbar_copy(s->sim, sizeof(s->sim), v, vl);
				} else if (fl == 3 && memcmp(f, "rat", 3) == 0) {
					cellbar_copy(s->rat, sizeof(s->rat), v, vl);
				} else if (fl == 2 && memcmp(f, "op", 2) == 0) {
					cellbar_copy(s->op, sizeof(s->op), v, vl);
				}
			}
		}
		if (nl == NULL) {
			break;
		}
		p = nl + 1;
	}
	/* the kernel's rule, once more at this end: no bars without a registration */
	for (int i = 0; i < 2; i++) {
		if (o->state == CB_OFF || !o->radio_online || o->sub[i].reg != 2) {
			o->sub[i].bars = 0;
		}
		if (o->sub[i].bars > 4) {
			o->sub[i].bars = 4;
		}
	}
}
#endif
