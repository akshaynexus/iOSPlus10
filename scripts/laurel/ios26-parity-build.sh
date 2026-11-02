#!/bin/bash
# Every binary of the iOS 26 root's parity hooks (docs/laurel_sprout/ios26-parity.md), then the check of each against 23F84. Nothing here writes to a device.
#   scripts/bg.sh ios26-parity scripts/laurel/ios26-parity-build.sh      (minutes: the HEVC decoder builds FFmpeg once; the check asks the cache per binary)
#   CHECK=0 only the builds
# One failed build does not stop the others: its binary stays unchecked, and ios26-root-spec.py turns that hook off with one line.
# Output: the stages (out/laurel/{notch,cell,bt,hevc}, out/ios26/{audio,flashlight,ringer,xnutils}), out/ios26/parity-check.tsv: "sha256 TAB path" of each binary that passed all of:
#   thin plain arm64; 0 instructions newer than ARMv8.0; each library and import in the 23F84 cache (ios26-injected-check.py); signed, CodeDirectory page size 4096.
# ios26-root-spec.py takes only a file with its sha256 on that list. Exit 1 when a build or a check failed: the lines below name it.
set -uo pipefail
. "$(dirname "$0")/../lib/env.sh"
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
cd "$REPO" || exit 1
mkdir -p logs out/laurel out/ios26
export THEOS=${THEOS:-$OUT/laurel-kernel/theos}
[ -x "$THEOS/toolchain/linux/iphone/bin/ld" ] || THEOS=$MAIN/out/laurel-kernel/theos
[ -d "${SDK:-$OUT/laurel/gpu/deps/sdks/iPhoneOS16.5.sdk}/usr/include" ] || export SDK=$MAIN/out/laurel/gpu/deps/sdks/iPhoneOS16.5.sdk
bad=
step() {   # NAME CMD...: one log per step, at the same time as the others
  local n=$1; shift
  ( "$@" > "logs/parity-$n.log" 2>&1; echo $? > "logs/parity-$n.rc" ) &
}
step notch scripts/laurel/notch-build.sh
step cell scripts/laurel/cell-build.sh
step hevc scripts/laurel/hevc-build.sh
step audio env IOS26=1 userland/laurel/audio/build.sh
step bt userland/laurel/bt/build.sh
step flashlight env IOS26=1 userland/laurel/flashlight/build.sh
step xnutils env XNUTILS_IOS26=1 scripts/laurel/xnutils-build.sh
wait
for n in notch cell hevc audio bt flashlight xnutils; do
  rc=$(cat "logs/parity-$n.rc" 2>/dev/null || echo none)
  echo "ios26-parity-build: build $n: exit $rc"
  [ "$rc" = 0 ] || { bad="$bad build:$n"; tail -5 "logs/parity-$n.log"; }
done
BINS="out/laurel/notch/root/usr/local/lib/liblaurel-notch.dylib out/laurel/notch/root/usr/local/libexec/laurel-springboard out/ios26/ringer/usr/local/lib/liblaurel-ringer.dylib
out/laurel/cell/root/usr/local/lib/liblaurel-cellbar.dylib out/laurel/cell/root/usr/local/libexec/laurel-celld out/ios26/audio/RedwoodAudio.driver/RedwoodAudio out/laurel/bt/negroni-bluetool
out/ios26/flashlight/LaurelFlashlight.driver/LaurelFlashlight out/ios26/flashlight/laurel-cameracaptured out/laurel/hevc/HEVCH8.videodecoder
out/ios26/xnutils/root/Applications/XNUtils.app/XNUtils out/ios26/xnutils/root/usr/local/libexec/powermenu-helper out/ios26/xnutils/root/usr/local/bin/pmregister"
if [ "${CHECK:-1}" = 0 ]; then echo "ios26-parity-build: CHECK=0: no check"; exit 0; fi
T=$OUT/ios26/parity-check.tsv
: > "$T.new"
printf '# sha256\tpath: passed armv80-check, ios26-injected-check, page size 4096 (scripts/laurel/ios26-parity-build.sh)\n' >> "$T.new"
# one at a time: each check maps the whole cache through ipsw (several GB): with many at once the host's memory killer took this job on 2026-11-02
for b in $BINS; do
  if [ ! -f "$b" ]; then echo "ios26-parity-build: check $b: no file"; bad="$bad check:$b"; continue; fi
  ( out=$(python3 -I scripts/laurel/ios26-injected-check.py "$REPO/$b" 2>&1); rc=$?
    printf '%s\n' "$out"
    printf '%s\n' "$out" | grep -q 'page size 4096,' || rc=1
    if [ "$rc" = 0 ]; then printf '%s\t%s\n' "$(sha256sum "$b" | cut -d' ' -f1)" "$b" >> "$T.new"; else echo "ios26-parity-build: check $b: FAILED (rc $rc)"; fi
  ) > "logs/parity-check-$(basename "$b").log" 2>&1
done
for b in $BINS; do
  l="logs/parity-check-$(basename "$b").log"
  sed -n '/thin arm64/,$p' "$l" | cut -c1-170
  grep -q "	$b$" "$T.new" || bad="$bad check:$b"
done
mv -f "$T.new" "$T"
echo "ios26-parity-build: $(grep -vc '^#' "$T") of $(echo "$BINS" | wc -w) binaries passed: $T"
[ -z "$bad" ] || { echo "ios26-parity-build: FAILED:$bad"; exit 1; }
echo "ios26-parity-build: done"
