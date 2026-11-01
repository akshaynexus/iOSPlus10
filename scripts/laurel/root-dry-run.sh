#!/bin/bash
# Dry run of the Mi A3 root tweaks on a copy of the stock image's job and app files, as the user (no sudo, no loop mount, no phone).
#   scripts/bg.sh sysf-dry scripts/laurel/root-dry-run.sh
# Copies launchd.plist, the job plists, the staged apps, the placeholders, the preferences and the InterfaceNamer plist from the
# OS DMG ($APPLE/20H392/087-86698-044.dmg through apfs-fuse; macOS or a mounted image: ROOT_SRC=DIR holding the OS root) to
# out/laurel-root-dry/root, runs topaz sweet-root-tweaks.py, root-tweaks-extra.py, root-tweaks-perf.py, root-system-features.py
# and bt-launchd.py on it in the order of root.sh (chown off: the user cannot make 0 or 501 files), then checks the result:
# the job list against the expected list in docs/laurel_sprout/system-features.md, 32 apps moved, no staged app left, the
# aggregated job and its limit, then root-xnutils.sh when XNUtils is built. Exit 0 = PASS. It does not build a root: that is `sudo scripts/laurel/root.sh`.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
APPLE=${APPLE:-$HOME/op10-apple}
W=$REPO/out/laurel-root-dry
R=$W/root
TOPAZ=$REPO/external/ios-topaz/tools
[ -f "$TOPAZ/sweet-root-tweaks.py" ] || { echo "root-dry-run: missing external/ios-topaz (scripts/setup/get-references.sh ios-topaz)" >&2; exit 1; }
rm -rf "$W"
mkdir -p "$R" "$W/mnt"
SRC=${ROOT_SRC:-}
if [ -z "$SRC" ]; then
  command -v apfs-fuse >/dev/null || { echo "root-dry-run: no apfs-fuse: mount the OS DMG and set ROOT_SRC" >&2; exit 1; }
  ln -s "$APPLE/20H392/087-86698-044.dmg" "$W/os.dmg"     # apfs-fuse parses UDIF only for a name ending in .dmg
  apfs-fuse -o ro "$W/os.dmg" "$W/mnt"
  trap 'fusermount3 -u "$W/mnt" 2>/dev/null || umount "$W/mnt" 2>/dev/null || true' EXIT
  SRC=$W/mnt/root
fi
[ -f "$SRC/System/Library/xpc/launchd.plist" ] || { echo "root-dry-run: $SRC is not an iOS root" >&2; exit 1; }

for d in System/Library/xpc System/Library/LaunchDaemons System/Library/AppPlaceholders private/var/staged_system_apps \
         private/var/mobile/Library/Preferences System/Library/SystemConfiguration/InterfaceNamer.bundle; do
  mkdir -p "$R/$(dirname "$d")"
  cp -R "$SRC/$d" "$R/$(dirname "$d")/" 2>/dev/null || echo "root-dry-run: note: /$d not copied"
