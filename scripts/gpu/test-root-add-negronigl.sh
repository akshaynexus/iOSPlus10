#!/bin/sh
# Run the installer against a disposable fake iOS root (no phone, no real root):
#   scripts/gpu/test-root-add-negronigl.sh
# Checks: the NEGRONIGL guard, the bundle copy and modes, removal of the old backboardd injection
# (other inserted libraries kept), plist mode, idempotence.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/gpu/env.sh"
[ -f "$G/NegroniGL.bundle/NegroniGL" ] || { echo "run scripts/gpu/build.sh first" >&2; exit 1; }
tmp=$(mktemp -d "$G/root-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
root=$tmp/root
plist=$root/System/Library/xpc/launchd.plist
mkdir -p "$(dirname "$plist")"
python3 -I - "$plist" <<'PY'
import plistlib, sys
job = {'Label': 'com.apple.backboardd',
       'EnvironmentVariables': {'DYLD_INSERT_LIBRARIES': '/usr/lib/old.dylib:/usr/lib/negronigl.dylib'}}
data = {'LaunchDaemons': {'/System/Library/LaunchDaemons/com.apple.backboardd.plist': job}}
with open(sys.argv[1], 'wb') as f: plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
PY
chmod 640 "$plist"
NEGRONIGL=0 "$REPO/scripts/gpu/root-add-negronigl.sh" "$root" | grep -q skipped
[ ! -e "$root/System/Library/Extensions/NegroniGL.bundle" ] || { echo 'guard failed' >&2; exit 1; }
NEGRONIGL=1 "$REPO/scripts/gpu/root-add-negronigl.sh" "$root"
NEGRONIGL=1 "$REPO/scripts/gpu/root-add-negronigl.sh" "$root" >/dev/null
B=$root/System/Library/Extensions/NegroniGL.bundle
cmp "$G/NegroniGL.bundle/NegroniGL" "$B/NegroniGL"
cmp "$G/NegroniGL.bundle/Info.plist" "$B/Info.plist"
[ "$(stat -f %Lp "$B/NegroniGL" 2>/dev/null || stat -c %a "$B/NegroniGL")" = 755 ]
[ "$(stat -f %Lp "$B/Info.plist" 2>/dev/null || stat -c %a "$B/Info.plist")" = 644 ]
python3 -I - "$plist" <<'PY'
import os, plistlib, stat, sys
p = sys.argv[1]
d = plistlib.load(open(p, 'rb'))
job = d['LaunchDaemons']['/System/Library/LaunchDaemons/com.apple.backboardd.plist']
assert job['EnvironmentVariables']['DYLD_INSERT_LIBRARIES'] == '/usr/lib/old.dylib', job
assert stat.S_IMODE(os.stat(p).st_mode) == 0o640
print('fake-root installer check passed: guard, bundle copy + modes, old injection removed, plist mode')
PY
