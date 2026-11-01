#!/bin/sh
# Host test of scripts/laurel/dual-boot.sh itself: a fake adb, fastboot and phone drive the real script through each failure path. Each case proves the next step did not run.
#   scripts/laurel/dual-boot-test.sh [TREE]     TREE: where the scripts under test come from (default: this repo). scripts/laurel/dualboot-tests-detect.sh gives it the old code.
#   OP10TOOL=path (default out/cargo/release/op10tool)   a real op10tool: tables and frame streams are real
# The real adb and fastboot cannot be reached: PATH is $T/bin (fakes) + $T/tools (symlinks to a short list of tools, adb and fastboot not among them), and the test checks that first.
# The scripts run from a copy in a temp folder, so out/ of this repo is not touched. Proves the script on the host. Nothing here proves anything about the phone.
# Test names with [R] are regressions: the old code passed them too. Each other test failed on the old code (scripts/laurel/dualboot-tests-detect.sh).
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${1:-$REPO}
TOOL=${OP10TOOL:-$REPO/out/cargo/release/op10tool}
[ -x "$TOOL" ] || { echo "dual-boot-test: FAILED: no op10tool at $TOOL (cargo build --release in tools/op10tool)" >&2; exit 1; }
ONLY=${ONLY:-}
T=$(mktemp -d "${TMPDIR:-/tmp}/ldb-db.XXXXXX")
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/bin" "$T/tools" "$T/pbin" "$T/repo/config"
cp -R "$SRC/scripts" "$T/repo/scripts"
mkdir -p "$T/repo/tools"; cp -R "$SRC/tools/laurel-dualboot" "$T/repo/tools/laurel-dualboot"
: > "$T/repo/config/laurel-android-data"
HOST_PATH=$PATH
# git is left out on purpose: env.sh then takes the repo root from the script's folder, which is the copy
for c in sh bash cat sed awk grep tr cut head tail wc mkdir rm mv cp ln chmod dirname basename date sleep sha256sum mktemp env printf test expr uname nproc touch sort od cmp clang ld.lld lld truncate dd python3 kill ls true false timeout tee stat readlink id; do
  p=$(PATH=$HOST_PATH command -v "$c" 2>/dev/null) || continue
  case "$p" in /*) ln -sf "$p" "$T/tools/$c" ;; esac
done
PATH=$T/bin:$T/tools; export PATH

P=$T/phone
# ---- the fake phone ----
cat > "$T/bin/adb" <<EOT
#!/bin/sh
# Fake adb. shell: the exit code of the remote command (shell protocol). exec-in: copies stdin, shows no remote output, returns 0, does not wait: as client/commandline.cpp. exec-out: no remote exit code.
T="$T"; P="$P"
PPATH=\$T/pbin:\$T/tools
fails() { case " \${FAKE_FAIL:-} " in *" \$1 "*) return 0 ;; esac; return 1; }
rewrite() { printf '%s' "\$1" | sed -e "s#/data/#\$P/data/#g" -e "s#/dev/block/#\$P/dev/block/#g" -e "s#/sys/#\$P/sys/#g"; }
shortcmd() { printf '%s' "\$1" | sed -e 's/; _ldb_r=.*//'; }
case "\$1" in
get-state) echo "adb get-state" >> "\$T/calls"; fails adb-off && exit 1; echo device ;;
devices) echo "adb devices" >> "\$T/calls"; printf 'List of devices attached\n'; fails adb-off || printf 'FAKE\tdevice\n' ;;
push)
  echo "adb push \$3" >> "\$T/calls"
  fails push && { echo "adb: push failed" >&2; exit 1; }
  if [ "\$3" = /data/local/tmp/ldbhelper ]; then
    LC_ALL=C grep -ao 'ldbhelper-version [0-9a-z]*' "\$2" | head -1 > "\$P/state/helper_version" || true
    cp "\$T/fake-helper" "\$P/data/local/tmp/ldbhelper"
  else
    cp "\$2" "\$(rewrite "\$3")"
  fi ;;
shell)
  shift
  echo "adb shell \$(shortcmd "\$*")" >> "\$T/calls"
  fails adb-off && exit 1
  PATH=\$PPATH sh -c "\$(rewrite "\$*")"
  r=\$?
  [ "\$r" -lt 128 ] || exit 255
  exit "\$r" ;;
