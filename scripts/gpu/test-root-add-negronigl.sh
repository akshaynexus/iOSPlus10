#!/bin/sh
# Exercise the installer against a disposable fake iOS root. No phone or real root is touched.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/gpu/env.sh"
tmp=$(mktemp -d "$G/root-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
root=$tmp/root
plist=$root/System/Library/xpc/launchd.plist
mkdir -p "$(dirname "$plist")"
python3 - "$plist" <<'PY'
import plistlib, sys
job = {'Label': 'com.apple.backboardd', 'EnvironmentVariables': {'DYLD_INSERT_LIBRARIES': '/usr/lib/old.dylib'}}
data = {'LaunchDaemons': {'/System/Library/LaunchDaemons/com.apple.backboardd.plist': job}}
with open(sys.argv[1], 'wb') as f: plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
PY
chmod 640 "$plist"
if NEGRONIGL=0 "$REPO/scripts/gpu/root-add-negronigl.sh" "$root" >/dev/null 2>&1; then
	echo 'installer guard failed' >&2; exit 1
fi
NEGRONIGL=1 "$REPO/scripts/gpu/root-add-negronigl.sh" "$root"
NEGRONIGL=1 "$REPO/scripts/gpu/root-add-negronigl.sh" "$root" >/dev/null
cmp "$G/negronigl.dylib" "$root/usr/lib/negronigl.dylib"
cmp "$G/libvulkan_freedreno.dylib" "$root/usr/lib/libvulkan_freedreno.dylib"
python3 - "$plist" <<'PY'
import os, plistlib, stat, sys
p = sys.argv[1]
d = plistlib.load(open(p, 'rb'))
job = d['LaunchDaemons']['/System/Library/LaunchDaemons/com.apple.backboardd.plist']
assert job['EnvironmentVariables']['DYLD_INSERT_LIBRARIES'] == '/usr/lib/old.dylib:/usr/lib/negronigl.dylib'
assert stat.S_IMODE(os.stat(p).st_mode) == 0o640
st = os.stat(p)
assert (st.st_uid, st.st_gid) == (os.getuid(), os.getgid())
print('fake-root installer check: guard, file copies, backboardd environment and plist mode passed')
PY
