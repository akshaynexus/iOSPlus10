#!/bin/sh
# Host test of the phone helper's refusals: stale table, no record, moved file, the frozen seal and each way it can fail. A real file with real FIEMAP on this host, a fake partition file.
#   scripts/laurel/ldbhelper-test.sh HELPER TOOL [--old-api]
#   HELPER: built for this host with -DLDB_TEST_NO_PIN (no f2fs here: pin, immutable, freeze and reboot are stubs that trace; LDB_TEST_FAULT makes them fail). That code is not in the phone binary.
#   --old-api: the commands as the code before this fix had them (scripts/laurel/dualboot-tests-detect.sh).
# Test names with [R] are regressions: the old code passed them too. [N]: a refusal of a command the old code does not have, so it refuses too. Each other test failed on the old code.
# Nothing here proves anything about the phone.
set -u
H=$1; TOOL=$2; OLD=${3:-}
D=$(mktemp -d "${LDB_TEST_DIR:-${TMPDIR:-/tmp}}/ldb-helper.XXXXXX")
trap 'rm -rf -- "$D"' EXIT
fails=0; n=0
A=$D/area.bin; TB=$D/t.ldbt; PT=$D/part.img; FS=$D/fs.img
head -c $((16 * 1024 * 1024)) /dev/urandom > "$A"; sync "$A"
"$H" map "$A" > "$D/map.txt" 2>"$D/map.err" || true
if ! grep -q '^extent' "$D/map.txt" || grep -qE '^extent [0-9]+ [0-9]+ [0-9]+ ([0-9]*[2-9]|[0-9]+[0-9])$' "$D/map.txt"; then
  # a test that did not run is no pass
  echo "ldbhelper-test: FAILED: not run: FIEMAP of $D gives no plain extents ($(tr -d '\n' < "$D/map.err")). Set LDB_TEST_DIR to a folder on ext4, xfs or btrfs" >&2
  exit 1
fi
MAX=$(awk '/^extent/ {e = ($3 + $4) / 4096; if (e > m) m = e} END {printf "%d", m + 2000}' "$D/map.txt")
"$TOOL" dualboot table --fiemap "$D/map.txt" --part-first 4096 --part-blocks "$MAX" --id 0x1234 -o "$TB" >/dev/null
"$TOOL" dualboot table --fiemap "$D/map.txt" --part-first 4096 --part-blocks "$MAX" --id 0x5678 -o "$D/other.ldbt" >/dev/null
python3 -I - "$FS" <<'PY'
import struct, sys
b = bytearray(4096)
b[1024:1028] = struct.pack('<I', 0xF2F52010); b[1024 + 20:1024 + 24] = struct.pack('<I', 9); b[1024 + 76:1024 + 80] = struct.pack('<I', 512)
open(sys.argv[1], 'wb').write(b)
PY
# ./tool.py: operations on the sparse partition file
cat > "$D/p.py" <<'PY'
import hashlib, os, struct, sys
cmd, p = sys.argv[1], sys.argv[2]
def fnv(d):
    h = 0xcbf29ce484222325
    for x in d: h = ((h ^ x) * 0x100000001b3) & (2**64 - 1)
    return h
def table(path):
    b = open(path, 'rb').read()
    count = struct.unpack_from('<I', b, 16)[0]
    return [struct.unpack_from('<QQQ', b, 64 + 24 * i) for i in range(count)]
def block(f, ext, ab):
    for a, pb, n in ext:
        if a <= ab < a + n:
            f.seek((pb + ab - a) * 4096); return f.read(4096)
if cmd == 'init':            # a live f2fs: only the fingerprint blocks and a few others hold data
    size = int(sys.argv[3])
    with open(p, 'wb') as f:
        f.truncate(size * 4096)
        for b in (0, 512, 1024, 2048, size - 1):
            f.seek(b * 4096); f.write(hashlib.sha256(b'x%d' % b).digest() * 128)