exec-in)
  shift
  echo "adb exec-in \$*" >> "\$T/calls"
  cat > "\$T/exec-in.stdin"
  if [ "\${FAKE_LATE:-0}" = 1 ]; then
    ( sleep 3; PATH=\$PPATH sh -c "\$(rewrite "\$*")" < "\$T/exec-in.stdin" >/dev/null 2>&1 ) >/dev/null 2>&1 &
  else
    PATH=\$PPATH sh -c "\$(rewrite "\$*")" < "\$T/exec-in.stdin" >/dev/null 2>&1
  fi
  exit 0 ;;
exec-out)
  shift
  echo "adb exec-out \$*" >> "\$T/calls"
  PATH=\$PPATH sh -c "\$(rewrite "\$*")" 2>/dev/null
  exit 0 ;;
*) echo "adb \$*" >> "\$T/calls" ;;
esac
EOT
cat > "$T/fake-helper" <<EOT
#!/bin/sh
# Fake ldbhelper. The real one has its own test: scripts/laurel/ldbhelper-test.sh.
T="$T"; P="$P"
fails() { case " \${FAKE_FAIL:-} " in *" \$1 "*) return 0 ;; esac; return 1; }
c=\$1
{ printf 'helper'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } | sed -e "s#\$P##g" >> "\$T/calls"
fails "drop:\$c" && { kill -9 \$PPID; exit 137; }
fails "\$c" && { echo "ldbhelper: FAILED: \$c (fake)" >&2; exit 1; }
case "\$c" in
version) if fails stale-on-phone; then echo "ldbhelper-version 0000"; else cat "\$P/state/helper_version"; [ -s "\$P/state/helper_version" ] || echo "ldbhelper-version unversioned"; fi ;;
alloc) : > "\$2"; cat "\$P/state/fiemap" ;;
map) [ -e "\$2" ] || { echo "ldbhelper: FAILED: \$2 (errno 2)" >&2; exit 1; }; cat "\$P/state/fiemap" ;;
check-map) echo "check-map ok: 64 samples" ;;
lock) echo locked ;;
write)
  if [ -f "\$P/state/no-result" ]; then exit 0; fi
  n=\$(python3 -I -c '
import struct, sys
f = sys.stdin.buffer; n = 0
while True:
    h = f.read(32)
    if len(h) < 32: sys.exit(9)
    b, fl = struct.unpack("<II", h[16:24])
    if b == 0: break
    n += 1
    if not fl & 1: f.read(b * 4096)
print(n)') || { echo "ldbhelper: FAILED: frame header (fake)" >&2; exit 1; }
  fails write-short && n=\$((n - 1))
  echo "write ok: \$n frames, 0 blocks"
  echo "helper write end" >> "\$T/calls" ;;
verify)
  n=\$((\$(wc -c) / 32 - 1))
  if fails verify-wrong; then echo "verify: \$n frames, 3 wrong"; echo "ldbhelper: FAILED: the raw blocks are not the image" >&2; exit 1; fi
  echo "verify: \$n frames, 0 wrong" ;;
read) fails read-empty && exit 1; head -c 4198400 /dev/zero ;;
seal)
  echo "sealed: generation 1, pin failures 0, /data frozen, reboot now"
  echo sealed > "\$P/state/sealed"
  kill -9 \$PPID; exit 137 ;;
