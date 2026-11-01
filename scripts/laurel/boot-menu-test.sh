#!/bin/bash
# Host test of the boot menu, no phone: slot core on the phone's GPT dump; the Android helper script on a fake phone; the app's adb client against a fake adbd with real crypto;
# TOML with the UniXNU rule; image marker. Fake bootctl, getprop, svc: PATH holds them first; real adb and fastboot are never called.
#   scripts/bg.sh menu-test scripts/laurel/boot-menu-test.sh          LAUREL_BACKUP=dir (default ~/laurel-backup/android-20261102-0137)
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
LAUREL_BACKUP=${LAUREL_BACKUP:-$HOME/laurel-backup/android-20261102-0137}
W=$OUT/laurel/menu-test; rm -rf "$W"; mkdir -p "$W"
S=$REPO/tools/laurel-switcher/assets/to-ios.sh

echo "== 1. slot core on the GPT dump (ASan, UBSan)"
cc -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -DLAUREL_SLOT_HOST -D_DEFAULT_SOURCE -o "$W/test_slot" "$REPO/tools/laurel-slot/laurel_slot.c" "$REPO/tools/laurel-slot/test/test_slot.c"
"$W/test_slot" "$LAUREL_BACKUP"

echo "== 2. helper script on a fake phone"
BIN=$W/bin; BLK=$W/blk; mkdir -p "$BIN" "$BLK"
cat > "$BIN/bootctl" <<'F'
#!/bin/sh
echo "bootctl $*" >> "$FAKE_LOG"
case "$1" in
  get-current-slot) echo "${FAKE_CURRENT:-0}" ;;
  get-active-boot-slot) cat "$FAKE_STATE/active" ;;
  is-slot-marked-successful) if [ "$2" = 0 ]; then [ "${FAKE_A_OK:-1}" = 1 ]; else [ "$(cat "$FAKE_STATE/b_ok")" = 1 ]; fi ;;
  set-active-boot-slot) [ "${FAKE_HAL_FAIL:-0}" = 0 ] || exit 1; [ "${FAKE_NO_FLIP:-0}" = 1 ] || echo "$2" > "$FAKE_STATE/active"; [ "${FAKE_B_STAYS_OK:-0}" = 1 ] || echo 0 > "$FAKE_STATE/b_ok" ;;
  mark-boot-successful) ;;
