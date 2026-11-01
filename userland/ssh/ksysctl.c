/*
 * ksysctl NAME...: read kernel values by name, for a shell on iOS (the iOS root has no /usr/sbin/sysctl). Read-only. scripts/laurel/ios26-diag.py reads kern.laurel_stats with it.
 *   ksysctl kern.laurel_stats kern.laurel_reboot_mode kern.bootargs
 * A value of 4 or 8 bytes prints as a number, anything else as text. A name the kernel does not have: one line, and exit 1 at the end.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

int main(int argc, char **argv)
{
	int rc = 0;

	if (argc < 2) {
		fprintf(stderr, "usage: ksysctl NAME...\n");
		return 2;
	}
	for (int i = 1; i < argc; i++) {
		size_t len = 0;

		if (sysctlbyname(argv[i], NULL, &len, NULL, 0) != 0) {
			printf("%s: not in this kernel\n", argv[i]);
			rc = 1;
			continue;
		}
		char *buf = malloc(len + 1);
		if (buf == NULL || sysctlbyname(argv[i], buf, &len, NULL, 0) != 0) {
			printf("%s: read failed\n", argv[i]);
			free(buf);
			rc = 1;
			continue;
		}
		buf[len] = 0;
		if (len == 4) {
			int32_t v;
			memcpy(&v, buf, 4);
			printf("%s: %d\n", argv[i], v);
		} else if (len == 8) {
			int64_t v;
			memcpy(&v, buf, 8);
			printf("%s: %lld\n", argv[i], (long long)v);
		} else {
			printf("%s: %s\n", argv[i], buf);
		}
		free(buf);
	}
	return rc;
}
