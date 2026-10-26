#!/bin/sh
# Reverse-engineering inputs for the iOS camera service design (docs/camera-plan.md "iOS capture service").
#   scripts/bg.sh cam-re scripts/camera/ios-re.sh
# Needs ipsw and the extracted 20H392 shared cache (out/dsc/cache, out/dsc/20H392.a2s; docs/gpu-userland.md).
# Downloads only the 20H392 iPhone10,3 kernelcache (~51 MB; Apple binary: out/ is git-ignored, never commit it).
# Output: out/camera/ios-re/: <image>.s/.strings.txt/.symbols.txt, sites-<image>.txt (IOConnectCall* sites),
# kext-dispatch.txt (AppleH10CamInUserClient method table). Read only on its inputs. macOS and Linux.
set -eu
. "$(dirname "$0")/../lib/env.sh"
RE=$OUT/camera/ios-re
DSC=$OUT/dsc/cache/dyld_shared_cache_arm64
A2S=$OUT/dsc/20H392.a2s
mkdir -p "$RE/kc"
for i in H10ISP.mediacapture H10ISPServices CMCapture; do
  ipsw dyld macho "$DSC" "$i" --strings > "$RE/$i.strings.txt" 2>&1
  ipsw dyld macho "$DSC" "$i" --symbols > "$RE/$i.symbols.txt" 2>&1
  ipsw dyld disass "$DSC" --image "$i" --cache "$A2S" > "$RE/$i.s" 2>&1
  python3 -I "$REPO/scripts/camera/ios-re/selector-sites.py" "$RE/$i.s" > "$RE/sites-$i.txt"
done
KC=$(ls "$RE"/kc/*/kernelcache.release.iPhone10,3* 2>/dev/null | head -1 || true)
if [ -z "$KC" ]; then
  ipsw download ipsw --device iPhone10,3 --build 20H392 --kernel --output "$RE/kc" -y
  KC=$(ls "$RE"/kc/*/kernelcache.release.iPhone10,3* | head -1)
fi
python3 -I "$REPO/scripts/camera/ios-re/dispatch-table.py" "$KC" 0xfffffff006f3c768 94 > "$RE/kext-dispatch.txt"
strings -a -t x "$KC" | grep -i camin > "$RE/kext-strings.txt" || true
wc -l "$RE"/sites-*.txt "$RE/kext-dispatch.txt"
