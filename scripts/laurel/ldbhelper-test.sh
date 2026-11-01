#!/bin/sh
# Host test of the phone helper: the real gpt-write and gpt-dump on a sparse file of the size of the phone's LUN 0, with a table in its layout (gpt-fake.py), and a power cut after each step.
#   scripts/laurel/ldbhelper-test.sh HELPER TOOL     HELPER: built for this host with -DLDB_TEST_FILE (DEV is a file: no ioctl, no O_DIRECT; LDB_TEST_STOP=N ends it after step N, as a power cut)
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
"$TOOL" gpt plan --head "$H0" --tail "$T0" -o "$D/back" --reverse > /dev/null || exit 1
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
start() { name=$1; bad=; n=$((n + 1)); F disk "$DISK"; before=$(snap); }
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
start "G the back plan gives the old table, byte for byte"
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
echo "ldbhelper-test: $n cases, $fails failed"
[ "$fails" = 0 ]
