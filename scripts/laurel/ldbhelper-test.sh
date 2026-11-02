#!/bin/sh
# Host test of the phone helper: the real gpt-write and gpt-dump on a sparse file of the size of the phone's LUN 0, with a table in its layout (gpt-fake.py), and a power cut after each step.
#   scripts/laurel/ldbhelper-test.sh HELPER TOOL     HELPER: built for this host with -DLDB_TEST_FILE (DEV is a file: no ioctl, no O_DIRECT; LDB_TEST_STOP=N ends it after step N, as a power cut)
#   LDB_DIRECT=path LDB_DIO=path: the phone's own code built for this host (no test define), and test/dio_check.c: the same writes with real O_DIRECT and the block rules of 4.14. ONLY=glob: only the F* cases that match (dualboot-tests-detect.sh).
# Proves the logic on the host. Nothing here proves anything about the phone: block device, SELinux, UFS behaviour at a power loss.
set -u
H=$1; TOOL=$2
HERE=$(cd "$(dirname "$0")" && pwd)
F() { python3 -I "$HERE/gpt-fake.py" "$@"; }
D=$(mktemp -d "${LDB_TEST_DIR:-${TMPDIR:-/tmp}}/ldb-helper.XXXXXX")
trap 'rm -rf -- "$D"' EXIT
fails=0; n=0
DISK=$D/sda; H0=$D/old.head; T0=$D/old.tail
F dumps "$H0" "$T0"
"$TOOL" gpt plan --head "$H0" --tail "$T0" -o "$D/plan" > "$D/plan.txt" || { echo "ldbhelper-test: FAILED: no plan"; cat "$D/plan.txt"; exit 1; }
cat > "$D/snap.py" <<'PY'
import hashlib, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY); h = hashlib.sha256(); off = 0; end = os.fstat(fd).st_size
skip = set(int(x) for x in sys.argv[2:])
while off < end:
    try: d = os.lseek(fd, off, os.SEEK_DATA)
    except OSError: break
    e = os.lseek(fd, d, os.SEEK_HOLE)
    while d < e:
        c = os.pread(fd, min(4096, e - d), d)
        if d // 4096 not in skip and c.strip(b'\0'):
            h.update(d.to_bytes(8, 'little')); h.update(c)
        d += len(c)
    off = e
print(h.hexdigest())
PY
snap() { python3 -I "$D/snap.py" "$DISK" "$@"; }
run() { rc=0; o=$(env "$@" 2>&1) || rc=$?; }
ONLY=${ONLY:-}
start() { name=$1; [ -z "$ONLY" ] || case "$name" in $ONLY) ;; *) return 1 ;; esac; bad=; n=$((n + 1)); F disk "$DISK"; before=$(snap); return 0; }
no() { bad="$bad${bad:+; }$1"; }
exit_not0() { [ "$rc" != 0 ] || no "exit 0, wanted a failure"; }
exit_0() { [ "$rc" = 0 ] || no "exit $rc, wanted 0"; }
said() { printf '%s' "$o" | grep -qF -- "$1" || no "no text '$1'"; }
same_disk() { [ "$(snap)" = "$before" ] || no "the disk changed"; }
table() { F check "$DISK"; }
has() { table | grep -qF -- "$1" || no "table: no '$1': $(table | tr '\n' ';' | cut -c1-200)"; }
done_() {
  if [ -z "$bad" ]; then echo "ok   $name"; else fails=$((fails + 1)); echo "FAIL $name: $bad"; printf '%s\n' "$o" | tail -4 | sed 's/^/     | /'; fi
}
# The new table's blocks, for the torn cases, and the plan back made from a disk with that table
F disk "$DISK"; "$H" gpt-write "$D/plan" "$DISK" > /dev/null 2>&1 || true
"$H" gpt-dump "$DISK" "$D/new.head" "$D/new.tail" > /dev/null || exit 1
"$TOOL" gpt plan-restore --head "$D/new.head" --tail "$D/new.tail" --ref-head "$H0" --ref-tail "$T0" -o "$D/back" > "$D/back.txt" || { echo "ldbhelper-test: FAILED: no restore plan"; cat "$D/back.txt"; exit 1; }
if [ -z "$ONLY" ]; then
start "version: the helper says which source it is"
run X=1 "$H" version; exit_0; said "ldbhelper-version"; done_

