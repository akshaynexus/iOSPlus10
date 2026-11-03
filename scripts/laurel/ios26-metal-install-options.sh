#!/bin/sh
# Mi A3 iOS 26: the three Metal stacks on a running writable root, with no flash; route B of docs/laurel_sprout/ios26-native-metal.md section 11.7. Owner's yes first.
#   scripts/laurel/ios26-metal-install-options.sh [default|hot|native]         the setting; default of this script: native
#   NO_RESTART=1 ...      the setting acts at the next start of the UI
# Each file: written as NAME.new, read back by SHA-256, then moved over NAME. The stacks go first and the selector last: the selector needs options/default.
# Fallback to `default` is the selector's: no frame in 240 s, 30 s black, no device, 2 starts with no lit screen, or a GPU hang (a GPU hang also needs a reboot).
set -eu
cd "$(dirname "$0")/../.."
OPT=${1:-native}
case "$OPT" in default|hot|native) ;; *) echo "metal-install: $OPT: default, hot or native"; exit 2 ;; esac
HOST=root@192.168.7.2
B=/System/Library/Extensions/NegroniMetal.bundle
S=out/ios26/metal-all/stage$B
say() { echo "$(date +%H:%M:%S) metal-install: $*"; }
die() { say "STOP: $*"; exit 1; }
sh_phone() { sshpass -p "${IOS_PASSWORD:-alpine}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 "$HOST" "$@"; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
[ -s "$S/NegroniMetal" ] && [ -s "$S/options/default/NegroniMetal" ] && [ -s "$S/options/native/NegroniMetal" ] || die "no stage: scripts/laurel/ios26-metal-options.sh"
python3 -I scripts/ios26/abi-check.py out/ios26/metal-all/stage > /dev/null || die "the stage fails abi-check"
[ "$(sh_phone uname -s)" = Darwin ] || die "no iOS on SSH"
put() {
  _rel=$1; _mode=$2; _dst=$B/$_rel
  _want=$(sha "$S/$_rel")
  if [ "$(sh_phone "sha256sum '$_dst' 2>/dev/null" | cut -d' ' -f1)" = "$_want" ]; then say "same: $_rel"; return 0; fi
  sh_phone "mkdir -p \"\$(dirname '$_dst')\"; cat > '$_dst.new'" < "$S/$_rel"
  [ "$(sh_phone "sha256sum '$_dst.new'" | cut -d' ' -f1)" = "$_want" ] || die "$_rel does not read back the same"
  sh_phone "chown 0:0 '$_dst.new' && chmod $_mode '$_dst.new' && mv -f '$_dst.new' '$_dst'"
  say "written: $_rel"
}
# Stacks and what they load, then the Info.plist, then the selector.
for f in $(cd "$S" && find options -type f | sort); do
  case "$f" in */NegroniMetal|*.dylib) put "$f" 755 ;; *) put "$f" 644 ;; esac
done
[ ! -s "$S/libvulkan_freedreno.dylib" ] || put libvulkan_freedreno.dylib 755
put Info.plist 644
put NegroniMetal 755
sh_phone "echo $OPT > /private/var/db/negronimetal/option; echo $OPT > $B/option.local; chmod 644 /private/var/db/negronimetal/option $B/option.local; mkdir -p /private/var/db/negronimetal/stack; : > /private/var/db/negronimetal/stack/state; sync"
say "setting: $OPT"
if [ "${NO_RESTART:-0}" = 1 ]; then say "done: no restart"; exit 0; fi
sh_phone 'p=; for w in $(ps -ax -o pid=,comm= | grep "/backboardd$"); do p=$w; break; done; [ -n "$p" ] && kill -9 "$p"' || die "no backboardd to restart"
say "done: the UI restarts. Read: LAUREL METAL: on: stack ..., LAUREL METAL26: on: stack ..., LAUREL METAL NATIVE: off: ..."
