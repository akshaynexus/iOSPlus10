/*
 * Host test of bsd/dev/laurel_bt_fw.c (laurel 2600/2601): the kernel file, compiled for the host with stubs for the
 * UART/HCI side. Firmware files come from a directory (the BTFM.bin FAT image, extracted by bt-fw-test.sh).
 *   bt-fw-test DIR PRODUCT ROM SOC   e.g. bt-fw-test out/bt-fw 0xf 0x0102 0x40070120
 * Prints the kernel's LAUREL BT lines, the result and the NVM tag-17 bytes as sent. Exit 0 = download accepted.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "laurel_bt.h"

static const char *dir;
static uint8_t sent[1 << 20];
static uint32_t sent_n, nvm_at = ~0u;

uint64_t lbt_us(void) { static uint64_t t; return t += 10; }
int lbt_hci_send(uint16_t op, const uint8_t *p, uint8_t n)
{
	if (op != LBT_EDL_OP || n < 2 || sent_n + p[1] > sizeof(sent)) {
		return EIO;
	}
	memcpy(sent + sent_n, p + 2, p[1]);
	sent_n += p[1];
	return 0;
}
uint32_t lbt_hci_event(uint8_t *ev, uint32_t max, uint32_t ms) { (void)ms; return max >= 6 ? 6 : 0; }
int lbt_qca_tlv_ack(const uint8_t *e, size_t n) { (void)e; (void)n; return 1; }
int lbt_fat_load(const char *name, uint8_t **d, uint32_t *n, char part[16], const char **why)
{
	char path[512];
	FILE *f;
	long l;

	snprintf(path, sizeof(path), "%s/%s", dir, name);
	if ((f = fopen(path, "rb")) == NULL) {
		*why = "not found";
		return ENOENT;
	}
	fseek(f, 0, SEEK_END);
	l = ftell(f);
	rewind(f);
	*d = malloc((size_t)l);
	*n = (uint32_t)fread(*d, 1, (size_t)l, f);
	fclose(f);
	snprintf(part, 16, "host");
	if (name[2] == 'n') {
		nvm_at = sent_n;                /* the NVM starts here in sent[] */
	}
	return 0;
}
void lbt_fw_free(uint8_t *d, uint32_t n) { (void)n; free(d); }

int
main(int argc, char **argv)
{
	struct lbt_qca_version v;
	uint8_t addr[6];
	bool have = false;
	char names[128] = "";
	const char *why = "";

	if (argc != 5) {
		fprintf(stderr, "usage: %s DIR PRODUCT ROM SOC\n", argv[0]);
		return 2;
	}
	dir = argv[1];
	v.product = (uint32_t)strtoul(argv[2], NULL, 0);
	v.rom = (uint16_t)strtoul(argv[3], NULL, 0);
	v.soc = (uint32_t)strtoul(argv[4], NULL, 0);
	v.patch = 1;
	int e = lbt_fw_download(&v, 0x0e, addr, &have, names, sizeof(names), &why);
	printf("result: %s: %s%s\n", e ? "off" : "on", names, e ? "" : "");
	if (e) {
		printf("why: %s (errno %d)\n", why, e);
		return 1;
	}
	if (nvm_at != ~0u) {
		/* find tag 17 in the NVM as sent (type 4 or 2 header) */
		uint8_t *d = sent + nvm_at;
		uint32_t base = d[0] == 4 ? 8 : 4, len = lbt_le32(d + base - 4) >> 8;
		for (uint32_t off = base; off + 12 <= base + len; off += 12 + lbt_le16(d + off + 2)) {
			if (lbt_le16(d + off) == 17) {
				printf("NVM tag 17 as sent:");
				for (unsigned i = 0; i < lbt_le16(d + off + 2); i++) {
					printf(" %02x", d[off + 12 + i]);
				}
				printf("\n");
			}
		}
	}
	printf("BD_ADDR from NVM: %s\n", have ? "yes" : "no");
	return 0;
}
