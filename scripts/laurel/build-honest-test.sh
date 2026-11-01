#!/bin/bash
# Host test of the honest build (docs/laurel_sprout/build-honest.md) on a fake tree: no sudo, no phone, no Apple files, no real stages.
#   scripts/laurel/build-honest-test.sh       (seconds; exit 0 = all pass)
# The fake repo has the real scripts/laurel; tools that are not under test (FFmpeg-level builds, table parsers, root-add-ssh.py) are stubs.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$REPO/out"
T=$(mktemp -d "$REPO/out/honest-test.XXXXXX")
trap 'rm -rf -- "$T"' EXIT
R=$T/repo; ROOT=$T/root; A=$T/apple; BIN=$T/bin
fails=0; n=0
pass() { n=$((n + 1)); echo "ok   $1"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $1"; sed 's/^/     | /' "$T/o" | tail -12; }
# expect NAME RC SUBSTRING CMD...: exit code and one output text
expect() {
  local name=$1 rc=$2 text=$3 got=0; shift 3
  "$@" > "$T/o" 2>&1 || got=$?
  if [ "$got" = "$rc" ] && { [ -z "$text" ] || grep -qF -- "$text" "$T/o"; }; then pass "$name"; else echo "     got exit $got, wanted $rc, text '$text'" >> "$T/o"; bad "$name"; fi
}
MAN=$R/scripts/laurel/root-manifest.py; BS=$R/scripts/laurel/build-stamp.py
man() { python3 -I "$MAN" "$@"; }
stamp() { python3 -I "$BS" "$@"; }
macho() { python3 -I "$T/macho.py" "$@"; }

cat > "$T/macho.py" <<'EOF'
import struct, sys
path, ftype, text = sys.argv[1], int(sys.argv[2]), (sys.argv[3] if len(sys.argv) > 3 else '')
cmds = struct.pack('<II', 0x1d, 16) + b'\0' * 8 + struct.pack('<II', 0x80000028, 24) + b'\0' * 16
open(path, 'wb').write(struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, ftype, 2, len(cmds), 0, 0) + cmds + text.encode())
EOF
cat > "$T/plist.py" <<'EOF'
import plistlib, sys
J = '/System/Library/LaunchDaemons/%s.plist'
root = sys.argv[1]
jobs = {J % 'com.apple.SpringBoard': {'Label': 'com.apple.SpringBoard', 'ProgramArguments': ['/System/Library/CoreServices/SpringBoard.app/SpringBoard']},
        J % 'com.apple.BlueTool': {'Label': 'com.apple.BlueTool', 'ProgramArguments': ['/usr/sbin/BlueTool', '-R']},
        J % 'com.apple.backboardd': {'Label': 'com.apple.backboardd', 'ProgramArguments': ['/usr/libexec/backboardd']}}
plistlib.dump({'LaunchDaemons': jobs}, open(root + '/System/Library/xpc/launchd.plist', 'wb'), fmt=plistlib.FMT_BINARY)
plistlib.dump({'Label': 'com.apple.bluetoothd', 'ProgramArguments': ['/usr/sbin/bluetoothd']}, open(root + '/System/Library/LaunchDaemons/com.apple.bluetoothd.plist', 'wb'))
plistlib.dump({'MachServices': {'com.apple.coremedia.capturesource': True, 'com.apple.coremedia.capturesession': True}},
              open(root + '/System/Library/LaunchDaemons/com.apple.mediaserverd.plist', 'wb'))
EOF