elif cmd == 'snap':          # every written range of the sparse file
    fd = os.open(p, os.O_RDONLY); h = hashlib.sha256(); off = 0; end = os.fstat(fd).st_size
    while off < end:
        try: d = os.lseek(fd, off, os.SEEK_DATA)
        except OSError: break
        e = os.lseek(fd, d, os.SEEK_HOLE)
        while d < e:
            c = os.pread(fd, min(1 << 20, e - d), d)
            if not c.strip(b'\0'): d += len(c); continue
            h.update(struct.pack('<Q', d)); h.update(c); d += len(c)
        off = e
    print(h.hexdigest())
elif cmd == 'header':        # state of the header at area block 0, and whether the fingerprint is that of the raw blocks
    ext = table(sys.argv[3])
    with open(p, 'rb') as f:
        b = block(f, ext, 0)
        if b[:8] != b'LAURELDB': print('none'); sys.exit(0)
        ver, state = struct.unpack_from('<II', b, 8)
        pbs = struct.unpack_from('<QQQ', b, 48); hs = struct.unpack_from('<QQQ', b, 72)
        ok = True
        for pb, want in zip(pbs, hs):
            f.seek(pb * 4096)
            ok = ok and fnv(f.read(4096)) == want
        print('version=%d state=%d fp=%s' % (ver, state, 'right' if ok else 'wrong'))
elif cmd == 'zero':          # are area blocks 0 and 256 all zero
    ext = table(sys.argv[3])
    with open(p, 'rb') as f:
        print('zero' if not block(f, ext, 0).strip(b'\0') and not block(f, ext, 256).strip(b'\0') else 'data')
elif cmd == 'zero-fp':       # the fingerprint block 512 holds zeros
    with open(p, 'r+b') as f:
        f.seek(512 * 4096); f.write(bytes(4096))
