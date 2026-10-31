#!/bin/sh
# Check `op10tool fatls` (the host model of the kernel FAT parser, laurel patch 2400) on small FAT16 and
# FAT32 images made with mkfs.fat + mtools: long names, upper-case short names, a path 13 directories
# deep, a fragmented file, a path over 255 characters (must be skipped), CRC-32 of every file equal to
# the source. Needs dosfstools + mtools. Works in out/test/fatls. Binary: scripts/setup/build-op10tool.sh.
set -eu
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
. "$REPO/scripts/lib/env.sh"
OP=$OUT/bin/op10tool
[ -x "$OP" ] || { echo "fatls-test: no $OP: scripts/bg.sh op10tool scripts/setup/build-op10tool.sh" >&2; exit 1; }
for t in mkfs.fat mcopy mmd mdel python3; do command -v $t >/dev/null || { echo "fatls-test: missing $t" >&2; exit 1; }; done
T=$OUT/test/fatls
rm -rf "$T"; mkdir -p "$T/src"
fail=0
ok() { if "$@"; then echo "  ok: $*"; else echo "  FAIL: $*"; fail=1; fi; }

# source files (fixed seed) and their CRC-32
python3 -I - "$T/src" <<'EOF'
import os, random, sys, zlib
d = sys.argv[1]; r = random.Random(2400)
for name, size in [("modem.mdt", 9100), ("a.bin", 40000), ("b.bin", 3000), ("big.bin", 300000),
                   ("Long Name File.BIN", 5000), ("deep.bin", 77), ("UPPER.TXT", 12), ("toolong.bin", 5)]:
    data = bytes(r.getrandbits(8) for _ in range(size))
    open(os.path.join(d, name), "wb").write(data)
    print(f"{zlib.crc32(data):08x}\t{name}", file=open(os.path.join(d, "crc.txt"), "a"))
EOF
crc() { awk -F '\t' -v n="$1" '$2 == n { print $1 }' "$T/src/crc.txt"; }

for fat in 16 32; do
  echo "== FAT$fat"
  I=$T/fat$fat.img
  if [ $fat = 16 ]; then mkfs.fat -F 16 -S 512 -s 4 -C "$I" 16384 >/dev/null; else mkfs.fat -F 32 -S 512 -s 1 -C "$I" 65536 >/dev/null; fi
  mmd -i "$I" ::/image
  mcopy -i "$I" "$T/src/modem.mdt" "$T/src/UPPER.TXT" "$T/src/Long Name File.BIN" ::/image/
  # fragmented: a.bin, b.bin, delete a.bin, big.bin fills a's hole and goes on after b.bin
  mcopy -i "$I" "$T/src/a.bin" "$T/src/b.bin" ::/image/
  mdel -i "$I" ::/image/a.bin
  # FAT32: forget the FSInfo next-free hint (else mtools allocates after b.bin, not in the hole)
  [ $fat = 32 ] && python3 -I -c 'import struct,sys
f=open(sys.argv[1],"r+b"); bs=f.read(512); fsi=struct.unpack_from("<H",bs,48)[0]*512
f.seek(fsi+492); f.write(b"\xff\xff\xff\xff")' "$I"
  mcopy -i "$I" "$T/src/big.bin" ::/image/
  deep=image; for k in 1 2 3 4 5 6 7 8 9 10 11 12; do deep=$deep/d$k; mmd -i "$I" "::/$deep"; done
  mcopy -i "$I" "$T/src/deep.bin" "::/$deep/"
  long=image/$(printf 'x%.0s' $(seq 1 120))/$(printf 'y%.0s' $(seq 1 120))
  mmd -i "$I" "::/${long%/*}"; mmd -i "$I" "::/$long"
  mcopy -i "$I" "$T/src/toolong.bin" "::/$long/"
  sz=$(wc -c < "$I" | tr -d ' ')
  "$OP" fatls --part-bytes "$sz" "$I" > "$T/list$fat.txt"
  ok grep -q "FAT$fat, 512-byte sectors, .* 6 files (1 fragmented)\$" "$T/list$fat.txt"
  for f in modem.mdt upper.txt "long name file.bin" b.bin big.bin; do
    "$OP" fatls --part-bytes "$sz" "$I" "image/$f" > "$T/one.txt"
    src=$(ls "$T/src" | awk -v f="$f" 'tolower($0) == f')
    ok grep -q "crc32 $(crc "$src")  image/$f\$" "$T/one.txt"
  done
  ok grep -q " runs   2  image/big.bin\$" "$T/list$fat.txt"
  ok grep -q "crc32 $(crc deep.bin)  $deep/deep.bin\$" "$("$OP" fatls --part-bytes "$sz" "$I" "$deep/deep.bin" > "$T/one.txt"; echo "$T/one.txt")"
  ok sh -c "! grep -q toolong.bin '$T/list$fat.txt'"
  # the volume must fit in the partition (kernel: GPT size)
  ok sh -c "! '$OP' fatls --part-bytes $((sz - 4096)) '$I' >/dev/null 2>&1"
done
[ $fail = 0 ] && echo "fatls-test: all ok" || { echo "fatls-test: FAILED"; exit 1; }