wipe) rm -f "\$4"; echo removed ;;
unlink-only) rm -f "\$2"; echo removed ;;
esac
EOT
chmod +x "$T/bin/adb" "$T/fake-helper"
cat > "$T/pbin/getprop" <<EOT
#!/bin/sh
P="$P"
case "\${1:-}" in
ro.product.device) echo "\${FAKE_DEVICE:-laurel_sprout}" ;;
ro.boot.slot_suffix) echo "_\$(cat "\$P/state/running")" ;;
ro.build.version.release) echo 15 ;;
ro.lineage.version) echo 22.2 ;;
esac
EOT
cat > "$T/pbin/id" <<'EOT'
#!/bin/sh
echo "${FAKE_UID:-0}"
EOT
cat > "$T/pbin/readlink" <<'EOT'
#!/bin/sh
echo /dev/block/sda15
EOT
cat > "$T/pbin/dmctl" <<EOT
#!/bin/sh
cat "$P/state/dm"
EOT
cat > "$T/pbin/df" <<'EOT'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "/dev/block/dm-40 113154000 10000000 ${FAKE_FREE_KB:-109051904} 9% /data"
EOT
cat > "$T/pbin/mount" <<EOT
#!/bin/sh
cat "$P/state/mount"
EOT
cat > "$T/pbin/lsattr" <<'EOT'
#!/bin/sh
echo "${FAKE_LSATTR:-----i---------e---} $1"
EOT
cat > "$T/pbin/pm" <<'EOT'
#!/bin/sh
exit 0
EOT
cat > "$T/pbin/sync" <<EOT
#!/bin/sh
echo "phone sync" >> "$T/calls"
case " \${FAKE_FAIL:-} " in *" sync "*) exit 1 ;; esac
EOT
cat > "$T/pbin/chattr" <<EOT
#!/bin/sh
echo "phone chattr \$*" >> "$T/calls"
case " \${FAKE_FAIL:-} " in *" chattr "*) exit 1 ;; esac
EOT
cat > "$T/pbin/rm" <<EOT
#!/bin/sh
echo "phone rm \$*" | sed -e "s#$P##g" >> "$T/calls"
case " \${FAKE_FAIL:-} " in *" rm "*) exit 1 ;; esac
exec "$T/tools/rm" "\$@"
EOT
cat > "$T/pbin/bootctl" <<EOT
#!/bin/sh
P="$P"; S=\$P/state
echo "bootctl \$*" >> "$T/calls"
fails() { case " \${FAKE_FAIL:-} " in *" \$1 "*) return 0 ;; esac; return 1; }
case "\$1" in
get-current-slot) cat "\$S/current" ;;
get-active-boot-slot) fails bootctl-read && exit 1; cat "\$S/active" ;;
get-number-slots) echo 2 ;;
is-slot-bootable) [ "\$(cat "\$S/bootable\$2")" = 1 ] ;;
is-slot-marked-successful) [ "\$(cat "\$S/successful\$2")" = 1 ] ;;
set-active-boot-slot)
  fails "set-active\$2" && { echo "bootctl: failed" >&2; exit 1; }
  # boot_control.cpp [V doc]: byte 0x3F for the new slot (successful clear, 7 retries); the other slot only loses its active bit
  echo "\$2" > "\$S/active"
  fails keep-successful || echo 0 > "\$S/successful\$2" ;;
mark-boot-successful) fails mark && exit 1; echo 1 > "\$S/successful\$(cat "\$S/current")" ;;
esac
EOT
cat > "$T/bin/fastboot" <<EOT
#!/bin/sh
T="$T"
[ "\${1:-}" = -s ] && shift 2
echo "fastboot \$*" >> "\$T/calls"
case "\$1" in
devices) case "\${FAKE_FB:-one}" in one) printf 'FAKESER\tfastboot\n' ;; two) printf 'FAKE1\tfastboot\nFAKE2\tfastboot\n' ;; esac ;;
getvar)
  case "\$2" in
  product)
    n=\$(grep -c '^fastboot flash' "\$T/calls")
    if [ -n "\${FAKE_PRODUCT_AFTER_FLASH:-}" ] && [ "\$n" -gt 0 ]; then echo "product: \$FAKE_PRODUCT_AFTER_FLASH" >&2
    elif [ "\${FAKE_PRODUCT:-laurel_sprout}" != none ]; then echo "product: \${FAKE_PRODUCT:-laurel_sprout}" >&2; fi ;;
  current-slot) echo "current-slot: \${FAKE_SLOT:-a}" >&2 ;;
  esac ;;
