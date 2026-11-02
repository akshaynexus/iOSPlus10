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
# /tmp first: \$P itself can lie under /tmp, and each rule runs once on the text
rewrite() { printf '%s' "\$1" | sed -e "s#^/tmp/#\$P/tmp/#" -e "s# /tmp/# \$P/tmp/#g" -e "s#/data/#\$P/data/#g" -e "s#/dev/block/#\$P/dev/block/#g" -e "s#/sys/#\$P/sys/#g"; }
shortcmd() { printf '%s' "\$1" | sed -e 's/; _ldb_r=.*//'; }
case "\$1" in
get-state) echo "adb get-state" >> "\$T/calls"; fails adb-off && exit 1; echo "\${FAKE_STATE:-device}" ;;
devices) echo "adb devices" >> "\$T/calls"; printf 'List of devices attached\n'; fails adb-off || printf 'FAKE\tdevice\n' ;;
push)
  echo "adb push \$3" >> "\$T/calls"
  fails push && { echo "adb: push failed" >&2; exit 1; }
  case "\$3" in /data/*) [ -d "\$P/data/local/tmp" ] || { echo "adb: error: remote couldn't create file: No such file or directory" >&2; exit 1; } ;; esac
  if [ "\${3##*/}" = ldbhelper ]; then
    LC_ALL=C grep -ao 'ldbhelper-version [0-9a-z]*' "\$2" | head -1 > "\$P/state/helper_version" || true
    cp "\$T/fake-helper" "\$(rewrite "\$3")"
    fails helper-noexec && chmod 000 "\$(rewrite "\$3")"
    :
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
fails "hang:\$c" && exec sleep 20 > /dev/null 2>&1
fails "\$c" && { echo "ldbhelper: FAILED: \$c (fake)" >&2; exit 1; }
case "\$c" in
version) fails helper-noexec && exit 126; if fails stale-on-phone; then echo "ldbhelper-version 0000"; else cat "\$P/state/helper_version"; [ -s "\$P/state/helper_version" ] || echo "ldbhelper-version unversioned"; fi ;;
gpt-write) [ -n "\${FAKE_STOP:-}" ] && export LDB_TEST_STOP=\$FAKE_STOP; exec "\$T/real-helper" "\$@" ;;
gpt-dump|root-verify) exec "\$T/real-helper" "\$@" ;;
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
  partition-size:iosroot)
    k=\$(grep -c 'getvar partition-size:iosroot' "\$T/calls"); v=\$(printf '%s,' "\${FAKE_IR_SEQ:-}" | cut -d, -f"\$k")
    if [ -n "\$v" ]; then
      if [ "\$v" = none ]; then echo "unknown command" >&2; else echo "partition-size:iosroot: \$v" >&2; fi
    elif [ "\${FAKE_IR_LATE:-0}" = 1 ] && [ "\$(grep -c 'getvar partition-size:iosroot' "\$T/calls")" -lt 2 ]; then echo "unknown command" >&2
    elif [ "\${FAKE_IR:-}" != none ]; then echo "partition-size:iosroot: \${FAKE_IR:-0x817d8}" >&2; fi ;;
  esac ;;
set_active) case " \${FAKE_FAIL:-} " in *" fb-set-active "*) echo "FAILED (remote: 'garbled')" >&2; exit 1 ;; esac ;;
-S)
  # fastboot -S 512M flash iosroot FILE: with FAKE_APPLY=1 the chunks really go to the fake partition: DON'T CARE leaves the old bytes. ABL answers OKAY for each piece, and a lost last piece shows nothing here (FastbootCmds.c:3425-3437).
  case " \${FAKE_FAIL:-} " in *" fb-flash "*) echo "FAILED (remote: 'Download failed')" >&2; exit 1 ;; esac
  [ "\${FAKE_APPLY:-0}" != 1 ] || python3 -I "\$T/apply-simg.py" "\$5" "$P/dev/block/by-name/\$4" "\${FAKE_LOSE_LAST:-0}" ;;
