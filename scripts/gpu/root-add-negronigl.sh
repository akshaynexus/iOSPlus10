#!/bin/sh
# Install the built GPU libraries into a mounted iOS root. This only edits that root when explicitly
# enabled: NEGRONIGL=1 scripts/gpu/root-add-negronigl.sh MOUNTED_ROOT
set -eu
[ "${NEGRONIGL:-0}" = 1 ] || { echo 'set NEGRONIGL=1 to enable installation' >&2; exit 2; }
[ "$#" = 1 ] || { echo "usage: NEGRONIGL=1 $0 MOUNTED_ROOT" >&2; exit 2; }
ROOT=$(cd "$1" && pwd -P)
[ "$ROOT" != / ] || { echo 'refusing to install into /' >&2; exit 2; }
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
GL=$G/negronigl.dylib
VK=$G/libvulkan_freedreno.dylib
[ -s "$GL" ] && [ -s "$VK" ] || { echo 'run scripts/gpu/build.sh first' >&2; exit 1; }
PLIST=$ROOT/System/Library/xpc/launchd.plist
[ -f "$PLIST" ] || { echo "missing launchd database: $PLIST" >&2; exit 1; }

install -d -m 755 "$ROOT/usr/lib/vulkan/icd.d"
install -m 755 "$GL" "$ROOT/usr/lib/negronigl.dylib"
install -m 755 "$VK" "$ROOT/usr/lib/libvulkan_freedreno.dylib"
cat > "$ROOT/usr/lib/vulkan/icd.d/freedreno_icd.json" <<'EOF'
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "/usr/lib/libvulkan_freedreno.dylib",
    "api_version": "1.3.296"
  }
}
EOF
chmod 644 "$ROOT/usr/lib/vulkan/icd.d/freedreno_icd.json"

python3 - "$PLIST" <<'PY'
import os, plistlib, stat, sys, tempfile
path = sys.argv[1]
st = os.stat(path, follow_symlinks=False)
with open(path, 'rb') as f:
    raw = f.read()
data = plistlib.loads(raw)
jobs = data.get('LaunchDaemons')
key = '/System/Library/LaunchDaemons/com.apple.backboardd.plist'
job = jobs.get(key) if isinstance(jobs, dict) else None
if not isinstance(job, dict) or job.get('Label') != 'com.apple.backboardd':
    raise SystemExit('launchd.plist has no matching backboardd job entry')
env = job.setdefault('EnvironmentVariables', {})
if not isinstance(env, dict):
    raise SystemExit('backboardd EnvironmentVariables is not a dictionary')
inject = '/usr/lib/negronigl.dylib'
existing = env.get('DYLD_INSERT_LIBRARIES', '')
parts = [p for p in existing.split(':') if p]
if inject not in parts:
    parts.append(inject)
env['DYLD_INSERT_LIBRARIES'] = ':'.join(parts)
fmt = plistlib.FMT_BINARY if raw.startswith(b'bplist') else plistlib.FMT_XML
blob = plistlib.dumps(data, fmt=fmt, sort_keys=False)
fd, tmp = tempfile.mkstemp(prefix='.launchd.plist.', dir=os.path.dirname(path))
try:
    with os.fdopen(fd, 'wb') as f:
        f.write(blob)
    os.chmod(tmp, stat.S_IMODE(st.st_mode))
    try: os.chown(tmp, st.st_uid, st.st_gid)
    except PermissionError: pass
    os.replace(tmp, path)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
PY
echo "installed negronigl and Turnip under $ROOT/usr/lib; launchd backboardd injection updated"
