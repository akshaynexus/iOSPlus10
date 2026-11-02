#!/bin/sh
# Host test of the Android guard: every script that can write userdata, with a fake adb, fastboot, lsusb and ssh that record every call. No phone is touched, also when one is on the cable.
#   scripts/laurel/android-guard-test.sh [TREE]     (scripts/laurel/test-dualboot.sh runs it; TREE: the scripts under test, default this repo)
# The real adb and fastboot cannot be reached: PATH is the fakes + a short list of tool links, without adb and fastboot; checked first. The scripts run from a copy in a temp folder.
# ONLY=glob runs the matching tests (scripts/laurel/dualboot-tests-detect.sh shows that these tests find the defects).
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${1:-$REPO}
T=$(mktemp -d "${TMPDIR:-/tmp}/ldb-guard.XXXXXX")
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/bin" "$T/tools" "$T/tools-noto" "$T/tools-bare" "$T/repo/config"
cp -R "$SRC/scripts" "$T/repo/scripts"
mkdir -p "$T/repo/tools"; cp -R "$SRC/tools/laurel-dualboot" "$T/repo/tools/laurel-dualboot"
: > "$T/repo/config/laurel-android-data"
HOST_PATH=$PATH
for c in sh bash cat sed awk grep tr cut head tail wc mkdir rm mv cp ln chmod dirname basename date sleep sha256sum mktemp env printf test expr uname nproc touch sort od cmp git python3 kill ls true false timeout perl tee stat readlink id gzip dd truncate find cpio; do
  p=$(PATH=$HOST_PATH command -v "$c" 2>/dev/null) || continue
  case "$p" in /*)
    ln -sf "$p" "$T/tools/$c"
    [ "$c" = timeout ] || ln -sf "$p" "$T/tools-noto/$c"
    [ "$c" = timeout ] || [ "$c" = perl ] || ln -sf "$p" "$T/tools-bare/$c" ;;
  esac
done
cat > "$T/bin/fastboot" <<EOT
#!/bin/sh
T="$T"
[ "\${1:-}" = -s ] && shift 2
echo "fastboot \$*" >> "\$T/calls"
case "\${1:-}" in
devices)
  # after-reboot: the phone reaches fastboot only after adb reboot bootloader
  case "\${FAKE_FB:-one}" in
  one) printf 'FAKE\tfastboot\n' ;;
  two) printf 'A\tfastboot\nB\tfastboot\n' ;;
  after-reboot) grep -q '^adb reboot bootloader' "\$T/calls" && printf 'FAKE\tfastboot\n' ;;
  esac ;;
getvar)
  case "\$2" in
  product)
    if [ -n "\${FAKE_PRODUCT_AFTER_FLASH:-}" ] && grep -q '^fastboot flash' "\$T/calls"; then echo "product: \$FAKE_PRODUCT_AFTER_FLASH" >&2
    elif [ -n "\${FAKE_PRODUCT_AFTER_USERSPACE:-}" ] && grep -q '^fastboot getvar is-userspace' "\$T/calls"; then echo "product: \$FAKE_PRODUCT_AFTER_USERSPACE" >&2
    else echo "product: \${FAKE_PRODUCT:-laurel_sprout}" >&2; fi ;;
  is-userspace) echo "is-userspace: no" >&2 ;;
  current-slot) echo "current-slot: a" >&2 ;;
  esac ;;
esac
exit 0
EOT
printf '#!/bin/sh\nsha256sum "$3"\n' > "$T/bin/shasum"
for t in lsusb sudo ssh; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 0\n' "$t" "$T" > "$T/bin/$t"; done
cat > "$T/bin/adb" <<EOT
#!/bin/sh
echo "adb \$*" >> "$T/calls"
case "\${FAKE_ADB:-android}" in
off) exit 1 ;;
oneplus) d=OP516FL1 ;;
*) d=laurel_sprout ;;
esac
case "\$*" in
get-state) echo device ;;
devices) printf 'List of devices attached\nFAKE\tdevice\n' ;;
*ro.product.device*) echo "\$d" ;;
*ro.build.version.release*) echo 17 ;;
esac
exit 0
EOT
cat > "$T/repo/scripts/laurel/phone-ssh.sh" <<'EOT'
#!/bin/sh
[ -n "${FAKE_SYSCTL:-}" ] && echo "$FAKE_SYSCTL"
exit 0
EOT
cat > "$T/ssh-on" <<'EOT'
#!/bin/sh
echo 1
EOT
chmod +x "$T"/bin/* "$T/repo/scripts/laurel/phone-ssh.sh" "$T/ssh-on"
PATH=$T/bin:$T/tools; export PATH
fails=0; n=0
[ "$(command -v adb)" = "$T/bin/adb" ] && [ "$(command -v fastboot)" = "$T/bin/fastboot" ] || { echo "FAIL the fakes are not first in PATH"; exit 1; }
if PATH=$T/tools command -v adb >/dev/null 2>&1 || PATH=$T/tools command -v fastboot >/dev/null 2>&1; then echo "FAIL a real adb or fastboot is in the tool list"; exit 1; fi
echo "ok   real adb and fastboot cannot be reached: PATH holds fakes and a short tool list only"
WRITES='^(fastboot (flash|erase|format|-w|-S|boot|set_active|reboot|--disable)|sudo )'
# expect NAME EXIT TEXT CMD...: exit code, text in the output, and no fastboot write / no ssh write in the record
expect() {
  name=$1; rc=$2; text=$3; shift 3
  [ -z "${ONLY:-}" ] || case "$name" in $ONLY) ;; *) return 0 ;; esac
  : > "$T/calls"
  got=0; o=$("$@" 2>&1 < /dev/null) || got=$?
  n=$((n + 1))
  if [ "$got" != "$rc" ] || { [ -n "$text" ] && ! printf '%s' "$o" | grep -qF -- "$text"; }; then
    fails=$((fails + 1)); echo "FAIL $name: exit $got, wanted $rc, wanted text '$text'"; printf '%s\n' "$o" | tail -4 | sed 's/^/     | /'; return
  fi
  if grep -qE "$WRITES" "$T/calls"; then
    fails=$((fails + 1)); echo "FAIL $name: a write reached the phone tools:"; sed 's/^/     | /' "$T/calls"; return
  fi
  echo "ok   $name"
}
# expect_calls NAME EXIT MUST_RUN MUST_NOT_RUN CMD...: writes are allowed here; the record decides
expect_calls() {
  name=$1; rc=$2; must=$3; mustnot=$4; shift 4
  [ -z "${ONLY:-}" ] || case "$name" in $ONLY) ;; *) return 0 ;; esac
  : > "$T/calls"
  got=0; o=$("$@" 2>&1 < /dev/null) || got=$?
  n=$((n + 1)); b=
  [ "$got" = "$rc" ] || b="exit $got, wanted $rc"
  [ -z "$must" ] || grep -qF -- "$must" "$T/calls" || b="$b; did not run: $must"
  [ -z "$mustnot" ] || ! grep -qF -- "$mustnot" "$T/calls" || b="$b; ran: $mustnot"
  if [ -n "$b" ]; then fails=$((fails + 1)); echo "FAIL $name: $b"; printf '%s\n' "$o" | tail -4 | sed 's/^/     | /'; sed 's/^/     calls: /' "$T/calls" | tail -6; return; fi
  echo "ok   $name"
}
R=$T/repo
F=$R/config/laurel-android-data
G=$R/scripts/laurel
M=$(sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$SRC/tools/laurel-dualboot/laurel_dualboot.h")
export HOME=$T/home
LB=$HOME/laurel-backup/lineage-24.0-20261027; AB=$HOME/laurel-backup/android-20261102-0137
mkdir -p "$LB" "$AB"
# a boot image header with an OS field (Lineage: 17.0.0, 2026-10 = raw 0x220001aa), then TEXT
mkimg() {
  python3 -I - "$1" "$2" "${3:-570425770}" <<'PY'
import struct, sys
b = bytearray(4096); b[:8] = b'ANDROID!'; struct.pack_into('<I', b, 40, 2); struct.pack_into('<I', b, 44, int(sys.argv[3]))
open(sys.argv[1], 'wb').write(bytes(b) + sys.argv[2].encode())
PY
}
FAKEIMG=$T/some.img; mkimg "$FAKEIMG" "linux kernel"
cp "$FAKEIMG" "$LB/boot.img"; printf '%s  boot.img\n' "$(sha256sum "$FAKEIMG" | cut -d' ' -f1)" > "$LB/SHA256SUMS"
IOSIMG=$T/ios.img; mkimg "$IOSIMG" " LAURELESP "
SHIMIMG=$T/shim.img; mkimg "$SHIMIMG" " shim, kernel compressed, no label"
sidecar() { printf 'image %s\nmode %s\nmarker %s\nos 17.0.0 2026-10\n' "$(sha256sum "$1" | cut -d' ' -f1)" "${2:-ro}" "$M" > "$1.dualboot"; }
# with the flag, adb shows Android
expect "flash-root.sh: not a sparse image: refused" 3 "not a sparse" sh "$G/flash-root.sh" "$FAKEIMG"
expect "[R] root-flash-test.sh refused" 3 "dual-boot" sh "$G/root-flash-test.sh"
expect "[R] update-phone.sh refused" 3 "dual-boot" sh "$G/update-phone.sh"
expect "[R] root-update.sh refused" 3 "dual-boot" sh "$G/root-update.sh"
expect "[R] root-update.sh --rollback refused" 3 "dual-boot" sh "$G/root-update.sh" --rollback
expect "[R] flash-boot.sh: an image not built for this phone refused" 3 "not built for this phone" env WAIT_NEW=0 sh "$G/flash-boot.sh" "$FAKEIMG"
expect "[R] boot-test.sh: an image not built for this phone refused" 3 "not built for this phone" env IMG="$FAKEIMG" sh "$G/boot-test.sh"
expect "[R] fastboot-drain.py flash userdata refused" 3 "REFUSED" python3 -I "$G/fastboot-drain.py" flash userdata "$FAKEIMG"
expect "[R] ios16.sh refused on the Mi A3" 3 "OnePlus" sh "$R/scripts/flash/ios16.sh" userdata --yes
expect "[R] all.sh refused on the Mi A3" 3 "OnePlus" env CONFIRM=yes sh "$R/scripts/flash/all.sh"
expect "[R] restore.sh refused on the Mi A3" 3 "OnePlus" env CONFIRM=yes sh "$R/scripts/flash/restore.sh"
# the flag alone (phone off the cable or in fastboot), adb silent
expect "[R] guard userdata: flag, no adb" 3 "config/laurel-android-data" env FAKE_ADB=off sh "$G/android-guard.sh" userdata
expect "[R] running-ios: no answer" 3 "no answer" env FAKE_ADB=off sh "$G/android-guard.sh" running-ios
expect "[R] running-ios: fence off" 3 "kern.laurel_dualboot=1" env FAKE_ADB=off FAKE_SYSCTL=0 sh "$G/android-guard.sh" running-ios
# boot images
expect "[R] F2 boot-image: Lineage's image with ANDROID_IMAGE=1 goes" 0 "" env ANDROID_IMAGE=1 sh "$G/android-guard.sh" boot-image "$FAKEIMG"
expect "[R] F2 boot-image: iOS image with ANDROID_IMAGE=1 refused" 3 "iOS payload" env ANDROID_IMAGE=1 sh "$G/android-guard.sh" boot-image "$IOSIMG"
# F2: the label alone let a shim through
expect "F2 boot-image: a shim image with no label, ANDROID_IMAGE=1: refused by its hash" 3 "not Lineage's boot image" env ANDROID_IMAGE=1 sh "$G/android-guard.sh" boot-image "$SHIMIMG"
for tx in 'rd=ufsroot0' 'ufsrw=1' 'rootrw=1' 'Darwin Kernel Version 25.5.0' 'xnu-12377.121.6'; do
  mkimg "$T/tx.img" " $tx "
  # the hash listed too: the text alone must stop it
  printf '%s  boot.img\n' "$(sha256sum "$T/tx.img" | cut -d' ' -f1)" >> "$LB/SHA256SUMS"
  expect "F2 boot-image: '$tx' in the image with ANDROID_IMAGE=1, its hash in the backup list: refused" 3 "iOS payload" env ANDROID_IMAGE=1 sh "$G/android-guard.sh" boot-image "$T/tx.img"
done
mkimg "$T/a.img" "another linux"; printf '%s  boot_a.img\n' "$(sha256sum "$T/a.img" | cut -d' ' -f1)" > "$AB/SHA256SUMS"
expect "[R] F2 boot-image: boot_a of the android backup goes" 0 "" env ANDROID_IMAGE=1 sh "$G/android-guard.sh" boot-image "$T/a.img"
expect "F2 boot-image: no backup folder: refused" 3 "not Lineage's boot image" env ANDROID_IMAGE=1 HOME="$T/nohome" sh "$G/android-guard.sh" boot-image "$FAKEIMG"
mkdir -p "$R/out/laurel"; cp "$SHIMIMG" "$R/out/laurel/laurel-boot.img"
expect_calls "F2 flash-boot.sh: ANDROID_IMAGE=1 with no image named: no flash of the default shim" 1 "" "fastboot flash" env WAIT_NEW=0 ANDROID_IMAGE=1 timeout 8 sh "$G/flash-boot.sh"
expect_calls "F2 flash-boot.sh: ANDROID_IMAGE=1 + BOOTIMG= the default shim: no flash" 3 "" "fastboot flash" env WAIT_NEW=0 ANDROID_IMAGE=1 BOOTIMG="$R/out/laurel/laurel-boot.img" timeout 8 sh "$G/flash-boot.sh"
# the image of this phone
mkimg "$IOSIMG" " LAURELESP "; printf 'image 0000\n' > "$IOSIMG.dualboot"
expect "[R] boot-image: sidecar of another image refused" 3 "changed after" sh "$G/android-guard.sh" boot-image "$IOSIMG"
sidecar "$IOSIMG"
expect "H1 boot-image: a kernel without 2950: refused" 3 "patch 2950" sh "$G/android-guard.sh" boot-image "$IOSIMG"
mkimg "$IOSIMG.old" " LAURELESP LAUREL-2950-DUALBOOT-FENCE-V2-SEAL-AT-FREEZE "; sidecar "$IOSIMG.old"
expect "H1 boot-image: the marker of the file design (kernel looks for a table): refused" 3 "patch 2950" sh "$G/android-guard.sh" boot-image "$IOSIMG.old"
mkimg "$IOSIMG.good" " LAURELESP $M "; sidecar "$IOSIMG.good"
expect "[R] boot-image: fence kernel, read-only, Lineage's header: goes" 0 "" sh "$G/android-guard.sh" boot-image "$IOSIMG.good"
# S1
mkimg "$T/s1.img" " LAURELESP $M " 369099112; sidecar "$T/s1.img"
expect "S1 boot-image: the stock header 11.0.0, 2022-08: refused" 3 "OS version field" sh "$G/android-guard.sh" boot-image "$T/s1.img"
expect "S1 boot-image: no Lineage backup to compare: refused" 3 "no Lineage boot image" env HOME="$T/nohome" sh "$G/android-guard.sh" boot-image "$IOSIMG.good"
# read-only first
mkimg "$T/rw.img" " LAURELESP $M ufsrw=1 rootrw=1 "; sidecar "$T/rw.img" rw
expect "RO gate boot-image: a writable image, no result on record: refused" 3 "can write" sh "$G/android-guard.sh" boot-image "$T/rw.img"
mkimg "$T/rw2.img" " LAURELESP $M ufsrw=1 rootrw=1 "; sidecar "$T/rw2.img" ro
expect "RO gate boot-image: a writable image whose sidecar says ro: refused" 3 "can write" sh "$G/android-guard.sh" boot-image "$T/rw2.img"
mkimg "$T/rw3.img" " LAURELESP $M "; printf 'image %s\n' "$(sha256sum "$T/rw3.img" | cut -d' ' -f1)" > "$T/rw3.img.dualboot"
expect "RO gate boot-image: a sidecar with no mode counts as writable: refused" 3 "can write" sh "$G/android-guard.sh" boot-image "$T/rw3.img"
# F7: any token of ufsrw or rootrw counts, whatever its value, unless the value is the literal 0. The kernel's number parser takes 0x1 and 01. A kernel's own text has these names only between NUL bytes.
for tx in 'ufsrw=0x1' 'ufsrw=01' 'ufsrw=2' 'ufsrw=1k' 'ufsrw=00' 'rootrw=0x1' 'rootrw=01' 'ufsrw=' ' ufsrw ' ' rootrw '; do
  mkimg "$T/f7.img" " LAURELESP $M args = \"rd=ufsroot0 $tx\" "; sidecar "$T/f7.img" ro
  expect "F7 boot-image: '$tx' with a sidecar that says ro: refused" 3 "can write" sh "$G/android-guard.sh" boot-image "$T/f7.img"
done
mkimg "$T/f7ok.img" " LAURELESP $M args = \"rd=ufsroot0 ufsrw=0 rootrw=0\" "; sidecar "$T/f7ok.img" ro
expect "[R] F7 boot-image: ufsrw=0 rootrw=0: read-only: goes" 0 "" sh "$G/android-guard.sh" boot-image "$T/f7ok.img"
python3 -I - "$T/f7k.img" "$M" <<'PY'
import struct, sys
b = bytearray(4096); b[:8] = b'ANDROID!'; struct.pack_into('<I', b, 40, 2); struct.pack_into('<I', b, 44, 570425770)
open(sys.argv[1], 'wb').write(bytes(b) + b' LAURELESP ' + sys.argv[2].encode() + b' \0ufsroot\0ufsrw\0ufscache\0root_device\0rootrw\0%s() VFS_RO\n')
PY
sidecar "$T/f7k.img" ro
expect "[R] F7 boot-image: the names as a kernel holds them, between NUL bytes: read-only: goes" 0 "" sh "$G/android-guard.sh" boot-image "$T/f7k.img"
mkdir -p "$R/out/laurel/dualboot"; printf 'ro-on %s x\n' "$M" > "$R/out/laurel/dualboot/first-boot.result"
expect "RO gate boot-image: a result, Android not checked after it: refused" 3 "not opened its data" sh "$G/android-guard.sh" boot-image "$T/rw.img"
printf 'ro-on %s x\nandroid-opened-after-ro x\n' "$M" > "$R/out/laurel/dualboot/first-boot.result"
expect "[R] RO gate boot-image: result + Android: a writable image goes" 0 "" sh "$G/android-guard.sh" boot-image "$T/rw.img"
printf 'ro-on OTHER-MARKER x\nandroid-opened-after-ro x\n' > "$R/out/laurel/dualboot/first-boot.result"
expect "RO gate boot-image: the result of another fence kernel: refused" 3 "can write" sh "$G/android-guard.sh" boot-image "$T/rw.img"
rm -f "$R/out/laurel/dualboot/first-boot.result"
# the image build
K=$T/kernel; ST="0123456789 1 patches, series 0123456789abcdef, 4k"
mkdir -p "$T/w" "$T/mu" "$R/out/venv/bin" "$R/out/laurel/dualboot"
cat > "$R/out/venv/bin/python3" <<EOT
#!/bin/sh
case "\${1:-}" in
-c) exit 0 ;;
*mkdarwinboot.py) echo "mkdarwinboot \$*" >> "$T/calls"; printf 'payload' > "\$4" ;;
esac
exit 0
EOT
chmod +x "$R/out/venv/bin/python3"
cat > "$T/bin/mkbootimg" <<EOT
#!/bin/sh
echo "mkbootimg \$*" >> "$T/calls"
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && mkimg_out=\$2; shift; done
printf x > "\$mkimg_out"
EOT
cat > "$T/bin/unpack_bootimg" <<'EOT'
#!/bin/sh
mkdir -p "$4"; printf x > "$4/dtb"
EOT
printf '#!/bin/sh\nexit 0\n' > "$T/bin/uv"; chmod +x "$T/bin/mkbootimg" "$T/bin/unpack_bootimg" "$T/bin/uv"
printf 'x' > "$T/mu/fd"; printf 'x' > "$T/mu/shim"; printf 'x' > "$T/stock"
mk_kernel() {
  printf 'mach-o %s\nLAUREL BUILD: %s\n' "$1" "$ST" > "$K"
  printf 'stamp=%s\nseries=0123456789abcdef\nsha256=%s\n' "$ST" "$(sha256sum "$K" | cut -d' ' -f1)" > "$K.stamp"
}
printf 'pass\n' > "$R/scripts/laurel/mkadt.py"   # the real one needs external/ios-topaz; it takes no part in these checks
# a menu image needs an FD of this tree's Mu patches
mkdir -p "$T/repo/patches/laurel/mu"; echo fake > "$T/repo/patches/laurel/mu/0201.patch"
sha256sum "$T/repo/patches/laurel/mu/0201.patch" | cut -d' ' -f1 > "$T/mu/fd.patches"
UE="env UEFI_W=$T/w FD=$T/mu/fd SHIM=$T/mu/shim STOCK_BOOT=$T/stock KERNEL=$K"
mk_kernel "no marker here"
expect "H1 uefi-image.sh: a kernel without 2950: no image" 1 "no patch 2950" $UE bash "$G/uefi-image.sh"
mv "$T/mu/fd.patches" "$T/mu/fd.patches.good"
expect "Menu uefi-image.sh: an FD with no record of its Mu patches: no image" 1 "not built from patches/laurel/mu" $UE bash "$G/uefi-image.sh"
echo stale > "$T/mu/fd.patches"
expect "Menu uefi-image.sh: an FD of other Mu patches: no image" 1 "not built from patches/laurel/mu" $UE bash "$G/uefi-image.sh"
mv "$T/mu/fd.patches.good" "$T/mu/fd.patches"
mk_kernel "$M"
ue() { : > "$T/calls"; o=$("$@" 2>&1) || true; n=$((n + 1)); }
ok_() { echo "ok   $1"; }
bad_() { fails=$((fails + 1)); echo "FAIL $1: $o"; sed 's/^/     calls: /' "$T/calls" | cut -c1-260 | tail -4; }
if [ -z "${ONLY:-}" ] || case "S1 uefi-image.sh" in $ONLY) true ;; *) false ;; esac; then
  ue $UE LAUREL_READONLY=1 bash "$G/uefi-image.sh"
  if grep -q -- '--os_version 17.0.0 --os_patch_level 2026-10' "$T/calls"; then ok_ "S1 uefi-image.sh: the header carries Lineage's 17.0.0, 2026-10, read from the backup"; else bad_ "S1 uefi-image.sh: the header"; fi
  if grep '^mkdarwinboot' "$T/calls" | grep -q 'ufsrw=1\|rootrw=1'; then bad_ "RO uefi-image.sh: LAUREL_READONLY=1 left ufsrw or rootrw"; else ok_ "RO uefi-image.sh: LAUREL_READONLY=1: no ufsrw, no rootrw in the command line"; fi
  ue env UEFI_W=$T/w FD=$T/mu/fd SHIM=$T/mu/shim STOCK_BOOT=$T/stock KERNEL=$K LINEAGE_BOOT=$T/nothing bash "$G/uefi-image.sh"
  case "$o" in *"no Lineage boot image"*) ok_ "S1 uefi-image.sh: no Lineage image: no boot image" ;; *) bad_ "S1 uefi-image.sh: no Lineage image" ;; esac
fi
if [ -z "${ONLY:-}" ] || case "F7 uefi-image.sh" in $ONLY) true ;; *) false ;; esac; then
  for tx in ufsrw=0x1 ufsrw=01 rootrw=01 ufsrw; do
    rm -f "$T/w/laurel-uefi-boot.img.dualboot"
    ue $UE LAUREL_READONLY=1 EXTRA_ARGS="$tx" bash "$G/uefi-image.sh"
    case "$o" in *"the command line can write"*) ok_ "F7 uefi-image.sh: LAUREL_READONLY=1 with $tx: no image" ;; *) bad_ "F7 uefi-image.sh: LAUREL_READONLY=1 with $tx" ;; esac
    rm -f "$T/w/laurel-uefi-boot.img.dualboot"
    ue $UE EXTRA_ARGS="$tx" bash "$G/uefi-image.sh"
    if grep -q '^mode rw$' "$T/w/laurel-uefi-boot.img.dualboot" 2>/dev/null; then ok_ "F7 uefi-image.sh: $tx: the sidecar says rw"; else bad_ "F7 uefi-image.sh: $tx: the sidecar: $(cat "$T/w/laurel-uefi-boot.img.dualboot" 2>/dev/null)"; fi
  done
  rm -f "$T/w/laurel-uefi-boot.img.dualboot"
  ue $UE LAUREL_READONLY=1 EXTRA_ARGS="ufsrw=0 rootrw=0" bash "$G/uefi-image.sh"
  if grep -q '^mode ro$' "$T/w/laurel-uefi-boot.img.dualboot" 2>/dev/null; then ok_ "F7 uefi-image.sh: ufsrw=0 rootrw=0: the sidecar says ro"; else bad_ "F7 uefi-image.sh: ufsrw=0 rootrw=0"; fi
fi
# M2: the other phone must say who it is
expect "M2 other-device: no phone on adb or fastboot: refused" 3 "OnePlus" env FAKE_ADB=off FAKE_FB=none sh "$G/android-guard.sh" other-device
expect "M2 other-device: phone in fastboot with a wrong answer: refused" 3 "OnePlus" env FAKE_ADB=off FAKE_PRODUCT=unknown sh "$G/android-guard.sh" other-device
expect "M2 other-device: two phones in fastboot: refused" 3 "OnePlus" env FAKE_ADB=off FAKE_FB=two FAKE_PRODUCT=taro sh "$G/android-guard.sh" other-device
expect "[R] other-device: Mi A3 in fastboot: refused" 3 "OnePlus" env FAKE_ADB=off sh "$G/android-guard.sh" other-device
expect "[R] other-device: OnePlus on adb goes" 0 "" env FAKE_ADB=oneplus FAKE_FB=none sh "$G/android-guard.sh" other-device
expect "[R] other-device: OnePlus in fastboot goes" 0 "" env FAKE_ADB=off FAKE_PRODUCT=taro sh "$G/android-guard.sh" other-device
mkdir -p "$T/backup/images" "$T/backup/magisk" "$R/out/ios16"
# F3: test-boot.sh, with the boot_a it would not flash again: it goes straight to fastboot boot
mkdir -p "$R/out/t" "$R/out/s"; printf t > "$R/out/t/boot_a.img"; printf s > "$R/out/s/boot_a.img"; echo 'negroniusb_lost_reboot=30' > "$R/out/t/cmdline.txt"
sha256sum "$R/out/s/boot_a.img" | cut -c1-64 > "$R/out/.boot_a.sha256"
expect_calls "F3 test-boot.sh: the Mi A3 in fastboot: no fastboot boot" 3 "" "fastboot boot" env FAKE_ADB=off sh -c 'cd "$0" && sh scripts/flash/test-boot.sh out/t out/s' "$R"
expect_calls "F3 test-boot.sh: the phone changes before the boot: no fastboot boot" 3 "" "fastboot boot" env FAKE_ADB=off FAKE_PRODUCT=unknown sh -c 'cd "$0" && sh scripts/flash/test-boot.sh out/t out/s' "$R"
expect_calls "[R] F3 test-boot.sh: the OnePlus in fastboot: fastboot boot" 0 "fastboot boot" "" env FAKE_ADB=off FAKE_PRODUCT=taro sh -c 'cd "$0" && sh scripts/flash/test-boot.sh out/t out/s' "$R"
for f in boot vendor_boot dtbo vbmeta; do printf 'x' > "$T/backup/images/$f.img"; done
printf 'x' > "$R/out/ios16/boot_a.img"
RS="env BACKUP=$T/backup CONFIRM=yes"
expect_calls "M2 restore.sh: phone off at the start: refused, no flash, no wait" 3 "" "fastboot flash" $RS FAKE_ADB=off FAKE_FB=none sh "$R/scripts/flash/restore.sh"
expect_calls "M2 restore.sh: OnePlus on adb, Mi A3 at the fastboot stage: no flash, no -w" 3 "" "fastboot flash" $RS FAKE_ADB=oneplus FAKE_FB=after-reboot FAKE_PRODUCT=laurel_sprout sh "$R/scripts/flash/restore.sh"
expect_calls "M2 restore.sh: OnePlus on adb, a wrong answer at the fastboot stage: no flash" 3 "" "fastboot flash" $RS FAKE_ADB=oneplus FAKE_FB=after-reboot FAKE_PRODUCT=unknown sh "$R/scripts/flash/restore.sh"
expect_calls "M2 restore.sh: the phone changes after the flashes: no -w" 3 "fastboot flash" "fastboot -w" $RS FAKE_ADB=oneplus FAKE_PRODUCT=taro FAKE_PRODUCT_AFTER_FLASH=laurel_sprout sh "$R/scripts/flash/restore.sh"
expect_calls "[R] restore.sh: the OnePlus all the way: flashes and -w" 0 "fastboot -w" "" $RS FAKE_ADB=oneplus FAKE_PRODUCT=taro sh "$R/scripts/flash/restore.sh"
expect_calls "M2 ios16.sh: OnePlus on adb, Mi A3 at the write: no flash" 3 "" "fastboot flash" env BACKUP="$T/backup" FAKE_ADB=oneplus FAKE_PRODUCT=taro FAKE_PRODUCT_AFTER_USERSPACE=laurel_sprout sh "$R/scripts/flash/ios16.sh" boot --yes
# S2: stock macOS has no timeout
noto() { PATH=$T/bin:$T/tools-noto "$@"; }
bare() { PATH=$T/bin:$T/tools-bare "$@"; }
expect "S2 no timeout tool, perl there: the Mi A3 on the cable is still seen" 3 "OnePlus" noto sh "$G/android-guard.sh" other-device
expect "S2 no timeout tool, perl there: Android on adb is still seen" 3 "runs Android" noto sh "$G/android-guard.sh" userdata
expect "S2 no timeout tool and no perl: refused, not 'no phone'" 3 "no timeout" bare sh "$G/android-guard.sh" other-device
expect "S2 no timeout tool and no perl, userdata: refused" 3 "no timeout" bare sh "$G/android-guard.sh" userdata
expect "[R] no timeout tool, perl there: the OnePlus goes" 0 "" noto env FAKE_ADB=oneplus sh "$G/android-guard.sh" other-device
# M4: no variable can stand in for the kernel's answer
expect "M4 running-ios: PHONE_SSH cannot fake the fence" 3 "kern.laurel_dualboot=1" env FAKE_ADB=off PHONE_SSH="$T/ssh-on" sh "$G/android-guard.sh" running-ios
expect "[R] running-ios: the kernel says fence on: goes" 0 "" env FAKE_ADB=off FAKE_SYSCTL=1 sh "$G/android-guard.sh" running-ios
# the dual boot script itself: nothing that writes runs without its CONFIRM word
D=$G/dual-boot.sh
for s in gpt-write after-gpt install flash-slot-b switch to-android gpt-restore; do
  expect "[R] dual-boot.sh $s without CONFIRM refused" 4 "CONFIRM=$s" sh "$D" "$s"
done
echo "android-guard-test: $n checks, $fails failed"
[ "$fails" = 0 ]
