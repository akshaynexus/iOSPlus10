#!/bin/sh
# Mi A3 iOS 26: the three Metal stacks on a running writable root, with no flash; route B of docs/laurel_sprout/ios26-native-metal.md section 11.7. Owner's yes first.
#   scripts/laurel/ios26-metal-install-options.sh [default|hot|native]         the setting; default of this script: native
#   NO_RESTART=1 ...      the setting acts at the next start of the UI
# Each file: written as NAME.new, read back by SHA-256, then moved over NAME. The stacks go first and the selector last: the selector needs options/default.
# Fallback to `default` is the selector's: no frame in 240 s, 30 s black, no device, 2 starts with no lit screen, or a GPU hang (a GPU hang also needs a reboot). The fallback holds across reboots for that build (option_store.h).
#   ONLY_NATIVE=1 ...     of the stacks only options/native: the phone keeps the default stack another agent installed (this tree's copy can be older)
#   RESET_FAILED=1 ...    the owner's reset: try a build again that already failed. Without it this script does not remove a failed mark; a new build needs no reset.
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
if [ "${ONLY_NATIVE:-0}" = 1 ]; then
  # 2026-11-07: a root with the old one-stack layout has the default stack as the bundle's own NegroniMetal and no options/default: the selector
  # written over it left no Metal at all after a native hang. ONLY_NATIVE needs a phone that already has the selector layout.
  sh_phone "test -s $B/options/default/NegroniMetal" || die "the phone has no options/default (one-stack root): run this script without ONLY_NATIVE first"
  put options/native/NegroniMetal 755
else
  for f in $(cd "$S" && find options -type f | sort); do
    case "$f" in */NegroniMetal|*.dylib) put "$f" 755 ;; *) put "$f" 644 ;; esac
  done
  [ ! -s "$S/libvulkan_freedreno.dylib" ] || put libvulkan_freedreno.dylib 755
  put Info.plist 644
fi
put NegroniMetal 755
# As root this script must not create a file in stack/: backboardd runs as mobile, the sticky bit then stops every write (06:49: `: > state` here made the fallback forget its count at each reboot). Remove, and let the compositor create them.
K=/private/var/db/negronimetal/stack
sh_phone "echo $OPT > /private/var/db/negronimetal/option; echo $OPT > $B/option.local; chmod 644 /private/var/db/negronimetal/option $B/option.local; mkdir -p $K; chown 0:0 $K; chmod 1777 $K; rm -f $K/state $K/ok $K/failed; sync"
if [ "${RESET_FAILED:-0}" = 1 ]; then
  sh_phone "rm -f $K/failed-hot $K/failed-native; sync"
  say "reset: the failed marks are gone"
else
  M=$(sh_phone "cat $K/failed-$OPT 2>/dev/null" || true)
  [ -z "$M" ] || say "failed mark of $OPT: $M. The same build stays off (RESET_FAILED=1 tries it again); a new build takes no notice of it"
fi
say "setting: $OPT"
if [ "${NO_RESTART:-0}" = 1 ]; then say "done: no restart"; exit 0; fi
sh_phone 'p=; for w in $(ps -ax -o pid=,comm= | grep "/backboardd$"); do p=$w; break; done; [ -n "$p" ] && kill -9 "$p"' || die "no backboardd to restart"
say "done: the UI restarts. Read: LAUREL METAL: on: stack ..., LAUREL METAL26: on: stack ..., LAUREL METAL NATIVE: off: ..."