start "G gpt-write: 4 table blocks and 2 superblock blocks change, nothing else; an independent reader sees the plan"
run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0; said "gpt-write ok"
[ "$(python3 -I "$D/snap.py" "$DISK" 1 2 1831432 1831433 30119931 30119935)" = "$(cp --sparse=always "$DISK" "$D/x" 2>/dev/null; F disk "$D/x"; python3 -I "$D/snap.py" "$D/x" 1 2 1831432 1831433 30119931 30119935)" ] || no "a block outside the six changed"
has "primary valid backup valid"; has "userdata 1831432 21633535"; has "iosroot 21633536 30119930"; has "metadata 1827336 1831431"; has "sb zero"
"$H" gpt-dump "$DISK" "$D/h" "$D/t" > /dev/null || no "gpt-dump"
"$TOOL" gpt verify-new --head "$D/h" --tail "$D/t" --ref-head "$H0" --ref-tail "$T0" > "$D/v" 2>&1 || no "verify-new: $(cat "$D/v")"
done_
start "G fdisk, a third reader, sees 16 partitions and the sizes"
run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0
if command -v fdisk >/dev/null 2>&1; then
  o=$(LC_ALL=C fdisk -b 4096 -l "$DISK" 2>&1); printf '%s' "$o" | grep -qE 'sda16 +21633536 +30119930' || no "fdisk: $(printf '%s' "$o" | tail -3)"
else echo "note fdisk not here"; fi; done_

