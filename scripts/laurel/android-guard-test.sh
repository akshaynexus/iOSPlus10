#!/bin/sh
# Host test of the Android guard: every script that can write userdata, with a fake adb, fastboot, lsusb and ssh that record every call. No phone is touched, also when one is on the cable.
#   scripts/laurel/android-guard-test.sh        (scripts/laurel/test-dualboot.sh runs it)
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ldb-guard.XXXXXX")
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/bin"
for t in fastboot lsusb sudo; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\ncase "$1" in devices) echo "FAKE fastboot" ;; getvar) echo "product: ${FAKE_PRODUCT:-laurel_sprout}" >&2 ;; esac\nexit 0\n' "$t" "$T" > "$T/bin/$t"
done
cat > "$T/bin/adb" <<EOT
#!/bin/sh
echo "adb \$*" >> "$T/calls"
[ "\${FAKE_ADB:-android}" = android ] || { [ "\$1" = get-state ] && exit 1; exit 1; }
case "\$*" in
get-state) echo device ;;
*ro.product.device*) echo laurel_sprout ;;
*ro.build.version.release*) echo 17 ;;
esac
exit 0
EOT
cat > "$T/ssh-on" <<'EOT'
#!/bin/sh
echo 1
EOT
cat > "$T/ssh-off" <<'EOT'
#!/bin/sh
echo 0
EOT
chmod +x "$T"/bin/* "$T/ssh-on" "$T/ssh-off"
PATH=$T/bin:$PATH; export PATH
fails=0; n=0
# expect NAME EXIT TEXT CMD...: exit code, text in the output, and no fastboot write / no ssh write in the record
expect() {
  name=$1; rc=$2; text=$3; shift 3
  : > "$T/calls"
  got=0; o=$("$@" 2>&1 < /dev/null) || got=$?
  n=$((n + 1))
  if [ "$got" != "$rc" ] || { [ -n "$text" ] && ! printf '%s' "$o" | grep -qF -- "$text"; }; then
    fails=$((fails + 1)); echo "FAIL $name: exit $got, wanted $rc, wanted text '$text'"; printf '%s\n' "$o" | tail -4 | sed 's/^/     | /'; return
  fi
  if grep -qE '^(fastboot (flash|erase|format|-w|-S|boot|set_active|reboot)|sudo )' "$T/calls"; then
    fails=$((fails + 1)); echo "FAIL $name: a write reached the phone tools:"; sed 's/^/     | /' "$T/calls"; return
  fi
  echo "ok   $name"
}
F=$REPO/config/laurel-android-data
[ -e "$F" ] || { echo "FAIL flag file missing: $F"; exit 1; }
G=$REPO/scripts/laurel
FAKEIMG=$T/some.img; printf 'ANDROID!' > "$FAKEIMG"
IOSIMG=$T/ios.img; printf 'ANDROID! LAURELESP ' > "$IOSIMG"
# with the flag, adb shows Android
expect "flash-root.sh refused, names the dual boot path" 3 "dual-boot" sh "$G/flash-root.sh"
expect "flash-root.sh IMAGE refused" 3 "REFUSED" sh "$G/flash-root.sh" "$FAKEIMG"
expect "root-flash-test.sh refused" 3 "dual-boot" sh "$G/root-flash-test.sh"
expect "update-phone.sh refused" 3 "dual-boot" sh "$G/update-phone.sh"
expect "root-update.sh refused" 3 "dual-boot" sh "$G/root-update.sh"
expect "root-update.sh --rollback refused" 3 "dual-boot" sh "$G/root-update.sh" --rollback
expect "flash-boot.sh: an image without a table refused" 3 "no extent table" env WAIT_NEW=0 sh "$G/flash-boot.sh" "$FAKEIMG"
expect "boot-test.sh: an image without a table refused" 3 "no extent table" env IMG="$FAKEIMG" sh "$G/boot-test.sh"
expect "fastboot-drain.py flash userdata refused" 3 "REFUSED" python3 -I "$G/fastboot-drain.py" flash userdata "$FAKEIMG"
expect "ios16.sh refused on the Mi A3" 3 "OnePlus" sh "$REPO/scripts/flash/ios16.sh" userdata --yes
expect "all.sh refused on the Mi A3" 3 "OnePlus" env CONFIRM=yes sh "$REPO/scripts/flash/all.sh"
expect "restore.sh refused on the Mi A3" 3 "OnePlus" env CONFIRM=yes sh "$REPO/scripts/flash/restore.sh"
# the flag alone (phone off the cable or in fastboot), adb silent
expect "guard userdata: flag, no adb" 3 "config/laurel-android-data" env FAKE_ADB=off sh "$G/android-guard.sh" userdata
expect "flash-root.sh: flag, no adb" 3 "config/laurel-android-data" env FAKE_ADB=off sh "$G/flash-root.sh" "$FAKEIMG"
expect "running-ios: no answer" 3 "no answer" env FAKE_ADB=off PHONE_SSH=/nonexistent sh "$G/android-guard.sh" running-ios
expect "running-ios: fence off" 3 "kern.laurel_dualboot=1" env FAKE_ADB=off PHONE_SSH="$T/ssh-off" sh "$G/android-guard.sh" running-ios
expect "running-ios: fence on goes" 0 "" env FAKE_ADB=off PHONE_SSH="$T/ssh-on" sh "$G/android-guard.sh" running-ios
# boot images
expect "boot-image: Android image with ANDROID_IMAGE=1 goes" 0 "" env ANDROID_IMAGE=1 sh "$G/android-guard.sh" boot-image "$FAKEIMG"
expect "boot-image: iOS image with ANDROID_IMAGE=1 refused" 3 "iOS payload" env ANDROID_IMAGE=1 sh "$G/android-guard.sh" boot-image "$IOSIMG"
printf 'image 0000\n' > "$IOSIMG.dualboot"
expect "boot-image: sidecar of another image refused" 3 "changed after" sh "$G/android-guard.sh" boot-image "$IOSIMG"
printf 'image %s\n' "$(sha256sum "$IOSIMG" | cut -d' ' -f1)" > "$IOSIMG.dualboot"
expect "boot-image: image with its table goes" 0 "" sh "$G/android-guard.sh" boot-image "$IOSIMG"
# another phone: the OnePlus scripts stay usable
expect "other-device: OnePlus on the cable goes" 0 "" env FAKE_ADB=off FAKE_PRODUCT=OP5900 sh "$G/android-guard.sh" other-device
# the dual boot script itself: nothing that writes runs without its CONFIRM word
D=$G/dual-boot.sh
for s in allocate check-map install flash-slot-b switch to-android remove; do
  expect "dual-boot.sh $s without CONFIRM refused" 4 "CONFIRM=$s" sh "$D" "$s"
done
echo "android-guard-test: $n checks, $fails failed"
[ "$fails" = 0 ]
