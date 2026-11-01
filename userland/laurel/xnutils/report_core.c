/* The report's parser and row writer (report.h). */
#include <stdarg.h>
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

void
rp_section(struct rp *r, const char *title, const char *state, const char *reason)
{
	if (r->plain) {
		fprintf(r->out, "\n== %s: %s%s%s\n", title, state, reason && reason[0] ? ": " : "", reason ? reason : "");
	} else {
		fprintf(r->out, "#\t%s\t%s\t%s\n", title, state, reason ? reason : "");
	}
}

void
rp_state(struct rp *r, const char *title, const struct rp_rec *s, const char *none)
{
	if (s == NULL) {
		rp_section(r, title, "none", none);
	} else {
		rp_section(r, title, s->a, s->text);
	}
}

void
rp_sysctl_section(struct rp *r, const char *title, const char *text)
{
	if (strncmp(text, "on: ", 4) == 0) {
		rp_section(r, title, "on", text + 4);
	} else if (strncmp(text, "off: ", 5) == 0) {
		rp_section(r, title, "off", text + 5);
	} else if (strcmp(text, "on") == 0) {
		rp_section(r, title, "on", "");
	} else {
		rp_section(r, title, "none", text);
	}
}

void
rp_row(struct rp *r, const char *key, const char *value, long age)
{
	if (value == NULL || value[0] == 0) {
		value = NA;
	}
	if (r->plain) {
		if (age >= 0) {
			fprintf(r->out, "  %s: %s (%ld s ago)\n", key, value, age);
		} else {
			fprintf(r->out, "  %s: %s\n", key, value);
		}
	} else {
		fprintf(r->out, "=\t%s\t%s\t%ld\n", key, value, age);
	}
}

void
rp_rowf(struct rp *r, const char *key, long age, const char *fmt, ...)
{
	char b[512];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(b, sizeof(b), fmt, ap);
	va_end(ap);
	rp_row(r, key, b, age);
}

void
rp_line(struct rp *r, const char *key, const struct rp_rec *line)
{
	if (line == NULL) {
		rp_row(r, key, NULL, -1);
		return;
	}
	const char *c = strchr(line->text, ':');

	c = c != NULL ? c + 1 : line->text;
	while (*c == ' ') {
		c++;
	}
	rp_row(r, key, c, line->age);
}

void
rp_srow(struct rp *r, const char *key, const struct rp_rec *s)
{
	if (s == NULL) {
		rp_row(r, key, NULL, -1);
		return;
	}
	rp_rowf(r, key, s->age, "%s%s%s", s->a, s->text[0] ? ": " : "", s->text);
}

int
rp_after(const char *text, const char *label, char *out, size_t cap)
{
	const char *p = text != NULL ? strstr(text, label) : NULL;

	out[0] = 0;
	if (p == NULL) {
		return 0;
	}
	p += strlen(label);
	while (*p == ' ') {
		p++;
	}
	size_t n = strcspn(p, ",;|(");

	while (n != 0 && p[n - 1] == ' ') {
		n--;
	}
	if (n >= cap) {
		n = cap - 1;
	}
	memcpy(out, p, n);
	out[n] = 0;
	return n != 0;
}

int
rp_before(const char *text, const char *label, char *out, size_t cap)
{
	const char *p = text != NULL ? strstr(text, label) : NULL;

	out[0] = 0;
	if (p == NULL) {
		return 0;
	}
	const char *b = p;

	while (b != text && b[-1] != ' ') {
		b--;
	}
	size_t n = (size_t)(p - b);

	if (n == 0 || n >= cap) {
		return 0;
	}
	memcpy(out, b, n);
	out[n] = 0;
	return 1;
}

void
rp_cut_row(struct rp *r, const char *key, const struct rp_rec *line, const char *label)
{
	char b[160];

	if (line != NULL && rp_after(line->text, label, b, sizeof(b))) {
		rp_row(r, key, b, line->age);
	} else {
		rp_row(r, key, NULL, -1);
	}
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
