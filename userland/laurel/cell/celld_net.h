/*
 * The parser of kern.laurel_cell_net (kernel patch 2942, bsd/dev/laurel_pdp_text.h): key=value lines -> struct. Plain C with no iOS header: the host test
 * (scripts/laurel/test-cell.sh) parses the kernel's own text with this file. Used by laurel_celld.c.
 */
#ifndef CELLD_NET_H
#define CELLD_NET_H
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

struct celld_net {
	bool on;
	char ifname[16];
	int mtu;
	char v4[16], v4_mask[16], v4_gw[16], v4_dns[2][16];
	int v4_dns_n;
	char v6[40], v6_gw[40], v6_dns[2][40];
	int v6_plen, v6_dns_n;
};

static inline void
celld_copy(char *d, size_t max, const char *s, size_t n)
{
	if (n >= max) {
		n = max - 1;
	}
	memcpy(d, s, n);
	d[n] = 0;
}

static inline bool
celld_key(const char *p, size_t kl, const char *k)
{
	return strlen(k) == kl && memcmp(p, k, kl) == 0;
}

static inline void
celld_parse(const char *text, struct celld_net *o)
{
	memset(o, 0, sizeof(*o));
	for (const char *p = text; *p != 0;) {
		const char *nl = strchr(p, '\n'), *eq = strchr(p, '=');
		size_t len = nl != NULL ? (size_t)(nl - p) : strlen(p);

		if (eq != NULL && (size_t)(eq - p) < len) {
			size_t kl = (size_t)(eq - p), vl = len - kl - 1;
			const char *v = eq + 1;
			char num[8];

			celld_copy(num, sizeof(num), v, vl);
			if (celld_key(p, kl, "state")) {
				o->on = vl == 2 && memcmp(v, "on", 2) == 0;
			} else if (celld_key(p, kl, "if")) {
				celld_copy(o->ifname, sizeof(o->ifname), v, vl);
			} else if (celld_key(p, kl, "mtu")) {
				o->mtu = atoi(num);
			} else if (celld_key(p, kl, "v4")) {
				celld_copy(o->v4, sizeof(o->v4), v, vl);
			} else if (celld_key(p, kl, "v4.mask")) {
				celld_copy(o->v4_mask, sizeof(o->v4_mask), v, vl);
			} else if (celld_key(p, kl, "v4.gw")) {
				celld_copy(o->v4_gw, sizeof(o->v4_gw), v, vl);
			} else if (celld_key(p, kl, "v4.dns") && o->v4_dns_n < 2) {
				celld_copy(o->v4_dns[o->v4_dns_n++], sizeof(o->v4_dns[0]), v, vl);
			} else if (celld_key(p, kl, "v6")) {
				celld_copy(o->v6, sizeof(o->v6), v, vl);
			} else if (celld_key(p, kl, "v6.plen")) {
				o->v6_plen = atoi(num);
			} else if (celld_key(p, kl, "v6.gw")) {
				celld_copy(o->v6_gw, sizeof(o->v6_gw), v, vl);
			} else if (celld_key(p, kl, "v6.dns") && o->v6_dns_n < 2) {
				celld_copy(o->v6_dns[o->v6_dns_n++], sizeof(o->v6_dns[0]), v, vl);
			}
		}
		if (nl == NULL) {
			break;
		}
		p = nl + 1;
	}
}
#endif