esac
exit 0
EOT
for f in "$T"/pbin/*; do chmod +x "$f"; done
chmod +x "$T/bin/fastboot"

fails=0; n=0
[ "$(command -v adb)" = "$T/bin/adb" ] && [ "$(command -v fastboot)" = "$T/bin/fastboot" ] || { echo "FAIL the fakes are not first in PATH"; exit 1; }
if PATH=$T/tools command -v adb >/dev/null 2>&1 || PATH=$T/tools command -v fastboot >/dev/null 2>&1; then echo "FAIL a real adb or fastboot is in the tool list"; exit 1; fi
for s in "$T/repo/scripts/lib/env.sh" "$T/repo/scripts/laurel/dual-boot.sh" "$T/repo/scripts/laurel/android-guard.sh"; do
  grep -nE '(/[A-Za-z_.-]+)+/(adb|fastboot)( |$)|PATH=' "$s" | grep -v '^#' && { echo "FAIL $s names a tool path or sets PATH"; exit 1; }
done
echo "ok   real adb and fastboot cannot be reached: PATH holds fakes and a short tool list only"

DB=$T/repo/scripts/laurel/dual-boot.sh
D=$T/repo/out/laurel/dualboot
# 64 MiB area in two extents
FIEMAP1="pin-failures 0
extent 0 $((70000 * 4096)) $((8192 * 4096)) 0
extent $((8192 * 4096)) $((40000 * 4096)) $((8192 * 4096)) 1"
FIEMAP2="pin-failures 0
extent 0 $((90000 * 4096)) $((8192 * 4096)) 0
extent $((8192 * 4096)) $((40000 * 4096)) $((8192 * 4096)) 1"
START=$((0x10000)); SECTORS=226307992
DMLINE="0-$SECTORS: default-key, aes-xts-plain64 - 0 8:15 0 3 allow_discards sector_size:4096 iv_large_sectors"
python3 -I - "$T/root.img" <<'PY'
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
printf 'not an image, and big enough to read its header area ......' > "$T/bad.img"; truncate -s 8192 "$T/bad.img"
head -c 4096 /dev/urandom > "$T/dtbo.img"
export STOCK_DTBO="$T/dtbo.img" OP10TOOL="$TOOL" APPLE="$T/apple" WRITE_WAIT=2
M=$(sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$REPO/tools/laurel-dualboot/laurel_dualboot.h")
IMG=$T/repo/out/laurel/uefi/laurel-uefi-boot.img
reset() {
  rm -rf "$P"
  mkdir -p "$P/data/laurel-ios" "$P/data/local/tmp" "$P/state" "$P/dev/block/by-name" "$P/sys/class/block/sda15" "$P/sys/block/sda/queue" "$P/sys/block/dm-40/slaves/sda15"
  mkdir -p "$D" "$T/repo/out/laurel/uefi"
  rm -f "$D/table.ldbt" "$D/table.new" "$D/map.txt" "$D/root.idx" "$D/stream.rc" "$IMG" "$IMG.dualboot"
  : > "$T/calls"
  echo "$START" > "$P/sys/class/block/sda15/start"; echo "$SECTORS" > "$P/sys/class/block/sda15/size"; echo 8:15 > "$P/sys/class/block/sda15/dev"
  echo 4096 > "$P/sys/block/sda/queue/logical_block_size"
  printf '%s\n' "$DMLINE" > "$P/state/dm"
  echo "/dev/block/dm-40 on /data type f2fs (rw,background_gc=on,discard,mode=adaptive)" > "$P/state/mount"
  printf '%s\n' "$FIEMAP1" > "$P/state/fiemap"
  echo a > "$P/state/running"; echo 0 > "$P/state/current"; echo 0 > "$P/state/active"
  echo 1 > "$P/state/bootable0"; echo 1 > "$P/state/bootable1"; echo 1 > "$P/state/successful0"; echo 1 > "$P/state/successful1"
  : > "$P/dev/block/by-name/userdata"
}
# the phone after allocate, check-map, install, image, flash-slot-b
sealed_ready() {
  : > "$P/data/laurel-ios/root.area"
  printf '%s\n' "$FIEMAP1" > "$T/map1.txt"
  "$TOOL" dualboot table --fiemap "$T/map1.txt" --part-first $((START / 8)) --part-blocks $((SECTORS / 8)) -o "$D/table.ldbt" >/dev/null
  printf 'ANDROID! LAURELESP laurel-dualboot %s\n' "$M" > "$IMG"
  printf 'image %s\ntable %s\n' "$(sha256sum "$IMG" | cut -d' ' -f1)" "$(sha256sum "$D/table.ldbt" | cut -d' ' -f1)" > "$IMG.dualboot"
  cp "$IMG" "$P/dev/block/by-name/boot_b"; cp "$STOCK_DTBO" "$P/dev/block/by-name/dtbo_b"
}
with_table() { sealed_ready; }
# the command under test
run() { rc=0; o=$(env "$@" 2>&1 < /dev/null) || rc=$?; }
# ---- one test ----
start() { name=$1; [ -z "$ONLY" ] || case "$name" in $ONLY) ;; *) return 1 ;; esac; reset; bad=; n=$((n + 1)); return 0; }
no() { bad="$bad${bad:+; }$1"; }
exit_is() { [ "$rc" = "$1" ] || no "exit $rc, wanted $1"; }
exit_not0() { [ "$rc" != 0 ] || no "exit 0, wanted a failure"; }
said() { printf '%s' "$o" | grep -qF -- "$1" || no "no text '$1'"; }
ran() { grep -qF -- "$1" "$T/calls" || no "did not run: $1"; }
not_ran() { ! grep -qF -- "$1" "$T/calls" || no "ran: $1"; }
state_is() { [ "$(cat "$P/state/$1")" = "$2" ] || no "state $1 = $(cat "$P/state/$1"), wanted $2"; }
order() { awk -v a="$1" -v b="$2" 'index($0, a) && !x {x = NR} index($0, b) && !y {y = NR} END {exit !(x && y && x < y)}' "$T/calls" || no "wanted '$1' before '$2'"; }
done_() {
  if [ -z "$bad" ]; then echo "ok   $name"; else
    fails=$((fails + 1)); echo "FAIL $name: $bad"
    printf '%s\n' "$o" | tail -4 | sed 's/^/     | /'; sed 's/^/     calls: /' "$T/calls" | tail -8
  fi
}
SW="CONFIRM=switch"

# ---- C1: the real remote status ----
if start "C1 allocate: file exists: stops, no alloc"; then
  : > "$P/data/laurel-ios/root.area"
  run CONFIRM=allocate sh "$DB" allocate 1
  exit_not0; said "exists"; not_ran "helper alloc"; done_
fi
if start "C1 allocate: exists test lost (adb gone): stops, no alloc"; then
  run CONFIRM=allocate FAKE_FAIL=drop:alloc sh "$DB" allocate 1
  exit_not0; [ ! -f "$D/table.ldbt" ] || no "a table was left"; not_ran "helper map"; done_
fi
if start "C1 check-map fails on the phone: no lock, exit not 0"; then
  with_table
  run CONFIRM=check-map FAKE_FAIL=check-map sh "$DB" check-map
  exit_not0; ran "helper check-map"; not_ran "helper lock"; done_
fi
if start "C1 check-map: adb drops, no marker: no lock"; then
  with_table
  run CONFIRM=check-map FAKE_FAIL=drop:check-map sh "$DB" check-map
  exit_not0; ran "helper check-map"; not_ran "helper lock"; done_
fi
if start "C1 lock fails: exit not 0"; then
  with_table
  run CONFIRM=check-map FAKE_FAIL=lock sh "$DB" check-map
  exit_not0; ran "helper lock"; done_
fi
if start "C1 switch: set-active fails: no seal, no reboot, slot a"; then
  with_table
  run "$SW" FAKE_FAIL=set-active1 sh "$DB" switch
  exit_not0; not_ran "helper seal"; not_ran "adb reboot"; state_is active 0; done_
fi
if start "C1 switch: seal fails: back on slot a, marked successful, no reboot"; then
  with_table
  run "$SW" FAKE_FAIL=seal sh "$DB" switch
  exit_not0; ran "helper seal"; not_ran "adb reboot"; state_is active 0; state_is successful0 1; ran "bootctl mark-boot-successful"; done_
fi
if start "C1 install: write fails on the phone (exec-in says 0): no verify, exit not 0"; then
  with_table
  run CONFIRM=install FAKE_FAIL=write sh "$DB" install "$T/root.img"
  exit_not0; ran "adb exec-in"; not_ran "helper verify"; said "write failed"; done_
fi
if start "C1 install: the phone never writes a result: no verify, exit not 0"; then
  with_table; : > "$P/state/no-result"
  rm -f "$P/data/local/tmp/ldbhelper.result"
  run CONFIRM=install sh "$DB" install "$T/root.img"
  exit_not0; not_ran "helper verify"; done_
fi
if start "C1 install: verify sees wrong blocks: exit not 0, not 'installed'"; then
  with_table
  run CONFIRM=install FAKE_FAIL=verify-wrong sh "$DB" install "$T/root.img"
  exit_not0; ran "helper verify"; case "$o" in *"installed "*) no "said installed" ;; esac; done_
fi
if start "C1 install: exec-in returns before the phone ends: the host waits, verify comes after the write"; then
  with_table
  run CONFIRM=install FAKE_LATE=1 WRITE_WAIT=30 sh "$DB" install "$T/root.img"
  exit_is 0; order "helper write end" "helper verify"; done_
fi
if start "C1 install: the phone wrote fewer frames than sent: no verify"; then
  with_table
  run CONFIRM=install FAKE_FAIL=write-short sh "$DB" install "$T/root.img"
  exit_not0; not_ran "helper verify"; done_
fi
if start "C1 install: op10tool stream fails, stale index on disk: exit not 0, not 'installed'"; then
  with_table
  "$TOOL" dualboot stream "$D/table.ldbt" "$T/root.img" --index "$D/root.idx" >/dev/null 2>&1
  run CONFIRM=install sh "$DB" install "$T/bad.img"
  exit_not0; case "$o" in *"installed "*) no "said installed" ;; esac; done_
fi
if start "C1 install: all well: exit 0, says the frames were read back"; then
  with_table
  run CONFIRM=install sh "$DB" install "$T/root.img"
  exit_is 0; order "adb exec-in" "helper verify"; said "0 wrong"; done_
fi
if start "C1 logs: read fails on the phone (exec-out says 0): exit not 0"; then
  with_table
  run FAKE_FAIL=read-empty sh "$DB" logs "$T/log.bin"
  exit_not0; done_
fi

# ---- C2: the seal comes last, and there is no clean reboot ----
if start "C2 switch: slot b first, seal reboots itself, no 'adb reboot'"; then
  with_table
  run "$SW" sh "$DB" switch
  exit_is 0; order "bootctl set-active-boot-slot 1" "helper seal"; not_ran "adb reboot"; state_is active 1; state_is sealed sealed; state_is successful1 0; done_
fi
if start "C2 switch: slot b stays marked successful: ABL cannot count down: no seal, back on a"; then
  with_table
  run "$SW" FAKE_FAIL=keep-successful sh "$DB" switch
  exit_not0; not_ran "helper seal"; state_is active 0; done_
fi
if start "C2 switch: slot a not marked successful: no fallback target: nothing done"; then
  with_table; echo 0 > "$P/state/successful0"
  run "$SW" sh "$DB" switch
  exit_not0; not_ran "bootctl set-active-boot-slot"; not_ran "helper seal"; done_
fi

# ---- C3 ----
if start "C3 install: the helper gets the file and runs after the dm check"; then
  with_table
  run CONFIRM=install sh "$DB" install "$T/root.img"
  exit_is 0; ran "helper write /data/local/tmp/ldbhelper.table /dev/block/by-name/userdata /data/laurel-ios/root.area"; done_
fi
if start "C3 install: device-mapper changed: no raw write"; then
  with_table; echo "0-$SECTORS: default-key, aes-xts-plain64 - 0 8:15 8 3" > "$P/state/dm"
  run CONFIRM=install sh "$DB" install "$T/root.img"
  exit_not0; not_ran "adb exec-in"; done_
fi
if start "C3 install: table of another partition: no raw write"; then
  with_table; echo $((START + 4096)) > "$P/sys/class/block/sda15/start"
  run CONFIRM=install sh "$DB" install "$T/root.img"
  exit_not0; said "not for this userdata"; not_ran "adb exec-in"; done_
fi

# ---- H2 ----
if start "H2 remove: zeroes by the helper, then the table goes; text says so"; then
  with_table
  run CONFIRM=remove sh "$DB" remove
  exit_is 0; ran "helper wipe"; [ ! -f "$D/table.ldbt" ] || no "table left"; [ ! -e "$P/data/laurel-ios/root.area" ] || no "file left"; said "header zero"; done_
fi
if start "H2 remove: slot b active, Android still on a: refused"; then
  with_table; echo 1 > "$P/state/active"
  run CONFIRM=remove sh "$DB" remove
  exit_not0; said "slot b is active"; not_ran "helper wipe"; not_ran "phone rm"; [ -f "$D/table.ldbt" ] || no "table gone"; [ -e "$P/data/laurel-ios/root.area" ] || no "file gone"; done_
fi
if start "H2 remove: the delete fails: the table stays"; then
  with_table
  run CONFIRM=remove "FAKE_FAIL=wipe chattr rm" sh "$DB" remove
  exit_not0; [ -f "$D/table.ldbt" ] || no "table gone"; done_
fi
if start "H2 remove --unverified: no raw write, the file goes"; then
  with_table
  run CONFIRM=remove sh "$DB" remove --unverified
  exit_is 0; not_ran "helper wipe"; ran "helper unlink-only"; done_
fi

# ---- M1 ----
if start "M1 flash-slot-b: OnePlus in fastboot: nothing written"; then
  with_table
  run CONFIRM=flash-slot-b FAKE_PRODUCT=taro sh "$DB" flash-slot-b
  exit_not0; said "not say it is the Mi A3"; not_ran "fastboot flash"; not_ran "fastboot reboot"; done_
fi
if start "M1 flash-slot-b: no answer to getvar: nothing written"; then
  with_table
  run CONFIRM=flash-slot-b FAKE_PRODUCT=none sh "$DB" flash-slot-b
  exit_not0; not_ran "fastboot flash"; done_
fi
if start "M1 flash-slot-b: two phones in fastboot: nothing written"; then
  with_table
  run CONFIRM=flash-slot-b FAKE_FB=two sh "$DB" flash-slot-b
  exit_not0; not_ran "fastboot flash"; done_
fi
if start "M1 flash-slot-b: the phone changes after the first flash: no second write"; then
  with_table
  run CONFIRM=flash-slot-b FAKE_PRODUCT_AFTER_FLASH=taro sh "$DB" flash-slot-b
  exit_not0; ran "fastboot flash boot_b"; not_ran "fastboot flash dtbo_b"; done_
fi
if start "[R] M1 flash-slot-b: Mi A3: both written"; then
  with_table
  run CONFIRM=flash-slot-b sh "$DB" flash-slot-b
  exit_is 0; ran "fastboot flash boot_b"; ran "fastboot flash dtbo_b"; done_
fi
if start "M1 to-android: OnePlus in fastboot: no set_active"; then
  run CONFIRM=to-android FAKE_PRODUCT=taro sh "$DB" to-android
  exit_not0; not_ran "fastboot set_active"; not_ran "fastboot reboot"; done_
fi
if start "[R] M1 to-android: Mi A3: set_active a"; then
  run CONFIRM=to-android sh "$DB" to-android
  exit_is 0; ran "fastboot set_active a"; done_
fi

# ---- M3 ----
if start "M3 helper: a stale binary is rebuilt when a source changes"; then
  with_table
  mkdir -p "$D"; printf 'stale' > "$D/ldbhelper-arm64"; chmod +x "$D/ldbhelper-arm64"
  run CONFIRM=check-map sh "$DB" check-map
  exit_is 0
  grep -q 'ldbhelper-version [0-9a-f]\{32\}' "$P/state/helper_version" || no "the pushed helper has no source hash: $(cat "$P/state/helper_version")"
  done_
fi
if start "M3 helper: the phone reports another version: stops before any step"; then
  with_table
  run CONFIRM=check-map FAKE_FAIL=stale-on-phone sh "$DB" check-map
  exit_not0; not_ran "helper check-map"; done_
fi

# ---- M4 ----
if start "M4 map: the same blocks keep the table id, other blocks get a new one"; then
  with_table; : > "$P/data/laurel-ios/root.area"
  a=$("$TOOL" dualboot check "$D/table.ldbt" | sed -n 's/.* id \([0-9a-f]*\),.*/\1/p')
  run sh "$DB" map; exit_is 0
  b=$("$TOOL" dualboot check "$D/table.ldbt" | sed -n 's/.* id \([0-9a-f]*\),.*/\1/p')
  [ "$a" = "$b" ] || no "same blocks: id $a -> $b"
  printf '%s\n' "$FIEMAP2" > "$P/state/fiemap"
  run sh "$DB" map; exit_is 0
  c=$("$TOOL" dualboot check "$D/table.ldbt" | sed -n 's/.* id \([0-9a-f]*\),.*/\1/p')
  [ "$a" != "$c" ] || no "other blocks kept id $a"
  done_
