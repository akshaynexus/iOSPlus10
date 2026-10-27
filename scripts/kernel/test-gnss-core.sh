#!/bin/sh
# Host test of the pure GNSS code of patch 0397 (bsd/dev/negroni_gnss_core.h): soft float, QMI TLV lookup,
# TFTP path map, and the FAT16 reader on a copy of the modem_a image (out/firmware/modem/modem.img, if
# present) against an independent Python reader. macOS and Linux (cc, python3). Quick, foreground is fine.
#   scripts/kernel/test-gnss-core.sh [PATCH | HEADER]
#     PATCH   default patches/xnu/0397-negroni-gnss.patch (the header is taken from it)
#     HEADER  a negroni_gnss_core.h file (a scratch tree while the patch is written)
set -eu
. "$(dirname "$0")/../lib/env.sh"
SRC=${1:-$REPO/patches/xnu/0397-negroni-gnss.patch}
D=$OUT/gnss-core-test
rm -rf "$D"
mkdir -p "$D"
case "$SRC" in
*.h) cp "$SRC" "$D/negroni_gnss_core.h" ;;
*) awk '/^\+\+\+ b\/bsd\/dev\/negroni_gnss_core\.h$/ {p=1; next}
     p && /^diff --git / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$SRC" > "$D/negroni_gnss_core.h" ;;
esac
[ -s "$D/negroni_gnss_core.h" ] || { echo "no negroni_gnss_core.h in $SRC" >&2; exit 1; }
${CC:-cc} -O2 -Wall -Wextra -I"$D" -o "$D/gnss-core-test" "$REPO/patches/xnu/tests/gnss-core-test.c" -lm
"$D/gnss-core-test"

IMG=${GNSS_IMG:-$OUT/firmware/modem/modem.img}
[ -f "$IMG" ] || { echo "no $IMG: FAT test skipped (scripts/modem or a dump of modem_a)"; exit 0; }
FILES="image/modem.mdt image/modem.b02 image/modem.b23 image/modem.b19 image/modemr.jsn image/modem_pr/so/771_0_0.mbn
image/modem_pr/mcfg/configs/mcfg_hw/mbn_hw.txt image/modem_pr/mcfg/configs/mcfg_hw/oem_hw.txt verinfo/ver_info.txt
IMAGE/MODEM.MDT"
# shellcheck disable=SC2086
"$D/gnss-core-test" "$IMG" $FILES > "$D/c.txt"
# shellcheck disable=SC2086
python3 -I - "$IMG" $FILES > "$D/py.txt" <<'EOF'
import struct, sys
f = open(sys.argv[1], "rb")
b = f.read(512)
bps, spc, res, nf, rootents, tot16, media, fatsz = struct.unpack("<HBHBHHBH", b[11:24])
fat_off = res * bps
root_off = fat_off + nf * fatsz * bps
data_off = root_off + ((rootents * 32 + bps - 1) // bps) * bps
cl = spc * bps
f.seek(fat_off); fat = f.read(fatsz * bps)
def chain(c):
    while 2 <= c < 0xfff8:
        yield c
        c = struct.unpack_from("<H", fat, 2 * c)[0]
def readc(c, size):
    d = b"".join((f.seek(data_off + (x - 2) * cl), f.read(cl))[1] for x in chain(c))
    return d[:size]
def entries(raw):
    lfn = {}
    for i in range(0, len(raw), 32):
        e = raw[i:i + 32]
        if e[0] == 0: break
        if e[0] == 0xe5: lfn = {}; continue
        if e[11] == 0x0f:
            part = (e[1:11] + e[14:26] + e[28:32]).decode("utf-16le", "replace")
            lfn[e[0] & 0x1f] = part; continue
        long = "".join(lfn[k] for k in sorted(lfn)).split("\0")[0].replace("￿", "")
        lfn = {}
        short = e[0:8].decode().rstrip() + ("." + e[8:11].decode().rstrip() if e[8:11].strip() else "")
        yield long, short, e[11], struct.unpack_from("<H", e, 26)[0], struct.unpack_from("<I", e, 28)[0]
f.seek(root_off); root = f.read(rootents * 32)
def find(path):
    raw = root
    parts = [p for p in path.split("/") if p]
    for i, p in enumerate(parts):
        for lng, sht, attr, c, sz in entries(raw):
            if p.lower() in (lng.lower(), sht.lower()):
                if i == len(parts) - 1:
                    return None if attr & 0x10 else readc(c, sz)
                raw = readc(c, 1 << 30); break
        else:
            return None
for p in sys.argv[2:]:
    d = find(p)
    if d is None:
        print(p, "missing"); continue
    h = 0xcbf29ce484222325
    for x in d:
        h = ((h ^ x) * 0x100000001b3) & 0xffffffffffffffff
    print(p, len(d), "%016x" % h)
EOF
if cmp -s "$D/c.txt" "$D/py.txt"; then
  echo "FAT PASS ($(wc -l < "$D/c.txt" | tr -d ' ') files, same bytes as the Python reader)"
  cat "$D/c.txt"
else
  echo "FAT FAIL"; diff "$D/c.txt" "$D/py.txt" || true; exit 1
fi
