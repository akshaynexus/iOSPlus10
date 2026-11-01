#!/bin/sh
# Host test of the Mi A3 dual boot (docs/laurel_sprout/dual-boot.md). No phone, no root, no write outside out/. Some minutes: run it with scripts/bg.sh.
#   scripts/laurel/test-dualboot.sh
#   1. op10tool unit tests: FIEMAP -> table rules (overlap, alignment, outside userdata, holes, flags, damage).
#   2. The same format in C: laurel_dualboot.h reads what op10tool wrote; refused by both.
#   3. The real bsd/dev/sweet_ufs.c (the tree of `AUDIT=1 scripts/laurel/kernel-linux.sh` or a build) over a RAM disk: mapping, fence, self-checks, log thread, each failure = no block changed.
#   4. The phone helper, built for this host: write/verify/read on a fake partition file; scripts/laurel/ldbhelper-test.sh: file checks, record, the frozen seal and its failures, wipe. (aarch64 build: compile check only.)
#   6. scripts/laurel/android-guard-test.sh and scripts/laurel/dual-boot-test.sh: the scripts themselves, with a fake adb and fastboot. PATH holds no real adb or fastboot there.
# Proves the code on the host. Nothing here proves anything about the phone.
set -eu
. "$(dirname "$0")/../lib/env.sh"
T=$REPO/tools/laurel-dualboot
D=$OUT/laurel-dualboot-test
X=$OUT/laurel-kernel/xnu-src/xnu-8796.141.3
P=$REPO/patches/laurel/xnu/2950-laurel-dual-boot.patch
rm -rf "$D"; mkdir -p "$D"
CC=${CC:-clang}
CT=${CARGO_TARGET_DIR:-$OUT/cargo}
case "$CT" in /*) ;; *) CT=$PWD/$CT ;; esac

echo "== 1. op10tool unit tests"
(cd "$REPO/tools/op10tool" && CARGO_TARGET_DIR=$CT cargo test --release dualboot) > "$D/cargo-test.out" 2>&1 || { tail -30 "$D/cargo-test.out"; echo "test-dualboot: FAILED: cargo test" >&2; exit 1; }
grep -E '^test |^test result' "$D/cargo-test.out"
(cd "$REPO/tools/op10tool" && CARGO_TARGET_DIR=$CT cargo build --release) > "$D/cargo-build.out" 2>&1 || { tail -30 "$D/cargo-build.out"; exit 1; }
TOOL=$CT/release/op10tool

echo "== 2. the patch carries this header"
awk '$0 ~ /^\+\+\+ b\/bsd\/dev\/laurel_dualboot.h/ {p=1; next} p && /^diff / {exit} p && /^@@/ {next} p && /^\+/ {print substr($0, 2)}' "$P" > "$D/from-patch.h"
cmp "$D/from-patch.h" "$T/laurel_dualboot.h" || { echo "test-dualboot: FAILED: patch 2950 has another laurel_dualboot.h: regenerate it" >&2; exit 1; }
echo "ok   patch 2950 has the same laurel_dualboot.h"

echo "== 3. the real sweet_ufs.c over a RAM disk"
[ -f "$X/bsd/dev/sweet_ufs.c" ] && grep -q 'laurel 2950' "$X/bsd/dev/sweet_ufs.c" || { echo "test-dualboot: FAILED: no patched tree: AUDIT=1 scripts/laurel/kernel-linux.sh" >&2; exit 1; }
cmp "$X/bsd/dev/laurel_dualboot.h" "$T/laurel_dualboot.h"
mkdir -p "$D/k/sys" "$D/k/miscfs/devfs" "$D/k/kern" "$D/k/machine" "$D/k/arm" "$D/k/vm" "$D/k/pexpert" "$D/k/libkern"
for h in sys/param.h sys/systm.h sys/buf.h sys/conf.h sys/disk.h sys/errno.h sys/proc.h sys/uio.h sys/sysctl.h miscfs/devfs/devfs.h kern/locks.h kern/clock.h kern/sched_prim.h machine/machine_routines.h arm/caches_internal.h vm/pmap.h vm/vm_kern.h pexpert/pexpert.h pexpert/device_tree.h libkern/libkern.h machine/atomic.h kern/kalloc.h; do
  : > "$D/k/$h"
done
# the one change to the driver: its SCSI command goes to the RAM disk. ufs_scsi_hw (the MMIO path) stays compiled and unused.
sed -e 's/^ufs_scsi(const uint8_t \*cdb/ufs_scsi_hw(const uint8_t *cdb/' -e 's/\bufs_scsi(\([a-z]\)/ufs_scsi_fake(\1/g' "$X/bsd/dev/sweet_ufs.c" > "$D/k/sweet_ufs_host.c"
cp "$T/laurel_dualboot.h" "$D/k/"
grep -q '^ufs_scsi_hw(const' "$D/k/sweet_ufs_host.c"
sed -i '1i static int ufs_scsi_fake(const uint8_t *cdb, unsigned cdb_len, uint32_t len, bool write);' "$D/k/sweet_ufs_host.c"
$CC -std=gnu11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -Wall -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter -Wno-format -Wno-duplicate-decl-specifier \
  -I"$D/k" -I"$T/test" -o "$D/test_kernel" "$T/test/test_kernel.c"
ASAN_OPTIONS=detect_leaks=0 "$D/test_kernel" > "$D/test_kernel.out" 2>&1 || { grep -v '^SWEET' "$D/test_kernel.out" | tail -40; echo "test-dualboot: FAILED: test_kernel" >&2; exit 1; }
grep -E '^ok|^test_kernel:' "$D/test_kernel.out"
LDB_MARKER=$(sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$T/laurel_dualboot.h")
LC_ALL=C grep -aqF "$LDB_MARKER" "$D/test_kernel" || { echo "test-dualboot: FAILED: the kernel object has no marker text $LDB_MARKER" >&2; exit 1; }
echo "ok   H1 the driver built with the marker holds the text: $LDB_MARKER"
grep -E 'LAUREL DUALBOOT: (on|off)' "$D/test_kernel.out" | sed 's/^/     /' | sort -u

echo "== 4. the phone helper"
HC="$CC -std=gnu11 -O1 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld -Wall -Wextra -Wno-unused-parameter -I$T"
$HC -DLDB_TEST_NO_PIN -o "$D/ldbhelper" "$T/ldbhelper.c"
$HC --target=aarch64-linux-gnu -o "$D/ldbhelper-arm64" "$T/ldbhelper.c"
file "$D/ldbhelper-arm64" | cut -d, -f1-3
H=$D/ldbhelper
# a synthetic FIEMAP: fragmented, out of order on the partition
{ echo "pin-failures 0"; echo "extent 0 $((70000*4096)) $((512*4096)) 0"; echo "extent $((512*4096)) $((40000*4096)) $((3584*4096)) 0"; echo "extent $((4096*4096)) $((2048*4096)) $((4096)) 0"; echo "extent $((4097*4096)) $((90000*4096)) $((7903*4096)) 1"; } > "$D/fiemap.txt"
"$TOOL" dualboot table --fiemap "$D/fiemap.txt" --part-first 4096 --part-blocks 200000 --id 0xfeed -o "$D/table.ldbt" | sed 's/^/     /'
"$TOOL" dualboot check "$D/table.ldbt" >/dev/null
"$H" check "$D/table.ldbt" | sed 's/^/     C reads the Rust table: /'
# every byte of the table is checked, in C too
python3 -I - "$D/table.ldbt" "$H" <<'PY'
import subprocess, sys
p, h = sys.argv[1:]
b = open(p, 'rb').read()
bad = 0
for i in range(len(b)):
    c = bytearray(b); c[i] ^= 0x20
    open(p + '.x', 'wb').write(c)
    if subprocess.run([h, 'check', p + '.x'], capture_output=True).returncode == 0:
        bad += 1; print('accepted with byte', i, 'changed')
sys.exit(1 if bad else print(f'ok   C refuses the table with any of its {len(b)} bytes changed'))
PY
# overlap etc: op10tool refuses before there is a table
for bad in "extent 0 $((1000*4096)) $((1024*4096)) 0
extent $((1024*4096)) $((1500*4096)) $((1024*4096)) 0|overlap" "extent 0 4097 $((1024*4096)) 0|aligned" "extent 0 $((199999*4096)) $((1024*4096)) 0|outside" "extent 0 $((100*4096)) $((1024*4096)) 0|outside" "extent 0 $((1000*4096)) $((1024*4096)) 2048|flags"; do
  printf '%s\n' "${bad%%|*}" > "$D/bad.txt"
  o=$("$TOOL" dualboot table --fiemap "$D/bad.txt" --part-first 4096 --part-blocks 200000 -o "$D/bad.ldbt" 2>&1) && { echo "test-dualboot: FAILED: accepted: $bad" >&2; exit 1; }
  case "$o" in *"${bad##*|}"*) echo "ok   op10tool refuses: ${bad##*|}" ;; *) echo "test-dualboot: FAILED: $o" >&2; exit 1 ;; esac
done
# a fake HFS+ image with holes: an allocated hole must become zeros, a free hole stays
python3 -I - "$D/root.img" <<'PY'
import struct, sys
p = sys.argv[1]
blocks = 8000
with open(p, 'wb') as f:
    f.truncate(blocks * 4096)
    # volume header
    f.seek(1024)
    h = bytearray(512); h[:2] = b'HX'; h[3] = 5
    h[0x28:0x2c] = struct.pack('>I', 4096); h[0x2c:0x30] = struct.pack('>I', blocks)
    h[0x7c:0x80] = struct.pack('>I', 1)                      # allocation file: 1 block at block 2
    h[0x80:0x88] = struct.pack('>II', 2, 1)
    f.write(h)
    bm = bytearray(1000)
    for b in list(range(0, 3)) + list(range(100, 110)) + list(range(5000, 5100)):
        bm[b // 8] |= 0x80 >> (b % 8)
    f.seek(2 * 4096); f.write(bm)
    # data: crossing area extent ends
    f.seek(250 * 4096); f.write(bytes(range(256)) * 16 * 20)          # around area block 512 (image block 256)
    f.seek(3838 * 4096); f.write(b'\x77' * 4096 * 6)                  # around area blocks 4096, 4097 (the one-block extent)
PY
"$TOOL" dualboot stream "$D/table.ldbt" "$D/root.img" --index "$D/root.idx" > "$D/root.frames"
truncate -s $((200000 * 4096)) "$D/part.img"
python3 -I - "$D/part.img" <<'PY'
import sys, random
with open(sys.argv[1], 'r+b') as f:
    r = random.Random(5)
    for b in range(0, 200000, 7):
        f.seek(b * 4096); f.write(r.randbytes(4096))
PY
cp "$D/part.img" "$D/part.before"
# the frames against a fragmented synthetic table: no file behind it, so this test build skips the file checks here (those: ldbhelper-test.sh)
: > "$D/nofile"
NF="env LDB_TEST_FAULT=no-file-check"
$NF "$H" write "$D/table.ldbt" "$D/part.img" "$D/nofile" < "$D/root.frames" | sed 's/^/     /'
$NF "$H" verify "$D/table.ldbt" "$D/part.img" "$D/nofile" < "$D/root.idx" | sed 's/^/     /'
python3 -I - "$D" <<'PY'
import sys
d = sys.argv[1]
ext = [(0, 70000, 512), (512, 40000, 3584), (4096, 2048, 1), (4097, 90000, 7903)]
mask = bytearray(200000)
for a, p, n in ext:
    for i in range(n): mask[p + i] = 1
A, B, I = open(d + '/part.before', 'rb'), open(d + '/part.img', 'rb'), open(d + '/root.img', 'rb')
outside = 0
for b in range(200000):
    x, y = A.read(4096), B.read(4096)
    if x != y and not mask[b]: outside += 1
assert outside == 0, f'{outside} blocks outside the table changed'
def area(ab):
    for a, p, n in ext:
        if a <= ab < a + n:
            B.seek((p + ab - a) * 4096); return B.read(4096)
for b in (0, 2, 250, 256, 300, 3838, 3840, 3841, 3843):
    I.seek(b * 4096)
    assert area(b + 256) == I.read(4096), f'image block {b}'
# an allocated hole reads zero, a free hole keeps the old bytes
assert area(100 + 256) == bytes(4096) and area(5050 + 256) == bytes(4096), 'allocated hole not zero'
A.seek(0)
free_ab = 2000 + 256
for a, p, n in ext:
    if a <= free_ab < a + n: pb = p + free_ab - a
A.seek(pb * 4096)
assert area(free_ab) == A.read(4096), 'a free hole was written'
print('ok   image on the partition: 0 blocks outside the table changed, data right across extents, allocated holes zero, free holes untouched')
PY
# a frame outside the table, and over the header: refused, nothing written
python3 -I - "$D/evil.frames" <<'PY'
import struct, sys
def fnv(d):
    h = 0xcbf29ce484222325
    for x in d: h = ((h ^ x) * 0x100000001b3) & (2**64 - 1)
    return h
d = bytes(4096)
with open(sys.argv[1], 'wb') as f:
    f.write(b'LDBFRAME' + struct.pack('<QIIQ', 12000, 1, 0, fnv(d)) + d)
open(sys.argv[1] + '.hdr', 'wb').write(b'LDBFRAME' + struct.pack('<QIIQ', 0, 1, 0, fnv(d)) + d)
PY
cp "$D/part.img" "$D/part.before"
for e in evil.frames evil.frames.hdr; do
  if $NF "$H" write "$D/table.ldbt" "$D/part.img" "$D/nofile" < "$D/$e" > "$D/o" 2>&1; then echo "test-dualboot: FAILED: $e accepted" >&2; exit 1; fi
  grep -q 'out of range' "$D/o" || { cat "$D/o"; exit 1; }
done
cmp "$D/part.before" "$D/part.img"
echo "ok   helper: a frame outside the area and a frame over the header are refused, partition identical"
# bad hash in a frame
python3 -I - "$D/evil2" <<'PY'
import struct, sys
open(sys.argv[1], 'wb').write(b'LDBFRAME' + struct.pack('<QIIQ', 300, 1, 0, 12345) + bytes(4096))
PY
if $NF "$H" write "$D/table.ldbt" "$D/part.img" "$D/nofile" < "$D/evil2" >/dev/null 2>&1; then echo "test-dualboot: FAILED: bad frame hash accepted" >&2; exit 1; fi
cmp "$D/part.before" "$D/part.img"
echo "ok   helper: a frame with a wrong hash is refused, partition identical"
# check-map must not run over an installed root (the root is on the fake partition now): on a real file it would overwrite the image
if "$H" check-map "$D/table.ldbt" "$D/root.img" "$D/part.img" > "$D/o" 2>&1; then echo "test-dualboot: FAILED: check-map over a root" >&2; exit 1; fi
grep -q 'holds a root' "$D/o" || { cat "$D/o"; exit 1; }
cmp "$D/part.before" "$D/part.img"
echo "ok   helper: check-map refuses an area that holds a root"
# the refusals and the seal: a real file with real FIEMAP on this filesystem
LDB_TEST_DIR=$D sh "$REPO/scripts/laurel/ldbhelper-test.sh" "$H" "$TOOL" || { echo "test-dualboot: FAILED: ldbhelper-test" >&2; exit 1; }
echo "== 5. the table in the ADT, the way DarwinBoot hands it to the kernel"
if [ -f "$EXT/ios-topaz/tools/mkadt.py" ]; then
  python3 "$REPO/scripts/laurel/mkadt.py" "$D/t.adt" --cores 8 --boot gold --dram 0x81000000:0x30000000 --darwinboot --dualboot-table "$D/table.ldbt" 2>&1 | sed 's/^/     /'
  python3 -I - "$D/t.adt" "$D/table.ldbt" <<'PY'
import sys
blob, table = open(sys.argv[1], 'rb').read(), open(sys.argv[2], 'rb').read()
at = blob.find(b'laurel-dualboot\0')
assert at > 0, 'no property'
import struct
n = struct.unpack('<I', blob[at + 32:at + 36])[0]
assert n == len(table) and blob[at + 36:at + 36 + n] == table, f'property length {n}'
print(f'ok   ADT /chosen laurel-dualboot holds the table, {n} bytes, in the 32-byte name + length layout DarwinBoot checks')
PY
else
  echo "note ADT test skipped: no external/ios-topaz"
fi
echo "== 6. guards and the dual boot script, with a fake adb and fastboot"
sh "$REPO/scripts/laurel/android-guard-test.sh" || { echo "test-dualboot: FAILED: android-guard-test" >&2; exit 1; }
OP10TOOL=$TOOL sh "$REPO/scripts/laurel/dual-boot-test.sh" || { echo "test-dualboot: FAILED: dual-boot-test" >&2; exit 1; }
echo "test-dualboot: PASS"
