/*
 * Host test of the laurel 2770 ext4 reader (bsd/dev/laurel_ext4.c + laurel_ext4_dir.c, taken from the patch):
 *   ext4_test IMAGE OUTDIR PATH...
 * Reads each PATH from the raw ext4 IMAGE with the kernel code and writes it to OUTDIR/<basename>; prints
 * "PATH SIZE". test-ipa.sh compares the files with debugfs (when present) and checks the ELF layout.
 * Also checks the error paths: a missing file, a directory as a file, a file as a directory.
 */
#include "kstub_ipa.h"
#include <stdlib.h>

int kt_printf(const char *fmt, ...) { va_list ap; va_start(ap, fmt); int n = vprintf(fmt, ap); va_end(ap); return n; }
uint64_t kt_now_ns;
int PE_parse_boot_argn(const char *n, void *v, int s) { (void)n; (void)v; (void)s; return 0; }

#include "laurel_ext4.c"
#include "laurel_ext4_dir.c"

static int
rd_file(void *ctx, uint64_t off, void *dst, uint64_t len)
{
	FILE *f = ctx;
	if (fseeko(f, (off_t)off, SEEK_SET) != 0 || fread(dst, 1, len, f) != len) {
		return EIO;
	}
	return 0;
}

static int
expect_err(struct lext4 *fs, const char *path, int64_t want)
{
	char why[96] = "";
	int64_t r = lext4_read_file(fs, path, NULL, 0, why, sizeof(why));
	if (r != want) {
		printf("FAIL: %s: %lld (want %lld) %s\n", path, (long long)r, (long long)want, why);
		return 1;
	}
	printf("ok: %s: %s\n", path, why);
	return 0;
}

int
main(int argc, char **argv)
{
	struct lext4 fs;
	char why[96] = "";
	int bad = 0;

	if (argc < 4) {
		fprintf(stderr, "usage: ext4_test IMAGE OUTDIR PATH...\n");
		return 2;
	}
	FILE *f = fopen(argv[1], "rb");
	if (f == NULL || fseeko(f, 0, SEEK_END) != 0) {
		perror(argv[1]);
		return 2;
	}
	uint64_t vol = (uint64_t)ftello(f);
	if (lext4_mount(&fs, rd_file, f, vol, why, sizeof(why)) != 0) {
		printf("FAIL: mount: %s\n", why);
		return 1;
	}
	printf("mounted: block %u, %llu blocks, %u groups, inode %u, incompat %x\n", fs.bsize,
	    (unsigned long long)fs.blocks, fs.groups, fs.inode_size, fs.incompat);
	for (int i = 3; i < argc; i++) {
		int64_t n = lext4_read_file(&fs, argv[i], NULL, 0, why, sizeof(why));
		if (n < 0) {
			printf("FAIL: %s: %s\n", argv[i], why);
			bad++;
			continue;
		}
		uint8_t *b = malloc((size_t)n + 1);
		int64_t m = lext4_read_file(&fs, argv[i], b, (uint64_t)n, why, sizeof(why));
		const char *base = strrchr(argv[i], '/');
		char out[512];
		snprintf(out, sizeof(out), "%s/%s", argv[2], base != NULL ? base + 1 : argv[i]);
		FILE *o = fopen(out, "wb");
		if (m != n || o == NULL || fwrite(b, 1, (size_t)n, o) != (size_t)n) {
			printf("FAIL: %s: read %lld of %lld\n", argv[i], (long long)m, (long long)n);
			bad++;
		} else {
			printf("%s %lld\n", argv[i], (long long)n);
		}
		if (o != NULL) {
			fclose(o);
		}
		free(b);
	}
	bad += expect_err(&fs, "/firmware/no_such_file.bin", -ENOENT);
	bad += expect_err(&fs, "/firmware", -EINVAL);
	bad += expect_err(&fs, "/firmware/ipa_fws.mdt/x", -ENOTDIR);
	lext4_unmount(&fs);
	fclose(f);
	return bad != 0;
}
