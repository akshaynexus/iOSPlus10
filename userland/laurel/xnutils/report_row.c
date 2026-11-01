/* The report's row writer and its small text helpers (report.h). */
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include "report.h"

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

