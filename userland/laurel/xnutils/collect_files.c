/* The Metal and GL switch files, as the report shows them (collect_ios.c has the frame). Read-only. */
#include <dirent.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "collect.h"
#include <sys/stat.h>

/* the tokens of a list file, one line, without comment lines */
static int
read_list(const char *path, char *o, size_t cap)
{
	FILE *f = fopen(path, "r");
	char line[512];
	size_t n = 0;

	o[0] = 0;
	if (f == NULL) {
		return 0;
	}
	while (fgets(line, sizeof(line), f) != NULL) {
		if (line[0] == '#') {
			continue;
		}
		char *save = NULL;

		for (char *t = strtok_r(line, " \t\r\n", &save); t != NULL; t = strtok_r(NULL, " \t\r\n", &save)) {
			n += (size_t)snprintf(o + n, cap - n, "%s%s", n ? " " : "", t);
			if (n >= cap) {
				n = cap - 1;
			}
		}
	}
	fclose(f);
	return 1;
}

static int
first_line_is(const char *path, const char *mark)
{
	char line[128] = "";
	FILE *f = fopen(path, "r");

	if (f == NULL) {
		return 0;
	}
	if (fgets(line, sizeof(line), f) == NULL) {
		line[0] = 0;
	}
	fclose(f);
	return strncmp(line, mark, strlen(mark)) == 0;
}

void
xt_collect_files(void)
{
	char list[512], names[256] = "";
	struct stat st;
	int off = stat(XT_METAL_OFF, &st) == 0;

	kv("metal.off", "%d", off);
	int have = read_list(XT_METAL_CLIENTS, list, sizeof(list));

	if (have) {
		kv("metal.clients", "%s", list[0] ? list : "(empty)");
	}
	if (off) {
		kv("metal.mode", "off (off file)");
	} else if (!have) {
		kv("metal.mode", "no clients file");
	} else if (first_line_is(XT_METAL_CLIENTS, XT_GATE_MARK)) {
		kv("metal.mode", "auto (the gate's list)");
	} else if (strcmp(list, XT_METAL_WIDE) == 0) {
		kv("metal.mode", "all (own list)");
	} else if (strcmp(list, XT_METAL_PROBES) == 0) {
		kv("metal.mode", "probes (own list)");
	} else {
		kv("metal.mode", "custom (own list)");
	}
	if (read_list(XT_METAL_LOCAL, list, sizeof(list))) {
		kv("metal.local", "%s", list[0] ? list : "(empty)");
	}
	if (read_list(XT_METAL_GATE, list, sizeof(list))) {
		/* "<state> <tries> <full> <key>": the key is a long build hash */
		char *sp = strchr(list, ' ');

		sp = sp ? strchr(sp + 1, ' ') : NULL;
		sp = sp ? strchr(sp + 1, ' ') : NULL;
		if (sp != NULL) {
			*sp = 0;
		}
		kv("metal.gate", "%s", list);
	}
	int strikes = 0;
	DIR *d = opendir(XT_METAL_STRIKES);

	if (d != NULL) {
		size_t n = 0;

		for (struct dirent *e; (e = readdir(d)) != NULL;) {
			if (e->d_name[0] != '.') {
				strikes++;
				if (n + e->d_namlen + 3 < sizeof(names)) {
					n += (size_t)snprintf(names + n, sizeof(names) - n, "%s%s", n ? ", " : "", e->d_name);
				}
			}
		}
		closedir(d);
		kv("metal.strikes", strikes ? "%d: %s" : "%d%s", strikes, names);
	}
	if ((d = opendir(XT_METAL_CACHE)) != NULL) {
		long files = 0;
		uint64_t bytes = 0;

		for (struct dirent *e; (e = readdir(d)) != NULL;) {
			char p[300];

			if (e->d_name[0] == '.') {
				continue;
			}
			snprintf(p, sizeof(p), XT_METAL_CACHE "/%s", e->d_name);
			DIR *sub = opendir(p);

			if (sub == NULL) {
				continue;
			}
			for (struct dirent *f; (f = readdir(sub)) != NULL;) {
				char q[600];

				snprintf(q, sizeof(q), "%s/%s", p, f->d_name);
				if (f->d_name[0] != '.' && lstat(q, &st) == 0 && S_ISREG(st.st_mode)) {
					files++;
					bytes += (uint64_t)st.st_size;
				}
			}
			closedir(sub);
		}
		closedir(d);
		kv("metal.cache_files", "%ld", files);
		kv("metal.cache_bytes", "%llu", (unsigned long long)bytes);
	}
	kv("gl.off", "%d", stat(XT_GL_OFF, &st) == 0);
}