esac
F
cat > "$BIN/getprop" <<'F'
#!/bin/sh
case "$1" in ro.product.device) echo "${FAKE_DEVICE:-laurel_sprout}" ;; ro.boot.slot_suffix) echo "${FAKE_SUFFIX:-_a}" ;; esac
F
printf '#!/bin/sh\necho "svc $*" >> "$FAKE_LOG"\n' > "$BIN/svc"
printf '#!/bin/sh\necho "setprop $*" >> "$FAKE_LOG"\n' > "$BIN/setprop"
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo "${FAKE_UID:-0}"; else exec /usr/bin/id "$@"; fi\n' > "$BIN/id"
chmod +x "$BIN"/*
python3 -I - "$BLK" <<'P'
import hashlib,os,struct,sys
b=sys.argv[1]
pay=os.urandom(4096*20)
dtbo=os.urandom(5000)
hdr=bytearray(4096); hdr[:8]=b'ANDROID!'
cmd=f"console=null laurel_ios_image=20:{hashlib.sha256(pay).hexdigest()} laurel_ios_dtbo=5000:{hashlib.sha256(dtbo).hexdigest()}".encode()
hdr[64:64+len(cmd)]=cmd
open(b+'/boot_b','wb').write(bytes(hdr)+pay+b'\0'*4096)
open(b+'/dtbo_b','wb').write(dtbo+b'\0'*1000)
open(b+'/iosroot','wb').write(b'H+')
E=bytearray(4096); E[:8]=b'ANDROID!'; c=b'console=ttyMSM0 androidboot.hardware=qcom'; E[64:64+len(c)]=c
open(b+'/lineage_boot','wb').write(bytes(E)+pay)
P
n=0; fail=0
export FAKE_LOG=$W/log FAKE_STATE=$W/state LS_BLOCK=$BLK PATH="$BIN:$PATH"
mkdir -p "$FAKE_STATE"
reset() { echo 0 > "$FAKE_STATE/active"; echo 1 > "$FAKE_STATE/b_ok"; : > "$FAKE_LOG"; }
# name want-rc want-text-part [env...] -- cmd
t() {
  name=$1; rc=$2; want=$3; shift 3
  reset
  got=0; out=$(env "$@" sh "$S" "${CMD:-switch}" 2>&1) || got=$?
  n=$((n+1))
  if [ "$got" != "$rc" ] || ! printf '%s' "$out" | grep -qF "$want"; then fail=$((fail+1)); echo "FAIL $name: rc $got, out: $out"; fi
  # no HAL write or reboot on any refusal of the checks
  case "$want" in
    refused*HAL*|refused*"after the HAL"*|*"stayed marked"*) ;;
    refused*) if grep -qE 'set-active|svc |setprop' "$FAKE_LOG"; then fail=$((fail+1)); echo "FAIL $name: wrote on refusal: $(cat "$FAKE_LOG")"; fi ;;
  esac
}
t "all good" 0 "ok: slot b active"
grep -q 'bootctl set-active-boot-slot 1' "$FAKE_LOG" && grep -q 'svc power reboot' "$FAKE_LOG" || { fail=$((fail+1)); echo "FAIL all good: $(cat "$FAKE_LOG")"; }
[ "$(cat "$FAKE_STATE/active")" = 1 ] || { fail=$((fail+1)); echo "FAIL active"; }
CMD=check t "check writes nothing" 0 "ok: ready"
grep -qE 'set-active|svc ' "$FAKE_LOG" && { fail=$((fail+1)); echo "FAIL check wrote"; }
t "not root" 1 "refused: not root" FAKE_UID=2000
t "other phone" 1 "refused: this phone" FAKE_DEVICE=taro
t "Android on slot b" 1 "refused: Android does not run on slot a" FAKE_SUFFIX=_b
t "HAL current 1" 1 "refused: HAL says" FAKE_CURRENT=1
t "slot a not successful" 1 "refused: slot a is not marked" FAKE_A_OK=0
reset; echo 1 > "$FAKE_STATE/active"; got=0; out=$(sh "$S" switch 2>&1) || got=$?; n=$((n+1)); { [ "$got" = 1 ] && printf '%s' "$out" | grep -qF "an update waits"; } || { fail=$((fail+1)); echo "FAIL active slot b: $out"; }
mv "$BLK/iosroot" "$BLK/x"; t "no iosroot" 1 "refused: no partition iosroot"; mv "$BLK/x" "$BLK/iosroot"
cp "$BLK/boot_b" "$BLK/keep"
cp "$BLK/lineage_boot" "$BLK/boot_b"; t "Lineage boot image on boot_b" 1 "refused: boot_b does not hold our image"
head -c 4096 /dev/zero > "$BLK/boot_b"; t "empty boot_b" 1 "refused: boot_b holds no boot image"
cp "$BLK/keep" "$BLK/boot_b"; printf 'x' | dd of="$BLK/boot_b" bs=1 seek=8000 conv=notrunc 2>/dev/null; t "one byte changed in boot_b" 1 "refused: boot_b is damaged"
cp "$BLK/keep" "$BLK/boot_b"; head -c 50000 "$BLK/keep" > "$BLK/boot_b"; t "boot_b cut short" 1 "refused: boot_b is damaged"
cp "$BLK/keep" "$BLK/boot_b"
cp "$BLK/dtbo_b" "$BLK/keep2"; printf 'x' | dd of="$BLK/dtbo_b" bs=1 seek=10 conv=notrunc 2>/dev/null; t "other dtbo" 1 "refused: dtbo_b is not the stock"; cp "$BLK/keep2" "$BLK/dtbo_b"
t "HAL refuses" 1 "refused: the HAL refused" FAKE_HAL_FAIL=1
grep -q 'svc' "$FAKE_LOG" && { fail=$((fail+1)); echo "FAIL HAL refused but rebooted"; }
t "HAL no flip" 1 "refused: slot b is not active after the HAL" FAKE_NO_FLIP=1
grep -q 'set-active-boot-slot 0' "$FAKE_LOG" && grep -q 'mark-boot-successful' "$FAKE_LOG" || { fail=$((fail+1)); echo "FAIL no way back: $(cat "$FAKE_LOG")"; }
t "slot b stays successful" 1 "stayed marked successful" FAKE_B_STAYS_OK=1
grep -q 'svc' "$FAKE_LOG" && { fail=$((fail+1)); echo "FAIL rebooted with b successful"; }
echo "helper script: $n cases, $fail failures"
[ "$fail" = 0 ]

echo "== 3. the app's adb client, real script, fake adbd"
CL=$W/classes; mkdir -p "$CL"
javac -nowarn --release 17 -d "$CL" "$REPO"/tools/laurel-switcher/src/org/iosplus10/laurelswitcher/AdbClient.java "$REPO"/tools/laurel-switcher/src/org/iosplus10/laurelswitcher/Switcher.java "$REPO"/tools/laurel-switcher/test/*.java
reset
java -cp "$CL" TestSwitcher "$S" "$BIN" "$BLK" "$FAKE_LOG"

echo "== 4. menu config"
python3 -I - "$REPO/scripts/laurel/mkdarwinboot.py" <<'P'
import sys,re,tomllib
src=open(sys.argv[1]).read()
ns={}
exec(src[src.index("TOML = '''"):src.index("def main")],ns)
t=tomllib.loads(ns['TOML'].format(timeout=5,title='iOS 26 (laurel XNU)',cmdline='a=1')+ns['ANDROID_ENTRY'])
assert t['boot']['default']=='ios16' and t['boot']['timeout']==5
e={x['id']:x for x in t['entry']}
assert e['ios16']['type']=='xnu' and e['ios16']['title']=='iOS 26 (laurel XNU)'
assert e['android']['type']=='action' and e['android']['action']=='laurel-android' and e['android']['confirm']
print('toml ok: entries',list(e))
P
echo "== 5. the real boot images, if built: size, the app's check on their bytes, the menu in the payload"
for I in "$OUT/laurel/uefi/laurel-uefi-boot.img" "$OUT/laurel-ios26/uefi/laurel-uefi-boot.img"; do
  [ -f "$I" ] || { echo "no $I: skipped"; continue; }
  sz=$(wc -c < "$I"); [ "$sz" -le $((64 * 1024 * 1024)) ] || { echo "FAIL $I: $sz bytes > 64 MiB of boot_b"; exit 1; }
  rm -f "$BLK/boot_b"; ln -s "$I" "$BLK/boot_b"
  cp "${STOCK_DTBO:-$HOME/laurel-backup/stock/images/dtbo.img}" "$BLK/dtbo_b"
  reset
  out=$(sh "$S" check 2>&1) || { echo "FAIL $I: $out"; exit 1; }
  echo "$(basename "$(dirname "$(dirname "$I")")"): $sz bytes (limit 67108864), helper says: $out"
  "$OUT/venv/bin/python3" -W ignore - "$(dirname "$I")/payload.img" <<'P'
import sys,tomllib
from pyfatfs.PyFatFS import PyFatFS
fs=PyFatFS(sys.argv[1],read_only=True)
t=tomllib.loads(fs.open('/EFI/UniXNU/unixnu.toml','r').read())
print('  payload toml: timeout',t['boot']['timeout'],'entries',[e['title'] for e in t['entry']],'laurelpanic' , 'laurelpanic=30' in t['entry'][0]['args'])
assert t['boot']['timeout']==5 and t['entry'][1]['action']=='laurel-android' and 'laurelpanic=30' in t['entry'][0]['args']
P
done
echo "PASS boot-menu-test"