# the fake repo: real scripts, small patch set, old sources
make_repo() {
  mkdir -p "$R"/scripts/{laurel,lib,bt,net,metal,ios16} "$R"/patches/laurel/xnu "$R"/patches/laurel/xnu-linux-fixes "$R"/external/ios-topaz/xnu/patches \
    "$R"/external/ios-topaz/tools "$R"/external/ios-sweet-linux/linux/fixes "$R"/logs "$A"
  cp "$REPO"/scripts/laurel/{root*.sh,root*.py,build-stamp.py,build-all.sh} "$R/scripts/laurel/"
  cp "$REPO"/scripts/lib/env.sh "$R/scripts/lib/"
  cp "$REPO"/scripts/bt/bt-launchd.py "$R/scripts/bt/"
  cp "$REPO"/scripts/net/root-add-ssh.sh "$R/scripts/net/"
  cp "$REPO"/scripts/metal/root-add-metal.sh "$R/scripts/metal/"
  # not under test: stubs
  printf 'import sys\nsys.exit(0)\n' > "$R/scripts/laurel/camera-tables.py"
  cat > "$R/scripts/laurel/camera-tuning.py" <<'EOF'
import os, sys
if sys.argv[2] == os.environ.get('FAKE_NO_TUNING'):
    sys.exit(1)
open(sys.argv[3], 'w').write('x')
EOF
  printf 'import sys\n' > "$R/scripts/laurel/metal-gate-job.py"; cp "$R/scripts/laurel/metal-gate-job.py" "$R/scripts/laurel/metal-job-env.py"
  printf 'print("stub")\n' > "$R/scripts/ios16/jetsam_widgets.py"; : > "$R/scripts/ios16/root-tweaks-extra.py"; : > "$R/scripts/ios16/root-tweaks-boldtext.py"
  cat > "$R/scripts/net/root-add-ssh.py" <<'EOF'
import os, plistlib, sys
r = sys.argv[1]
os.makedirs(r + '/usr/local/bin', exist_ok=True); open(r + '/usr/local/bin/dropbearmulti', 'w').write('x')
p = r + '/System/Library/xpc/launchd.plist'; d = plistlib.load(open(p, 'rb'))
d['LaunchDaemons']['/System/Library/LaunchDaemons/dev.iosplus10.dropbear.plist'] = {'Label': 'dev.iosplus10.dropbear'}
plistlib.dump(d, open(p, 'wb'), fmt=plistlib.FMT_BINARY)
EOF
  : > "$R/external/ios-topaz/tools/mkiosroot.sh"; : > "$R/external/ios-topaz/tools/sweet-root-tweaks.py"
  echo topaz > "$R/external/ios-topaz/xnu/patches/0001-a.patch"; echo sh > "$R/external/ios-topaz/xnu/patches/0002-b.sh"
  echo laurel > "$R/patches/laurel/xnu/2000-c.patch"; echo fix > "$R/patches/laurel/xnu-linux-fixes/0100-d.patch"; echo skips > "$R/patches/laurel/known-skips.txt"
  for f in 0001-kalloc-stock-clang-void-ptr.patch 0003-corecrypto-sha256-asm-operands.patch; do echo "$f" > "$R/external/ios-sweet-linux/linux/fixes/$f"; done
  for d in userland/laurel/gpu userland/laurel/metal userland/laurel/hevc userland/laurel/audio userland/laurel/bt userland/bluetooth userland/laurel/camera \
           userland/camera userland/laurel/flashlight userland/laurel/notch userland/laurel/xnutils userland/rebootapp userland/ssh; do mkdir -p "$R/$d"; echo src > "$R/$d/src.c"; done
  echo gate > "$R/userland/laurel/metal/metal_gate.c"
  find "$R/userland" "$R/patches" "$R/external" -type f -exec touch -d '2 days ago' {} +
  git -C "$R" init -q; git -C "$R" add -A scripts patches userland; git -C "$R" -c user.name=t -c user.email=t@t commit -qm fake
}
make_stages() {
  local G=$R/out/laurel/gpu/root B=$R/out/metal/stage/System/Library/Extensions/NegroniMetal.bundle C=$R/out/laurel/camera
  mkdir -p "$G/topaz/lib" "$G/usr/libexec" "$G/usr/share/firmware/laurel" "$B" "$R/out/metal/stage/usr/local/bin" "$R/out/laurel/hevc" "$R/out/laurel/audio/RedwoodAudio.driver" \
    "$R/out/laurel/bt" "$C/ios/NegroniCamera.driver" "$C/lib" "$R/out/laurel/flashlight/LaurelFlashlight.driver" "$R/out/laurel/notch/root/usr/local/lib" \
    "$R/out/laurel/notch/root/usr/local/libexec" "$R/out/ssh/ios"
  for f in libOSMesa.8.dylib libtopaz-gl.dylib libtopaz-inject.dylib; do echo x > "$G/topaz/lib/$f"; done
  macho "$G/usr/libexec/backboardd.wrap" 2 /usr/libexec/real/backboardd; echo x > "$G/usr/libexec/laurel-metal-gate"
  echo x > "$G/usr/share/firmware/laurel/a610_zap.mdt"; echo x > "$G/usr/share/firmware/laurel/a610_zap.b00"
  for f in NegroniMetal libvulkan_freedreno.dylib Info.plist; do echo x > "$B/$f"; done; echo x > "$R/out/metal/stage/usr/local/bin/m2vtest"
  mkdir -p "$R/out/metal/stage/var/db/negronimetal"; echo '*' > "$R/out/metal/stage/var/db/negronimetal/clients"
  echo x > "$R/out/laurel/hevc/HEVCH8.videodecoder"; (cd "$R/out/laurel/hevc" && sha256sum HEVCH8.videodecoder > SHA256SUMS)
  echo x > "$R/out/laurel/audio/RedwoodAudio.driver/RedwoodAudio"; echo x > "$R/out/laurel/bt/negroni-bluetool"
  echo x > "$C/ios/NegroniCamera.driver/NegroniCamera"
  for f in libmmcamera_laurus_imx586_qtech.so libmmcamera_laurus_imx586_sunny.so libactuator_dw9800.so libactuator_laurus_dw9800w_qtech.so; do echo x > "$C/lib/$f"; done
  echo x > "$R/out/laurel/flashlight/LaurelFlashlight.driver/LaurelFlashlight"
  macho "$R/out/laurel/notch/root/usr/local/lib/liblaurel-notch.dylib" 6
  macho "$R/out/laurel/notch/root/usr/local/libexec/laurel-springboard" 2 /System/Library/CoreServices/SpringBoard.app/SpringBoard
  echo x > "$R/out/ssh/ios/dropbearmulti"
  local X=$R/out/laurel/xnutils/root
  mkdir -p "$X/Applications/XNUtils.app" "$X/usr/local/libexec" "$X/usr/local/bin"
  echo x > "$X/Applications/XNUtils.app/XNUtils"; chmod +x "$X/Applications/XNUtils.app/XNUtils"; echo x > "$X/Applications/XNUtils.app/Info.plist"
  echo x > "$X/usr/local/libexec/powermenu-helper"; echo x > "$X/usr/local/bin/pmregister"
}
make_root() {
  rm -rf -- "$ROOT"
  mkdir -p "$ROOT"/System/Library/{xpc,LaunchDaemons,VideoDecoders,Extensions,Audio/UISounds} "$ROOT"/usr/libexec "$ROOT"/Applications "$ROOT"/private/var/{mobile,root} \
    "$ROOT"/Library/Audio/Tunings/D22 "$ROOT"/Library/Ringtones "$ROOT"/Library/Audio/Plug-Ins/HAL.disabled/VirtualAudio.plugin
  echo x > "$ROOT/usr/libexec/backboardd"; chmod +x "$ROOT/usr/libexec/backboardd"
  python3 -I "$T/plist.py" "$ROOT"
}
# a fake kernel build tree that passes every check
make_kernel() {
  local W=$R/out/laurel-kernel
  mkdir -p "$W/patches" "$W/linux/fixes" "$W/out" "$W/xnu/iokit/DriverKit"
  cp "$R"/external/ios-topaz/xnu/patches/* "$R"/patches/laurel/xnu/* "$W/patches/"
  cp "$R"/external/ios-sweet-linux/linux/fixes/* "$R"/patches/laurel/xnu-linux-fixes/* "$W/linux/fixes/"
  cp "$R/patches/laurel/known-skips.txt" "$W/linux/known-skips.txt"
  KSTAMP=$(stamp kernel-stamp "$W" 4k)
  { printf 'ld: symbol(s) not found\nclang++: error: linker command failed with exit code 1\nclang++: error: linker command failed with exit code 1\nbuilt kernel at /x\nmake: *** Error 2\n'; } > "$W/build.log"
  : > "$W/xnu/iokit/DriverKit/OSObject.iig.cpp"; touch -d '2 minutes ago' "$W/xnu/iokit/DriverKit/OSObject.iig.cpp"
  K=$T/K; { head -c 5000000 /dev/zero; printf 'LAUREL BUILD: %s\n' "$KSTAMP"; head -c 100 /dev/zero; } > "$K"
  KT0=$(($(date +%s) - 60))
}
verify() { stamp kernel-verify --kernel "$K" --work "$R/out/laurel-kernel" --stamp "$KSTAMP" --t0 "$KT0" --xnu "$R/out/laurel-kernel/xnu"; }
seal_kernel() {
  local W=$R/out/laurel-kernel; cp "$K" "$W/out/kernel.development.sweet.4k"; stamp kernel-seal "$K" "$W/out/kernel.development.sweet.4k" "$KSTAMP"
  mkdir -p "$R/out/laurel/mu" "$R/out/laurel/uefi"; echo fd > "$R/out/laurel/mu/SILICIUM_UEFI-DEBUG.fd"; echo img > "$R/out/laurel/uefi/laurel-uefi-boot.img"
  stamp image-seal "$R/out/laurel/uefi/laurel-uefi-boot.img" "$(stamp image-line "$W/out/kernel.development.sweet.4k" "$R/out/laurel/mu/SILICIUM_UEFI-DEBUG.fd")" \
    "$W/out/kernel.development.sweet.4k" "$R/out/laurel/mu/SILICIUM_UEFI-DEBUG.fd" args
}
features() { "$@" bash "$R/scripts/laurel/root-features.sh" "$ROOT" --inputs "$T/in" --sidecar "$A/laurel-ios16-root.manifest"; }
make_repo; make_stages; make_root; make_kernel
echo "== kernel"
expect "good kernel, 2 stub-round linker lines, passes" 0 "linker failures in build.log: 2" verify
cp "$K" "$T/K.good"; head -c 4096 /dev/zero > "$T/nostamp"
K=$T/nostamp; expect "no embedded stamp" 1 "does not hold the line" verify; K=$T/K.good
K=$T/nofile; expect "no kernel file" 1 "no kernel at" verify; K=$T/K.good
touch "$R/out/laurel-kernel/xnu/iokit/DriverKit/OSObject.iig.cpp"; touch -d '1 minute ago' "$K"
expect "kernel older than the last stub round (a compile stopped the relink)" 1 "last relink did not make it" verify
touch -d '2 minutes ago' "$R/out/laurel-kernel/xnu/iokit/DriverKit/OSObject.iig.cpp"
touch -d '1 hour ago' "$K"; expect "kernel from before this run" 1 "before this run started" verify; touch "$K"
cp "$R/out/laurel-kernel/build.log" "$T/log.good"; echo 'clang++: error: linker command failed with exit code 1' >> "$R/out/laurel-kernel/build.log"
expect "last link round failed" 1 "last link round failed" verify; cp "$T/log.good" "$R/out/laurel-kernel/build.log"
grep -v 'built kernel at' "$T/log.good" > "$R/out/laurel-kernel/build.log"; expect "no 'built kernel at'" 1 "never printed" verify; cp "$T/log.good" "$R/out/laurel-kernel/build.log"
sleep 1; echo changed >> "$R/patches/laurel/xnu/2000-c.patch"
expect "a patch changed during the run" 1 "changed during this run: 2000-c.patch" verify
git -C "$R" checkout -q patches/laurel/xnu/2000-c.patch; touch -d '2 days ago' "$R/patches/laurel/xnu/2000-c.patch"
seal_kernel >/dev/null
KO=$R/out/laurel-kernel/out/kernel.development.sweet.4k
expect "sealed kernel: check ok" 0 "kernel ok" stamp kernel-check "$KO"
cp "$KO" "$T/ko"; echo y >> "$KO"; expect "kernel file changed after its stamp" 1 "sha256 differs" stamp kernel-check "$KO"; cp "$T/ko" "$KO"
echo changed >> "$R/patches/laurel/xnu/2000-c.patch"
expect "patches newer than the kernel: stale" 1 "the kernel is stale" stamp kernel-check "$KO"
expect "... a kernel by hand checks only itself" 0 "kernel ok" stamp kernel-check "$KO" --no-repo
git -C "$R" checkout -q patches/laurel/xnu/2000-c.patch; touch -d '2 days ago' "$R/patches/laurel/xnu/2000-c.patch"
IMGF=$R/out/laurel/uefi/laurel-uefi-boot.img; FDF=$R/out/laurel/mu/SILICIUM_UEFI-DEBUG.fd
expect "boot image: check ok" 0 "boot image ok" stamp image-check "$IMGF" "$KO" "$FDF"
echo y >> "$FDF"; expect "boot image: FD changed after it" 1 "FD changed" stamp image-check "$IMGF" "$KO" "$FDF"; echo fd > "$FDF"
echo "== preflight"
expect "all stages: ok" 0 "input script:scripts/laurel/root.sh" man preflight --inputs "$T/in"
mv "$R/out/laurel/audio" "$T/audio.saved"
expect "audio stage absent: named, with the way out" 1 "audio: no out/laurel/audio/RedwoodAudio.driver/RedwoodAudio" man preflight
expect "AUDIO=0: passes" 0 "audio      off: AUDIO=0" env AUDIO=0 python3 -I "$MAN" preflight
mv "$T/audio.saved" "$R/out/laurel/audio"
touch "$R/userland/laurel/hevc/src.c"; touch -d '1 day ago' "$R/out/laurel/hevc/HEVCH8.videodecoder"
expect "hevc source newer than its stage" 1 "hevc: stage is older than userland/laurel/hevc/src.c" man preflight
touch -d '2 days ago' "$R/userland/laurel/hevc/src.c"; touch "$R/out/laurel/hevc/HEVCH8.videodecoder"
echo "== features on a copy of a fake root"
man preflight --inputs "$T/in" > /dev/null
expect "all installed, exit 0" 0 "12 installed, 0 off by their own switch, 0 missing" features env
expect "root manifest: first line + table" 0 "kernel-series" head -1 "$ROOT/usr/share/laurel/root-manifest"
expect "root manifest: rows" 0 "feature	camera	installed" cat "$ROOT/usr/share/laurel/root-manifest"
make_root; mv "$R/out/laurel/hevc/HEVCH8.videodecoder" "$T/h"; printf '#!/bin/sh\nexit 1\n' > "$R/scripts/laurel/hevc-build.sh"; chmod +x "$R/scripts/laurel/hevc-build.sh"
expect "hevc build failed: missing, exit 1, reason from its step" 1 "hevc        missing" features env
cp "$T/o" "$T/o.hevc"; expect "... its reason" 0 "hevc-build.sh failed" cat "$T/o.hevc"
mv "$T/h" "$R/out/laurel/hevc/HEVCH8.videodecoder"
make_root; expect "HEVC=0 CAMERA=0 BT=0: off, exit 0; flashlight falls to its own plug-in" 0 "9 installed, 3 off by their own switch, 0 missing" features env HEVC=0 CAMERA=0 BT=0
expect "... LaurelFlashlight in the root" 0 "" test -f "$ROOT/System/Library/Audio/Plug-Ins/HAL/LaurelFlashlight.driver/LaurelFlashlight"
make_root; expect "camera without one colour tuning: missing, the file named" 1 "camera-imx586-qtech.isp" features env FAKE_NO_TUNING=qtech
make_root; rm -f "$R/out/laurel/gpu/root/topaz/lib/libtopaz-gl.dylib"
expect "no GPU stage: missing, and Metal says what it says" 1 "gpu         missing" features env
echo x > "$R/out/laurel/gpu/root/topaz/lib/libtopaz-gl.dylib"
make_root; rm -rf -- "$ROOT/Library/Audio/Tunings"; expect "audio without speaker tunings: missing" 1 "Library/Audio/Tunings/D22" features env
make_root; expect "again all installed" 0 "0 missing" features env
echo "== the race: a script changed during the run"
expect "inputs unchanged" 0 "" man inputs-check "$T/in"
cp "$R/scripts/laurel/root-camera.sh" "$T/cam"; echo '# edit' >> "$R/scripts/laurel/root-camera.sh"
expect "root-camera.sh edited: named" 1 "script:scripts/laurel/root-camera.sh changed during this run" man inputs-check "$T/in"
cp "$T/cam" "$R/scripts/laurel/root-camera.sh"
echo "== flash check"
S=$A/laurel-ios16-root.manifest; SIMG=$A/laurel-ios16-root.simg; echo simg > "$SIMG"
flash() { man flash-check "$S" "$SIMG" "$IMGF"; }
expect "not sealed: refused" 1 "status building" flash
man seal "$S" "$SIMG"
expect "sealed: ok, prints what it uses" 0 "root, kernel, boot image and stages are one build" flash
echo x >> "$R/out/laurel/hevc/SHA256SUMS"; echo y >> "$R/out/laurel/hevc/HEVCH8.videodecoder"
expect "a stage rebuilt after the image" 1 "stage:hevc:out/laurel/hevc/HEVCH8.videodecoder: image built from" flash
expect "STALE_OK=1 passes, lists it" 0 "STALE_OK=1: the owner flashes" env STALE_OK=1 python3 -I "$MAN" flash-check "$S" "$SIMG" "$IMGF"
sed -i '$d' "$R/out/laurel/hevc/HEVCH8.videodecoder"
echo '# edit' >> "$R/scripts/laurel/root-bt.sh"; expect "a script edited after the image" 1 "script:scripts/laurel/root-bt.sh" flash; sed -i '$d' "$R/scripts/laurel/root-bt.sh"
echo more >> "$SIMG"; expect "image changed after the seal" 1 "image changed after root.sh sealed it" flash; man seal "$S" "$SIMG"
echo y >> "$KO"; expect "kernel changed: root and boot image are not this build" 1 "kernel:" flash; cp "$T/ko" "$KO"
rm -f "$IMGF.stamp"; expect "boot image without a stamp" 1 "boot image: no laurel-uefi-boot.img.stamp" flash; seal_kernel > /dev/null
man fail "$S" "a feature is missing"; expect "run failed: refused" 1 "status failed a feature is missing" flash; man seal "$S" "$SIMG"
expect "no image" 1 "no root image" man flash-check "$S" "$SIMG.none" "$IMGF"
mv "$S" "$S.s"; expect "no sidecar (an old image)" 1 "not from a checked root.sh run" flash; mv "$S.s" "$S"

echo "== root-flash-test: nothing touches the phone before the checks pass"
mkdir -p "$BIN"
for t in lsusb fastboot; do printf '#!/bin/sh\necho "%s called" >> "%s/phone"\nexit 1\n' "$t" "$T" > "$BIN/$t"; chmod +x "$BIN/$t"; done
printf '#!/bin/sh\necho "sudo: $*" >> "%s/sudo.args"\nshift\nexit 7\n' "$T" > "$BIN/sudo"; chmod +x "$BIN/sudo"
rft() { env PATH="$BIN:$PATH" APPLE="$A" "$@" sh "$R/scripts/laurel/root-flash-test.sh"; }
echo x >> "$SIMG"
expect "BUILD=0, stale image: stops" 1 "nothing flashed" rft BUILD=0
expect "... the phone was not touched" 1 "" test -f "$T/phone"
man seal "$S" "$SIMG"
expect "BUILD=1: root.sh fails: stops" 7 "" rft BUILD=1 AUDIO=0
expect "... the switch reaches sudo" 0 "AUDIO=0" cat "$T/sudo.args"
expect "... the phone was not touched" 1 "" test -f "$T/phone"
mv "$R/out/laurel/bt" "$T/bt.saved"; rm -f "$T/sudo.args"
expect "BUILD=1: a stage absent: stops before sudo" 1 "bluetooth: no out/laurel/bt/negroni-bluetool" rft BUILD=1
expect "... no sudo" 1 "" test -f "$T/sudo.args"
mv "$T/bt.saved" "$R/out/laurel/bt"

echo "== build-all with stub stages"
mkdir -p "$R/userland/ssh" "$R/userland/laurel/camera" "$R/userland/laurel/audio" "$R/userland/laurel/bt" "$R/out/laurel-kernel/theos/toolchain/linux/iphone/bin"
printf '#!/bin/sh\n' > "$R/out/laurel-kernel/theos/toolchain/linux/iphone/bin/ld"; chmod +x "$R/out/laurel-kernel/theos/toolchain/linux/iphone/bin/ld"
for s in scripts/laurel/{camera-inventory,gpu-firmware,gpu-userland,metal-build,notch-build,hevc-build,xnutils-build,kernel-linux,uefi-image}.sh userland/laurel/{camera,audio,bt,flashlight}/build.sh userland/ssh/{fetch,fetch-sdk,build}.sh; do
  mkdir -p "$(dirname "$R/$s")"; printf '#!/bin/sh\nexit 0\n' > "$R/$s"; chmod +x "$R/$s"
done
git -C "$R" add -A scripts userland; git -C "$R" -c user.name=t -c user.email=t@t commit -qm stubs
find "$R/userland" -type f -exec touch -d '2 days ago' {} +
ba() { (cd "$R" && "$@" sh scripts/laurel/build-all.sh); }
expect "all stages built: done" 0 "build-all: done" ba env
printf '#!/bin/sh\nexit 1\n' > "$R/scripts/laurel/gpu-userland.sh"; printf '#!/bin/sh\necho no\nexit 1\n' > "$R/userland/laurel/audio/build.sh"
rm -f "$R/out/laurel/uefi/ran"; printf '#!/bin/sh\ntouch out/laurel/uefi/ran\n' > "$R/scripts/laurel/uefi-image.sh"
expect "gpu and audio failed: both named" 1 "build-all: FAILED: gpu audio" ba env
expect "... no boot image from it" 1 "" test -f "$R/out/laurel/uefi/ran"
expect "GPU=0 AUDIO=0: not built, not asked" 0 "build-all: done" ba env GPU=0 AUDIO=0
printf '#!/bin/sh\nexit 0\n' > "$R/scripts/laurel/gpu-userland.sh"; printf '#!/bin/sh\nexit 0\n' > "$R/userland/laurel/audio/build.sh"
touch -d '2 days ago' "$R/userland/laurel/audio/build.sh"
printf '#!/bin/sh\necho "# edit" >> scripts/laurel/root-camera.sh\nexit 0\n' > "$R/scripts/laurel/hevc-build.sh"
expect "a source edited during the build: named" 1 "changed during this run: scripts/laurel/root-camera.sh" ba env
printf '#!/bin/sh\nexit 0\n' > "$R/scripts/laurel/hevc-build.sh"
rm -f "$R/out/ssh/ios/dropbearmulti"; expect "a stage script passed, but its file is absent: not done" 1 "ssh: no out/ssh/ios/dropbearmulti" ba env

echo "== root-fsck with a fake fsck"
printf '#!/bin/sh\n[ "$2" = -y ] && exit 0\ncase "$FAKE_FSCK" in clean) exit 0;; minor) echo "Volume header needs minor repair (1, 0)"; exit 8;; *) echo "Invalid node structure"; exit 8;; esac\n' > "$BIN/fsck.hfsplus"
chmod +x "$BIN/fsck.hfsplus"; F=$R/scripts/laurel/root-fsck.sh
expect "clean" 0 "volume clean" env PATH="$BIN:$PATH" FAKE_FSCK=clean bash "$F" "$T/o2"
expect "only the header note: accepted" 0 "accepted" env PATH="$BIN:$PATH" FAKE_FSCK=minor bash "$F" "$T/o2"
expect "another finding: fails" 1 "FAILED: volume not clean" env PATH="$BIN:$PATH" FAKE_FSCK=bad bash "$F" "$T/o2"

echo "$((n - fails)) of $n passed"
[ "$fails" = 0 ]