for st in "1 primary valid backup INVALID|userdata 1831432 30119930|sb data" "2 primary valid backup valid|userdata 1831432 30119930|sb data" "3 primary valid backup valid|userdata 1831432 30119930|sb zero"; do
  k=${st%% *}; rest=${st#* }
  start "G power cut after step $k: the old table still rules (primary valid), and a new run ends in the new table"
  run LDB_TEST_STOP="$k" "$H" gpt-write "$D/plan" "$DISK"
  [ "$rc" = 137 ] || no "stop at step $k: exit $rc"
  IFS='|'; for t in $rest; do has "$t"; done; unset IFS
  run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0; said "gpt-write ok"; has "iosroot 21633536 30119930"; has "sb zero"; has "primary valid backup valid"
  done_
done
start "G a new run on the new table writes nothing"
run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0; before=$(snap); run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0; said "already holds"; same_disk; done_
start "G the plan back, with no slot change, gives the old table byte for byte"
run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0; run X=1 "$H" gpt-write "$D/back" "$DISK"; exit_0
"$H" gpt-dump "$DISK" "$D/h" "$D/t" > /dev/null; "$TOOL" gpt same --head "$D/h" --tail "$D/t" --ref-head "$H0" --ref-tail "$T0" > "$D/v" 2>&1 || no "same: $(cat "$D/v")"; has "userdata 1831432 30119930"; has "sb zero"; done_
start "G the table differs from the plan's old bytes (one attribute): refused, disk identical"
python3 -I - "$DISK" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek((30119931 * 4096) + 5 * 128 + 48); f.write(b'\x01')
PY
before=$(snap); run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_not0; said "not the one this plan"; same_disk; done_
start "G a device of another size: refused, disk identical"
truncate -s $(( (30119936 + 512) * 4096 )) "$DISK"; before=$(snap); run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_not0; said "another size"; same_disk; done_
start "G a damaged plan: refused, disk identical"
cp "$D/plan" "$D/badplan"; printf 'X' | dd of="$D/badplan" bs=1 seek=5000 conv=notrunc 2>/dev/null; run X=1 "$H" gpt-write "$D/badplan" "$DISK"; exit_not0; said "damaged"; same_disk; done_
start "G the primary is new and the backup old (not a state this plan can leave): refused, disk identical"
run LDB_TEST_STOP=9 "$H" gpt-write "$D/plan" "$DISK"; exit_0
python3 -I - "$DISK" "$H0" "$T0" <<'PY'
import sys
d, h, t = sys.argv[1:]
with open(d, 'r+b') as f:
    b = open(t, 'rb').read()
    f.seek((30119936 - 256) * 4096 + 251 * 4096); f.write(b[251 * 4096:])
PY
before=$(snap); run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_not0; said "later block"; same_disk; done_
fi
# F1: the phone's own code (no test define): real O_DIRECT on this host's file, and the rules of 4.14 fs/block_dev.c:227, :360 on memory, offset and length
if [ -n "${LDB_DIRECT:-}" ]; then
  dio() { o=$("$LDB_DIO" "$DISK" "$@" 2>&1); rc=$?; }
  dio_clean() { said "dio_check:"; said " 0 refused"; printf '%s' "$o" | grep -qF 'without O_DIRECT' && no "the device was opened without O_DIRECT"; printf '%s' "$o" | grep -q ' 0 O_DIRECT opens' && no "no O_DIRECT open"; }
  if start "F1 gpt-write of the phone's code: all I/O on the block in memory, offset and length; the new table on the disk"; then
    dio "$LDB_DIRECT" gpt-write "$D/plan" "$DISK"; exit_0; dio_clean; said "gpt-write ok"; has "iosroot 21633536 30119930"; has "sb zero"; has "primary valid backup valid"; printf '%s\n' "$o" | grep '^dio_check: [0-9]' | sed 's/^/     /'; done_
  fi
  if start "F1 gpt-restore's plan, the phone's code: the same rules"; then
    "$H" gpt-write "$D/plan" "$DISK" > /dev/null; dio "$LDB_DIRECT" gpt-write "$D/back" "$DISK"; exit_0; dio_clean; said "gpt-write ok"; has "userdata 1831432 30119930"; done_
  fi
  if start "F1 gpt-dump, the phone's code: the same rules"; then
    dio "$LDB_DIRECT" gpt-dump "$DISK" "$D/dh" "$D/dt"; exit_0; dio_clean; cmp -s "$D/dh" "$H0" || no "the dump is not the table"; done_
  fi
  if start "F1 gpt-write of the phone's code stopped after a run on a state: a resume keeps the rules"; then
    LDB_TEST_STOP=2 "$H" gpt-write "$D/plan" "$DISK" > /dev/null 2>&1; dio "$LDB_DIRECT" gpt-write "$D/plan" "$DISK"; exit_0; dio_clean; has "iosroot 21633536 30119930"; done_
  fi
fi
# F3: the way back is made from the table on the disk
back_from_disk() { "$H" gpt-dump "$DISK" "$D/bh" "$D/bt" > /dev/null; "$TOOL" gpt plan-restore --head "$D/bh" --tail "$D/bt" --ref-head "$H0" --ref-tail "$T0" -o "$D/back2" > "$D/back2.txt" 2>&1; }
if start "F3 after a slot change the disk is neither table of the first plan: the plan from the disk restores it, attributes and type GUIDs stay"; then
  "$H" gpt-write "$D/plan" "$DISK" > /dev/null; F slot-change "$DISK"; attrs=$(F entry "$DISK" system_a)
  back_from_disk || no "no plan: $(cat "$D/back2.txt")"
  run X=1 "$H" gpt-write "$D/back2" "$DISK"; exit_0; said "gpt-write ok"; has "userdata 1831432 30119930"; has "primary valid backup valid"; has "sb zero"
  table | grep -q iosroot && no "iosroot is still there"
  [ "$(F entry "$DISK" system_a)" = "$attrs" ] || no "attributes or type GUID of system_a changed"
  [ -n "$attrs" ] || no "no entry system_a"
  "$H" gpt-dump "$DISK" "$D/ah" "$D/at" > /dev/null
  got=$(F tablediff "$D/bh" "$D/bt" "$D/ah" "$D/at" | awk '{print $1, ($1 ~ /entries/) ? (($2 >= 1920 && $3 < 2048) ? "iosroot-slot" : ($2 >= 1832 && $3 < 1840) ? "userdata-last" : "OTHER " $2 " " $3) : (($2 >= 16 && $3 < 20) ? "hdr-crc" : ($2 >= 88 && $3 < 92) ? "entries-crc" : "OTHER " $2 " " $3)}' | sort -u | tr '\n' ';')
  [ "$got" = "backup-entries iosroot-slot;backup-entries userdata-last;backup-header entries-crc;backup-header hdr-crc;primary-entries iosroot-slot;primary-entries userdata-last;primary-header entries-crc;primary-header hdr-crc;" ] || no "the independent diff says: $got"
  done_
fi
if start "F3 a change a slot switch cannot make (another LBA, a non-slot attribute): no plan, disk identical"; then
  "$H" gpt-write "$D/plan" "$DISK" > /dev/null
  python3 -I - "$DISK" <<'PY'
import struct, sys, zlib
B = 4096; DISK = 30119936
with open(sys.argv[1], 'r+b') as f:
    f.seek(2 * B); e = bytearray(f.read(32 * 128)); e[1 * 128 + 48] ^= 1; ec = zlib.crc32(bytes(e))
    for hlba, pe in ((1, 2), (DISK - 1, DISK - 5)):
        f.seek(pe * B); f.write(e); f.seek(hlba * B); h = bytearray(f.read(B)); struct.pack_into('<I', h, 88, ec); h[16:20] = b'\0' * 4; struct.pack_into('<I', h, 16, zlib.crc32(bytes(h[:92]))); f.seek(hlba * B); f.write(h)
PY
  before=$(snap); back_from_disk && no "a plan was made"; grep -qF 'not a slot partition' "$D/back2.txt" || no "text: $(cat "$D/back2.txt")"; same_disk; done_
fi
if start "F3 the plan back stopped after each step: a new plan from the disk ends it"; then
  for k in 1 2 3; do
    F disk "$DISK"; "$H" gpt-write "$D/plan" "$DISK" > /dev/null; F slot-change "$DISK"; back_from_disk || no "no plan"
    run LDB_TEST_STOP=$k "$H" gpt-write "$D/back2" "$DISK"; [ "$rc" = 137 ] || no "stop at $k: exit $rc"; has "iosroot 21633536 30119930"
    back_from_disk || no "no second plan after a stop at $k: $(cat "$D/back2.txt")"
    run X=1 "$H" gpt-write "$D/back2" "$DISK"; exit_0; has "userdata 1831432 30119930"; has "primary valid backup valid"
  done; done_
fi
# F4: LBA 1 and 2 are compared one by one. A torn primary goes on only from a valid backup with the plan's new bytes.
tear() { "$H" gpt-write "$D/plan" "$DISK" > /dev/null; F disk "$DISK"; LDB_TEST_STOP=3 "$H" gpt-write "$D/plan" "$DISK" > /dev/null 2>&1; }
if start "F4 header new, entries old (backup new): the primary is written, the new table"; then
  tear; F block "$DISK" 1 "$D/new.head" 1; has "primary INVALID"; run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0; said "half written"; has "primary valid backup valid"; has "iosroot 21633536 30119930"; done_
fi
if start "F4 entries new, header old (backup new): the primary is written, the new table"; then
  tear; F block "$DISK" 2 "$D/new.head" 2; has "primary INVALID"; run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0; said "half written"; has "primary valid backup valid"; has "iosroot 21633536 30119930"; done_
fi
if start "F4 header neither old nor new (backup new): the primary is written"; then
  tear; F block "$DISK" 1 garbage; has "primary INVALID"; run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0; has "primary valid backup valid"; has "iosroot 21633536 30119930"; done_
fi
if start "F4 entries neither old nor new (backup new): the primary is written"; then
  tear; F block "$DISK" 2 garbage; run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0; has "primary valid backup valid"; has "iosroot 21633536 30119930"; done_
fi
if start "F4 a torn primary with an old backup: refused, disk identical"; then
  F block "$DISK" 1 "$D/new.head" 1; before=$(snap); run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_not0; said "not the one this plan"; same_disk; done_
fi
if start "F4 a torn primary with half a backup (entries new, header old): refused, disk identical"; then
  LDB_TEST_STOP=1 "$H" gpt-write "$D/plan" "$DISK" > /dev/null 2>&1; F block "$DISK" 2 garbage; before=$(snap); run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_not0; said "not the one this plan"; same_disk; done_
fi
if start "F4 a torn primary with a damaged backup: refused, disk identical"; then
  tear; F block "$DISK" 1 garbage; F block "$DISK" 30119935 garbage; before=$(snap); run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_not0; said "not the one this plan"; same_disk; done_
fi
if start "F4 a backup block is neither (the primary old and valid): refused, disk identical"; then
  F block "$DISK" 30119931 garbage; before=$(snap); run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_not0; said "neither the old nor the new"; has "primary valid"; same_disk; done_
fi
if start "F4 plan-repair: the primary from the backup copy, nothing else; it refuses a valid primary and a broken backup"; then
  tear; F block "$DISK" 1 garbage; "$H" gpt-dump "$DISK" "$D/th" "$D/tt" > /dev/null
  "$TOOL" gpt plan-repair --head "$D/th" --tail "$D/tt" --ref-head "$H0" --ref-tail "$T0" -o "$D/rep" > "$D/rep.txt" 2>&1 || no "no repair plan: $(cat "$D/rep.txt")"
  [ "$("$TOOL" gpt state --head "$D/th" --tail "$D/tt" --ref-head "$H0" --ref-tail "$T0")" = torn-backup-new ] || no "state"
  before=$(snap); run X=1 "$H" gpt-write "$D/rep" "$DISK"; exit_0; has "primary valid backup valid"; has "iosroot 21633536 30119930"
  [ "$(python3 -I "$D/snap.py" "$DISK" 1 2)" = "$(F disk "$D/x2"; LDB_TEST_STOP=3 "$H" gpt-write "$D/plan" "$D/x2" > /dev/null 2>&1; python3 -I "$D/snap.py" "$D/x2" 1 2)" ] || no "a block other than LBA 1, 2 changed"; rm -f "$D/x2"
  "$H" gpt-dump "$DISK" "$D/th" "$D/tt" > /dev/null; "$TOOL" gpt verify-new --head "$D/th" --tail "$D/tt" --ref-head "$H0" --ref-tail "$T0" > "$D/v" 2>&1 || no "not the planned table: $(cat "$D/v")"
  "$TOOL" gpt plan-repair --head "$D/th" --tail "$D/tt" --ref-head "$H0" --ref-tail "$T0" -o "$D/rep2" > "$D/v" 2>&1 && no "a plan for a valid primary"
  F block "$DISK" 1 garbage; F block "$DISK" 30119935 garbage; "$H" gpt-dump "$DISK" "$D/th" "$D/tt" > /dev/null
  "$TOOL" gpt plan-repair --head "$D/th" --tail "$D/tt" --ref-head "$H0" --ref-tail "$T0" -o "$D/rep2" > "$D/v" 2>&1 && no "a plan from a broken backup"
  [ "$("$TOOL" gpt state --head "$D/th" --tail "$D/tt" --ref-head "$H0" --ref-tail "$T0")" = broken ] || no "state broken"
  done_
fi
# F1 (install path): root-verify: the phone's code against a fake partition: the list and the CRC of the real tool on a real .simg; CRC-32 also by python's zlib
# A fake partition of 2048 blocks that holds old bytes; RAW and FILL chunks from the tool's img2simg go over it by simg-apply below.
RV=$D/rv; mkdir -p "$RV"
python3 -I - "$RV/root.img" <<'PY'
import os, sys
with open(sys.argv[1], 'wb') as f:
    f.truncate(2048 * 4096)
    # data at 0, an all-one-word block (FILL), a run of 1300 RAW blocks, more than one 4 MiB read (1024 blocks), a last block alone
    f.seek(0); f.write(os.urandom(4096 * 3))
    f.seek(10 * 4096); f.write(b'\xa5\x5a\x00\xff' * 1024)
    f.seek(300 * 4096); f.write(os.urandom(4096 * 1300))
    f.seek(2047 * 4096); f.write(os.urandom(4096))
PY
"$TOOL" img2simg "$RV/root.img" "$RV/root.simg" > /dev/null
RV_LINE=$("$TOOL" simg-verify-list "$RV/root.simg" -o "$RV/root.list" | tail -1)
rv_flash() { python3 -I - "$RV/root.simg" "$RV/part" "$1" <<'PY'
import struct, sys
s, dev, lose = sys.argv[1], sys.argv[2], sys.argv[3] == 'lose-last'
d = open(s, 'rb').read()
_, _, _, fh, ch, blk, total, chunks, _ = struct.unpack('<IHHHHIIII', d[:28])
open(dev, 'wb').write(b'\xee' * (total * blk))
at, pos, w = fh, 0, []
for _ in range(chunks):
    kind, _, size, n = struct.unpack('<HHII', d[at:at + 12])
    if kind == 0xcac1: w.append((pos, d[at + ch:at + n]))
    elif kind == 0xcac2: w.append((pos, d[at + ch:at + ch + 4] * (size * blk // 4)))
    pos += size; at += n
if lose: w.pop()
with open(dev, 'r+b') as f:
    for b, data in w:
        f.seek(b * blk); f.write(data)
PY
}
rv_poke() { python3 -I - "$RV/part" "$1" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(int(sys.argv[2])); b = f.read(1); f.seek(int(sys.argv[2])); f.write(bytes([b[0] ^ 1]))
PY
}
rv_last() { printf '%s\n' "$o" | grep '^verify ranges ' | tail -1; }
if start "F1 root-verify: the old bytes stay in the DON'T CARE blocks: the helper says the tool's line; python's zlib says the same CRC"; then
rv_flash all; run X=1 "$H" root-verify "$RV/root.list" "$RV/part"; exit_0; [ "$(rv_last)" = "$RV_LINE" ] || no "helper '$(rv_last)', tool '$RV_LINE'"
cmp -s "$RV/part" "$RV/root.img" && no "the fake partition has no old bytes: this tests nothing"
z=$(python3 -I - "$RV/part" "$RV/root.list" <<'PY'
import struct, sys, zlib
d = open(sys.argv[2], 'rb').read(); n = struct.unpack('<Q', d[8:16])[0]; f = open(sys.argv[1], 'rb'); c = 0
for i in range(n):
    a, k = struct.unpack('<II', d[40 + 8 * i:48 + 8 * i]); f.seek(a * 4096); c = zlib.crc32(f.read(k * 4096), c)
print('%08x' % c)
PY
); [ "$z" = "${RV_LINE##* }" ] || no "zlib $z, tool ${RV_LINE##* }"; done_
fi
if start "F1 root-verify: one byte damaged in a range: another CRC"; then
rv_flash all; rv_poke $((950 * 4096 + 123)); run X=1 "$H" root-verify "$RV/root.list" "$RV/part"; exit_0; [ "$(rv_last)" != "$RV_LINE" ] || no "not found"; done_
fi
if start "F1 root-verify: one byte damaged in the second 4 MiB read of a range: another CRC"; then
rv_flash all; rv_poke $(((300 + 1024) * 4096)); run X=1 "$H" root-verify "$RV/root.list" "$RV/part"; exit_0; [ "$(rv_last)" != "$RV_LINE" ] || no "not found"; done_
fi
if start "F1 root-verify: the last piece lost: another CRC"; then
rv_flash lose-last; run X=1 "$H" root-verify "$RV/root.list" "$RV/part"; exit_0; [ "$(rv_last)" != "$RV_LINE" ] || no "not found"; done_
fi
if start "F1 root-verify: a change in a DON'T CARE block: the same CRC"; then
rv_flash all; rv_poke $((1700 * 4096)); run X=1 "$H" root-verify "$RV/root.list" "$RV/part"; exit_0; [ "$(rv_last)" = "$RV_LINE" ] || no "'$(rv_last)', wanted '$RV_LINE'"; done_
fi
if start "F1 root-verify: it only reads: the partition is the same after it"; then
rv_flash all; a=$(sha256sum "$RV/part"); run X=1 "$H" root-verify "$RV/root.list" "$RV/part"; exit_0; [ "$(sha256sum "$RV/part")" = "$a" ] || no "changed"; done_
fi
if start "F1 root-verify: a damaged list: refused before any read of the partition"; then
rv_flash all; cp "$RV/root.list" "$RV/bad"; printf 'X' | dd of="$RV/bad" bs=1 seek=41 conv=notrunc 2>/dev/null; run X=1 "$H" root-verify "$RV/bad" "$RV/part"; exit_not0; said "damaged"; done_
fi
if start "F1 root-verify: a list cut in the middle of a range: refused"; then
rv_flash all; head -c 44 "$RV/root.list" > "$RV/bad"; run X=1 "$H" root-verify "$RV/bad" "$RV/part"; exit_not0; said "damaged"; done_
fi
if start "F1 root-verify: not a list: refused"; then
rv_flash all; run X=1 "$H" root-verify "$RV/root.img" "$RV/part"; exit_not0; said "not a range list"; done_
fi
if start "F1 root-verify: a partition shorter than the list: refused, no result line"; then
rv_flash all; truncate -s $((2000 * 4096)) "$RV/part"; run X=1 "$H" root-verify "$RV/root.list" "$RV/part"; exit_not0; said "ends past the device"; [ -z "$(rv_last)" ] || no "a result line"; done_
fi
if start "F1 root-verify: a partition that is not a whole number of blocks: refused"; then
rv_flash all; truncate -s $((2048 * 4096 + 1)) "$RV/part"; run X=1 "$H" root-verify "$RV/root.list" "$RV/part"; exit_not0; said "device size"; done_
fi
if [ -n "${LDB_DIRECT:-}" ]; then
  dio_rv() { o=$("$LDB_DIO" "$RV/part" "$LDB_DIRECT" root-verify "$RV/root.list" "$RV/part" 2>&1); rc=$?; }
  if start "F1 root-verify, the phone's code: real O_DIRECT, memory, offset and length on the block; the tool's line"; then
  rv_flash all; dio_rv; exit_0; said " 0 refused"; said " 1 O_DIRECT opens, 0 plain opens"; said " 0 pwrites"; [ "$(rv_last)" = "$RV_LINE" ] || no "'$(rv_last)', wanted '$RV_LINE'"; printf '%s\n' "$o" | grep '^dio_check: [0-9]' | sed 's/^/     /'; done_
  fi
  if start "F1 root-verify, the phone's code: the last piece lost: another CRC"; then
  rv_flash lose-last; dio_rv; exit_0; [ "$(rv_last)" != "$RV_LINE" ] || no "not found"; done_
  fi
fi
# S5: one writer
holding() { python3 -I - "$1" "$H" "$2" "$3" <<'PY'
import fcntl, subprocess, sys
l = open(sys.argv[1], 'w'); fcntl.flock(l, fcntl.LOCK_EX)
r = subprocess.run([sys.argv[2], 'gpt-write', sys.argv[3], sys.argv[4]], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
sys.stdout.write(r.stdout.decode()); sys.exit(r.returncode)
PY
}
if start "S5 a writer holds the lock: a second gpt-write stops first, disk identical; the lock ends with its holder"; then
  o=$(holding "$D/plan.lock" "$D/plan" "$DISK"); rc=$?; exit_not0; said "another gpt-write"; same_disk
  run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0; said "gpt-write ok"; done_
fi
if start "S5 a power cut leaves no lock"; then
  run LDB_TEST_STOP=2 "$H" gpt-write "$D/plan" "$DISK"; [ "$rc" = 137 ] || no "exit $rc"; run X=1 "$H" gpt-write "$D/plan" "$DISK"; exit_0; said "gpt-write ok"; done_
fi
echo "ldbhelper-test: $n cases, $fails failed"
[ "$fails" = 0 ]
