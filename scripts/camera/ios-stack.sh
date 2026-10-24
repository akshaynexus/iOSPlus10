#!/bin/sh
# Offline look at the iOS 16 camera stack in a read-only mounted root (nothing is written there).
#   scripts/bg.sh camera-ios scripts/camera/ios-stack.sh [IOSROOT]
# IOSROOT defaults to /tmp/iosroot-ro. Mount it read-only first (docs/camera-plan.md).
# ADT (optional): $APPLE/d22ap.adt, APPLE defaults to ~/op10-apple.
# Output: out/camera/ios-stack.txt. Needs ipsw (macOS: brew install blacktop/tap/ipsw; Linux: the
# release binary from https://github.com/blacktop/ipsw/releases) and python3.
# The kexts (AppleH10CamIn and its user client) are in the kernelcache, not in the root: not checked.
set -eu
# shellcheck source=scripts/lib/env.sh
. "$(dirname "$0")/../lib/env.sh"

R=${1:-/tmp/iosroot-ro}
APPLE=${APPLE:-$HOME/op10-apple}
DSC=$R/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
O=$OUT/camera/ios-stack.txt
[ -f "$R/System/Library/CoreServices/SystemVersion.plist" ] || { echo "no iOS root at $R" >&2; exit 1; }
command -v ipsw >/dev/null 2>&1 || { echo "ipsw missing (see the header of $0)" >&2; exit 1; }
mkdir -p "$OUT/camera"
{
	echo "== $R"
	python3 -I -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print(d["ProductVersion"], d["ProductBuildVersion"])' \
		"$R/System/Library/CoreServices/SystemVersion.plist"
	echo "== camera launchd jobs (program, exists in root?, IOKit launch matching)"
	for p in "$R"/System/Library/LaunchDaemons/*.plist; do
		case "$(basename "$p")" in *camera*|*mediaserverd*|*corecaptured*|*capture*) ;; *) continue ;; esac
		python3 -I -c '
import os, plistlib, sys
root, path = sys.argv[1], sys.argv[2]
d = plistlib.load(open(path, "rb"))
prog = d.get("Program") or d.get("ProgramArguments", ["?"])[0]
ev = d.get("LaunchEvents", {}).get("com.apple.iokit.matching", {})
match = sorted({str(v.get("IOPropertyMatch", v.get("IOProviderClass"))) for v in ev.values()})
print(os.path.basename(path), prog, "present" if os.path.exists(root + prog) else "MISSING", " ".join(match))
' "$R" "$p"
	done
	echo "== media capture plug-ins and CMCapture per-device files"
	ls "$R/System/Library/MediaCapture" "$R/System/Library/PrivateFrameworks/CMCapture.framework/D22"
	echo "== ISP firmware candidates in the root"
	find "$R/usr/standalone" "$R/System/Library/PrivateFrameworks/H10ISPServices.framework" \
		-maxdepth 2 2>/dev/null | head -40
	echo "== dyld shared cache images"
	ipsw dyld info -l "$DSC" 2>/dev/null | grep -i -E 'mediacapture|ISPServices|CMCapture.framework|AppleCameraInterface' || true
	echo "== dyld shared cache strings"
	ipsw dyld str --no-color "$DSC" AppleH10CamIn AppleH13CamIn AppleH9CamIn AppleH6CamIn \
		AppleH10CamInUserClient cameracaptured appleh13camerad "IODeviceTree:/arm-io/isp" \
		"Cannot find AppleH13CamIn" "_deviceCreateFunction" 2>&1 | grep -v Searching || true
	if [ -f "$APPLE/d22ap.adt" ]; then
		echo "== camera strings in $APPLE/d22ap.adt"
		strings -n 4 "$APPLE/d22ap.adt" | grep -E '^isp,|AppleH10CamIn|camera' | sort -u
	fi
} > "$O" 2>&1
cat "$O"