done
# the 141 stock app folders by name only (the copy needs the count, not their files)
mkdir -p "$R/Applications" "$R/private/var/containers"
for a in "$SRC"/Applications/*.app; do mkdir -p "$R/Applications/$(basename "$a")"; done
chmod -R u+w "$R"
stock_apps=$(ls "$R/Applications" | wc -l)

run() { python3 -I -c 'import os, runpy, sys; os.chown = lambda *a, **k: None; sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")' "$@"; }
run "$TOPAZ/sweet-root-tweaks.py" "$R"
CA_HEARTBEAT=60 run "$REPO/scripts/ios16/root-tweaks-extra.py" "$R"
run "$REPO/scripts/laurel/root-tweaks-perf.py" "$R"
run "$REPO/scripts/laurel/root-system-features.py" "$R"
run "$REPO/scripts/bt/bt-launchd.py" "$R/System/Library/xpc/launchd.plist" on "$R/System/Library/LaunchDaemons/com.apple.bluetoothd.plist"

python3 -I - "$SRC" "$R" "$stock_apps" <<'EOF'
import os, plistlib, sys
src, r, stock_apps = sys.argv[1], sys.argv[2], int(sys.argv[3])
load = lambda p: plistlib.load(open(p, 'rb'))
old = load(src + '/System/Library/xpc/launchd.plist')['LaunchDaemons']
new = load(r + '/System/Library/xpc/launchd.plist')['LaunchDaemons']
gone = sorted(k.split('/')[-1][:-6] for k in set(old) - set(new))
added = sorted(k.split('/')[-1][:-6] for k in set(new) - set(old))
EXPECT_OFF = sorted(['com.apple.CommCenter', 'com.apple.CommCenter-noncellular', 'com.apple.ReportCrash', 'com.apple.activityawardsd',
                     'com.apple.aggregated.addaily', 'com.apple.fairplayd.H2', 'com.apple.spindump', 'com.apple.tailspind',
                     'com.apple.voicemail.vmd', 'com.apple.nanotimekitcompaniond', 'com.apple.wifip2pd', 'com.apple.syncdefaultsd'])
fail = []
print(f'jobs: stock {len(old)}, now {len(new)}; off: {" ".join(gone)}; added: {" ".join(added) or "none"}')
if gone != EXPECT_OFF:
    fail.append(f'off list differs: extra {sorted(set(gone) - set(EXPECT_OFF))}, missing {sorted(set(EXPECT_OFF) - set(gone))}')
if '/System/Library/LaunchDaemons/com.apple.aggregated.plist' not in new:
    fail.append('no aggregated job')
lim = load(r + '/System/Library/LaunchDaemons/com.apple.jetsamproperties.D22.plist')['Version4']['Daemon']['Override']['com.apple.aggregated']
print('aggregated limits (D22):', lim)
if lim.get('InactiveHardMemoryLimit') != 32:
    fail.append('aggregated limit not 32 MiB')
apps = [a for a in os.listdir(r + '/Applications') if a.endswith('.app')]
staged = os.listdir(r + '/private/var/staged_system_apps')
print(f'apps: {stock_apps} stock + {len(apps) - stock_apps} moved = {len(apps)}; left in staged_system_apps: {len(staged)}; placeholders left: {len(os.listdir(r + "/System/Library/AppPlaceholders"))}')
if len(apps) - stock_apps != 32 or staged:
    fail.append('staged apps not all moved')
for a in ('MobileCal', 'MobileMail', 'MobileNotes', 'MobileTimer', 'Weather', 'Maps'):
    if not os.path.isfile(f'{r}/Applications/{a}.app/Info.plist'):
        fail.append(f'{a}.app has no Info.plist')
print('root-dry-run:', 'jobs + apps PASS' if not fail else 'FAIL: ' + '; '.join(fail))
sys.exit(1 if fail else 0)
EOF
# XNUtils (root-xnutils.sh), when it is built. As the user: no owners, no setuid bit (the script says so).
if [ -x "$REPO/out/laurel/xnutils/root/Applications/XNUtils.app/XNUtils" ]; then
  bash "$REPO/scripts/laurel/root-xnutils.sh" "$R"
  python3 -I - "$R" <<'EOF'
import os, plistlib, stat, sys
r = sys.argv[1]; a = r + '/Applications/XNUtils.app'
info = plistlib.load(open(a + '/Info.plist', 'rb'))
ok = (info['CFBundleIdentifier'] == 'dev.iosplus10.xnutils' and os.access(a + '/XNUtils', os.X_OK) and os.path.isfile(a + '/AppIcon60x60@2x.png')
      and os.path.isfile(r + '/usr/local/libexec/powermenu-helper') and os.access(r + '/usr/local/bin/pmregister', os.X_OK)
      and not os.path.exists(a + '.new') and stat.S_IMODE(os.stat(a + '/Info.plist').st_mode) == 0o644)
print('root-dry-run: XNUtils', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
EOF
else
  echo "root-dry-run: XNUtils: note: not built (scripts/laurel/xnutils-build.sh)"
fi
echo "root-dry-run: PASS"
