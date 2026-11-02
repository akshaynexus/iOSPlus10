#!/bin/sh
# Mi A3 iOS 26: new userland files on a running writable root, over SSH on USB, with no new root image and no flash.
#   scripts/laurel/ios26-live-update.sh           plug-in, XNUtils + helper, top bar library; the root's Metal list; restart of the UI
#   scripts/laurel/ios26-live-update.sh --check   only compares the files on the phone with the local builds
#   NO_RESTART=1 ...                              no restart of the UI: the files act at the next boot (the jetsam limits always do)
# A write to the iOS root: ask the owner first. Needs a boot with the rw image (scripts/laurel/ios26-retry.sh rw) and 192.168.7.1 on this computer (make usblog).
# Each file: written as NAME.new, read back by SHA-256, then moved over NAME, so a broken copy never replaces a good file. It stops at the first failure.
# The next root build has the same files: scripts/laurel/ios26-parity-build.sh, scripts/laurel/ios26-metal-build.sh, FORCE=1 scripts/laurel/ios26-root.sh.
set -eu
cd "$(dirname "$0")/../.."
HOST=root@192.168.7.2
LIST="* -chronod -cameracaptured -WidgetRenderer_Default -PosterBoard"   # scripts/laurel/root-add-metal-ios26.sh
say() { echo "$(date +%H:%M:%S) live-update: $*"; }
die() { say "STOP: $*"; exit 1; }
sh_phone() { sshpass -p "${IOS_PASSWORD:-alpine}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 "$HOST" "$@"; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# local file | path on the phone | owner | mode
FILES='out/ios26/metal/stage/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal|/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal|0:0|755
out/ios26/metal/stage/System/Library/Extensions/NegroniMetal.bundle/libvulkan_freedreno.dylib|/System/Library/Extensions/NegroniMetal.bundle/libvulkan_freedreno.dylib|0:0|755
out/ios26/xnutils/root/Applications/XNUtils.app/XNUtils|/Applications/XNUtils.app/XNUtils|0:0|755
out/ios26/xnutils/root/usr/local/libexec/powermenu-helper|/usr/local/libexec/powermenu-helper|0:501|4750
out/laurel/notch/root/usr/local/lib/liblaurel-notch.dylib|/usr/local/lib/liblaurel-notch.dylib|0:0|755
out/ios26/live-jetsam.plist|/System/Library/LaunchDaemons/com.apple.jetsamproperties.N104.plist|0:0|644'

phone_sha() { sh_phone "shasum -a 256 '$1' 2>/dev/null || sha256sum '$1' 2>/dev/null" | cut -d' ' -f1; }

old_ifs=$IFS
check_only=0; [ "${1:-}" != --check ] || check_only=1
[ "$(sh_phone uname -s 2>/dev/null)" = Darwin ] || die "no iOS on SSH at $HOST"
if [ $check_only = 0 ]; then
  sh_phone 'touch /private/var/db/.laurel-rw && rm /private/var/db/.laurel-rw && touch /System/.laurel-rw && rm /System/.laurel-rw' || die "the root is not writable: boot the rw image"
  python3 -I scripts/ios26/abi-check.py out/ios26/metal/stage > /dev/null || die "the plug-in fails scripts/ios26/abi-check.py"
fi
# The jetsam limits: the phone's plist + JETSAM_FLOORS of the root spec, the same rule as a root build. Only raises a limit.
JET=/System/Library/LaunchDaemons/com.apple.jetsamproperties.N104.plist
JET_OUT=out/ios26/live-jetsam.plist
mkdir -p out/ios26
sh_phone "cat '$JET'" > "$JET_OUT.phone"
python3 -I - "$JET_OUT.phone" "$JET_OUT" <<'PY'
import importlib.util, plistlib, sys
spec = importlib.util.spec_from_file_location('rootspec', 'scripts/laurel/ios26-root-spec.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = plistlib.load(open(sys.argv[1], 'rb'))
old = plistlib.dumps(d, fmt=plistlib.FMT_BINARY)
v4 = d.get('Version4')
if not isinstance(v4, dict): sys.exit('no Version4 in the plist')
for sec, names in m.JETSAM_FLOORS.items():
    over = v4.setdefault(sec, {}).setdefault('Override', {})
    for name, floors in names.items():
        e = over.setdefault(name, {})
        for k, mb in floors.items():
            if not isinstance(e.get(k), int) or e[k] < mb:
                print(f'jetsam: {name} {k} {e.get(k)} -> {mb}')
                e[k] = mb
open(sys.argv[2], 'wb').write(plistlib.dumps(d, fmt=plistlib.FMT_BINARY))
PY
differ=0
IFS='
'
for line in $FILES; do
  IFS='|'; set -- $line; IFS='
'
  src=$1 dst=$2 own=$3 mode=$4
  [ -s "$src" ] || die "no local $src"
  want=$(sha "$src")
  have=$(phone_sha "$dst")
  if [ "$want" = "$have" ]; then say "same: $dst"; continue; fi
  differ=$((differ + 1))
  say "differs: $dst"
  [ $check_only = 0 ] || continue
  sh_phone "cat > '$dst.new'" < "$src"
  [ "$(phone_sha "$dst.new")" = "$want" ] || die "the copy of $dst does not read back the same"
  # chown first: chown clears the setuid bit
  sh_phone "chown $own '$dst.new' && chmod $mode '$dst.new' && mv -f '$dst.new' '$dst'"
  say "written: $dst"
done
IFS=$old_ifs
if [ $check_only = 1 ]; then say "$differ file(s) differ"; exit 0; fi
sh_phone "printf '%s\n' '# laurel: the root list' '$LIST' > /private/var/db/negronimetal/clients && printf '%s\n' '$LIST' > /System/Library/Extensions/NegroniMetal.bundle/clients.local && rm -f /private/var/db/negronimetal/off /private/var/db/negronimetal/strikes/gpu-lost"
say "Metal list: $LIST"
if [ "${NO_RESTART:-0}" = 1 ]; then say "done: no restart; the files act at the next boot"; exit 0; fi
# no killall, awk or sed need on this root [V phone]: the shell's read gives the pid
sh_phone 'sync; p=; for w in $(ps -ax -o pid=,comm= | grep "/backboardd$"); do p=$w; break; done; [ -n "$p" ] && kill -9 "$p"' || die "no restart of the UI: no backboardd process"
say "done: the UI restarts. Read: LAUREL METAL26: on, SWEET FPS, LAUREL DEBUG ACK in logs/usblog-*.txt"
