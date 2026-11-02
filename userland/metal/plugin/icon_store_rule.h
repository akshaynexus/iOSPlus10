/*
 * iconservicesagent's store of drawn icons (.isdata, com.apple.IconsCache/<UUID>/) is keyed by build and language only [V __cache_info__ on the phone: ProductBuildVersion, language]: what a boot drew stays for all later boots.
 * Boot 16 [V]: 537 of 550 entries were drawn before the plug-in had specializedName links (flame-ios26/0002): 242 are empty, others have lost their glyph; those 13 drawn after it are right. The owner's photo of Home is those old entries.
 * So the store carries the generation of the drawing stack. Other generation: all .isdata go, iconservicesagent draws them again at their next use. A plain C rule: scripts/ios26/test-icon-store.sh runs it on a folder.
 * Raise LAUREL_ICON_GENERATION when a fix changes what RenderBox or IconRendering draw; not for each build (a new draw of 550 icons costs minutes of CPU and GPU [I]).
 */
#ifndef ICON_STORE_RULE_H
#define ICON_STORE_RULE_H
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define LAUREL_ICON_GENERATION 1
#define LAUREL_ICON_STORE "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache"
/* >= 0: entries removed (0: the store has this generation). -1: the store cannot be read or stamped: nothing changes for the next start's sake. */
static inline int laurel_icon_store_refresh(const char *base, int generation)
{
	char stamp[1024], text[32] = "", want[32];
	snprintf(stamp, sizeof(stamp), "%s/.laurel-generation", base);
	snprintf(want, sizeof(want), "%d\n", generation);
	int fd = open(stamp, O_RDONLY);
	if (fd >= 0) {
		ssize_t n = read(fd, text, sizeof(text) - 1);
		close(fd);
		if (n > 0 && strncmp(text, want, sizeof(text)) == 0)
			return 0;
	}
	DIR *top = opendir(base);
	if (top == NULL)
		return -1;
	int removed = 0;
	struct dirent *e;
	while ((e = readdir(top)) != NULL) {
		if (e->d_name[0] == '.')
			continue;
		char dir[1024];
		snprintf(dir, sizeof(dir), "%s/%s", base, e->d_name);
		DIR *d = opendir(dir);
		if (d == NULL)
			continue;
		struct dirent *f;
		while ((f = readdir(d)) != NULL) {
			size_t len = strlen(f->d_name);
			if (len > 7 && strcmp(f->d_name + len - 7, ".isdata") == 0) {
				char path[2048];
				snprintf(path, sizeof(path), "%s/%s", dir, f->d_name);
				if (unlink(path) == 0)
					removed++;
			}
		}
		closedir(d);
	}
	closedir(top);
	fd = open(stamp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
		return -1;
	ssize_t wrote = write(fd, want, strlen(want));
	close(fd);
	return wrote > 0 ? removed : -1;
}
#endif