fi
if start "M4 status: shows whether the file is encrypted"; then
  : > "$P/data/laurel-ios/root.area"
  run FAKE_LSATTR=----i---------E--- sh "$DB" status
  exit_is 0; said "ENCRYPTED"; done_
fi
if start "M4 status: says not encrypted"; then
  : > "$P/data/laurel-ios/root.area"
  run sh "$DB" status
  exit_is 0; said "not encrypted"; done_
fi

# ---- S5: the exact line from the phone, and what is not that ----
if start "S5 check_dm: the phone's line passes"; then
  with_table; : > "$P/data/laurel-ios/root.area"
  run sh "$DB" map
  exit_is 0; said "whole of userdata"; said "8:15"; done_
fi
if start "[R] S5 check_dm: header line of dmctl is no second target"; then
  with_table; : > "$P/data/laurel-ios/root.area"
  printf 'Targets in the device:\n%s\n' "$DMLINE" > "$P/state/dm"
  run sh "$DB" map
  exit_is 0; done_
fi
if start "S5 check_dm: a target shorter than the partition: stops"; then
  with_table; echo "0-226300000: default-key, aes-xts-plain64 - 0 8:15 0 3 allow_discards" > "$P/state/dm"
  run CONFIRM=check-map sh "$DB" check-map
  exit_not0; not_ran "helper check-map"; done_