stage) echo "FAILED (remote: 'stage is no verdict')" >&2; exit 1 ;;
reboot) if [ -z "\${2:-}" ]; then case " \${FAKE_FAIL:-} " in *" fb-reboot-hang "*) exec sleep 20 > /dev/null 2>&1 ;; *" fb-reboot "*) echo "FAILED (remote: 'garbled')" >&2; exit 1 ;; esac; fi; if [ "\${2:-}" = recovery ]; then case " \${FAKE_FAIL:-} " in *" fb-reboot-recovery "*) echo "FAILED (remote: 'unknown command')" >&2; exit 1 ;; esac; fi ;;
esac
exit 0
EOT
cat > "$T/pbin/pm" <<EOT
#!/bin/sh
echo "pm \$*" >> "$T/calls"
case "\$1" in
list) [ "\${FAKE_UPDATER:-off}" = on ] || echo package:org.lineageos.updater ;;
disable-user) case " \${FAKE_FAIL:-} " in *" pm-disable "*) exit 1 ;; esac; echo "Package org.lineageos.updater new state: disabled-user" ;;
esac
EOT
cat > "$T/apply-simg.py" <<'PY'
# What ABL does with a sparse image: RAW and FILL go to the partition, DON'T CARE leaves its bytes. Argument 3 = 1: the last piece that holds data is lost, as a write failure after ABL's OKAY.
import struct, sys
s, dev, lose = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
d = open(s, 'rb').read()
_, _, _, fh, ch, blk, total, chunks, _ = struct.unpack('<IHHHHIIII', d[:28])
at, pos, writes = fh, 0, []
for _ in range(chunks):
    kind, _, size, bytes_ = struct.unpack('<HHII', d[at:at + 12])
    body = d[at + ch:at + bytes_]
    if kind == 0xcac1: writes.append((pos, body))
    elif kind == 0xcac2: writes.append((pos, body[:4] * (size * blk // 4)))
    pos += size; at += bytes_
if lose: writes.pop()
with open(dev, 'r+b') as f:
    for b, data in writes:
        f.seek(b * blk); f.write(data)
PY
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
    # all of the first MiB in use, as in the real root (its first range starts at block 0): `switch` hashes the first MiB
    for b in range(0, 256): bm[b // 8] |= 0x80 >> (b % 8)
    f.seek(2 * 4096); f.write(bm)
    f.seek(100 * 4096); f.write(b'\x55' * 8192)
    # data past the first MiB, in its own piece, at the end: the part that `switch` never read before verify-root
    f.seek(1000 * 4096); f.write(bytes(range(256)) * 16)
    f.seek(2000 * 4096); f.write(bytes(range(255, -1, -1)) * 16)
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
  mkdir -p "$P/data/local/tmp" "$P/tmp" "$P/state" "$P/dev/block/by-name" "$P/sys/class/block/sda15" "$P/sys/class/block/sda16" "$P/sys/block/sda/queue" "$P/sys/block/dm-40/slaves/sda15"
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
  # steps 1 and 1b are done, unless a case takes them away
  rec_backup "$H/android-20261102-0137"
  printf 'recovery root x\n' > "$D/rehearsal.result"
}
# what step 1 records
rec_backup() { { echo "$1"; sha256sum "$1/gpt-sda-head.bin" | cut -d' ' -f1; sha256sum "$1/gpt-sda-tail.bin" | cut -d' ' -f1; } > "$D/pre-write-backup"; }
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
  printf 'root-verified x verify ranges 1 blocks 1 end 1 crc32 00000000 %s\n' "$(sha256sum "$T/first1m" | cut -d' ' -f1)" >> "$RES"
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
  rec_backup "$H/android-20261102-0137"
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
if start "F9 restore print: each flash has -S 512M, each image a hash check from SHA256SUMS"; then
  run sh "$DB" gpt-restore-print
  exit_is 0; said "fastboot -S 512M flash partition:0"; said "fastboot -S 512M flash P"; said "SHA256SUMS"; said "sha256sum"
  printf '%s\n' "$o" | grep -E '^ +fastboot flash ' && no "a plain fastboot flash in the text"; done_
fi

# ---- F2: gpt-restore from recovery: adb get-state says recovery, no /data there ----
if start "F2 restore in recovery: state recovery, no /data: the helper runs from /tmp, the old layout comes back"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0; rm -rf "$P/data"; : > "$T/calls"
  run CONFIRM=gpt-restore FAKE_STATE=recovery sh "$DB" gpt-restore
  exit_is 0; said "Format data"; ran "adb push /tmp/ldbhelper"; not_ran "adb push /data"; tbl | grep -q '^userdata 1831432 30119930$' || no "not the old layout"; done_
fi
if start "F2 restore dry run in recovery: nothing written"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0; rm -rf "$P/data"; : > "$T/calls"
  run FAKE_STATE=recovery sh "$DB" gpt-restore --dry-run
  exit_is 0; said "dry run"; not_ran "helper gpt-write"; disk_is_new; done_
fi
if start "F2 the first write refuses recovery: nothing runs"; then
  run CONFIRM=gpt-write FAKE_STATE=recovery sh "$DB" gpt-write
  exit_not0; said "only in Android"; not_ran "helper"; disk_is_old; done_
fi
if start "F2 switch refuses recovery"; then
  ready
  run "$SW" FAKE_STATE=recovery sh "$DB" switch
  exit_not0; said "only in Android"; not_ran "bootctl set-active"; done_
fi
if start "F2 restore in recovery with no root adb: stops, says so"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0
  run CONFIRM=gpt-restore FAKE_STATE=recovery FAKE_UID=2000 sh "$DB" gpt-restore
  exit_not0; said "not root"; disk_is_new; done_
fi

# ---- F3: the way back is made from the table on the disk ----
if start "F3 restore after a slot change: only the last LBA of userdata and the iosroot slot change, by an independent diff"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0
  python3 -I "$REPO/scripts/laurel/gpt-fake.py" slot-change "$P/dev/block/sda"
  a0=$(python3 -I "$REPO/scripts/laurel/gpt-fake.py" entry "$P/dev/block/sda" system_a)
  run CONFIRM=gpt-restore sh "$DB" gpt-restore
  exit_is 0; said "only: last LBA of userdata"; tbl | grep -q '^userdata 1831432 30119930$' || no "not the old layout"; tbl | grep -q iosroot && no "iosroot is still there"; tbl | grep -q 'primary valid backup valid' || no "a copy is not valid"
  [ "$(python3 -I "$REPO/scripts/laurel/gpt-fake.py" entry "$P/dev/block/sda" system_a)" = "$a0" ] || no "system_a changed"
  d=$(python3 -I "$REPO/scripts/laurel/gpt-fake.py" tablediff "$D/gpt/before.head" "$D/gpt/before.tail" "$D/gpt/after.head" "$D/gpt/after.tail" | awk '{print $1, ($1 ~ /entries/) ? (($2 >= 1920 && $3 < 2048) ? "iosroot-slot" : ($2 >= 1832 && $3 < 1840) ? "userdata-last" : "OTHER") : (($2 >= 16 && $3 < 20) ? "hdr-crc" : ($2 >= 88 && $3 < 92) ? "entries-crc" : "OTHER")}' | sort -u | tr '\n' ';')
  [ "$d" = "backup-entries iosroot-slot;backup-entries userdata-last;backup-header entries-crc;backup-header hdr-crc;primary-entries iosroot-slot;primary-entries userdata-last;primary-header entries-crc;primary-header hdr-crc;" ] || no "the independent diff: $d"; done_
fi
if start "F3 restore stopped after step 2, adb gone: the same command ends it"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0
  python3 -I "$REPO/scripts/laurel/gpt-fake.py" slot-change "$P/dev/block/sda"
  run CONFIRM=gpt-restore FAKE_STOP=2 sh "$DB" gpt-restore; exit_not0; disk_is_new
  run CONFIRM=gpt-restore sh "$DB" gpt-restore; exit_is 0; tbl | grep -q '^userdata 1831432 30119930$' || no "not the old layout"; tbl | grep -q 'primary valid backup valid' || no "a copy is not valid"; done_
fi
if start "F3 restore with the old layout on the flash: nothing written"; then
  run CONFIRM=gpt-restore sh "$DB" gpt-restore
  exit_is 0; said "already"; not_ran "helper gpt-write"; disk_is_old; done_
fi
if start "F3 restore of a stopped gpt-write (primary old, backup new): refused, nothing written"; then
  run CONFIRM=gpt-write FAKE_STOP=2 sh "$DB" gpt-write; exit_not0; : > "$T/calls"
  run CONFIRM=gpt-restore sh "$DB" gpt-restore
  exit_not0; said "stopped gpt-write"; not_ran "helper gpt-write"; done_
fi

# ---- F4: a half-written primary ----
# the new table's primary blocks, then a stop before step 4, then one of them on the disk
torn_setup() {
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0; cp "$D/gpt/after.head" "$T/new.head"
  python3 -I "$REPO/scripts/laurel/gpt-fake.py" disk "$P/dev/block/sda"
  run CONFIRM=gpt-write FAKE_STOP=3 sh "$DB" gpt-write
  : > "$T/calls"
}
if start "F4 a torn primary, Android still up: --resume writes it from the plan: the new table"; then
  torn_setup; python3 -I "$REPO/scripts/laurel/gpt-fake.py" block "$P/dev/block/sda" 1 "$T/new.head" 1
  run CONFIRM=gpt-write sh "$DB" gpt-write --resume
  exit_is 0; said "half written"; disk_is_new; tbl | grep -q 'primary valid backup valid' || no "a copy is not valid"; done_
fi
if start "F4 a torn primary, recovery: gpt-repair writes it from the backup, nothing else: the new table"; then
  torn_setup; python3 -I "$REPO/scripts/laurel/gpt-fake.py" block "$P/dev/block/sda" 2 "$T/new.head" 2; rm -rf "$P/data"
  run CONFIRM=gpt-repair FAKE_STATE=recovery sh "$DB" gpt-repair
  exit_is 0; said "torn-backup-new"; said "after-gpt"; disk_is_new; tbl | grep -q 'primary valid backup valid' || no "a copy is not valid"; done_
fi
if start "F4 a torn primary, recovery: gpt-restore repairs first, then the old layout"; then
  torn_setup; python3 -I "$REPO/scripts/laurel/gpt-fake.py" block "$P/dev/block/sda" 1 garbage; rm -rf "$P/data"
  run CONFIRM=gpt-restore FAKE_STATE=recovery sh "$DB" gpt-restore
  exit_is 0; said "from the backup copy"; said "Format data"; tbl | grep -q '^userdata 1831432 30119930$' || no "not the old layout"; tbl | grep -q 'primary valid backup valid' || no "a copy is not valid"; done_
fi
if start "F4 repair: a dry run writes nothing"; then
  torn_setup; python3 -I "$REPO/scripts/laurel/gpt-fake.py" block "$P/dev/block/sda" 1 garbage; rm -rf "$P/data"
  run FAKE_STATE=recovery sh "$DB" gpt-repair --dry-run
  exit_is 0; said "dry run"; not_ran "helper gpt-write"; tbl | grep -q 'primary INVALID' || no "the primary changed"; done_
fi
if start "F4 no valid copy at all: refused, the last resort named"; then
  python3 -I "$REPO/scripts/laurel/gpt-fake.py" block "$P/dev/block/sda" 1 garbage; python3 -I "$REPO/scripts/laurel/gpt-fake.py" block "$P/dev/block/sda" 30119935 garbage; rm -rf "$P/data"
  run CONFIRM=gpt-restore FAKE_STATE=recovery sh "$DB" gpt-restore
  exit_not0; said "neither copy"; said "gpt-restore-print"; not_ran "helper gpt-write"; done_
fi

# ---- F5: the backup of step 1 ----
later_backup() {  # a backup made after the write: it holds the new table, and it is the newest folder
  mkdir -p "$H/android-20261103-0900"; cp "$D/gpt/after.head" "$H/android-20261103-0900/gpt-sda-head.bin"; cp "$D/gpt/after.tail" "$H/android-20261103-0900/gpt-sda-tail.bin"; : > "$H/android-20261103-0900/SHA256SUMS"
}
if start "F5 a backup after the write is newer: restore, the print and check-slot-b use the one of step 1"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0; later_backup
  run sh "$DB" gpt-restore-print; exit_is 0; said "android-20261102-0137"
  run sh "$DB" check-slot-b; exit_is 0; said "android-20261102-0137"
  run CONFIRM=gpt-restore sh "$DB" gpt-restore; exit_is 0; tbl | grep -q '^userdata 1831432 30119930$' || no "not the old layout"; done_
fi
if start "F5 a backup after the write is newer: --resume keeps the plan of step 1"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0; later_backup
  run CONFIRM=gpt-write sh "$DB" gpt-write --resume; exit_is 0; said "nothing written"; done_
fi
if start "F5 step 1 records the backup, and a second run keeps it"; then
  rm -f "$D/pre-write-backup"
  run sh "$DB" gpt-write --dry-run; exit_is 0; said "pre-write backup on record"; [ "$(sed -n 1p "$D/pre-write-backup")" = "$H/android-20261102-0137" ] || no "the record: $(cat "$D/pre-write-backup")"
  mkdir -p "$H/android-20261103-0900"; cp "$T/head" "$H/android-20261103-0900/gpt-sda-head.bin"; cp "$T/tail" "$H/android-20261103-0900/gpt-sda-tail.bin"
  run sh "$DB" gpt-write --dry-run; exit_is 0; [ "$(sed -n 1p "$D/pre-write-backup")" = "$H/android-20261102-0137" ] || no "the record moved: $(cat "$D/pre-write-backup")"; done_
fi
if start "F5 no record: the write and the restore stop with a clear error, nothing runs on the phone"; then
  rm -f "$D/pre-write-backup"
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_not0; said "no record of the pre-write backup"; not_ran "helper gpt-write"
  run CONFIRM=gpt-restore sh "$DB" gpt-restore; exit_not0; said "no record of the pre-write backup"; not_ran "helper gpt-write"
  run sh "$DB" gpt-restore-print; exit_not0; said "no record of the pre-write backup"; done_
fi
if start "F5 a dry run that does not match the phone records nothing"; then
  rm -f "$D/pre-write-backup"
  python3 -I "$REPO/scripts/laurel/gpt-fake.py" slot-change "$P/dev/block/sda"
  run sh "$DB" gpt-write --dry-run; exit_not0; said "not the backup"; [ ! -f "$D/pre-write-backup" ] || no "a record"; done_
fi
if start "F5 the table files of the recorded backup changed: stops"; then
  printf x >> "$H/android-20261102-0137/gpt-sda-head.bin"
  run sh "$DB" gpt-restore-print; exit_not0; said "changed after step 1"; done_
fi
if start "F5 record-backup: a backup that holds the new table is refused"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0; later_backup; cp "$D/pre-write-backup" "$T/rec"
  run sh "$DB" record-backup "$H/android-20261103-0900"; exit_not0; cmp -s "$T/rec" "$D/pre-write-backup" || no "the record changed"; done_
fi

# ---- F6: --resume on a phone with the new table ----
if start "F6 --resume, the new table there: the record keeps every line, nothing is written"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0
  printf 'gpt-written x\nandroid-opened x f2fs-bytes 1\ninstalled x y z\nro-on %s x\n' "$M" > "$RES"; cp "$RES" "$T/res0"; : > "$T/calls"
  run CONFIRM=gpt-write sh "$DB" gpt-write --resume
  exit_is 0; said "nothing written"; cmp -s "$T/res0" "$RES" || no "the record changed: $(cat "$RES")"; not_ran "helper gpt-write"; done_
fi
if start "F6 --resume after adb was lost right after the write: the new table there, the record gets its line"; then
  run CONFIRM=gpt-write sh "$DB" gpt-write; exit_is 0; rm -f "$RES"
  run CONFIRM=gpt-write sh "$DB" gpt-write --resume
  exit_is 0; grep -q '^gpt-written ' "$RES" || no "no record"; done_
fi

# ---- S5: one writer at a time on the phone ----
if start "S5 a writer runs on the phone: --resume stops, disk unchanged"; then
  run CONFIRM=gpt-write FAKE_STOP=2 sh "$DB" gpt-write; exit_not0
  : > "$P/data/local/tmp/ldbhelper.plan.lock"
  python3 -I - "$P/data/local/tmp/ldbhelper.plan.lock" env CONFIRM=gpt-write sh "$DB" gpt-write --resume > "$T/s5.out" 2>&1 <<'PY'
import fcntl, subprocess, sys
l = open(sys.argv[1], 'r+'); fcntl.flock(l, fcntl.LOCK_EX)
sys.exit(subprocess.run(sys.argv[2:], stdin=subprocess.DEVNULL, close_fds=True).returncode)
PY
  rc=$?; o=$(cat "$T/s5.out"); exit_not0; said "another gpt-write"; tbl | grep -q '^userdata 1831432 30119930$' || no "the write went on"; 
  run CONFIRM=gpt-write sh "$DB" gpt-write --resume; exit_is 0; disk_is_new; done_
fi

# ---- the rehearsal, and step 2's guard ----
if start "S1 rehearsal: the guide, asks the phone nothing"; then
  run sh "$DB" rehearsal
  exit_is 0; said "FastbootCmds.c:2596"; said "writes its boot message to misc"; said "Enable ADB"; not_ran "adb"; not_ran "fastboot"; done_
fi
if start "S1 rehearsal reach: needs its word"; then
  run sh "$DB" rehearsal reach
  exit_is 4; said "CONFIRM=rehearsal-reach"; not_ran "fastboot"; done_
fi
if start "S1 rehearsal reach: ABL refuses: a record, the next step, exit 0"; then
  rm -f "$D/rehearsal.result"
  run CONFIRM=rehearsal-reach FAKE_FAIL=fb-reboot-recovery sh "$DB" rehearsal reach
  exit_is 0; said "Power + Vol Up"; grep -q '^reach fastboot-reboot-recovery refused' "$D/rehearsal.result" || no "no record"; done_
fi
if start "S1 rehearsal reach: ABL accepts: a record"; then
  rm -f "$D/rehearsal.result"
  run CONFIRM=rehearsal-reach sh "$DB" rehearsal reach
  exit_is 0; ran "fastboot reboot recovery"; grep -q '^reach fastboot-reboot-recovery accepted' "$D/rehearsal.result" || no "no record"; done_
fi
if start "S2 rehearsal recovery: root adb: a read-only dump from /tmp, a record, no write on the phone"; then
  rm -f "$D/rehearsal.result"; rm -rf "$P/data"
  before=$(sha256sum "$P/dev/block/sda" 2>/dev/null | cut -c1-16)
  run FAKE_STATE=recovery sh "$DB" rehearsal recovery
  exit_is 0; said "gives root adb"; ran "adb push /tmp/ldbhelper"; ran "helper gpt-dump"; not_ran "helper gpt-write"; grep -q '^recovery root ' "$D/rehearsal.result" || no "no record"; disk_is_old; done_
fi
if start "S2 rehearsal recovery: no root adb: a record, and the owner reads what it means"; then
  rm -f "$D/rehearsal.result"
  run FAKE_STATE=recovery FAKE_UID=2000 sh "$DB" rehearsal recovery
  exit_is 0; said "GIVES NO ROOT ADB"; said "ERASES ALL OF LUN 0"; said "persist"; not_ran "helper"; grep -q '^recovery no-root' "$D/rehearsal.result" || no "no record"; done_
fi
if start "S2 rehearsal recovery: the helper does not run there: counts as no root"; then
  rm -f "$D/rehearsal.result"
  run FAKE_STATE=recovery FAKE_FAIL=helper-noexec sh "$DB" rehearsal recovery
  exit_is 0; said "GIVES NO ROOT ADB"; grep -q '^recovery no-root' "$D/rehearsal.result" || no "no record"; done_
fi
if start "S2 rehearsal recovery: the phone is in Android: no record"; then
  rm -f "$D/rehearsal.result"
  run sh "$DB" rehearsal recovery
  exit_not0; said "not recovery"; [ ! -f "$D/rehearsal.result" ] || no "a record"; done_
fi
if start "S2 rehearsal no-adb: a record, what it means"; then
  rm -f "$D/rehearsal.result"
  run sh "$DB" rehearsal no-adb
  exit_is 0; said "ERASES ALL OF LUN 0"; grep -q '^recovery no-root' "$D/rehearsal.result" || no "no record"; not_ran "adb"; done_
fi
if start "S1 guard: step 2 with no rehearsal on record: refused, the phone is not asked"; then
  rm -f "$D/rehearsal.result"
  run CONFIRM=gpt-write sh "$DB" gpt-write
  exit_not0; said "no rehearsal on record"; not_ran "adb"; disk_is_old; done_
fi
if start "S1 guard: a dry run says that step 2 refuses"; then
  rm -f "$D/rehearsal.result"
  run sh "$DB" gpt-write --dry-run
  exit_is 0; said "step 2 refuses"; done_
fi
if start "S2 guard: recovery has no root: step 2 refuses until the owner's word, the text is shown"; then
  printf 'recovery no-root: x\n' > "$D/rehearsal.result"
  run CONFIRM=gpt-write sh "$DB" gpt-write
  exit_not0; said "ERASES ALL OF LUN 0"; said "NO_RECOVERY_ROOT=lun-erase-accepted"; not_ran "helper gpt-write"; disk_is_old
  run sh "$DB" gpt-write --dry-run; exit_is 0; said "ERASES ALL OF LUN 0"
  run CONFIRM=gpt-write NO_RECOVERY_ROOT=lun-erase-accepted sh "$DB" gpt-write
  exit_is 0; said "ERASES ALL OF LUN 0"; disk_is_new; done_
fi
if start "After GPT: never runs fastboot reboot recovery: on this phone it boots Android; says the buttons"; then
  formatted 2>/dev/null || true
  fb CONFIRM=after-gpt sh "$DB" after-gpt
  exit_is 0; not_ran "fastboot reboot recovery"; said "Volume Up + Power"; said "Format data"; done_
fi

# ---- a stale op10tool: the main checkout's out/bin/op10tool had no gpt command ----
cat > "$T/stale-tool" <<'EOT'
#!/bin/sh
echo "error: unrecognized subcommand 'gpt'" >&2
exit 2
EOT
chmod +x "$T/stale-tool"
if start "O stale op10tool by hand: stops before the phone is asked, says how to build"; then
  run OP10TOOL="$T/stale-tool" CONFIRM=gpt-write sh "$DB" gpt-write
  exit_not0; said "no GPT support"; said "build-op10tool.sh"; not_ran "adb"; disk_is_old; done_
fi
for c in "gpt-write --dry-run" gpt-restore-print gpt-plan "rehearsal recovery"; do
  if start "O stale op10tool: $c stops"; then
    # shellcheck disable=SC2086
    run OP10TOOL="$T/stale-tool" CONFIRM=gpt-restore sh "$DB" $c
    exit_not0; said "no GPT support"; not_ran "helper"; done_
  fi
done
if start "O stale out/bin/op10tool, no cargo: stops; with cargo: rebuilt, and the step goes on"; then
  mkdir -p "$T/repo/out/bin"; cp "$T/stale-tool" "$T/repo/out/bin/op10tool"
  run OP10TOOL= sh "$DB" gpt-plan
  exit_not0; said "no GPT support"
  mkdir -p "$T/repo/scripts/setup"; cp "$T/repo/scripts/setup/build-op10tool.sh" "$T/build.saved"
  printf '#!/bin/sh\ncp "%s" "%s"\n' "$TOOL" "$T/repo/out/bin/op10tool" > "$T/repo/scripts/setup/build-op10tool.sh"; chmod +x "$T/repo/scripts/setup/build-op10tool.sh"
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/cargo"; chmod +x "$T/bin/cargo"
  run sh -c 'unset OP10TOOL; exec sh "$0" gpt-plan' "$DB"
  exit_is 0; said "building it now"; said "IOSROOT_BYTES="
  rm -f "$T/bin/cargo"; cp "$T/build.saved" "$T/repo/scripts/setup/build-op10tool.sh"; rm -f "$T/repo/out/bin/op10tool"; done_
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
  exit_is 0; not_ran "fastboot reboot recovery"; said "Volume Up + Power"; said "Format data"; done_
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
if start "Install: one garbled getvar: asked again, not called absent"; then
  printf 'android-opened x f2fs-bytes 1\n' > "$RES"; mkdir -p "$D"
  fb CONFIRM=install FAKE_IR_LATE=1 sh "$DB" install "$T/root.img"
  exit_is 0; ran "fastboot -S 512M flash iosroot"; done_
fi
if start "F2 install: no fastboot stage: it is no verdict, and it stops no good flash"; then
  printf 'android-opened x f2fs-bytes 1\n' > "$RES"
  fb CONFIRM=install sh "$DB" install "$T/root.img"
  exit_is 0; not_ran "fastboot stage"; grep -q '^installed ' "$RES" || no "no record"; said "verify-root"; done_
fi
if start "F2 fastboot reboot is refused after the flash: a warning, what to do, the record, exit 0"; then
  printf 'android-opened x f2fs-bytes 1\n' > "$RES"
  fb CONFIRM=install FAKE_FAIL=fb-reboot sh "$DB" install "$T/root.img"
  exit_is 0; said "WARNING: ABL did not take 'reboot'"; said "Hold Power"; said "verify-root"; grep -q '^installed ' "$RES" || no "no record"; done_
fi
if start "F2 ABL hangs at fastboot reboot: the job ends at the limit, a warning, what to do, the record"; then
  printf 'android-opened x f2fs-bytes 1\n' > "$RES"; t0=$(date +%s)
  fb CONFIRM=install FAKE_FAIL=fb-reboot-hang FLASH_REBOOT_LIMIT=2 sh "$DB" install "$T/root.img"
  exit_is 0; said "did not answer 'reboot' in 2 s"; said "Hold Power"; said "verify-root"; grep -q '^installed ' "$RES" || no "no record"
  [ $(($(date +%s) - t0)) -lt 15 ] || no "it waited past the limit"; done_
fi
if start "F2 the flash itself fails: no installed record, what to do"; then
  printf 'android-opened x f2fs-bytes 1\n' > "$RES"
  fb CONFIRM=install FAKE_FAIL=fb-flash sh "$DB" install "$T/root.img"
  exit_not0; said "flash failed"; said "Power+VolDown"; grep -q '^installed ' "$RES" && no "recorded as installed"; [ "$(sed -n 2p "$RES" | cut -d' ' -f1)" = install-started ] || no "no install-started line"; done_
fi

# ---- F6: flash-root.sh asks getvar again ----
FR=$T/repo/scripts/laurel/flash-root.sh
if start "F6 flash-root: one getvar with no answer: asked again, no wrong advice, the flash goes"; then
  rm -f "$T/root.simg"; run sh "$DB" prepare-root "$T/root.img"; exit_is 0
  fb FAKE_IR_SEQ=none sh "$FR" "$T/root.simg"
  exit_is 0; ran "fastboot -S 512M flash iosroot"; printf '%s' "$o" | grep -q 'GPT steps' && no "wrong advice"; done_
fi
if start "F6 flash-root: one garbled size: asked again, no shell error, the flash goes"; then
  rm -f "$T/root.simg"; run sh "$DB" prepare-root "$T/root.img"; exit_is 0
  fb FAKE_IR_SEQ=0xZZ sh "$FR" "$T/root.simg"
  exit_is 0; ran "fastboot -S 512M flash iosroot"; done_
fi
if start "F6 flash-root: three garbled sizes: refused, says what to do, no flash"; then
  rm -f "$T/root.simg"; run sh "$DB" prepare-root "$T/root.img"; exit_is 0
  fb FAKE_IR_SEQ=0xZZ,0xZZ,0xZZ sh "$FR" "$T/root.simg"
  exit_is 3; said "not a number"; said "fastboot reboot bootloader"; said "Nothing was written"; not_ran "-S 512M"; done_
fi
if start "F6 flash-root: three answers with no size: only then the GPT steps, after a clean session"; then
  rm -f "$T/root.simg"; run sh "$DB" prepare-root "$T/root.img"; exit_is 0
  fb FAKE_IR_SEQ=none,none,none sh "$FR" "$T/root.simg"
  exit_is 3; said "after 3 tries"; said "fastboot reboot bootloader"; said "GPT steps"; not_ran "-S 512M"; done_
fi
if start "F6 flash-root: a garbled userdata size: refused, no shell error"; then
  rm -f "$T/root.simg"; run sh "$DB" prepare-root "$T/root.img"; exit_is 0
  run FAKE_UD=0xQQ "FAKE_IR=$FBI" sh "$FR" "$T/root.simg"
  exit_is 3; said "userdata the size '0xQQ'"; not_ran "-S 512M"; done_
fi
if start "F6 dual-boot: a garbled size in need_fastboot_layout: refused with words, no shell error"; then
  run CONFIRM=after-gpt "FAKE_IR=0xZZ" "FAKE_UD=$FBU" sh "$DB" after-gpt
  exit_not0; said "not numbers"; not_ran "fastboot reboot"; done_
fi

# ---- F1: the read-back of the whole root ----
# the partition with old bytes in every block, then the real chunks over it: what a flash leaves behind
oldbytes() { rm -f "$P/dev/block/by-name/iosroot"; python3 -I - "$P/dev/block/by-name/iosroot" <<'PY'
import sys
open(sys.argv[1], 'wb').write(b'\xa5' * (2048 * 4096))
PY
}
installed() { formatted; printf 'android-opened x f2fs-bytes 1\n' > "$RES"; oldbytes; fb CONFIRM=install FAKE_APPLY=1 "$@" sh "$DB" install "$T/root.img"; exit_is 0; }
slotb() { mkimg "$ROIMG" " boot args: rd=ufsroot0 $M LAURELESP"; sidecar "$ROIMG" ro; cp "$ROIMG" "$P/dev/block/by-name/boot_b"; cp "$STOCK_DTBO" "$P/dev/block/by-name/dtbo_b"; }
patch_block() { python3 -I - "$P/dev/block/by-name/iosroot" "$1" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(int(sys.argv[2])); b = f.read(1); f.seek(int(sys.argv[2])); f.write(bytes([b[0] ^ 0xff]))
PY
}
if start "F1 install, verify-root, switch: all well: the record, then slot b"; then
  installed; grep -q '^installed ' "$RES" || no "no installed"; [ -f "$D/root-verify.list" ] || no "no list"
  run sh "$DB" verify-root
  exit_is 0; said "read back"; said "root-verify: read in"; ran "helper root-verify"; grep -q '^root-verified ' "$RES" || no "no record"
  slotb; run "$SW" sh "$DB" switch; exit_is 0; state_is active 1; done_
fi
if start "F1 the first flash leaves old bytes in the DON'T CARE blocks, and a change there is no failure"; then
  installed
  cmp -s "$P/dev/block/by-name/iosroot" "$T/root.img" && no "the fake partition has no old bytes, so this tests nothing"
  [ "$(od -An -tx1 -j$((1500 * 4096)) -N1 "$P/dev/block/by-name/iosroot" | tr -d ' ')" = a5 ] || no "block 1500 is not old flash bytes"
  patch_block $((1500 * 4096)); run sh "$DB" verify-root
  exit_is 0; grep -q '^root-verified ' "$RES" || no "no record"; done_
fi
if start "F1 one byte damaged in a range: found, no record, switch refused"; then
  installed; patch_block $((1000 * 4096 + 77)); run sh "$DB" verify-root
  exit_not0; said "not what was flashed"; said "CONFIRM=install"; ! grep -q '^root-verified ' "$RES" || no "a record"
  slotb; run "$SW" sh "$DB" switch; exit_not0; said "not read back"; not_ran "bootctl set-active"; done_
fi
if start "F1 ABL says OKAY and the last piece is lost: first MiB good, found by verify-root only"; then
  installed FAKE_LOSE_LAST=1
  [ "$(head -c 1048576 "$P/dev/block/by-name/iosroot" | sha256sum | cut -d' ' -f1)" = "$(head -c 1048576 "$T/root.img" | sha256sum | cut -d' ' -f1)" ] || no "the first MiB differs: this tests nothing"
  run sh "$DB" verify-root
  exit_not0; said "not what was flashed"; ! grep -q '^root-verified ' "$RES" || no "a record"; done_
fi
if start "F1 adb lost during the read: no record, says so"; then
  installed; run FAKE_FAIL=drop:root-verify sh "$DB" verify-root
  exit_not0; said "adb lost the phone"; ! grep -q '^root-verified ' "$RES" || no "a record"; done_
fi
if start "F1 the time limit ends: no record, says so, the job ends"; then
  installed; t0=$(date +%s); run ROOT_VERIFY_LIMIT=2 FAKE_FAIL=hang:root-verify sh "$DB" verify-root
  exit_not0; said "no answer from the phone in 2 s"; ! grep -q '^root-verified ' "$RES" || no "a record"; [ $(($(date +%s) - t0)) -lt 15 ] || no "it waited past the limit"; done_
fi
if start "F1 the helper fails on the phone: no record, says so"; then
  installed; run FAKE_FAIL=root-verify sh "$DB" verify-root
  exit_not0; said "the helper failed"; ! grep -q '^root-verified ' "$RES" || no "a record"; done_
fi
if start "F1 verify-root with no install on record: nothing asked of the phone"; then
  printf 'android-opened x f2fs-bytes 1\n' > "$RES"; run sh "$DB" verify-root
  exit_not0; said "no record of an installed root"; not_ran "adb"; done_
fi
if start "F1 switch with no read-back: refused"; then
  ready; grep -v '^root-verified ' "$RES" > "$RES.x"; mv "$RES.x" "$RES"
  run "$SW" sh "$DB" switch; exit_not0; said "not read back"; said "verify-root"; not_ran "bootctl set-active"; done_
fi
if start "F1 a later flash voids the read-back: a failed one: switch refused, though the first MiB still matches"; then
  installed; run sh "$DB" verify-root; exit_is 0
  fb CONFIRM=install FAKE_FAIL=fb-flash sh "$DB" install "$T/root.img"; exit_not0
  slotb; run "$SW" sh "$DB" switch; exit_not0; said "did not end with a record"; not_ran "bootctl set-active"
  run sh "$DB" verify-root; exit_not0; said "CONFIRM=install"; done_
fi
if start "F1 a later flash voids the read-back: a good one needs its own"; then
  installed; run sh "$DB" verify-root; exit_is 0
  fb CONFIRM=install FAKE_APPLY=1 sh "$DB" install "$T/root.img"; exit_is 0
  slotb; run "$SW" sh "$DB" switch; exit_not0; said "not read back"; not_ran "bootctl set-active"
  run sh "$DB" verify-root; exit_is 0; run "$SW" sh "$DB" switch; exit_is 0; done_
fi
if start "F1 image rw: the marks let the app switch: refused with no read-back"; then
  ready; printf 'ro-on %s x\nandroid-opened-after-ro x\n' "$M" >> "$RES"; grep -v '^root-verified ' "$RES" > "$RES.x"; mv "$RES.x" "$RES"
  run sh "$DB" image rw; exit_not0; said "not read back"; done_
fi
if start "F1 a stale op10tool, install: stops before the phone is asked"; then
  printf 'android-opened x f2fs-bytes 1\n' > "$RES"
  run OP10TOOL="$T/stale-tool" CONFIRM=install sh "$DB" install "$T/root.img"
  exit_not0; said "no GPT support"; not_ran "fastboot"; done_
fi

# ---- F4: a failed conversion is a failure ----
cat > "$T/fail-tool" <<EOT
#!/bin/sh
case "\$1" in \${FAIL_CMD:-none}) echo "op10tool: \$1: failed (fake)" >&2; exit 1 ;; esac
exec "$TOOL" "\$@"
EOT
chmod +x "$T/fail-tool"
if start "F4 prepare-root: img2simg fails: exit not 0, no ready line, no image"; then
  rm -f "$T/root.simg" "$T/root.simg.partial"
  run OP10TOOL="$T/fail-tool" FAIL_CMD=img2simg sh "$DB" prepare-root "$T/root.img"
  exit_not0; printf '%s' "$o" | grep -q 'ready:' && no "says ready: $o"; said "no sparse image"; [ ! -f "$T/root.simg" ] || no "an image"; [ ! -f "$T/root.simg.partial" ] || no "a partial file"; done_
fi
if start "F4 prepare-root: the read-back list fails: exit not 0, no ready line"; then
  rm -f "$T/root.simg"
  run OP10TOOL="$T/fail-tool" FAIL_CMD=simg-verify-list sh "$DB" prepare-root "$T/root.img"
  exit_not0; printf '%s' "$o" | grep -q 'ready:' && no "says ready: $o"; said "no read-back list"; done_
fi
if start "F4 install: make_simg fails: nothing asked of fastboot, no record"; then
  printf 'android-opened x f2fs-bytes 1\n' > "$RES"; rm -f "$T/root.simg"
  fb OP10TOOL="$T/fail-tool" FAIL_CMD=img2simg CONFIRM=install sh "$DB" install "$T/root.img"
  exit_not0; said "no sparse image"; not_ran "fastboot"; grep -q '^install' "$RES" && no "a record"; done_
fi
if start "Prepare root: host only, makes the sparse image, asks nothing of the phone"; then
  rm -f "$T/root.simg"; run sh "$DB" prepare-root "$T/root.img"
  exit_is 0; said "ready: $T/root.simg"; [ -f "$T/root.simg" ] || no "no simg"; [ -f "$D/simg.list" ] || no "no list"; not_ran "adb"; not_ran "fastboot"; done_
fi
if start "Switch: Lineage's Updater is on: refused before set-active"; then
  ready
  run CONFIRM=switch FAKE_UPDATER=on sh "$DB" switch
  exit_not0; said "Updater is on"; not_ran "bootctl set-active-boot-slot"; done_
fi
if start "F3 Android check: Updater disable fails: stops, no record, and it did reach pm"; then
  formatted; : > "$RES"; run FAKE_FAIL=pm-disable sh "$DB" android-check
  exit_not0; said "Updater"; ran "pm disable-user"; grep -q '^android-opened ' "$RES" && no "recorded"; done_
fi
if start "F3 Android check after the read-only boot: pm fails: neither record; the next run writes both"; then
  formatted; printf 'android-opened x f2fs-bytes 1\nro-on %s x\n' "$M" > "$RES"; run FAKE_FAIL=pm-disable sh "$DB" android-check
  exit_not0; ! grep -q '^android-opened-after-ro ' "$RES" || no "after-ro recorded"; [ "$(grep -c '^android-opened ' "$RES")" = 1 ] || no "a new android-opened line"
  run sh "$DB" android-check; exit_is 0; grep -q '^android-opened-after-ro ' "$RES" || no "the next run wrote no after-ro"; [ "$(grep -c '^android-opened ' "$RES")" = 2 ] || no "the next run wrote no android-opened"; done_
fi
if start "F3 Android check: pm runs before the record is written"; then
  formatted; : > "$RES"; run sh "$DB" android-check
  exit_is 0; ran "pm disable-user"; grep -q '^android-opened ' "$RES" || no "no record"; grep -q '^android-opened-after-ro ' "$RES" && no "after-ro with no read-only boot"; done_
fi
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
if start "To Android: set_active fails: stops, says what to do, no reboot"; then
  run CONFIRM=to-android FAKE_FAIL=fb-set-active sh "$DB" to-android
  exit_not0; said "fastboot reboot bootloader"; not_ran "fastboot reboot"; done_
fi
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
for s in gpt-write after-gpt install flash-slot-b switch to-android gpt-restore gpt-repair; do
  if start "CONFIRM $s without its word: refused, adb not asked"; then
    run sh "$DB" "$s"
    exit_is 4; said "CONFIRM=$s"; not_ran "adb"; not_ran "fastboot"; done_
  fi
done
echo "dual-boot-test: $n cases, $fails failed"
[ "$fails" = 0 ]
