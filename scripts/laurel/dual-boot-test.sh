#!/bin/sh
# Host test of scripts/laurel/dual-boot.sh itself: a fake adb, fastboot and phone drive the real script through each failure path. Each case proves the next step did not run.
#   scripts/laurel/dual-boot-test.sh [TREE]     TREE: where the scripts under test come from (default: this repo). scripts/laurel/dualboot-tests-detect.sh gives it the old code.
#   OP10TOOL=path (default out/cargo/release/op10tool)   a real op10tool, and a real helper built for this host (-DLDB_TEST_FILE): plans and GPT writes are real, on a sparse file
# The real adb and fastboot cannot be reached: PATH is $T/bin (fakes) + $T/tools (symlinks to a short list of tools, adb and fastboot not among them), and the test checks that first.
# The scripts run from a copy in a temp folder, so out/ of this repo is not touched. Proves the script on the host. Nothing here proves anything about the phone.
# scripts/laurel/dualboot-tests-detect.sh shows that these tests find the defects.
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
pull)
  echo "adb pull \$2" >> "\$T/calls"
  fails pull && exit 1
  cp "\$(rewrite "\$2")" "\$3" ;;
reboot)
  echo "adb reboot \${2:-}" >> "\$T/calls"
  fails adb-reboot && exit 1
  exit 0 ;;
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
gpt-write) [ -n "\${FAKE_STOP:-}" ] && export LDB_TEST_STOP=\$FAKE_STOP; exec "\$T/real-helper" "\$@" ;;
gpt-dump) exec "\$T/real-helper" "\$@" ;;
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
sys.boot_completed) echo "\${FAKE_BOOTED:-1}" ;;
sys.user.0.ce_available) echo "\${FAKE_CE:-true}" ;;
ro.crypto.state) echo encrypted ;;
esac
EOT
cat > "$T/pbin/id" <<'EOT'
#!/bin/sh
echo "${FAKE_UID:-0}"
EOT
cat > "$T/pbin/readlink" <<EOT
#!/bin/sh
case "\$2" in
*iosroot) [ -e "$P/state/new-table" ] || exit 1; echo /dev/block/sda16 ;;
*) echo /dev/block/sda15 ;;
esac
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
is-slot-bootable) fails "bootctl-error\$2" && { echo "Error calling isSlotBootable()" >&2; exit 70; }; if [ "\$(cat "\$S/bootable\$2")" = 1 ]; then echo 1; else echo 0; exit 70; fi ;;
is-slot-marked-successful)
  # AOSP and LineageOS bootctl.cpp: true: 1, exit 0. false: 0, exit 70. HAL error: text on stderr, exit 70
  fails "bootctl-error\$2" && { echo "Error calling isSlotMarkedSuccessful()" >&2; exit 70; }
  if [ "\$(cat "\$S/successful\$2")" = 1 ]; then echo 1; else echo 0; exit 70; fi ;;
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
  partition-size:userdata) echo "partition-size:userdata: \${FAKE_UD:-0x12e1}" >&2 ;;
  partition-size:iosroot) [ "\${FAKE_IR:-}" != none ] && echo "partition-size:iosroot: \${FAKE_IR:-0x817d8}" >&2 ;;
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
RES=$D/first-boot.result
export HOME=$P/home
H=$HOME/laurel-backup
SECTORS_OLD=226307992; UD_BYTES=81109417984; IR_BYTES=34760273920; UD_SEC=$((UD_BYTES / 512))
# the helper for real, on the fake disk: its own test is ldbhelper-test.sh
clang -std=gnu11 -O1 -static -nostdlib -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -fuse-ld=lld -w -DLDB_TEST_FILE -o "$T/real-helper" "$SRC/tools/laurel-dualboot/ldbhelper.c" 2>/dev/null
[ -x "$T/real-helper" ] || { echo "FAIL no real helper"; exit 1; }
python3 -I "$REPO/scripts/laurel/gpt-fake.py" dumps "$T/head" "$T/tail"
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
head -c 4096 /dev/urandom > "$T/dtbo.img"
export STOCK_DTBO="$T/dtbo.img" OP10TOOL="$TOOL" APPLE="$T/apple"
M=$(sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$SRC/tools/laurel-dualboot/laurel_dualboot.h")
ROIMG=$T/repo/out/laurel-ios26/uefi-ro/laurel-uefi-boot.img
RWIMG=$T/repo/out/laurel-ios26/uefi-rw/laurel-uefi-boot.img
FW="abl bluetooth cmnlib cmnlib64 devcfg dsp hyp imagefv keymaster modem qupfw rpm storsec tz uefisecapp xbl xbl_config vbmeta"
# a boot image header with the OS field of Lineage 17.0.0, 2026-10 (raw 0x220001aa), then TEXT
mkimg() {
  python3 -I - "$1" "$2" "${3:-570425770}" <<'PY'
import struct, sys
b = bytearray(4096); b[:8] = b'ANDROID!'; struct.pack_into('<I', b, 40, 2); struct.pack_into('<I', b, 44, int(sys.argv[3]))
open(sys.argv[1], 'wb').write(bytes(b) + sys.argv[2].encode())
PY
}
sidecar() { printf 'image %s\nmode %s\nmarker %s\nos 17.0.0 2026-10\n' "$(sha256sum "$1" | cut -d' ' -f1)" "$2" "$M" > "$1.dualboot"; }
reset() {
  rm -rf "$P" "$D" "$T/repo/out/laurel-ios26"
  mkdir -p "$P/data/local/tmp" "$P/state" "$P/dev/block/by-name" "$P/sys/class/block/sda15" "$P/sys/class/block/sda16" "$P/sys/block/sda/queue" "$P/sys/block/dm-40/slaves/sda15"
  mkdir -p "$D" "${ROIMG%/*}" "${RWIMG%/*}" "$H/android-20261102-0137" "$H/lineage-24.0-20261027" "$T/apple"
  : > "$T/calls"
  # the phone before the change: the old table
  cp "$T/head" "$H/android-20261102-0137/gpt-sda-head.bin"; cp "$T/tail" "$H/android-20261102-0137/gpt-sda-tail.bin"
  python3 -I "$REPO/scripts/laurel/gpt-fake.py" disk "$P/dev/block/sda"
  echo $((30119936 * 8)) > "$P/sys/block/sda/size"; echo 4096 > "$P/sys/block/sda/queue/logical_block_size"
  : > "$H/android-20261102-0137/SHA256SUMS"
  for f in $FW; do
    printf 'firmware %s\n' "$f" > "$P/dev/block/by-name/${f}_b"
    printf '%s  %s_b.img\n' "$(sha256sum "$P/dev/block/by-name/${f}_b" | cut -d' ' -f1)" "$f" >> "$H/android-20261102-0137/SHA256SUMS"
  done
  mkimg "$H/lineage-24.0-20261027/boot.img" "linux kernel"
  printf '%s  boot.img\n' "$(sha256sum "$H/lineage-24.0-20261027/boot.img" | cut -d' ' -f1)" > "$H/lineage-24.0-20261027/SHA256SUMS"
  cp "$H/lineage-24.0-20261027/boot.img" "$P/dev/block/by-name/boot_a"
  echo 8:15 > "$P/sys/class/block/sda15/dev"
  echo "/dev/block/dm-40 on /data type f2fs (rw,background_gc=on,discard,mode=adaptive)" > "$P/state/mount"
  echo a > "$P/state/running"; echo 0 > "$P/state/current"; echo 0 > "$P/state/active"
  echo 1 > "$P/state/bootable0"; echo 1 > "$P/state/bootable1"; echo 1 > "$P/state/successful0"; echo 1 > "$P/state/successful1"
  echo $((1831432 * 8)) > "$P/sys/class/block/sda15/start"; echo "$SECTORS_OLD" > "$P/sys/class/block/sda15/size"
  echo "0-$SECTORS_OLD: default-key, aes-xts-plain64 - 0 8:15 0 3 allow_discards sector_size:4096 iv_large_sectors" > "$P/state/dm"
}
# the phone after the GPT write, the reboot and Format data: the kernel has the new table, f2fs of the new size
f2fs_sb() {
  python3 -I - "$P/dev/block/dm-40" "$1" <<'PY'
import struct, sys
b = bytearray(4096); struct.pack_into('<I', b, 1024, 0xF2F52010); struct.pack_into('<Q', b, 1024 + 36, int(sys.argv[2]))
open(sys.argv[1], 'wb').write(b)
PY
}
formatted() {
  : > "$P/state/new-table"
  echo $((1831432 * 8)) > "$P/sys/class/block/sda15/start"; echo "$UD_SEC" > "$P/sys/class/block/sda15/size"
  echo $((21633536 * 8)) > "$P/sys/class/block/sda16/start"; echo $((8486395 * 8)) > "$P/sys/class/block/sda16/size"
  echo "0-$UD_SEC: default-key, aes-xts-plain64 - 0 8:15 0 3 allow_discards sector_size:4096 iv_large_sectors" > "$P/state/dm"
  f2fs_sb $((UD_BYTES / 4096))
}
# after android-check, install, image, flash-slot-b
ready() {
  formatted
  printf 'gpt-written x\nandroid-opened x f2fs-bytes %s\n' "$UD_BYTES" > "$RES"
  cp "$T/root.img" "$P/dev/block/by-name/iosroot"
  head -c 1048576 "$T/root.img" > "$T/first1m"
  printf 'installed x %s %s\n' "$T/root.img" "$(sha256sum "$T/first1m" | cut -d' ' -f1)" >> "$RES"
  mkimg "$ROIMG" " boot args: rd=ufsroot0 $M LAURELESP"; sidecar "$ROIMG" ro
  cp "$ROIMG" "$P/dev/block/by-name/boot_b"; cp "$STOCK_DTBO" "$P/dev/block/by-name/dtbo_b"
}
rwimage() { mkimg "$RWIMG" " boot args: rd=ufsroot0 ufsrw=1 rootrw=1 $M LAURELESP"; sidecar "$RWIMG" rw; cp "$RWIMG" "$P/dev/block/by-name/boot_b"; }
THELINE="LAUREL DUALBOOT: on: root = iosroot, LUN 0, first block 21633536, 8486395 blocks (33149 MiB), read-only ($M)"
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
tbl() { python3 -I "$REPO/scripts/laurel/gpt-fake.py" check "$P/dev/block/sda"; }
disk_is_old() { tbl | grep -q '^userdata 1831432 30119930$' && tbl | grep -q 'sb data' || no "the table on the disk changed"; }
disk_is_new() { tbl | grep -q '^iosroot 21633536 30119930$' || no "no iosroot on the disk"; }
done_() {
  if [ -z "$bad" ]; then echo "ok   $name"; else
    fails=$((fails + 1)); echo "FAIL $name: $bad"
    printf '%s\n' "$o" | tail -4 | sed 's/^/     | /'; sed 's/^/     calls: /' "$T/calls" | tail -8
  fi
}
SW="CONFIRM=switch"
FBU=$(printf '0x%x' "$UD_BYTES"); FBI=$(printf '0x%x' "$IR_BYTES")
fb() { run "FAKE_UD=$FBU" "FAKE_IR=$FBI" "$@"; }

# ---- the GPT write ----
if start "GPT plan: host only, shows both tables, needs no phone"; then
  run FAKE_FAIL=adb-off sh "$DB" gpt-plan
  exit_is 0; said "before:"; said "after:"; said "IOSROOT_BYTES=$IR_BYTES"; not_ran "adb"; done_
fi
if start "GPT dry run: device check, fresh table, the exact commands, before and after; nothing written"; then
  run sh "$DB" gpt-write --dry-run
  exit_is 0; said "before:"; said "after:"; said "byte for byte"; said "gpt-write /data/local/tmp/ldbhelper.plan /dev/block/sda"; not_ran "helper gpt-write"; disk_is_old; done_
fi
if start "GPT write: all well: new table read back, a record, no reboot by the script"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write
  exit_is 0; ran "helper gpt-write"; said "gpt-write ok"; said "both CRCs right"; disk_is_new; grep -q '^gpt-written ' "$RES" || no "no record"; not_ran "adb reboot"
  [ "$(grep -n 'helper gpt-dump' "$T/calls" | tail -1 | cut -d: -f1)" -gt "$(grep -n '^helper gpt-write' "$T/calls" | cut -d: -f1)" ] || no "no read after the write"; done_
fi
if start "GPT write: the phone is another phone: nothing runs"; then
  run CONFIRM=gpt-write FAKE_DEVICE=OP516FL1 sh "$DB" gpt-write
  exit_not0; said "not the Mi A3"; not_ran "helper"; disk_is_old; done_
fi
if start "GPT write: adb is not root: nothing runs"; then
  run CONFIRM=gpt-write FAKE_UID=2000 sh "$DB" gpt-write
  exit_not0; said "not root"; not_ran "helper"; disk_is_old; done_
fi
if start "GPT write: slot b active: nothing runs"; then
  echo 1 > "$P/state/active"
  run CONFIRM=gpt-write sh "$DB" gpt-write
  exit_not0; not_ran "helper gpt-write"; disk_is_old; done_
fi
if start "GPT write: sda has another size: nothing runs"; then
  echo 123 > "$P/sys/block/sda/size"
  run CONFIRM=gpt-write sh "$DB" gpt-write
  exit_not0; said "the plan is for"; not_ran "helper gpt-write"; disk_is_old; done_
fi
if start "GPT write: the table on the phone differs from the backup: nothing written"; then
  python3 -I - "$P/dev/block/sda" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(2 * 4096 + 5 * 128 + 48); f.write(b'\x01')
PY
  run CONFIRM=gpt-write sh "$DB" gpt-write
  exit_not0; said "not the backup"; not_ran "helper gpt-write"; done_
fi
if start "GPT write: the backup dump is another layout: no plan"; then
  python3 -I - "$H/android-20261102-0137/gpt-sda-head.bin" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(2 * 4096 + 40); f.write(b'\x01')
PY
  run CONFIRM=gpt-write sh "$DB" gpt-write
  exit_not0; said "does not give a plan"; not_ran "helper gpt-write"; disk_is_old; done_
fi
if start "GPT write: the helper fails on the phone: exit not 0, no record"; then
  run CONFIRM=gpt-write FAKE_FAIL=gpt-write sh "$DB" gpt-write
  exit_not0; said "Do not reboot"; [ ! -f "$RES" ] || no "a record"; disk_is_old; done_
fi
if start "GPT write: adb lost during the write: exit not 0, no record"; then
  run CONFIRM=gpt-write FAKE_FAIL=drop:gpt-write sh "$DB" gpt-write
  exit_not0; [ ! -f "$RES" ] || no "a record"; done_
fi
if start "GPT write: stopped after step 2: a plain run refuses, --resume ends it"; then
  run CONFIRM=gpt-write FAKE_STOP=2 sh "$DB" gpt-write
  exit_not0; run CONFIRM=gpt-write sh "$DB" gpt-write
  exit_not0; said "--resume"; run CONFIRM=gpt-write sh "$DB" gpt-write --resume
  exit_is 0; disk_is_new; tbl | grep -q 'sb zero' || no "superblocks not zero"; done_
fi
if start "GPT restore: back to the old table by the same helper"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0
  run CONFIRM=gpt-restore sh "$DB" gpt-restore; exit_is 0; said "Format data"; tbl | grep -q '^userdata 1831432 30119930$' || no "not the old table"; done_
fi
if start "GPT restore print: runs nothing, says that LUN 0 is erased"; then
  run sh "$DB" gpt-restore-print
  exit_is 0; said "ERASES ALL OF LUN 0"; said "partition:0"; not_ran "fastboot"; not_ran "adb"; done_
fi

# ---- after the write ----
if start "After GPT: OnePlus in fastboot: no reboot"; then
  run CONFIRM=after-gpt FAKE_PRODUCT=taro sh "$DB" after-gpt
  exit_not0; not_ran "fastboot reboot"; done_
fi
if start "After GPT: ABL sees no iosroot: stops"; then
  run CONFIRM=after-gpt FAKE_IR=none sh "$DB" after-gpt
  exit_not0; said "no partition iosroot"; not_ran "fastboot reboot"; done_
fi
if start "After GPT: ABL sees other sizes: stops"; then
  run CONFIRM=after-gpt "FAKE_IR=$FBI" FAKE_UD=0x1000 sh "$DB" after-gpt
  exit_not0; not_ran "fastboot reboot"; done_
fi
if start "After GPT: right sizes: recovery, and the text says Format data"; then
  fb CONFIRM=after-gpt sh "$DB" after-gpt
  exit_is 0; ran "fastboot reboot recovery"; said "Format data"; done_
fi
if start "Android check: all well: a record"; then
  formatted; : > "$RES"
  run sh "$DB" android-check
  exit_is 0; grep -q '^android-opened ' "$RES" || no "no record"; done_
fi
if start "Android check: a stale superblock, old size: stops, no record"; then
  formatted; : > "$RES"; f2fs_sb 28288499
  run sh "$DB" android-check
  exit_not0; said "stale superblock"; ! grep -q '^android-opened ' "$RES" || no "a record"; done_
fi
if start "Android check: the dm target has the old size: stops"; then
  formatted; : > "$RES"; echo "0-$SECTORS_OLD: default-key, aes-xts-plain64 - 0 8:15 0 3" > "$P/state/dm"
  run sh "$DB" android-check
  exit_not0; said "new userdata has"; ! grep -q '^android-opened ' "$RES" || no "a record"; done_
fi
if start "Android check: the kernel has the old table: stops"; then
  : > "$RES"
  run sh "$DB" android-check
  exit_not0; said "iosroot"; ! grep -q '^android-opened ' "$RES" || no "a record"; done_
fi
if start "Android check: data not open yet: stops"; then
  formatted; : > "$RES"
  run FAKE_CE=false sh "$DB" android-check
  exit_not0; said "not open"; ! grep -q '^android-opened ' "$RES" || no "a record"; done_
fi

# ---- install ----
if start "Install: no record that Android opened its data: nothing"; then
  fb CONFIRM=install sh "$DB" install "$T/root.img"
  exit_not0; said "android-check"; not_ran "fastboot"; done_
fi
if start "Install: writes iosroot, in sparse pieces, never userdata"; then
  printf 'android-opened x\n' > "$RES"
  fb CONFIRM=install sh "$DB" install "$T/root.img"
  exit_is 0; ran "fastboot -S 512M flash iosroot"; not_ran "flash userdata"; grep -q '^installed ' "$RES" || no "no record"; done_
fi
if start "Install: an image over the limit: nothing"; then
  printf 'android-opened x\n' > "$RES"; truncate -s 34760273920 "$T/big.img"
  fb CONFIRM=install sh "$DB" install "$T/big.img"
  exit_not0; said "at most"; not_ran "fastboot"; rm -f "$T/big.img"; done_
fi
if start "Install: OnePlus in fastboot: nothing written"; then
  printf 'android-opened x\n' > "$RES"
  fb CONFIRM=install FAKE_PRODUCT=taro sh "$DB" install "$T/root.img"
  exit_not0; not_ran "fastboot flash"; not_ran "-S 512M"; done_
fi
if start "Install: ABL sees no iosroot: nothing written"; then
  printf 'android-opened x\n' > "$RES"
  run CONFIRM=install "FAKE_UD=$FBU" FAKE_IR=none sh "$DB" install "$T/root.img"
  exit_not0; not_ran "fastboot flash"; not_ran "-S 512M"; done_
fi

# ---- flash-slot-b ----
if start "Flash slot b: OnePlus in fastboot: nothing written"; then
  ready
  fb CONFIRM=flash-slot-b FAKE_PRODUCT=taro sh "$DB" flash-slot-b
  exit_not0; said "not say it is the Mi A3"; not_ran "fastboot flash"; not_ran "fastboot reboot"; done_
fi
if start "Flash slot b: two phones: nothing written"; then
  ready
  fb CONFIRM=flash-slot-b FAKE_FB=two sh "$DB" flash-slot-b
  exit_not0; not_ran "fastboot flash"; done_
fi
if start "Flash slot b: the phone changes after the first flash: no second write"; then
  ready
  fb CONFIRM=flash-slot-b FAKE_PRODUCT_AFTER_FLASH=taro sh "$DB" flash-slot-b
  exit_not0; ran "fastboot flash boot_b"; not_ran "fastboot flash dtbo_b"; done_
fi
if start "Flash slot b: the read-only image: both written"; then
  ready
  fb CONFIRM=flash-slot-b sh "$DB" flash-slot-b
  exit_is 0; ran "fastboot flash boot_b $ROIMG"; ran "fastboot flash dtbo_b"; done_
fi
if start "RO gate: flash-slot-b rw with no read-only result: refused"; then
  ready; rwimage
  fb CONFIRM=flash-slot-b sh "$DB" flash-slot-b rw
  exit_not0; said "read-only boot"; not_ran "fastboot flash"; done_
fi
if start "RO gate: image rw with no result: refused before any build"; then
  ready
  run sh "$DB" image rw
  exit_not0; said "read-only boot"; done_
fi
if start "Image: the installed root's hash goes to the image build (the Android app's root mark), rw only after the gate"; then
  ready
  printf 'ro-on %s x\nandroid-opened-after-ro x\n' "$M" >> "$RES"
  S26=$T/repo/scripts/laurel/ios26-image.sh
  cat > "$S26" <<'EOS'
#!/bin/sh
echo "$LAUREL_READONLY $IOSROOT_HEAD_SHA" > "$UEFI_W.env"
mkdir -p "$UEFI_W"; : > "$UEFI_W/laurel-uefi-boot.img"; printf 'mode %s\nos 17.0.0 2026-10\n' "$([ "$LAUREL_READONLY" = 1 ] && echo ro || echo rw)" > "$UEFI_W/laurel-uefi-boot.img.dualboot"
EOS
  chmod +x "$S26"
  run sh "$DB" image rw
  exit_is 0; said "mode rw"
  [ "$(cat "${RWIMG%/*}.env")" = "0 $(sha256sum "$T/first1m" | cut -d' ' -f1)" ] || no "image rw got: $(cat "${RWIMG%/*}.env")"
  rm -f "$S26" "${RWIMG%/*}.env"; done_
fi
if start "RO gate: a writable image named as the read-only path: refused by its text"; then
  ready; mkimg "$ROIMG" " ufsrw=1 rootrw=1 $M LAURELESP"; sidecar "$ROIMG" ro; cp "$ROIMG" "$P/dev/block/by-name/boot_b"
  run "$SW" sh "$DB" switch
  exit_not0; said "can write"; not_ran "bootctl set-active"; done_
fi

# ---- switch ----
if start "Switch: all well: slot b, normal reboot; no freeze, no seal"; then
  ready
  run "$SW" sh "$DB" switch
  exit_is 0; order "bootctl set-active-boot-slot 1" "adb reboot"; state_is active 1; state_is successful1 0; said "Back to Android"; not_ran "helper"; done_
fi
if start "S3 switch: xbl_b differs from the backup: refused before set-active"; then
  ready; echo other > "$P/dev/block/by-name/xbl_b"
  run "$SW" sh "$DB" switch
  exit_not0; said "xbl_b"; not_ran "bootctl set-active"; not_ran "adb reboot"; done_
fi
if start "S3 switch: another firmware differs (abl_b): refused before set-active"; then
  ready; echo other > "$P/dev/block/by-name/abl_b"
  run "$SW" sh "$DB" switch
  exit_not0; said "abl_b"; not_ran "bootctl set-active"; done_
fi
if start "S3 switch: a firmware cannot be read: refused"; then
  ready; rm -f "$P/dev/block/by-name/tz_b"
  run "$SW" sh "$DB" switch
  exit_not0; not_ran "bootctl set-active"; done_
fi
if start "S3 check-slot-b: read-only, all equal"; then
  run sh "$DB" check-slot-b
  exit_is 0; said "equal the backup"; not_ran "set-active"; done_
fi
if start "F5 switch: bootctl error on slot b's successful bit: stops, no reboot"; then
  ready
  run "$SW" FAKE_FAIL=bootctl-error1 sh "$DB" switch
  exit_not0; said "not a yes and not a no"; not_ran "adb reboot"; done_
fi
if start "F5 switch: bootctl error on slot a: stops before any write"; then
  ready
  run "$SW" FAKE_FAIL=bootctl-error0 sh "$DB" switch
  exit_not0; said "not a yes and not a no"; not_ran "bootctl set-active"; done_
fi
if start "F5 a real no (stdout 0, exit 70) is a no: slot a not successful: refused with that reason"; then
  ready; echo 0 > "$P/state/successful0"
  run "$SW" sh "$DB" switch
  exit_not0; said "not marked successful"; not_ran "bootctl set-active"; done_
fi
if start "Switch: slot b stays marked successful: back on slot a, no reboot"; then
  ready
  run "$SW" FAKE_FAIL=keep-successful sh "$DB" switch
  exit_not0; state_is active 0; not_ran "adb reboot"; ran "bootctl mark-boot-successful"; done_
fi
if start "Switch: set-active fails: no reboot, slot a"; then
  ready
  run "$SW" FAKE_FAIL=set-active1 sh "$DB" switch
  exit_not0; not_ran "adb reboot"; state_is active 0; done_
fi
if start "Switch: adb reboot fails: back on slot a"; then
  ready
  run "$SW" FAKE_FAIL=adb-reboot sh "$DB" switch
  exit_not0; state_is active 0; done_
fi
if start "Switch: Android runs on slot b after a manual update: refused"; then
  ready; echo b > "$P/state/running"; echo 1 > "$P/state/current"; echo 1 > "$P/state/active"
  run "$SW" sh "$DB" switch
  exit_not0; said "not on slot a"; not_ran "bootctl set-active"; done_
fi
if start "Switch: boot_b is no longer the image (a sideload): refused"; then
  ready; echo "lineage boot image" > "$P/dev/block/by-name/boot_b"
  run "$SW" sh "$DB" switch
  exit_not0; said "boot_b"; said "sideload"; not_ran "bootctl set-active"; done_
fi
if start "Switch: dtbo_b is no longer stock: refused"; then
  ready; echo "lineage dtbo" > "$P/dev/block/by-name/dtbo_b"
  run "$SW" sh "$DB" switch
  exit_not0; said "dtbo_b"; not_ran "bootctl set-active"; done_
fi
if start "Switch: an image without the fence kernel: refused"; then
  ready; mkimg "$ROIMG" " LAURELESP"; sidecar "$ROIMG" ro; cp "$ROIMG" "$P/dev/block/by-name/boot_b"
  run "$SW" sh "$DB" switch
  exit_not0; said "patch 2950"; not_ran "bootctl set-active"; done_
fi
if start "S1 switch: an image with another OS field than Lineage: refused"; then
  ready; mkimg "$ROIMG" " rd=ufsroot0 $M" 369099112; sidecar "$ROIMG" ro; cp "$ROIMG" "$P/dev/block/by-name/boot_b"
  run "$SW" sh "$DB" switch
  exit_not0; said "OS version field"; not_ran "bootctl set-active"; done_
fi
if start "S1 switch: boot_a on the phone has a newer header (a sideload) than the image: refused"; then
  ready; mkimg "$P/dev/block/by-name/boot_a" "linux" 570425771
  run "$SW" sh "$DB" switch
  exit_not0; said "boot_a"; not_ran "bootctl set-active"; done_
fi
if start "Switch: iosroot does not hold the root: refused"; then
  ready; echo garbage > "$P/dev/block/by-name/iosroot"
  run "$SW" sh "$DB" switch
  exit_not0; said "installed root"; not_ran "bootctl set-active"; done_
fi
if start "Switch: the kernel has the old table: refused"; then
  ready; rm -f "$P/state/new-table"
  run "$SW" sh "$DB" switch
  exit_not0; not_ran "bootctl set-active"; done_
fi

# ---- the read-only result ----
if start "RO result: the right line: recorded"; then
  ready; printf 'x\n%s\n' "$THELINE" > "$T/log"
  run sh "$DB" ro-result "$T/log"
  exit_is 0; grep -q "^ro-on $M " "$RES" || no "no record"; done_
fi
if start "RO result: an off line after it: no record"; then
  ready; printf '%s\nLAUREL DUALBOOT: off: x; no write anywhere\n' "$THELINE" > "$T/log"
  run sh "$DB" ro-result "$T/log"
  exit_not0; said "said no"; ! grep -q '^ro-on ' "$RES" || no "a record"; done_
fi
if start "RO result: a line of a writable boot: no record"; then
  ready; printf 'LAUREL DUALBOOT: on: root = iosroot, LUN 0, first block 21633536, 8486395 blocks (33149 MiB), writes fenced to this partition (%s)\n' "$M" > "$T/log"
  run sh "$DB" ro-result "$T/log"
  exit_not0; ! grep -q '^ro-on ' "$RES" || no "a record"; done_
fi
if start "RO result: other numbers: no record"; then
  ready; printf 'LAUREL DUALBOOT: on: root = iosroot, LUN 0, first block 21633537, 8486395 blocks (33149 MiB), read-only (%s)\n' "$M" > "$T/log"
  run sh "$DB" ro-result "$T/log"
  exit_not0; ! grep -q '^ro-on ' "$RES" || no "a record"; done_
fi
if start "RO result: no line: no record"; then
  ready; echo nothing > "$T/log"
  run sh "$DB" ro-result "$T/log"
  exit_not0; said "no LAUREL DUALBOOT line"; done_
fi
if start "RO gate: a result but Android not checked after it: rw refused"; then
  ready; rwimage; printf '%s\n' "$THELINE" > "$T/log"; run sh "$DB" ro-result "$T/log"
  fb CONFIRM=flash-slot-b sh "$DB" flash-slot-b rw
  exit_not0; said "android-check"; not_ran "fastboot flash"; done_
fi
if start "RO gate: result + Android opened after it: rw goes"; then
  ready; rwimage; printf '%s\n' "$THELINE" > "$T/log"; run sh "$DB" ro-result "$T/log"
  run sh "$DB" android-check; exit_is 0
  fb CONFIRM=flash-slot-b sh "$DB" flash-slot-b rw
  exit_is 0; ran "fastboot flash boot_b $RWIMG"; done_
fi

# ---- back to Android ----
if start "To Android: OnePlus in fastboot: no set_active"; then
  run CONFIRM=to-android FAKE_PRODUCT=taro sh "$DB" to-android
  exit_not0; not_ran "fastboot set_active"; not_ran "fastboot reboot"; done_
fi
if start "To Android: Mi A3: set_active a, reboot, says what is next"; then
  run CONFIRM=to-android sh "$DB" to-android
  exit_is 0; ran "fastboot set_active a"; order "fastboot set_active a" "fastboot reboot"; said "android-check"; done_
fi

# ---- helper version ----
if start "Helper: a stale binary is rebuilt when the source changes"; then
  mkdir -p "$D"; printf 'stale' > "$D/ldbhelper-arm64"; chmod +x "$D/ldbhelper-arm64"
  run sh "$DB" gpt-write --dry-run
  exit_is 0
  grep -q 'ldbhelper-version [0-9a-f]\{32\}' "$P/state/helper_version" || no "the pushed helper has no source hash: $(cat "$P/state/helper_version")"
  done_
fi
if start "Helper: the phone reports another version: stops before any step"; then
  run CONFIRM=gpt-write FAKE_FAIL=stale-on-phone sh "$DB" gpt-write
  exit_not0; not_ran "helper gpt-write"; disk_is_old; done_
fi

# ---- each writing step still needs its word ----
for s in gpt-write after-gpt install flash-slot-b switch to-android gpt-restore; do
  if start "CONFIRM $s without its word: refused, adb not asked"; then
    run sh "$DB" "$s"
    exit_is 4; said "CONFIRM=$s"; not_ran "adb"; not_ran "fastboot"; done_
  fi
done
echo "dual-boot-test: $n cases, $fails failed"
[ "$fails" = 0 ]
