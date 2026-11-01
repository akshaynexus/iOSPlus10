#!/bin/bash
# XNUtils as a system app in the Mi A3 iOS 16 root (docs/laurel_sprout/xnutils.md). root.sh calls it; XNUTILS=0 skips.
#   sudo scripts/laurel/root-xnutils.sh MOUNTED_ROOT
# Input: out/laurel/xnutils/root from scripts/laurel/xnutils-build.sh (built here if missing; no toolchain = a warning, the root goes on).
# Installs:
#   /Applications/XNUtils.app                 root:wheel, folders 755, files 644, the executable 755
#   /usr/local/libexec/powermenu-helper       root:mobile (0:501), 4750: setuid root, group mobile only. chown first: chown clears the bit
#   /usr/local/bin/pmregister                 root:wheel 755: LaunchServices register tool for a root that already booted
# Registration, no Setup step: a new root (root.sh makes one each time) has no LaunchServices store and no LastBuildInfo.plist, so lsd's
# first seed registers every app in /Applications, the 32 apps of root-system-features.py too. The app has platform-application and
# no-container, as installd wants of a system app. A root that booted before keeps its store: then one line says what to run.
# Writes nothing under /private/var. Undo: XNUTILS=0 root, or remove the three paths.
set -euo pipefail
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=$REPO/out/laurel/xnutils/root
ts() { date +%H:%M:%S; }
if [ "${XNUTILS:-1}" = 0 ]; then echo "$(ts) root-xnutils: skipped (XNUTILS=0)"; exit 0; fi
[ -d "$R/Applications" ] && [ -f "$R/System/Library/xpc/launchd.plist" ] || { echo "root-xnutils: $R is not an iOS root" >&2; exit 1; }
if [ ! -x "$S/Applications/XNUtils.app/XNUtils" ]; then
  if [ -n "${SUDO_USER:-}" ]; then b() { sudo -u "$SUDO_USER" "$REPO/scripts/laurel/xnutils-build.sh"; }; else b() { "$REPO/scripts/laurel/xnutils-build.sh"; }; fi
  if ! b || [ ! -x "$S/Applications/XNUtils.app/XNUtils" ]; then
    echo "$(ts) root-xnutils: WARNING: XNUtils could not be built (theos toolchain/SDK: scripts/laurel/kernel-linux.sh once); no XNUtils in this root" >&2
    exit 0
  fi
fi
root=1
[ "$(id -u)" = 0 ] || { root=0; echo "$(ts) root-xnutils: note: not root: owners and the setuid bit stay out (a dry run)"; }
own() { [ $root = 0 ] || chown "$@"; }
newdir() { # REL: new folders get root:wheel 755
  local p=$R part
  for part in $(echo "$1" | tr '/' ' '); do
    p=$p/$part
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then mkdir "$p"; own 0:0 "$p"; chmod 755 "$p"; fi
  done
}

A=$R/Applications/XNUtils.app
rm -rf "$A.new"
cp -R "$S/Applications/XNUtils.app" "$A.new"
own -R 0:0 "$A.new"
find "$A.new" -type d -exec chmod 755 {} +
find "$A.new" -type f -exec chmod 644 {} +
chmod 755 "$A.new/XNUtils"
rm -rf "$A"
mv "$A.new" "$A"
newdir usr/local/libexec
H=$R/usr/local/libexec/powermenu-helper
cp "$S/usr/local/libexec/powermenu-helper" "$H.new"
own 0:501 "$H.new"
if [ $root = 1 ]; then chmod 4750 "$H.new"; else chmod 750 "$H.new"; fi
mv "$H.new" "$H"
newdir usr/local/bin
P=$R/usr/local/bin/pmregister
cp "$S/usr/local/bin/pmregister" "$P.new"
own 0:0 "$P.new"
chmod 755 "$P.new"
mv "$P.new" "$P"
if [ -n "$(find "$R/private/var/containers/Data/System" -maxdepth 4 -name 'com.apple.LaunchServices*.csstore' 2>/dev/null | head -1)" ] ||
   [ -f "$R/private/var/mobile/Library/MobileInstallation/LastBuildInfo.plist" ]; then
  echo "$(ts) root-xnutils: WARNING: this root booted before: register on the phone: pmregister /Applications/XNUtils.app" >&2
else
  echo "$(ts) root-xnutils: new root: the first LaunchServices seed registers /Applications/XNUtils.app"
fi
echo "$(ts) root-xnutils: on: /Applications/XNUtils.app, /usr/local/libexec/powermenu-helper (root:mobile 4750), /usr/local/bin/pmregister"
