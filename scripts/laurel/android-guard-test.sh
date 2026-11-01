#!/bin/sh
# Host test of the Android guard: every script that can write userdata, with a fake adb, fastboot, lsusb and ssh that record every call. No phone is touched, also when one is on the cable.
#   scripts/laurel/android-guard-test.sh [TREE]     (scripts/laurel/test-dualboot.sh runs it; TREE: the scripts under test, default this repo)
# The real adb and fastboot cannot be reached: PATH is the fakes + a short list of tool links, without adb and fastboot; checked first. The scripts run from a copy in a temp folder.
# Test names with [R] are regressions: the old code passed them too. Each other new test failed on the old code (scripts/laurel/dualboot-tests-detect.sh).
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
  esac ;;
esac
exit 0
EOT
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
M=$(sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$REPO/tools/laurel-dualboot/laurel_dualboot.h")
FAKEIMG=$T/some.img; printf 'ANDROID!' > "$FAKEIMG"
IOSIMG=$T/ios.img; printf 'ANDROID! LAURELESP laurel-dualboot ' > "$IOSIMG"
sidecar() { printf 'image %s\n' "$(sha256sum "$1" | cut -d' ' -f1)" > "$1.dualboot"; }
# with the flag, adb shows Android
expect "[R] flash-root.sh refused, names the dual boot path" 3 "dual-boot" sh "$G/flash-root.sh"
expect "[R] flash-root.sh IMAGE refused" 3 "REFUSED" sh "$G/flash-root.sh" "$FAKEIMG"
expect "[R] root-flash-test.sh refused" 3 "dual-boot" sh "$G/root-flash-test.sh"
expect "[R] update-phone.sh refused" 3 "dual-boot" sh "$G/update-phone.sh"
expect "[R] root-update.sh refused" 3 "dual-boot" sh "$G/root-update.sh"
expect "[R] root-update.sh --rollback refused" 3 "dual-boot" sh "$G/root-update.sh" --rollback
expect "[R] flash-boot.sh: an image without a table refused" 3 "no extent table" env WAIT_NEW=0 sh "$G/flash-boot.sh" "$FAKEIMG"
expect "[R] boot-test.sh: an image without a table refused" 3 "no extent table" env IMG="$FAKEIMG" sh "$G/boot-test.sh"
expect "[R] fastboot-drain.py flash userdata refused" 3 "REFUSED" python3 -I "$G/fastboot-drain.py" flash userdata "$FAKEIMG"
expect "[R] ios16.sh refused on the Mi A3" 3 "OnePlus" sh "$R/scripts/flash/ios16.sh" userdata --yes
expect "[R] all.sh refused on the Mi A3" 3 "OnePlus" env CONFIRM=yes sh "$R/scripts/flash/all.sh"
expect "[R] restore.sh refused on the Mi A3" 3 "OnePlus" env CONFIRM=yes sh "$R/scripts/flash/restore.sh"
# the flag alone (phone off the cable or in fastboot), adb silent
expect "[R] guard userdata: flag, no adb" 3 "config/laurel-android-data" env FAKE_ADB=off sh "$G/android-guard.sh" userdata
expect "[R] flash-root.sh: flag, no adb" 3 "config/laurel-android-data" env FAKE_ADB=off sh "$G/flash-root.sh" "$FAKEIMG"
expect "[R] running-ios: no answer" 3 "no answer" env FAKE_ADB=off sh "$G/android-guard.sh" running-ios
expect "[R] running-ios: fence off" 3 "kern.laurel_dualboot=1" env FAKE_ADB=off FAKE_SYSCTL=0 sh "$G/android-guard.sh" running-ios
# boot images
expect "[R] boot-image: Android image with ANDROID_IMAGE=1 goes" 0 "" env ANDROID_IMAGE=1 sh "$G/android-guard.sh" boot-image "$FAKEIMG"
expect "[R] boot-image: iOS image with ANDROID_IMAGE=1 refused" 3 "iOS payload" env ANDROID_IMAGE=1 sh "$G/android-guard.sh" boot-image "$IOSIMG"
printf 'image 0000\n' > "$IOSIMG.dualboot"
expect "[R] boot-image: sidecar of another image refused" 3 "changed after" sh "$G/android-guard.sh" boot-image "$IOSIMG"
# H1: a table proves nothing about the kernel
sidecar "$IOSIMG"
expect "H1 boot-image: table but a kernel without 2950: refused" 3 "patch 2950" sh "$G/android-guard.sh" boot-image "$IOSIMG"
printf 'ANDROID! LAURELESP laurel-dualboot LAUREL-2950-OLD ' > "$IOSIMG.old"; sidecar "$IOSIMG.old"
expect "H1 boot-image: another marker text (older 2950): refused" 3 "patch 2950" sh "$G/android-guard.sh" boot-image "$IOSIMG.old"
printf 'ANDROID! LAURELESP %s ' "$M" > "$IOSIMG.noadt"; sidecar "$IOSIMG.noadt"
expect "H1 boot-image: fence kernel, no table in the ADT: refused" 3 "laurel-dualboot" sh "$G/android-guard.sh" boot-image "$IOSIMG.noadt"
printf 'ANDROID! LAURELESP laurel-dualboot %s ' "$M" > "$IOSIMG.good"; sidecar "$IOSIMG.good"
expect "[R] boot-image: fence kernel with its table goes" 0 "" sh "$G/android-guard.sh" boot-image "$IOSIMG.good"
# H1: the image build. KERNEL= by hand has only its own stamp: ios26-image.sh takes this path.
K=$T/kernel; ST="0123456789 1 patches, series 0123456789abcdef, 4k"
mkdir -p "$T/w" "$T/mu" "$R/out/venv/bin" "$R/out/laurel/dualboot"
printf '#!/bin/sh\nexit 0\n' > "$R/out/venv/bin/python3"; chmod +x "$R/out/venv/bin/python3"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/mkbootimg"; cp "$T/bin/mkbootimg" "$T/bin/unpack_bootimg"; cp "$T/bin/mkbootimg" "$T/bin/uv"; chmod +x "$T/bin/mkbootimg" "$T/bin/unpack_bootimg" "$T/bin/uv"
printf 'x' > "$T/mu/fd"; printf 'x' > "$T/mu/shim"; printf 'x' > "$T/stock"; printf 'x' > "$T/table"
printf '#!/bin/sh\nexit 0\n' > "$T/op10fake"; chmod +x "$T/op10fake"
mk_kernel() {
  printf 'mach-o %s\nLAUREL BUILD: %s\n' "$1" "$ST" > "$K"
  printf 'stamp=%s\nseries=0123456789abcdef\nsha256=%s\n' "$ST" "$(sha256sum "$K" | cut -d' ' -f1)" > "$K.stamp"
}
UE="env UEFI_W=$T/w FD=$T/mu/fd SHIM=$T/mu/shim STOCK_BOOT=$T/stock KERNEL=$K DUALBOOT_TABLE=$T/table OP10TOOL=$T/op10fake"
mk_kernel "no marker here"
expect "H1 uefi-image.sh: a table and a kernel without 2950: no image" 1 "no patch 2950" $UE bash "$G/uefi-image.sh"
mk_kernel "$M"
: > "$T/calls"; o=$($UE bash "$G/uefi-image.sh" 2>&1) || true; n=$((n + 1))
case "$o" in *"no patch 2950"*) fails=$((fails + 1)); echo "FAIL uefi-image.sh: a kernel with the marker refused: $o" ;; *) echo "ok   [R] uefi-image.sh: a kernel with the marker passes this check" ;; esac
# M2: the other phone must say who it is
expect "M2 other-device: no phone on adb or fastboot: refused" 3 "OnePlus" env FAKE_ADB=off FAKE_FB=none sh "$G/android-guard.sh" other-device
expect "M2 other-device: phone in fastboot with a wrong answer: refused" 3 "OnePlus" env FAKE_ADB=off FAKE_PRODUCT=unknown sh "$G/android-guard.sh" other-device
expect "M2 other-device: two phones in fastboot: refused" 3 "OnePlus" env FAKE_ADB=off FAKE_FB=two FAKE_PRODUCT=taro sh "$G/android-guard.sh" other-device
expect "[R] other-device: Mi A3 in fastboot: refused" 3 "OnePlus" env FAKE_ADB=off sh "$G/android-guard.sh" other-device
expect "[R] other-device: OnePlus on adb goes" 0 "" env FAKE_ADB=oneplus FAKE_FB=none sh "$G/android-guard.sh" other-device
expect "[R] other-device: OnePlus in fastboot goes" 0 "" env FAKE_ADB=off FAKE_PRODUCT=taro sh "$G/android-guard.sh" other-device
mkdir -p "$T/backup/images" "$T/backup/magisk" "$R/out/ios16"
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
for s in allocate check-map install flash-slot-b switch to-android remove; do
  expect "[R] dual-boot.sh $s without CONFIRM refused" 4 "CONFIRM=$s" sh "$D" "$s"
done
echo "android-guard-test: $n checks, $fails failed"
[ "$fails" = 0 ]
