/* The report's parser and row writer (report.h). */
#include <stdlib.h>
#include <string.h>
#include "report.h"

/* cut at the next tab; NULL when there is none */
static char *
field(char **p)
{
	char *s = *p;

	if (s == NULL) {
		return NULL;
	}
	char *t = strchr(s, '\t');

	if (t != NULL) {
		*t = 0;
		*p = t + 1;
	} else {
		*p = NULL;
	}
	return s;
}

void
rp_parse(struct rp *r, char *text)
{
	char *save = NULL;

	r->nkv = r->nrec = 0;
	for (char *line = strtok_r(text, "\n", &save); line != NULL; line = strtok_r(NULL, "\n", &save)) {
		if (line[1] == '\t' && strchr("SRCD", line[0]) != NULL) {
			if (r->nrec == RP_REC_MAX) {
				continue;
			}
			struct rp_rec *e = &r->rec[r->nrec];
			char *p = line + 2, *age = field(&p), *n = field(&p);

			if (age == NULL || n == NULL || p == NULL) {
				continue;
			}
			e->type = line[0];
			e->age = strtol(age, NULL, 10);
			e->n = strtol(n, NULL, 10);
			switch (line[0]) {
			case 'S': e->key = field(&p); e->a = field(&p); e->text = p; break;
			case 'R': e->key = field(&p); e->a = ""; e->text = p; break;
			case 'C': e->key = field(&p); e->a = field(&p); e->text = p; break;
			default:  e->a = field(&p); e->key = field(&p); e->text = p; break;
			}
			if (e->key == NULL || e->a == NULL) {
				continue;
			}
			if (e->text == NULL) {
				e->text = "";
			}
			r->nrec++;
			continue;
		}
		char *eq = strchr(line, '=');

		if (eq != NULL && r->nkv < RP_KV_MAX) {
			*eq = 0;
			r->kv[r->nkv].k = line;
			r->kv[r->nkv].v = eq + 1;
			r->nkv++;
		}
	}
}

const char *
rp_kv(const struct rp *r, const char *key)
{
	for (int i = 0; i < r->nkv; i++) {
		if (strcmp(r->kv[i].k, key) == 0) {
			return r->kv[i].v;
		}
	}
	return NULL;
}

long
rp_kvn(const struct rp *r, const char *key, long missing)
{
	const char *v = rp_kv(r, key);

	return v != NULL ? strtol(v, NULL, 10) : missing;
}

const struct rp_rec *
rp_s(const struct rp *r, const char *key)
{
	for (int i = 0; i < r->nrec; i++) {
		if (r->rec[i].type == 'S' && strcmp(r->rec[i].key, key) == 0) {
			return &r->rec[i];
		}
	}
	return NULL;
}

const struct rp_rec *
rp_r(const struct rp *r, const char *prefix)
{
	const struct rp_rec *best = NULL;
	size_t n = strlen(prefix);

	for (int i = 0; i < r->nrec; i++) {
		if (r->rec[i].type == 'R' && strncmp(r->rec[i].key, prefix, n) == 0 && (best == NULL || r->rec[i].age < best->age)) {
			best = &r->rec[i];
		}
	}
	return best;
}

long
rp_count(const struct rp *r, const char *prefix, long *age)
{
	long n = 0;
	size_t len = strlen(prefix);

	for (int i = 0; i < r->nrec; i++) {
		if (r->rec[i].type == 'R' && strncmp(r->rec[i].key, prefix, len) == 0) {
			n += r->rec[i].n;
			if (age != NULL && (*age < 0 || r->rec[i].age < *age)) {
				*age = r->rec[i].age;
			}
		}
	}
	return n;
}

/* procs.all = ",name,name,": what the helper saw this tick. The kernel's table cuts a name at 23 characters. */
int
rp_running(const struct rp *r, const char *name)
{
	const char *all = rp_kv(r, "procs.all");

	if (all == NULL) {
		return -1;
	}
	size_t n = strlen(name);

	for (const char *p = all; (p = strstr(p, name)) != NULL; p += n) {
		if (p != all && p[-1] == ',') {
			return 1;
		}
	}
	return 0;
}

void
rp_all(struct rp *r)
{
	rp_sec_kernel(r);
	rp_sec_gpu(r);
	rp_sec_metal(r);
	rp_sec_gl(r);
	rp_sec_display(r);
	rp_sec_cpu(r);
	rp_sec_thermal(r);
	rp_sec_memory(r);
	rp_sec_battery(r);
	rp_sec_wifi(r);
	rp_sec_bt(r);
	rp_sec_cell(r);
	rp_sec_camera(r);
	rp_sec_audio(r);
	rp_sec_clock(r);
	rp_sec_storage(r);
	rp_sec_crashes(r);
	rp_sec_features(r);
	if (!r->plain) {
		fprintf(r->out, "%%\n");
	}
	fflush(r->out);
}