fi
if start "S5 check_dm: another device: stops"; then
  with_table; echo "0-$SECTORS: default-key, aes-xts-plain64 - 0 8:14 0 3 allow_discards" > "$P/state/dm"
  run CONFIRM=check-map sh "$DB" check-map
  exit_not0; not_ran "helper check-map"; done_
fi
if start "S5 check_dm: two targets: stops"; then
  with_table; printf '0-1000: default-key, a - 0 8:15 0\n1000-%s: default-key, a - 0 8:15 1000\n' "$SECTORS" > "$P/state/dm"
  run CONFIRM=check-map sh "$DB" check-map
  exit_not0; not_ran "helper check-map"; done_
fi
if start "S5 check_dm: /data is not on sda15: stops"; then
  with_table; rm -rf "$P/sys/block/dm-40/slaves/sda15"; mkdir -p "$P/sys/block/dm-40/slaves/sda14"
  run CONFIRM=check-map sh "$DB" check-map
  exit_not0; not_ran "helper check-map"; done_
fi
if start "S5 check_dm: dmctl fails: stops"; then
  with_table; rm -f "$P/state/dm"
  run CONFIRM=check-map sh "$DB" check-map
  exit_not0; not_ran "helper check-map"; done_
fi

# ---- owner decision 2026-11-02: SIZE=32G by default, free margin, manual updates ----
if start "SIZE allocate with no size: the default area is 32 GiB + 6 MiB"; then
  run CONFIRM=allocate sh "$DB" allocate
  exit_is 0; ran "helper alloc /data/laurel-ios/root.area 34366029824 "; said "not a partition"; done_
