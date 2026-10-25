#!/bin/sh
# Add NegroniGL.bundle (the OpenGL ES driver plugin, docs/gpu-userland.md) to a mounted, writable
# iOS 16 root. Off unless NEGRONIGL=1. Run as root (macOS or Linux); scripts/ios16/root-finish.sh
# calls it:
#   NEGRONIGL=1 scripts/gpu/root-add-negronigl.sh MOUNTED_ROOT
# Needs out/gpu/NegroniGL.bundle from scripts/gpu/build.sh (macOS). Steps (idempotent):
#  1. /System/Library/Extensions/NegroniGL.bundle (root:wheel, 755/644). libGFXShared loads it
#     for IOAcceleratorES when the kernel sets IOGLESBundleName = "NegroniGL" (patch 0205).
#  2. removes the old backboardd DYLD_INSERT_LIBRARIES=/usr/lib/negronigl.dylib entry of the
#     earlier installer, if a root has it (launchd drops DYLD_* for com.apple.* jobs anyway).
# Undo: delete System/Library/Extensions/NegroniGL.bundle (or boot without patch 0205: negronigl=0).
set -eu
R=${1:?usage: NEGRONIGL=1 $0 MOUNTED_ROOT}
if [ "${NEGRONIGL:-0}" != 1 ]; then echo "negronigl: skipped (NEGRONIGL=1 adds NegroniGL.bundle)"; exit 0; fi
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/out/gpu/NegroniGL.bundle
R=$(cd "$R" && pwd -P)
[ "$R" != / ] || { echo "refusing to install into /" >&2; exit 1; }
[ -d "$R/System/Library/xpc" ] || { echo "$R is not an iOS root" >&2; exit 1; }
[ -f "$SRC/NegroniGL" ] && [ -f "$SRC/Info.plist" ] || { echo "missing $SRC: run scripts/gpu/build.sh (macOS)" >&2; exit 1; }
[ "$(id -u)" = 0 ] || echo "warning: not root; owners stay as they are (test runs only)" >&2
own() { [ "$(id -u)" != 0 ] || chown -R 0:0 "$@"; }

# 1. the bundle
EXT=$R/System/Library/Extensions
mkdir -p "$EXT"
rm -rf "${EXT:?}/NegroniGL.bundle"
cp -R "$SRC" "$EXT/NegroniGL.bundle"
own "$EXT/NegroniGL.bundle"
find "$EXT/NegroniGL.bundle" -type d -exec chmod 755 {} +
find "$EXT/NegroniGL.bundle" -type f -exec chmod 644 {} +
chmod 755 "$EXT/NegroniGL.bundle/NegroniGL"
echo "negronigl: $EXT/NegroniGL.bundle installed"

# 2. the old backboardd injection out
python3 -I - "$R/System/Library/xpc/launchd.plist" <<'PY'
import os, plistlib, sys
path = sys.argv[1]
if not os.path.isfile(path):
    sys.exit('negronigl: no launchd.plist at %s' % path)
raw = open(path, 'rb').read()
data = plistlib.loads(raw)
job = (data.get('LaunchDaemons') or {}).get('/System/Library/LaunchDaemons/com.apple.backboardd.plist')
env = job.get('EnvironmentVariables') if isinstance(job, dict) else None
old = '/usr/lib/negronigl.dylib'
if not isinstance(env, dict) or old not in env.get('DYLD_INSERT_LIBRARIES', '').split(':'):
    print('negronigl: backboardd has no old injection')
    sys.exit(0)
parts = [p for p in env['DYLD_INSERT_LIBRARIES'].split(':') if p and p != old]
if parts:
    env['DYLD_INSERT_LIBRARIES'] = ':'.join(parts)
else:
    del env['DYLD_INSERT_LIBRARIES']
st = os.stat(path)
fmt = plistlib.FMT_BINARY if raw.startswith(b'bplist') else plistlib.FMT_XML
tmp = path + '.new'
with open(tmp, 'wb') as f:
    plistlib.dump(data, f, fmt=fmt, sort_keys=False)
os.chmod(tmp, st.st_mode & 0o7777)
if os.geteuid() == 0:
    os.chown(tmp, st.st_uid, st.st_gid)
os.replace(tmp, path)
print('negronigl: removed the old backboardd DYLD_INSERT_LIBRARIES entry')
PY
