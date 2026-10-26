#!/bin/sh
# Install XNUtils.app (dev.iosplus10.xnutils; the old name was PowerMenu.app, dev.iosplus10.powermenu)
# on the running phone over SSH (no new root), then register it with LaunchServices so SpringBoard
# shows it. macOS and Linux. userland/rebootapp/README.md.
#   scripts/net/phone-add-powermenu.sh                   copy app + helper + pmregister, register
#   scripts/net/phone-add-powermenu.sh --register-only   only (re-)register (the app is in /Applications)
#   scripts/net/phone-add-powermenu.sh --remove          unregister, delete app, helper and pmregister
# Every mode first unregisters and deletes the old /Applications/PowerMenu.app (pmregister -u).
# Use --register-only after a root-update of a root that booted before: its app database still
# lists PowerMenu.app.
# Needs: userland/rebootapp/build.sh output in out/powermenu; a root with SSH=1 (dropbear, toybox in
# /usr/local/bin, scripts/net/root-add-ssh.sh); iOS up with the USB network (scripts/net/ssh-phone.sh).
# The root filesystem must be writable (it is on this port: rw HFS+ root in userdata).
# Status: written 2026-10-25 (XNUtils rename 2026-10-27), NOT run on the phone yet.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=$REPO/out/powermenu
P=${SSH_PHONE:-$REPO/scripts/net/ssh-phone.sh}   # SSH_PHONE=FILE: another ssh-phone.sh (dry runs)
D=/private/var/tmp/powermenu-push
mode=${1:-install}

case $mode in
install|--register-only|--remove) ;;
*) sed -n 2,14p "$0" >&2; exit 2 ;;
esac
APP=XNUtils      # CFBundleExecutable in userland/rebootapp/Info.plist
OLD=PowerMenu    # the old app name

# Phone side. toybox applets by full path: a non-interactive SSH shell reads no .profile (no PATH).
# The old app: unregister while its folder is still there (unregisterApplication: takes its URL),
# then delete it. Needs pmregister on the phone (install mode pushes it first).
remote_common="set -e
T=/usr/local/bin/toybox
[ -x \$T ] || { echo 'phone: no '\$T' (root without SSH=1?)' >&2; exit 1; }
if [ -x /usr/local/bin/pmregister ]; then /usr/local/bin/pmregister -u /Applications/$OLD.app || true; fi
if [ -e /Applications/$OLD.app ]; then \$T rm -rf /Applications/$OLD.app; echo phone: removed /Applications/$OLD.app; fi"

if [ "$mode" = install ]; then
  for f in $APP.app/$APP powermenu-helper pmregister; do
    [ -x "$S/$f" ] || { echo "no $S/$f: run userland/rebootapp/build.sh first" >&2; exit 1; }
  done
  sh "$P" "/usr/local/bin/toybox rm -rf $D && /usr/local/bin/toybox mkdir -p $D"
  sh "$P" push "$S/$APP.app" "$S/powermenu-helper" "$S/pmregister" "$D/"
  # pmregister first, so that remote_common can unregister the old app with it.
  sh "$P" "T=/usr/local/bin/toybox
\$T cp $D/pmregister /usr/local/bin/pmregister.new
\$T chown 0:0 /usr/local/bin/pmregister.new
\$T chmod 755 /usr/local/bin/pmregister.new
\$T mv /usr/local/bin/pmregister.new /usr/local/bin/pmregister"
  sh "$P" "$remote_common
D=$D
A=/Applications/$APP.app
\$T rm -rf \$A.new
\$T cp -R \$D/$APP.app \$A.new
\$T chown -R 0:0 \$A.new
\$T find \$A.new -type d -exec \$T chmod 755 {} \\;
\$T find \$A.new -type f -exec \$T chmod 644 {} \\;
\$T chmod 755 \$A.new/$APP
\$T rm -rf \$A
\$T mv \$A.new \$A
\$T mkdir -p /usr/local/libexec
H=/usr/local/libexec/powermenu-helper
\$T cp \$D/powermenu-helper \$H.new
\$T chown 0:501 \$H.new
\$T chmod 4750 \$H.new
\$T mv \$H.new \$H
\$T rm -rf \$D
\$T ls -l \$H /usr/local/bin/pmregister
echo phone: installed \$A"
fi

if [ "$mode" = --remove ]; then
  sh "$P" "$remote_common
/usr/local/bin/pmregister -u /Applications/$APP.app || true
\$T rm -rf /Applications/$APP.app /usr/local/libexec/powermenu-helper /usr/local/bin/pmregister
echo phone: $APP removed"
  exit 0
fi

# Register, then the helper's self-check (as root: caller ok; says if the kernel can select the bootloader).
sh "$P" "$remote_common
/usr/local/bin/pmregister /Applications/$APP.app
/usr/local/libexec/powermenu-helper check || echo 'phone: helper check exit' \$?"
echo "If the icon does not show on the home screen within a few seconds: reboot the phone"
echo "  (scripts/net/ssh-phone.sh reboot -f); the registration stays in the app database."
