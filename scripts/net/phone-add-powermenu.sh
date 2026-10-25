#!/bin/sh
# Install PowerMenu.app on the running phone over SSH (no new root), then register it with
# LaunchServices so SpringBoard shows it. macOS and Linux. userland/rebootapp/README.md.
#   scripts/net/phone-add-powermenu.sh                   copy app + helper + pmregister, register
#   scripts/net/phone-add-powermenu.sh --register-only   only register (the app is in /Applications)
#   scripts/net/phone-add-powermenu.sh --remove          unregister, delete app, helper and pmregister
# Needs: userland/rebootapp/build.sh output in out/powermenu; a root with SSH=1 (dropbear, toybox in
# /usr/local/bin, scripts/net/root-add-ssh.sh); iOS up with the USB network (scripts/net/ssh-phone.sh).
# The root filesystem must be writable (it is on this port: rw HFS+ root in userdata).
# Status: written 2026-10-25, NOT run on the phone yet.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=$REPO/out/powermenu
P=${SSH_PHONE:-$REPO/scripts/net/ssh-phone.sh}   # SSH_PHONE=FILE: another ssh-phone.sh (dry runs)
D=/private/var/tmp/powermenu-push
mode=${1:-install}

case $mode in
install|--register-only|--remove) ;;
*) sed -n 2,10p "$0" >&2; exit 2 ;;
esac

# Phone side. toybox applets by full path: a non-interactive SSH shell reads no .profile (no PATH).
remote_common='set -e
T=/usr/local/bin/toybox
[ -x $T ] || { echo "phone: no $T (root without SSH=1?)" >&2; exit 1; }'

if [ "$mode" = install ]; then
  for f in PowerMenu.app/PowerMenu powermenu-helper pmregister; do
    [ -x "$S/$f" ] || { echo "no $S/$f: run userland/rebootapp/build.sh first" >&2; exit 1; }
  done
  sh "$P" "/usr/local/bin/toybox rm -rf $D && /usr/local/bin/toybox mkdir -p $D"
  sh "$P" push "$S/PowerMenu.app" "$S/powermenu-helper" "$S/pmregister" "$D/"
  sh "$P" "$remote_common
D=$D
A=/Applications/PowerMenu.app
\$T rm -rf \$A.new
\$T cp -R \$D/PowerMenu.app \$A.new
\$T chown -R 0:0 \$A.new
\$T find \$A.new -type d -exec \$T chmod 755 {} \\;
\$T find \$A.new -type f -exec \$T chmod 644 {} \\;
\$T chmod 755 \$A.new/PowerMenu
\$T rm -rf \$A
\$T mv \$A.new \$A
\$T mkdir -p /usr/local/libexec
H=/usr/local/libexec/powermenu-helper
\$T cp \$D/powermenu-helper \$H.new
\$T chown 0:501 \$H.new
\$T chmod 4750 \$H.new
\$T mv \$H.new \$H
\$T cp \$D/pmregister /usr/local/bin/pmregister.new
\$T chown 0:0 /usr/local/bin/pmregister.new
\$T chmod 755 /usr/local/bin/pmregister.new
\$T mv /usr/local/bin/pmregister.new /usr/local/bin/pmregister
\$T rm -rf \$D
\$T ls -l \$H /usr/local/bin/pmregister
echo phone: installed \$A"
fi

if [ "$mode" = --remove ]; then
  sh "$P" "$remote_common
/usr/local/bin/pmregister -u /Applications/PowerMenu.app || true
\$T rm -rf /Applications/PowerMenu.app /usr/local/libexec/powermenu-helper /usr/local/bin/pmregister
echo phone: PowerMenu removed"
  exit 0
fi

# Register, then the helper's self-check (as root: caller ok; says if the kernel can select the bootloader).
sh "$P" "$remote_common
/usr/local/bin/pmregister /Applications/PowerMenu.app
/usr/local/libexec/powermenu-helper check || echo 'phone: helper check exit' \$?"
echo "If the icon does not show on the home screen within a few seconds: reboot the phone"
echo "  (scripts/net/ssh-phone.sh reboot -f); the registration stays in the app database."
