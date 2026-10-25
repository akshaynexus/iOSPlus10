#!/bin/sh
# Add PowerMenu.app (Reboot to Bootloader / Restart / Shut Down) and its setuid-root helper to a
# mounted, writable iOS 16 root. Off unless POWERMENU=1 (root-finish.sh sets it when
# out/powermenu/PowerMenu.app is built). Run as root (macOS or Linux) so that the owners are right:
#   POWERMENU=1 scripts/ios16/root-add-powermenu.sh MOUNTED_ROOT
# Input: out/powermenu from userland/rebootapp/build.sh. Installs:
#   /Applications/PowerMenu.app                 root:wheel, folders 755, files 644, executable 755
#   /usr/local/libexec/powermenu-helper         root:mobile (0:501), 4750 (setuid root, group mobile only)
# Registration: none needed in a new root. A new root has no LaunchServices database and no
# /var/mobile/Library/MobileInstallation/LastBuildInfo.plist, so the first boot registers every
# app in /Applications (as for the stock apps and the staged apps that root-finish.sh moves there).
# A root that booted before keeps its database: then register on the phone with
# scripts/net/phone-add-powermenu.sh (pmregister). Details: userland/rebootapp/README.md.
# Writes nothing under /var or /private/var (the var -> private/var symlink stays as it is).
set -eu
R=${1:?usage: POWERMENU=1 $0 MOUNTED_ROOT}
if [ "${POWERMENU:-0}" != 1 ]; then echo "powermenu: skipped (POWERMENU=1 adds PowerMenu.app + its helper)"; exit 0; fi
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=$REPO/out/powermenu
[ -d "$R/Applications" ] && [ -f "$R/System/Library/xpc/launchd.plist" ] || { echo "$R does not look like an iOS root" >&2; exit 1; }
[ -x "$S/PowerMenu.app/PowerMenu" ] && [ -x "$S/powermenu-helper" ] || { echo "no $S/PowerMenu.app or powermenu-helper: run userland/rebootapp/build.sh first" >&2; exit 1; }
root=1
[ "$(id -u)" = 0 ] || { root=0; echo "warning: not root; owners stay as they are (test runs only)" >&2; }
own() { [ $root = 1 ] && chown "$@" || true; }
newdir() { # REL: create ROOT/REL; new folders get root:wheel 755
  p=$R
  for part in $(echo "$1" | tr '/' ' '); do
    p=$p/$part
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then mkdir "$p"; own 0:0 "$p"; chmod 755 "$p"; fi
  done
}

# 1. the app (copy next to it, then swap: a failed copy leaves the old app in place)
A=$R/Applications/PowerMenu.app
rm -rf "$A.new"
cp -R "$S/PowerMenu.app" "$A.new"
own -R 0:0 "$A.new"
find "$A.new" -type d -exec chmod 755 {} +
find "$A.new" -type f -exec chmod 644 {} +
chmod 755 "$A.new/PowerMenu"
rm -rf "$A" && mv "$A.new" "$A"
echo "powermenu: installed /Applications/PowerMenu.app ($(plutil -extract CFBundleIdentifier raw "$A/Info.plist" 2>/dev/null ||
  sed -n '/CFBundleIdentifier/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$A/Info.plist"))"

# 2. the helper. chown before chmod: chown clears the setuid bit on Linux.
newdir usr/local/libexec
H=$R/usr/local/libexec/powermenu-helper
cp "$S/powermenu-helper" "$H.new"
own 0:501 "$H.new"
chmod 4750 "$H.new"
mv "$H.new" "$H"
echo "powermenu: installed /usr/local/libexec/powermenu-helper (root:mobile 4750)"

# 3. registration: a root that booted before has a LaunchServices database; it does not see new apps.
db=$(find "$R/private/var/containers/Data/System" -maxdepth 4 -name 'com.apple.LaunchServices*.csstore' 2>/dev/null | head -1)
if [ -n "$db" ] || [ -f "$R/private/var/mobile/Library/MobileInstallation/LastBuildInfo.plist" ]; then
  echo "warning: this root booted before (app database present): register the app on the phone with" >&2
  echo "  scripts/net/phone-add-powermenu.sh --register-only" >&2
else
  echo "powermenu: new root (no app database yet): the first boot registers /Applications/PowerMenu.app"
fi
