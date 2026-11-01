#!/bin/bash
# Host test of the boot menu, no phone: slot core on the phone's GPT dump; the Android helper script on a fake phone; the app's adb client against a fake adbd with real crypto;
# TOML with the UniXNU rule; real images in both modes: S1 header, marks, what the helper says. Fake bootctl, getprop, svc, blockdev: PATH holds them first; real adb and fastboot are never called.
#   scripts/bg.sh menu-test scripts/laurel/boot-menu-test.sh          GPT_DUMP=dir (default ~/laurel-backup/android-20261102-0137)
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/lib/laurel-layout.sh"
GPT_DUMP=${GPT_DUMP:-$HOME/laurel-backup/android-20261102-0137}
W=$OUT/laurel/menu-test; rm -rf "$W"; mkdir -p "$W"
S=$W/to-ios.sh
"$REPO/scripts/laurel/switcher-asset.sh" "$S"
FENCE=$(sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$REPO/tools/laurel-dualboot/laurel_dualboot.h")
PATH0=$PATH

echo "== 1. slot core on the GPT dump (ASan, UBSan)"
cc -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -DLAUREL_SLOT_HOST -D_DEFAULT_SOURCE -o "$W/test_slot" "$REPO/tools/laurel-slot/laurel_slot.c" "$REPO/tools/laurel-slot/test/test_slot.c"
"$W/test_slot" "$GPT_DUMP"

echo "== 2. helper script on a fake phone (layout of laurel-layout.sh, fence $FENCE)"
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
cat > "$BIN/blockdev" <<'F'
#!/bin/sh
case "$2" in */iosroot) echo "${FAKE_IOSROOT_BYTES:?}" ;; */userdata) echo "${FAKE_USERDATA_BYTES:?}" ;; esac
F
printf '#!/bin/sh\necho "svc $*" >> "$FAKE_LOG"\n' > "$BIN/svc"
printf '#!/bin/sh\necho "setprop $*" >> "$FAKE_LOG"\n' > "$BIN/setprop"
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo "${FAKE_UID:-0}"; else exec /usr/bin/id "$@"; fi\n' > "$BIN/id"
chmod +x "$BIN"/*
head -c 2097152 /dev/urandom > "$BLK/sda16"; : > "$BLK/sda15"; ln -s sda16 "$BLK/iosroot"; ln -s sda15 "$BLK/userdata"; : > "$BLK/sda9"
head -c 5000 /dev/urandom > "$BLK/dtbo_b"
ROOT_SHA=$(head -c 1048576 "$BLK/sda16" | sha256sum | cut -d' ' -f1)
# OUT, mode (rw, ro, -: no word), root mark (1/0), fence text in the payload (1/0)
mk_b() {
  python3 -I - "$BLK/dtbo_b" "$ROOT_SHA" "$FENCE" "$@" <<'P'
import hashlib,os,struct,sys
dtbo_f,root,fence,out,mode,rootmark,withfence=sys.argv[1:8]
dtbo=open(dtbo_f,'rb').read()
pay=os.urandom(4096*20)
if withfence=='1': pay=pay[:5000]+fence.encode()+pay[5000+len(fence):]
hdr=bytearray(4096); hdr[:8]=b'ANDROID!'; struct.pack_into('<I',hdr,44,0x220001aa)
words=['console=null']
if mode!='-': words.append('laurel_ios_mode='+mode)
words.append(f'laurel_ios_image=20:{hashlib.sha256(pay).hexdigest()}')
words.append(f'laurel_ios_dtbo={len(dtbo)}:{hashlib.sha256(dtbo).hexdigest()}')
if rootmark=='1': words.append(f'laurel_ios_root=1048576:{root}')
c=' '.join(words).encode(); assert len(c)<=512
hdr[64:64+len(c)]=c
open(out,'wb').write(bytes(hdr)+pay+b'\0'*4096)
P
}
python3 -I - "$BLK/boot_a" 0x220001aa <<'P'
import struct,sys
h=bytearray(4096); h[:8]=b'ANDROID!'; struct.pack_into('<I',h,44,int(sys.argv[2],16)); open(sys.argv[1],'wb').write(h)
P
python3 -I - "$BLK/lineage_boot" <<'P'
import sys
E=bytearray(8192); E[:8]=b'ANDROID!'; c=b'console=ttyMSM0 androidboot.hardware=qcom'; E[64:64+len(c)]=c
open(sys.argv[1],'wb').write(E)
P
mk_b "$BLK/boot_b" rw 1 1
n=0; fail=0
export FAKE_LOG=$W/log FAKE_STATE=$W/state LS_BLOCK=$BLK PATH="$BIN:$PATH" FAKE_IOSROOT_BYTES=$IOSROOT_BYTES FAKE_USERDATA_BYTES=$USERDATA_BYTES
mkdir -p "$FAKE_STATE"
reset() { echo 0 > "$FAKE_STATE/active"; echo 1 > "$FAKE_STATE/b_ok"; : > "$FAKE_LOG"; }
# name want-rc want-text-part [env...] -- cmd
t() {
  name=$1; rc=$2; want=$3; shift 3
  reset
  got=0; out=$(env "$@" sh "${SCRIPT:-$S}" "${CMD:-switch}" 2>&1) || got=$?
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
SCRIPT=$REPO/tools/laurel-switcher/assets/to-ios.sh t "script without the build's numbers" 1 "refused: this app was built without"
# the layout
mv "$BLK/iosroot" "$BLK/x"; t "no iosroot" 1 "refused: no partition iosroot"; mv "$BLK/x" "$BLK/iosroot"
rm "$BLK/iosroot"; ln -s sda9 "$BLK/iosroot"; t "iosroot on another partition" 1 "expected sda16, sda15"; rm "$BLK/iosroot"; ln -s sda16 "$BLK/iosroot"
t "iosroot size" 1 "refused: iosroot does not have the size" FAKE_IOSROOT_BYTES=$((IOSROOT_BYTES + 4096))
t "userdata of the old table" 1 "refused: userdata does not have the size" FAKE_USERDATA_BYTES=115869691904
# the flow: only the writable image of dual-boot.sh image rw
mk_b "$BLK/boot_b" ro 1 1; t "read-only image with marks" 1 "refused: boot_b is not the writable image"
mk_b "$BLK/boot_b" - 1 1; t "no mode word" 1 "refused: boot_b is not the writable image"
mk_b "$BLK/boot_b" rw 0 1; t "writable image not from dual-boot.sh image rw" 1 "refused: boot_b has no root mark"
mk_b "$BLK/boot_b" rw 1 0; t "older fence" 1 "refused: boot_b holds no kernel with this fence"
mk_b "$BLK/boot_b" rw 1 1; cp "$BLK/sda16" "$BLK/keep16"; printf 'x' | dd of="$BLK/sda16" bs=1 seek=500000 conv=notrunc 2>/dev/null; t "other root in iosroot" 1 "refused: iosroot does not start with"; cp "$BLK/keep16" "$BLK/sda16"
# S1
cp "$BLK/boot_a" "$BLK/keepa"; printf '\001' | dd of="$BLK/boot_a" bs=1 seek=44 conv=notrunc 2>/dev/null; t "Lineage update: other OS field" 1 "refused: boot_a and boot_b differ"; cp "$BLK/keepa" "$BLK/boot_a"
# the image
cp "$BLK/boot_b" "$BLK/keep"
cp "$BLK/lineage_boot" "$BLK/boot_b"; t "Lineage boot image on boot_b" 1 "refused: boot_b does not hold our image"
head -c 4096 /dev/zero > "$BLK/boot_b"; t "empty boot_b" 1 "refused: boot_b holds no boot image"
cp "$BLK/keep" "$BLK/boot_b"; printf 'x' | dd of="$BLK/boot_b" bs=1 seek=8000 conv=notrunc 2>/dev/null; t "one byte changed in boot_b" 1 "refused: boot_b is damaged"
cp "$BLK/keep" "$BLK/boot_b"; head -c 50000 "$BLK/keep" > "$BLK/boot_b"; t "boot_b cut short" 1 "refused: boot_b is damaged"
cp "$BLK/keep" "$BLK/boot_b"
cp "$BLK/dtbo_b" "$BLK/keep2"; printf 'x' | dd of="$BLK/dtbo_b" bs=1 seek=10 conv=notrunc 2>/dev/null; t "other dtbo" 1 "refused: dtbo_b is not the stock"; cp "$BLK/keep2" "$BLK/dtbo_b"
# the HAL
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
echo "== 5. mkbootimg: what the header page holds does not change what follows it (the hash of laurel_ios_image)"
P5=$W/p5; mkdir -p "$P5"; head -c 9000 /dev/urandom > "$P5/k"; head -c 8192 /dev/urandom > "$P5/r"; head -c 5000 /dev/urandom > "$P5/d"
for v in "11.0.0 2022-08 console=null" "17.0.0 2026-10 console=null laurel_ios_mode=rw"; do
  set -- $v; o=$1; l=$2; shift 2
  PATH=$PATH0 mkbootimg --header_version 2 --kernel "$P5/k" --ramdisk "$P5/r" --dtb "$P5/d" --pagesize 4096 --os_version "$o" --os_patch_level "$l" --cmdline "$*" -o "$P5/i-$o"
done
cmp <(head -c 4096 "$P5/i-11.0.0" | od -An -tx1 -j44 -N4) <(head -c 4096 "$P5/i-17.0.0" | od -An -tx1 -j44 -N4) >/dev/null && { echo "FAIL the OS field did not change"; exit 1; }
cmp <(tail -c +4097 "$P5/i-11.0.0") <(tail -c +4097 "$P5/i-17.0.0") || { echo "FAIL bytes after the header page differ"; exit 1; }
echo "OS field differs, $(($(wc -c < "$P5/i-17.0.0") - 4096)) bytes after the header page are the same"

echo "== 6. real boot images in both modes, S1 header, marks, helper"
LB=$(laurel_backup_dir 'lineage-*')/boot.img
LB_RAW=$(boot_os_raw "$LB")
echo "Lineage $LB: OS field $LB_RAW = $(boot_os_version "$LB_RAW") $(boot_os_patch "$LB_RAW")"
rm -f "$BLK/boot_a"; ln -s "$LB" "$BLK/boot_a"
cp "${STOCK_DTBO:-$HOME/laurel-backup/stock/images/dtbo.img}" "$BLK/dtbo_b"
head_of() { python3 -I "$REPO/scripts/laurel/boot-menu-header.py" "$1"; }
check_img() { # NAME IMG WANT_HELPER_TEXT WANT_RC
  sz=$(wc -c < "$2"); [ "$sz" -le $((64 * 1024 * 1024)) ] || { echo "FAIL $2: $sz bytes > 64 MiB of boot_b"; exit 1; }
  [ "$(boot_os_raw "$2")" = "$LB_RAW" ] || { echo "FAIL $1: OS field $(boot_os_raw "$2"), Lineage $LB_RAW"; exit 1; }
  rm -f "$BLK/boot_b"; ln -s "$2" "$BLK/boot_b"
  reset
  rc=0; out=$(sh "$S" check 2>&1) || rc=$?
  [ "$rc" = "$4" ] && printf '%s' "$out" | grep -qF "$3" || { echo "FAIL $1: rc $rc: $out"; exit 1; }
  echo "$1: $sz bytes (limit 67108864), $(head_of "$2"), helper: $out"
}
built=0
for tgt in ios16 ios26; do
  case "$tgt" in ios16) sc=uefi-image.sh; k=$OUT/laurel-kernel/out/kernel.development.sweet.4k ;; ios26) sc=ios26-image.sh; k=$OUT/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k ;; esac
  [ -f "$k" ] || { echo "no $k: $tgt skipped"; continue; }
  built=$((built+1))
  I=$W/img-$tgt
  PATH=$PATH0 UEFI_W=$I-ro LAUREL_READONLY=1 "$REPO/scripts/laurel/$sc" > "$I-ro.log" 2>&1 || { tail -5 "$I-ro.log"; exit 1; }
  PATH=$PATH0 UEFI_W=$I-rw LAUREL_READONLY=0 IOSROOT_HEAD_SHA=$ROOT_SHA "$REPO/scripts/laurel/$sc" > "$I-rw.log" 2>&1 || { tail -5 "$I-rw.log"; exit 1; }
  check_img "$tgt ro" "$I-ro/laurel-uefi-boot.img" "refused: boot_b does not hold our image" 1
  check_img "$tgt rw" "$I-rw/laurel-uefi-boot.img" "LAUREL SWITCH: ok: ready" 0
  grep -q '^mode ro$' "$I-ro/laurel-uefi-boot.img.dualboot" && grep -q '^mode rw$' "$I-rw/laurel-uefi-boot.img.dualboot" || { echo "FAIL sidecars"; exit 1; }
  for m in ro rw; do grep -qF "marker $FENCE" "$I-$m/laurel-uefi-boot.img.dualboot" && LC_ALL=C grep -aqF "$FENCE" "$I-$m/laurel-uefi-boot.img" || { echo "FAIL marker $m"; exit 1; }; done
  LC_ALL=C grep -aqE 'ufsrw=[1-9]|rootrw=[1-9]' "$I-ro/laurel-uefi-boot.img" && { echo "FAIL ro image can write"; exit 1; }
  LC_ALL=C grep -aqE 'ufsrw=1' "$I-rw/laurel-uefi-boot.img" || { echo "FAIL rw image has no ufsrw"; exit 1; }
  "$OUT/venv/bin/python3" -W ignore - "$I-ro/payload.img" "$I-rw/payload.img" <<'P'
import sys,tomllib
from pyfatfs.PyFatFS import PyFatFS
def t(p):
    fs=PyFatFS(p,read_only=True); return tomllib.loads(fs.open('/EFI/UniXNU/unixnu.toml','r').read())
ro,rw=t(sys.argv[1]),t(sys.argv[2])
print('  ro menu: timeout',ro['boot']['timeout'],[e['title'] for e in ro['entry']])
print('  rw menu: timeout',rw['boot']['timeout'],[e['title'] for e in rw['entry']])
assert ro['boot']['timeout']==3 and len(ro['entry'])==1 and 'laurelpanic' not in ro['entry'][0]['args'] and 'ufsrw' not in ro['entry'][0]['args']
assert rw['boot']['timeout']==5 and rw['entry'][1]['action']=='laurel-android' and 'laurelpanic=30' in rw['entry'][0]['args'] and 'ufsrw=1' in rw['entry'][0]['args']
P
done
if [ "$built" -gt 0 ]; then
  # rw not through dual-boot.sh image rw, Mu alone, no menu: the header is still Lineage's
  I=$W/img-x
  PATH=$PATH0 UEFI_W=$I-noroot LAUREL_READONLY=0 "$REPO/scripts/laurel/$sc" > "$I-noroot.log" 2>&1 || { tail -5 "$I-noroot.log"; exit 1; }
  check_img "rw without the root mark" "$I-noroot/laurel-uefi-boot.img" "refused: boot_b has no root mark" 1
  PATH=$PATH0 UEFI_W=$I-nomenu BOOT_MENU=0 LAUREL_READONLY=0 "$REPO/scripts/laurel/$sc" > "$I-nomenu.log" 2>&1 || { tail -5 "$I-nomenu.log"; exit 1; }
  check_img "BOOT_MENU=0" "$I-nomenu/laurel-uefi-boot.img" "refused: boot_b does not hold our image" 1
  PATH=$PATH0 UEFI_W=$I-mu MU_ONLY=1 "$REPO/scripts/laurel/uefi-image.sh" > "$I-mu.log" 2>&1 || { tail -5 "$I-mu.log"; exit 1; }
  check_img "MU_ONLY=1" "$I-mu/laurel-mu-only-boot.img" "refused: boot_b does not hold our image" 1
fi
echo "PASS boot-menu-test"