fi
if start "SIZE allocate: too little free /data: refused, gives the numbers"; then
  # 44 GiB free - 32 GiB area = 12 GiB: under the 16 GiB margin
  run CONFIRM=allocate FAKE_FREE_KB=$((44 * 1024 * 1024)) sh "$DB" allocate 32
  exit_not0; said "44 GiB free"; said "16 GiB"; not_ran "helper alloc"; done_
fi
if start "[R] SIZE allocate: free /data cannot be read: refused"; then
  cat > "$T/pbin/df.keep" < "$T/pbin/df"; printf '#!/bin/sh\nexit 1\n' > "$T/pbin/df"
  run CONFIRM=allocate sh "$DB" allocate 32
  exit_not0; not_ran "helper alloc"; cat "$T/pbin/df.keep" > "$T/pbin/df"; rm -f "$T/pbin/df.keep"; done_
fi
if start "SIZE size: names the owner default"; then
  run sh "$DB" size ios26
  exit_is 0; said "SIZE=32G"; said "not a partition"; done_
fi
if start "[R] UPDATE switch: Android runs on slot b after a manual update: refused"; then
  with_table; echo b > "$P/state/running"; echo 1 > "$P/state/current"; echo 1 > "$P/state/active"
  run "$SW" sh "$DB" switch
  exit_not0; said "not on slot a"; not_ran "bootctl set-active"; not_ran "helper seal"; done_
