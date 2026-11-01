/*
 * Host test of XNUtils' data path (scripts/laurel/xnutils-test.sh): console text -> the kernel's table (laurel_stats_core.h, taken
 * from patch 2911) -> the report's parser and sections. Prints the report; checks are in the script.
 *   host_main LOG [KV_FILE] [--plain] [--chunk N]
 * LOG: console lines, an optional "HH:MM:SS " in front (usb log). KV_FILE: key=value lines, as collect_ios.c writes them.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "laurel_stats_core.h"
#include "report.h"

static struct ls_table t;
static struct rp r;

static char *
slurp(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");

	if (f == NULL) {
		perror(path);
		exit(2);
	}
	fseek(f, 0, SEEK_END);
	long n = ftell(f);

	fseek(f, 0, SEEK_SET);
	char *b = malloc((size_t)n + 1);

	if (fread(b, 1, (size_t)n, f) != (size_t)n) {
		exit(2);
	}
	b[n] = 0;
	fclose(f);
	*len = (size_t)n;
	return b;
}

int
main(int argc, char **argv)
{
	const char *log = NULL, *kv = NULL;
	int plain = 0;
	uint32_t chunk = 1024;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--plain") == 0) {
			plain = 1;
		} else if (strcmp(argv[i], "--chunk") == 0) {
			chunk = (uint32_t)atoi(argv[++i]);
		} else if (log == NULL) {
			log = argv[i];
		} else {
			kv = argv[i];
		}
	}
	size_t len;
	char *text = slurp(log, &len);
	/* the usb log's time stamp is the host's, not console text */
	char *clean = malloc(len + 1), *w = clean;

	for (char *line = text; line < text + len;) {
		char *e = memchr(line, '\n', (size_t)(text + len - line));
		size_t n = e != NULL ? (size_t)(e - line) + 1 : (size_t)(text + len - line);
		size_t skip = n > 9 && line[2] == ':' && line[5] == ':' && line[8] == ' ' ? 9 : 0;

		memcpy(w, line + skip, n - skip);
		w += n - skip;
		line += n;
	}
	uint64_t now = 1000, at = 0, total = (uint64_t)(w - clean);

	while (at < total) {
		uint32_t n = total - at < chunk ? (uint32_t)(total - at) : chunk;

		ls_feed(&t, clean + at, n, now);
		at += n;
	}
	static char out[LS_OUT_MAX + 65536];
	struct ls_out o = { out, 0, LS_OUT_MAX };
	uint64_t end = now + 5000;

	ls_s(&o, "v=1\nup_ms="); ls_u(&o, end);
	ls_s(&o, "\nlog.bytes="); ls_u(&o, total);
	ls_s(&o, "\nlog.lost=0\nlog.lines="); ls_u(&o, t.lines);
	ls_s(&o, "\nlog.full="); ls_u(&o, t.full);
	ls_s(&o, "\nlog.thread_scans=7\n");
	ls_print(&t, &o, end);
	if (kv != NULL) {
		size_t kn;
		char *k = slurp(kv, &kn);

		memcpy(out + o.at, k, kn + 1);
		o.at += (uint32_t)kn;
	}
	fprintf(stderr, "table: %llu lines, %llu dropped for a full table, report text %u bytes (limit %u)\n", (unsigned long long)t.lines,
	    (unsigned long long)t.full, o.at, (unsigned)LS_OUT_MAX);
	r.out = stdout;
	r.plain = plain;
	rp_parse(&r, out);
	rp_all(&r);
	return 0;
}