PY
fresh() {
  python3 -I "$D/p.py" init "$PT" "$MAX"
  rm -f "$A.ldbok" "$A.ldbok.t"
  before=$(python3 -I "$D/p.py" snap "$PT")
}
same_part() { [ "$(python3 -I "$D/p.py" snap "$PT")" = "$before" ] || no "the partition changed"; }
changed_part() { [ "$(python3 -I "$D/p.py" snap "$PT")" != "$before" ] || no "the partition did not change"; }
hstate() { python3 -I "$D/p.py" header "$PT" "$TB"; }
python3 -I - "$D/root.img" <<'PY'
import struct, sys
blocks = 2048
with open(sys.argv[1], 'wb') as f:
    f.truncate(blocks * 4096)
    f.seek(1024)
    h = bytearray(512); h[:2] = b'HX'; h[3] = 5
    h[0x28:0x2c] = struct.pack('>I', 4096); h[0x2c:0x30] = struct.pack('>I', blocks)
    h[0x7c:0x80] = struct.pack('>I', 1); h[0x80:0x88] = struct.pack('>II', 2, 1)
    f.write(h)
    bm = bytearray(256)
    for b in range(0, 3): bm[b // 8] |= 0x80 >> (b % 8)
    f.seek(2 * 4096); f.write(bm)
    f.seek(100 * 4096); f.write(b'\x55' * 8192)
PY
"$TOOL" dualboot stream "$TB" "$D/root.img" --index "$D/root.idx" > "$D/root.frames" 2>/dev/null
run() { rc=0; o=$(env "$@" 2>&1) || rc=$?; }
# the old code has no record, and its host build writes through the file: on a copy-on-write file system that moves the blocks, and then its seal refuses for the wrong reason
cm() { if [ "$OLD" = --old-api ]; then rc=0; o=; else run "$@" "$H" check-map "$TB" "$A" "$PT"; fi; }
# write and verify with the arguments of the code under test
wr() { if [ "$OLD" = --old-api ]; then _a=; else _a=$A; fi; rc=0; o=$(env "$@" "$H" write "$TB" "$PT" $_a < "$D/root.frames" 2>&1) || rc=$?; }
ve() { if [ "$OLD" = --old-api ]; then _a=; else _a=$A; fi; rc=0; o=$(env "$@" "$H" verify "$TB" "$PT" $_a < "$D/root.idx" 2>&1) || rc=$?; }
se() { run "$@" "$H" seal "$TB" "$PT" "$FS" "$A"; }
ready() { fresh; cm X=1; wr X=1; ve X=1; }
start() { name=$1; bad=; n=$((n + 1)); }
no() { bad="$bad${bad:+; }$1"; }
exit_not0() { [ "$rc" != 0 ] || no "exit 0, wanted a failure"; }
exit_0() { [ "$rc" = 0 ] || no "exit $rc, wanted 0"; }
said() { printf '%s' "$o" | grep -qF -- "$1" || no "no text '$1'"; }
never() { ! printf '%s' "$o" | grep -qF -- "$1" || no "text '$1'"; }
done_() {
  if [ -z "$bad" ]; then echo "ok   $name"; else fails=$((fails + 1)); echo "FAIL $name: $bad"; printf '%s\n' "$o" | tail -4 | sed 's/^/     | /'; fi
}

start "version: the helper says which source it is"
run X=1 "$H" version; exit_0; said "ldbhelper-version"; done_

# ---- C3: write sees a stale table ----
start "C3 write: the file was removed (Android reset): refused, partition identical"
fresh; cm X=1; before=$(python3 -I "$D/p.py" snap "$PT"); mv "$A" "$A.away"; wr X=1; mv "$A.away" "$A"
exit_not0; same_part; never "write ok"; done_
start "C3 write: another file at other blocks: refused, partition identical"
fresh; cm X=1; before=$(python3 -I "$D/p.py" snap "$PT"); head -c $((16 * 1024 * 1024)) /dev/urandom > "$A.new"; sync "$A.new"; mv "$A.new" "$A"; wr X=1; rc1=$rc; o1=$o
# put the original file back by name, not by blocks: from here the table does not fit it, so a new table for the tests after this
"$H" map "$A" > "$D/map.txt" 2>/dev/null; MAX=$(awk '/^extent/ {e = ($3 + $4) / 4096; if (e > m) m = e} END {printf "%d", m + 2000}' "$D/map.txt")
rc=$rc1; o=$o1; exit_not0; same_part; never "write ok"; done_
"$TOOL" dualboot table --fiemap "$D/map.txt" --part-first 4096 --part-blocks "$MAX" --id 0x1234 -o "$TB" >/dev/null
"$TOOL" dualboot table --fiemap "$D/map.txt" --part-first 4096 --part-blocks "$MAX" --id 0x5678 -o "$D/other.ldbt" >/dev/null
"$TOOL" dualboot stream "$TB" "$D/root.img" --index "$D/root.idx" > "$D/root.frames" 2>/dev/null
start "C3 write: no record of check-map: refused, partition identical"
fresh; wr X=1; exit_not0; same_part; said "check-map"; done_
start "C3 write: check-map failed, so no record: refused"
fresh; cm LDB_TEST_FAULT=no-mirror; exit_not0; [ ! -e "$A.ldbok" ] || no "a record was written"; before=$(python3 -I "$D/p.py" snap "$PT"); wr X=1; exit_not0; same_part; done_
start "C3 write: the record is of another table: refused, partition identical"
fresh; run X=1 "$H" check-map "$D/other.ldbt" "$A" "$PT"; before=$(python3 -I "$D/p.py" snap "$PT"); wr X=1; exit_not0; same_part; said "another table"; done_
start "C3 write: the file has no immutable flag: refused, partition identical"
fresh; cm X=1; before=$(python3 -I "$D/p.py" snap "$PT"); wr LDB_TEST_FAULT=not-immutable; exit_not0; same_part; done_
start "C3 write: partition device of another size: refused"
fresh; cm X=1; truncate -s 8388608 "$D/small.img"; if [ "$OLD" = --old-api ]; then _a=; else _a=$A; fi; rc=0; o=$("$H" write "$TB" "$D/small.img" $_a < "$D/root.frames" 2>&1) || rc=$?
exit_not0; said "another size"; done_
start "C3 write and verify: check-map first: the image is on the partition and read back"
fresh; run X=1 "$H" check-map "$TB" "$A" "$PT"; exit_0; said "check-map ok"; if [ "$OLD" = --old-api ]; then "$H" map "$A" > "$D/map.txt" 2>/dev/null; "$TOOL" dualboot table --fiemap "$D/map.txt" --part-first 4096 --part-blocks "$MAX" --id 0x1234 -o "$TB" >/dev/null; "$TOOL" dualboot stream "$TB" "$D/root.img" --index "$D/root.idx" > "$D/root.frames" 2>/dev/null; fi; wr X=1; exit_0; said "write ok"; changed_part; ve X=1; exit_0; said "0 wrong"; done_
start "[R] write: a stream that stops early: exit not 0"
fresh; cm X=1; head -c 40 "$D/root.frames" > "$D/short"; if [ "$OLD" = --old-api ]; then _a=; else _a=$A; fi; rc=0; o=$("$H" write "$TB" "$PT" $_a < "$D/short" 2>&1) || rc=$?; exit_not0; done_
start "C3 alloc: no checkpoint reached the flash: refused"
fresh; rm -f "$D/al.bin"; if [ "$OLD" = --old-api ]; then run LDB_TEST_FAULT=no-checkpoint "$H" alloc "$D/al.bin" 4194304; else run LDB_TEST_FAULT=no-checkpoint "$H" alloc "$D/al.bin" 4194304 "$PT" "$FS"; fi; exit_not0; said "checkpoint"; done_
rm -f "$D/al.bin"
start "[R] alloc: makes the file and prints its extents"
fresh; if [ "$OLD" = --old-api ]; then run X=1 "$H" alloc "$D/al.bin" 4194304; else run X=1 "$H" alloc "$D/al.bin" 4194304 "$PT" "$FS"; fi; exit_0; said "extent"; done_
rm -f "$D/al.bin"

# ---- C2: the seal ----
start "C2 seal: freeze, then fingerprint and header BOUND, then reboot; no thaw"
ready; se X=1; exit_0; said "TEST freeze"; said "sealed:"; said "TEST reboot"; never "TEST thaw"
printf '%s\n' "$o" | awk '/TEST freeze/ {a = NR} /sealed:/ {b = NR} /TEST reboot/ {c = NR} END {exit !(a && a < b && b < c)}' || no "wrong order"
[ "$(hstate)" = "version=2 state=2 fp=right" ] || no "header: $(hstate)"
done_
start "C2 seal: /data cannot be frozen: exit not 0, header not written"
ready; before=$(python3 -I "$D/p.py" snap "$PT"); se LDB_TEST_FAULT=freeze; exit_not0; said "TEST freeze"; same_part; never "sealed:"; never "TEST reboot"; done_
start "C2 seal: the reboot call fails: header OFF, /data thawed, exit not 0"
ready; se LDB_TEST_FAULT=reboot; exit_not0; said "TEST thaw undo"; [ "$(hstate | cut -d' ' -f1,2)" = "version=2 state=3" ] || no "header: $(hstate)"; done_
start "C2 seal: the fingerprint changes on a frozen /data: header OFF, thawed, no reboot"
ready; se LDB_TEST_FAULT=fp-race; exit_not0; said "TEST thaw undo"; never "TEST reboot"; [ "$(hstate | cut -d' ' -f1,2)" = "version=2 state=3" ] || no "header: $(hstate)"; done_
start "C2 seal: the helper dies while frozen: the watchdog thaws"
ready; se LDB_TEST_FAULT=kill-frozen; said "TEST freeze"; said "TEST thaw watchdog"; done_
start "C2 seal: a fingerprint block of only zeros: refused, thawed"
ready; python3 -I "$D/p.py" zero-fp "$PT"; before=$(python3 -I "$D/p.py" snap "$PT"); se X=1; exit_not0; same_part; said "only zeros"; said "TEST thaw undo"; done_
start "[R] seal: the file moved: refused before anything, partition identical"
ready; head -c $((16 * 1024 * 1024)) /dev/urandom > "$D/moved.bin"; sync "$D/moved.bin"; before=$(python3 -I "$D/p.py" snap "$PT"); run X=1 "$H" seal "$TB" "$PT" "$FS" "$D/moved.bin"; exit_not0; same_part; never "TEST freeze"; done_
start "C2 seal: no record that the image was read back: refused, partition identical"
fresh; cm X=1; wr X=1; before=$(python3 -I "$D/p.py" snap "$PT"); se X=1; exit_not0; same_part; said "read back"; done_
start "C2 seal: verify found wrong blocks: refused"
fresh; cm X=1; wr X=1; python3 -I - "$D/root.idx" "$D/bad.idx" <<'PY'
import sys
b = bytearray(open(sys.argv[1], 'rb').read()); b[24] ^= 1; open(sys.argv[2], 'wb').write(b)
PY
if [ "$OLD" = --old-api ]; then _a=; else _a=$A; fi; rc=0; o=$("$H" verify "$TB" "$PT" $_a < "$D/bad.idx" 2>&1) || rc=$?; exit_not0
before=$(python3 -I "$D/p.py" snap "$PT"); se X=1; exit_not0; same_part; done_
start "C2 seal: no immutable flag: refused, partition identical"
ready; before=$(python3 -I "$D/p.py" snap "$PT"); se LDB_TEST_FAULT=not-immutable; exit_not0; same_part; done_
start "[R] seal: no f2fs on the filesystem device: refused"
ready; before=$(python3 -I "$D/p.py" snap "$PT"); run X=1 "$H" seal "$TB" "$PT" "$A" "$A"; exit_not0; same_part; done_
start "C2 write: a new install clears the old seal"
ready; se X=1; exit_0; wr X=1; exit_0; [ "$(hstate)" = none ] || no "header after a new write: $(hstate)"; done_

# ---- H2 ----
start "H2 wipe: file checks, headers zero, file and record gone"
fresh; cm X=1; wr X=1; python3 -I "$D/p.py" snap "$PT" >/dev/null; run X=1 "$H" wipe "$TB" "$PT" "$A"; exit_0; [ "$(python3 -I "$D/p.py" zero "$PT" "$TB")" = zero ] || no "headers not zero"; [ ! -e "$A" ] || no "file left"; [ ! -e "$A.ldbok" ] || no "record left"; done_
start "[N] H2 wipe: the file was removed from under the table: refused, partition identical"
fresh; before=$(python3 -I "$D/p.py" snap "$PT"); run X=1 "$H" wipe "$TB" "$PT" "$A"; exit_not0; same_part; done_
start "[N] H2 wipe: another file at other blocks: refused, partition identical, file stays"
fresh; before=$(python3 -I "$D/p.py" snap "$PT"); head -c $((16 * 1024 * 1024)) /dev/urandom > "$A"; sync "$A"; run X=1 "$H" wipe "$TB" "$PT" "$A"; exit_not0; same_part; [ -e "$A" ] || no "file gone"; done_
start "H2 unlink-only: no raw write"
fresh; before=$(python3 -I "$D/p.py" snap "$PT"); run X=1 "$H" unlink-only "$A"; exit_0; same_part; [ ! -e "$A" ] || no "file left"; done_
echo "ldbhelper-test: $n cases, $fails failed"
[ "$fails" = 0 ]
