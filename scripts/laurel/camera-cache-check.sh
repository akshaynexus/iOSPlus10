#!/bin/bash
# The 20H392 root's dyld cache against NegroniCamera.driver (Linux, no root): the hook table (scripts/camera/check-cache.sh) and
# every undefined symbol of the built bundle (out/laurel/camera/ios) against the image it links to.
#   scripts/bg.sh camapp-cache scripts/laurel/camera-cache-check.sh       (about 2 min: apfs-fuse + ipsw)
# Input: $APPLE/20H392/087-86593-047.dmg (SystemOS cryptex, the same dmg as scripts/laurel/root.sh), mounted read-only in user space
# while the check runs. ipsw: the pinned one of scripts/laurel/metal-env.sh. Apple content is never copied.
# Output: out/camera/cache-check.txt (check-cache.sh), out/laurel/camera/imports.txt. Exit 1 when something does not match.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
DMG=${DSC_DMG:-$APPLE/20H392/087-86593-047.dmg}
X=$OUT/laurel/camera/ios/NegroniCamera.driver/NegroniCamera
TC=$OUT/laurel-kernel/theos/toolchain/linux/iphone/bin
[ -s "$DMG" ] || { echo "camera-cache-check: no $DMG (scripts/ios16/fetch-dmgs.sh)" >&2; exit 1; }
[ -s "$X" ] || { echo "camera-cache-check: no $X (userland/laurel/camera/build.sh)" >&2; exit 1; }

# ipsw: PATH, the Metal build's, or the pinned download
IPSW_VERSION=$(sed -n 's/^IPSW_VERSION=//p' "$REPO/scripts/laurel/metal-env.sh")
IPSW_SHA256=$(sed -n 's/^IPSW_SHA256=\([0-9a-f]*\).*/\1/p' "$REPO/scripts/laurel/metal-env.sh")
if ! command -v ipsw > /dev/null; then
  I=$OUT/laurel-metal/ipsw
  if [ ! -x "$I/ipsw" ]; then
    mkdir -p "$I"
    curl -fsSL -o "$I/ipsw.tar.gz" "https://github.com/blacktop/ipsw/releases/download/v$IPSW_VERSION/ipsw_${IPSW_VERSION}_linux_x86_64.tar.gz"
    echo "$IPSW_SHA256  $I/ipsw.tar.gz" | sha256sum -c -
    tar -xzf "$I/ipsw.tar.gz" -C "$I" ipsw
  fi
  export PATH=$I:$PATH
fi

M=$(mktemp -d)
trap 'fusermount3 -u "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
apfs-fuse -o ro "$DMG" "$M"
C=$M/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
[ -f "$C" ] || { echo "camera-cache-check: no cache in $DMG" >&2; exit 1; }

sh "$REPO/scripts/camera/check-cache.sh" "$C"

# the bundle's undefined symbols: frameworks by name, the rest in libSystem's parts or libobjc
T=$(mktemp -d)
trap 'rm -rf "$T"; fusermount3 -u "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
for img in CoreFoundation CoreMedia CoreVideo libobjc.A.dylib libSystem.B.dylib libdispatch.dylib libsystem_c.dylib \
    libsystem_kernel.dylib libsystem_pthread.dylib libsystem_malloc.dylib libsystem_m.dylib libsystem_trace.dylib libdyld.dylib \
    libsystem_blocks.dylib libsystem_platform.dylib libcompiler_rt.dylib libsystem_dyld.dylib libmacho.dylib libunwind.dylib; do
  # the last word of each line: "ADDR: (regular) _name", "(resolver) _name", ... (libSystem's parts export some as resolvers)
  ipsw dyld symaddr "$C" --image "$img" 2>/dev/null | awk '{print $NF}' > "$T/$img.txt" || true
done
cat "$T"/lib*.txt | LC_ALL=C sort -u > "$T/system.txt"
R=$OUT/laurel/camera/imports.txt
: > "$R"
bad=0
for s in $("$TC/llvm-nm" -u -j "$X" | grep '^_' | LC_ALL=C sort -u); do
  case "$s" in
  _CF*|_kCF*|___CFConstantStringClassReference) f=$T/CoreFoundation.txt ;;
  _CM*|_kCM*) f=$T/CoreMedia.txt ;;
  _CV*|_kCV*) f=$T/CoreVideo.txt ;;
  *) f=$T/system.txt ;;
  esac
  if grep -q -x -F "$s" "$f"; then
    echo "OK   $s" >> "$R"
  else
    echo "BAD  $s not exported by $(basename "$f" .txt)" | tee -a "$R"
    bad=1
  fi
done
echo "camera-cache-check: $(grep -c '^OK' "$R") imports OK, $(grep -c '^BAD' "$R" || true) missing ($R)"
exit $bad