fi
if start "UPDATE switch: update done, slot b active, reboot pending: refused"; then
  with_table; echo 1 > "$P/state/active"
  run "$SW" sh "$DB" switch
  exit_not0; said "manual update"; not_ran "bootctl set-active"; not_ran "helper seal"; done_
fi
if start "UPDATE switch: boot_b is no longer the image (a sideload wrote it): refused"; then
  with_table; echo "lineage boot image" > "$P/dev/block/by-name/boot_b"
  run "$SW" sh "$DB" switch
  exit_not0; said "boot_b"; said "sideload"; not_ran "bootctl set-active"; not_ran "helper seal"; done_
fi
if start "UPDATE switch: dtbo_b is no longer stock: refused"; then
  with_table; echo "lineage dtbo" > "$P/dev/block/by-name/dtbo_b"
  run "$SW" sh "$DB" switch
  exit_not0; said "dtbo_b"; not_ran "bootctl set-active"; not_ran "helper seal"; done_
fi
if start "UPDATE switch: an image without the fence kernel: refused"; then
  with_table
  printf 'ANDROID! LAURELESP laurel-dualboot\n' > "$IMG"
  printf 'image %s\ntable %s\n' "$(sha256sum "$IMG" | cut -d' ' -f1)" "$(sha256sum "$D/table.ldbt" | cut -d' ' -f1)" > "$IMG.dualboot"
  cp "$IMG" "$P/dev/block/by-name/boot_b"
  run "$SW" sh "$DB" switch
  exit_not0; said "patch 2950"; not_ran "bootctl set-active"; done_
fi

# ---- each writing step still needs its word ----
for s in allocate check-map install flash-slot-b switch to-android remove; do
  if start "[R] CONFIRM $s without its word: refused, adb not asked"; then
    run sh "$DB" "$s"
    exit_is 4; said "CONFIRM=$s"; not_ran "adb"; not_ran "fastboot"; done_
  fi
done
echo "dual-boot-test: $n cases, $fails failed"
[ "$fails" = 0 ]
