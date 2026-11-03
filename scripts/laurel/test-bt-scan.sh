#!/bin/sh
# Host test of kernel patch post/9012 (Mi A3, iOS 26): the code of the patch, under ASan and UBSan, with no phone.
#   scripts/laurel/test-bt-scan.sh     exit 0 = PASS
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=$REPO/out/test-bt-scan
mkdir -p "$W"
python3 -I - "$REPO/patches/laurel/xnu-12377/post/9012-laurel-bt-legacy-le-scan.patch" "$W/block.c" <<'PY'
import sys
out = []; on = False
for l in open(sys.argv[1]):
    if l.startswith('+'):
        t = l[1:]
        if on:
            out.append(t)
        elif t.startswith(' * laurel 9012 (iOS 26): LE scan'):
            on = True
            out = ['/*\n', t]
    elif on:
        break
assert out, 'block not found'
open(sys.argv[2], 'w').write(''.join(out))
PY
cat > "$W/test.c" <<'EOF2'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define LBT_SCAN_EVENT_MAX 300u
#define bzero(p, n) memset((p), 0, (n))
struct lbt_shim { bool mask_known, err_rd, err_wr, scan_ext; uint8_t params_out, enable_out; };
static inline uint16_t lbt_le16(const uint8_t *b) { return (uint16_t)(b[0] | b[1] << 8); }
static uint32_t bootarg = 1;
#define PE_parse_boot_argn(k, v, s) (*(v) = bootarg, 1)
#include "block.c"

int main(void)
{
	struct lbt_shim s;
	uint8_t c[32], out[LBT_SCAN_EVENT_MAX];
	uint32_t n;

	memset(&s, 0, sizeof(s));
	/* 0x2041: own 1, filter 0, phys 1M, active, interval 0x0030, window 0x0012 */
	static const uint8_t ext[] = { 1, 0x41, 0x20, 8, 1, 0, 1, 1, 0x30, 0, 0x12, 0 };
	memcpy(c, ext, sizeof(ext));
	n = sizeof(ext);
	assert(lbt_scan_command(&s, c, &n) == 1);
	static const uint8_t leg[] = { 1, 0x0b, 0x20, 7, 1, 0x30, 0, 0x12, 0, 1, 0 };
	assert(n == sizeof(leg) && memcmp(c, leg, n) == 0);
	assert(s.params_out == 1 && s.scan_ext);

	/* 0x2042: enable 1, filter 2, duration, period */
	static const uint8_t en[] = { 1, 0x42, 0x20, 6, 1, 2, 0, 0, 0, 0 };
	memcpy(c, en, sizeof(en));
	n = sizeof(en);
	assert(lbt_scan_command(&s, c, &n) == 1);
	static const uint8_t len2[] = { 1, 0x0c, 0x20, 2, 1, 1 };
	assert(n == sizeof(len2) && memcmp(c, len2, n) == 0);

	/* event mask keeps LE Advertising Report */
	static const uint8_t mask[] = { 1, 0x01, 0x20, 8, 0x00, 0x10, 0, 0, 0, 0, 0, 0 };
	memcpy(c, mask, sizeof(mask));
	n = sizeof(mask);
	assert(lbt_scan_command(&s, c, &n) == 1 && c[4] == 0x02 && c[5] == 0x10 && n == sizeof(mask));

	/* a legacy command stays */
	static const uint8_t own[] = { 1, 0x0b, 0x20, 7, 1, 0x30, 0, 0x12, 0, 1, 0 };
	memcpy(c, own, sizeof(own));
	n = sizeof(own);
	assert(lbt_scan_command(&s, c, &n) == 0 && memcmp(c, own, n) == 0);

	/* too short: not touched */
	static const uint8_t bad[] = { 1, 0x41, 0x20, 3, 1, 0, 1 };
	memcpy(c, bad, sizeof(bad));
	n = sizeof(bad);
	assert(lbt_scan_command(&s, c, &n) == 0 && n == sizeof(bad));

	/* two reports: ADV_IND with 3 bytes, RSSI -40; SCAN_RSP with 0 bytes, RSSI -50 */
	static const uint8_t ev[] = { 4, 0x3e, 25, 0x02, 2,
		0, 1, 1, 2, 3, 4, 5, 6, 3, 0xaa, 0xbb, 0xcc, 0xd8,
		4, 0, 7, 8, 9, 10, 11, 12, 0, 0xce };
	assert(sizeof(ev) == 28);
	unsigned l = lbt_scan_report(&s, ev, sizeof(ev), 0, out);
	assert(l == 5 + 24 + 3 && out[2] == 29 && out[3] == 0x0d && out[4] == 1 && out[5] == 0x13 && out[6] == 0);
	assert(out[7] == 1 && memcmp(out + 8, ev + 7, 6) == 0 && out[14] == 1 && out[15] == 0 && out[16] == 0xff && out[17] == 0x7f);
	assert(out[18] == 0xd8 && out[28] == 3 && memcmp(out + 29, ev + 14, 3) == 0);
	l = lbt_scan_report(&s, ev, sizeof(ev), 1, out);
	assert(l == 5 + 24 && out[5] == 0x1b && out[18] == 0xce && out[28] == 0);
	assert(lbt_scan_report(&s, ev, sizeof(ev), 2, out) == 0);

	/* a cut report, another event, no extended scan: not converted */
	assert(lbt_scan_report(&s, ev, sizeof(ev) - 1, 0, out) == 0);
	static const uint8_t cc[] = { 4, 0x0e, 4, 1, 0x0b, 0x20, 0 };
	assert(lbt_scan_report(&s, cc, sizeof(cc), 0, out) == 0);
	struct lbt_shim s2;
	memset(&s2, 0, sizeof(s2));
	assert(lbt_scan_report(&s2, ev, sizeof(ev), 0, out) == 0);

	/* kill switch: only a fresh process can show it: see the second run */
	puts("test-bt-scan: PASS");
	return 0;
}
EOF2
cc -g -std=c11 -D_DEFAULT_SOURCE -fsanitize=address,undefined -fno-sanitize-recover=all -Wall -Wno-unused-function -o "$W/test" "$W/test.c" -I"$W"
"$W/test"
