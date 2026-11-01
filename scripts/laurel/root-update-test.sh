#!/bin/bash
# Host test of the update in place (docs/laurel_sprout/root-update.md) on a fake root and a fake phone in a temp folder: no sudo, no phone, no Apple files.
#   scripts/laurel/root-update-test.sh     (seconds; exit 0 = all pass; needs GNU stat, tar, sha256sum: macOS: brew install coreutils gnu-tar, first in PATH)
# The phone side is the real phone.sh, run by sh in a folder; the "SSH" is `sh -c`. Covers: file list, classes, plist merge, key step, atomic push, rollback, failure in the commit,
# lost link, refusals, the first update from an old root. The real root steps on a copy: scripts/laurel/root-dry-run.sh (it runs the delta too).
# Runs twice: with the host's GNU tools, then with the phone's tools: toybox + dash of out/ssh/host (the same sources as out/ssh/ios; userland/ssh/build.sh), alone in PATH.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
stat -c %f / >/dev/null 2>&1 || { echo "root-update-test: skipped: needs GNU stat (brew install coreutils)"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/rupd-test.XXXXXX")
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
STOCK=$T/stock; ROOT=$T/root; PH=$T/phone; D=$T/delta; D2=$T/delta2
DELTA=$REPO/scripts/laurel/root-delta.py; MAIN=$REPO/scripts/laurel/rootupdate/main.py
fails=0; n=0
pass() { n=$((n + 1)); echo "ok   $1"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $1"; sed 's/^/     | /' "$T/o" 2>/dev/null | tail -14; }
# expect NAME RC SUBSTRING CMD...
expect() {
  local name=$1 rc=$2 text=$3 got=0; shift 3
  "$@" > "$T/o" 2>&1 || got=$?
  cp "$T/o" "$T/last"
  if [ "$got" = "$rc" ] && { [ -z "$text" ] || grep -qF -- "$text" "$T/o"; }; then pass "$name"; else echo "     got exit $got, wanted $rc, text '$text'" >> "$T/o"; bad "$name"; fi
}
check() { local name=$1; shift; if "$@" > "$T/o" 2>&1; then pass "$name"; else bad "$name"; fi; }
tree_sum() { (cd "$1" && find . -type f -not -path './private/var/root/laurel-*' -print0 | sort -z | xargs -0 sha256sum; find . \( -type l -o -type d \) -not -path './private/var/root/laurel-*' -printf '%y %m %p %l\n' | sort); }

# The phone's tools, when asked
SHELL_C=sh
if [ -n "${ROOT_UPDATE_TOOLS:-}" ]; then
  mkdir "$T/tools"
  ln -s "$ROOT_UPDATE_TOOLS/dash" "$T/tools/sh"; ln -s "$ROOT_UPDATE_TOOLS/dash" "$T/tools/dash"
  for a in $("$ROOT_UPDATE_TOOLS/toybox"); do ln -s "$ROOT_UPDATE_TOOLS/toybox" "$T/tools/$a"; done
  export ROOT_UPDATE_PHONE_PATH=$T/tools
  SHELL_C=$ROOT_UPDATE_TOOLS/dash
  echo "root-update-test: phone tools: $("$ROOT_UPDATE_TOOLS/toybox" --version), dash"
fi
# The SSH stand-in: exit 255 once when $T/drop exists = a lost link
cat > "$T/ssh" <<EOF
#!/bin/sh
if [ -e "$T/drop" ]; then rm -f "$T/drop"; exit 255; fi
case "\$1" in *"tar xpf"*) if [ -e "$T/drop-tar" ]; then rm -f "$T/drop-tar"; exit 255; fi ;; esac
if [ "\$1" = "sh -s" ] && [ -e "$T/drop-status" ]; then
  f=\$(mktemp "$T/script.XXXXXX"); cat > "\$f"
  if tail -n 2 "\$f" | grep -q '^p_status'; then
    n=\$(cat "$T/drop-status")
    if [ "\$n" -gt 0 ]; then echo \$((n - 1)) > "$T/drop-status"; exit 255; fi
  fi
  exec $SHELL_C -c "\$1" < "\$f"
fi
exec $SHELL_C -c "\$1"
EOF
chmod +x "$T/ssh"
export ROOT_UPDATE_TRANSPORT="$T/ssh" ROOT_UPDATE_PHONE_ROOT=$PH ROOT_UPDATE_KEYCHECK=true REBOOT=0
up() { python3 -I "$MAIN" --dir "$D" "$@"; }

mk() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
plist() { python3 -I - "$1" "$2" <<'EOF'
import os, plistlib, sys
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
plistlib.dump(eval(sys.argv[2]), open(sys.argv[1], 'wb'), fmt=plistlib.FMT_BINARY)
EOF
}
pget() { python3 -I -c 'import plistlib, sys; d = plistlib.load(open(sys.argv[1], "rb")); print(eval(sys.argv[2], {"d": d}))' "$1" "$2"; }

. "$REPO/scripts/laurel/rootupdate/test-fake.sh"
expect "make" 0 "root-delta:" python3 -I "$DELTA" make "$ROOT" "$D.new"
expect "seal" 0 "update payload" python3 -I "$DELTA" seal "$D.new" "$D"
F=$D/files.tsv
row() { grep -P "\t$1\t" "$F" | head -1; }
has_row() { row "$2" | grep -qP "^$1\t$3\t"; }
check "file list: new binary, class install" has_row f usr/local/bin/toybox i
check "file list: moved stock file" has_row f usr/libexec/real/backboardd i
check "file list: symlink" has_row l bin/sh i
check "file list: changed launchd cache" has_row f System/Library/xpc/launchd.plist i
check "file list: setuid mode kept" sh -c "grep -F 'usr/local/libexec/powermenu-helper' '$F' | grep -qP '^f\ti\t4750\t'"
check "file list: name with space and quote" grep -qF "With space and 'quote.png" "$F"
check "file list: var plist is a merge" has_row f private/var/mobile/Library/Preferences/com.apple.springboard.plist m
check "file list: key file is a union" has_row f private/var/root/.ssh/authorized_keys a
check "file list: Metal clients stay the phone's" has_row f private/var/db/negronimetal/clients k
check "file list: a state folder is keep" has_row d private/var/db/negronicam k
check "file list: own data file in var installs" has_row f private/var/db/negronimetal/build.txt i
check "file list: gone app" has_row g Applications/Old.app i
check "file list: gone staged app goes" has_row g private/var/staged_system_apps/Mail.app i
check "file list: gone var state stays" has_row g private/var/db/lsd/stock-state s
check "file list: old USB job gets removed" has_row g System/Library/LaunchDaemons/dev.iosplus10.usbnetcfg.plist i
check "file list: unchanged stock file is out" sh -c "! grep -q 'usr/share/stock-data' '$F'"
check "file list: unchanged stock folder is out" sh -c "! grep -qP '^d\t.*\tusr/share\t' '$F'"
check "root-files is in the root" grep -q "^f.usr/local/bin/toybox" "$ROOT/usr/share/laurel/root-files"
check "store: each file by hash" sh -c "test \$(ls '$D/store' | wc -l) -ge 10"
expect "--list needs no phone" 0 "delta:" env ROOT_UPDATE_TRANSPORT=false python3 -I "$MAIN" --dir "$D" --list

## the OLD phone: stock + an older build + the owner's data. Password root: no key, no root-files.
cp -a "$STOCK" "$PH"
OLD_JOB=$PH/System/Library/LaunchDaemons/dev.iosplus10.usbnetcfg.plist
mk "$OLD_JOB" oldjob
plist "$PH/System/Library/xpc/launchd.plist" "{'LaunchDaemons': {'/System/Library/LaunchDaemons/dev.iosplus10.usbnetcfg.plist': {'Label': 'dev.iosplus10.usbnetcfg'}}}"
mkdir -p "$PH/usr/local/bin" "$PH/usr/share/laurel" "$PH/private/var/db/negronimetal"
for t in toybox dash usbnetcfg; do printf '#!/bin/sh\necho old\n' > "$PH/usr/local/bin/$t"; chmod 755 "$PH/usr/local/bin/$t"; done
ln -s /usr/local/bin/dash "$PH/bin/sh"
mk "$PH/usr/share/laurel/root-manifest" "old000 20261101T162734Z kernel-series aaaaaaaaaaaaaaaa features 1 installed 1 off 0 missing 0"
rm -rf "$PH/private/var/staged_system_apps/Mail.app"
# owner's data
WIFI=11111111-2222-3333-4444-555555555555
plist "$PH/private/var/preferences/SystemConfiguration/preferences.plist" "{'CurrentSet': '/Sets/$SET', 'NetworkServices': {'$SVC': {'IPv4': {'Router': '192.168.7.1'}, 'DNS': {'ServerAddresses': ['1.1.1.1']}}, '$WIFI': {'UserDefinedName': 'Wi-Fi'}}, 'Sets': {'$SET': {'Network': {'Service': {'$WIFI': {'__LINK__': 'x'}, '$SVC': {'__LINK__': 'x'}}, 'Global': {'IPv4': {'ServiceOrder': ['$SVC', '$WIFI']}}}}}}"
plist "$PH/private/var/preferences/SystemConfiguration/NetworkInterfaces.plist" "{'Interfaces': [{'BSD Name': 'en0', 'IOInterfaceUnit': 0}, {'BSD Name': 'ue0', 'IOInterfaceUnit': 9}]}"
plist "$PH/private/var/preferences/SystemConfiguration/com.apple.wifi.known-networks.plist" "{'wifi.network.ssid.Home': {'SSID': 'Home'}}"
plist "$PH/private/var/mobile/Library/Preferences/com.apple.springboard.plist" "{'StockKey': 5, 'OwnerKey': 'mine'}"
plist "$PH/private/var/mobile/Library/Preferences/.GlobalPreferences.plist" "{'AppleLanguages': ['de'], 'AppleLocale': 'de_DE'}"
mk "$PH/private/var/db/negronimetal/clients" "owner clients"
mk "$PH/private/var/root/.profile" "owner profile"
mk "$PH/private/var/mobile/Media/DCIM/photo.jpg" photo
mk "$PH/private/var/db/lsd/stock-state" "lsd state"
mkdir -p "$PH/private/var/mobile/Library/Caches"
plist "$PH/private/var/mobile/Library/Caches/com.apple.MobileGestalt.plist" "{'x': 1}"
exec 9< "$PH/usr/local/bin/dash"     # the "running binary"
OLD_INODE=$(stat -c %i "$PH/usr/local/bin/dash")
tree_sum "$PH" > "$T/before"

expect "dry run lists the changes" 0 "dry run: nothing changed" up --dry-run
check "dry run names a binary" grep -q 'put .*usr/local/bin/dropbearmulti' "$T/last"
check "dry run gives the byte count" grep -qE 'plan: [0-9]+ files to write \([0-9]+ bytes\)' "$T/last"
check "dry run says first update" grep -q 'first update of a root without root-files' "$T/last"
tree_sum "$PH" > "$T/after"; check "dry run wrote nothing" cmp "$T/before" "$T/after"
check "dry run left no update folder" test ! -e "$PH/private/var/root/laurel-update"

## the key step stops everything when the key does not log in
expect "bad key login stops before the commit" 1 "key login does not work" env ROOT_UPDATE_KEYCHECK=false python3 -I "$MAIN" --dir "$D"
check "only the key file changed" sh -c "! grep -q REPOKEY '$PH/usr/local/bin/toybox'; cmp '$PH/usr/libexec/backboardd' '$STOCK/usr/libexec/backboardd' && grep -q REPOKEY '$PH/private/var/root/.ssh/authorized_keys'"
rm -f "$PH/private/var/root/.ssh/authorized_keys"; rm -rf "$PH/private/var/root/laurel-update"

## a tool that does not start stops everything
cp "$D/files.tsv" "$T/files.good"
SHA=$(grep -P '\tusr/local/bin/toybox\t' "$F" | cut -f8); cp "$D/store/$SHA" "$T/toybox.good"
chmod u+w "$D/store/$SHA"; printf '#!/bin/sh\nkill -9 $$\n' > "$D/store/$SHA"
SZ=$(stat -c %s "$D/store/$SHA"); NEW=$(sha256sum "$D/store/$SHA" | cut -d' ' -f1); mv "$D/store/$SHA" "$D/store/$NEW"
python3 -I - "$F" "$SHA" "$NEW" "$SZ" <<'EOF'
import sys
p, a, b, sz = sys.argv[1:]
out = []
for line in open(p):
    f = line.split('\t')
    if f[7] == a:
        f[7], f[5] = b, sz
    out.append('\t'.join(f))
open(p, 'w').write(''.join(out))
EOF
expect "tool that cannot start stops in the stage" 1 "does not start: /usr/local/bin/" up
tree_sum "$PH" > "$T/after"; check "phone unchanged after the smoke failure" cmp "$T/before" "$T/after"
cp "$T/files.good" "$F"; cp "$T/toybox.good" "$D/store/$SHA"; rm -f "$D/store/$NEW"; rm -rf "$PH/private/var/root/laurel-update"

## a failure in the middle of the commit: rollback to exactly the old tree
chmod a-w "$PH/usr/share/addons"    # some files are in place when this rename fails
expect "failure in the commit rolls back" 1 "the phone is back on the old root files" up
check "the commit had begun" grep -q 'failed at line' "$T/last"
chmod u+w "$PH/usr/share/addons"
tree_sum "$PH" > "$T/after"
sed -i '/authorized_keys/d;/\/.ssh$/d' "$T/after"
grep -v 'authorized_keys\|/\.ssh$' "$T/before" > "$T/before.nokey"
check "the tree is the old tree (the key stays)" cmp "$T/before.nokey" "$T/after"
rm -f "$PH/private/var/root/.ssh/authorized_keys"; rm -rf "$PH/private/var/root/laurel-update"

## the first update: lost link during the transfer list, then all good
touch "$T/drop"
expect "first update" 0 "root-update: OK:" up
check "summary says hashes checked" grep -q 'hashes checked' "$T/last"

check "binary arrived" grep -q 'exit 0' "$PH/usr/local/bin/toybox"
check "running binary: new inode, not in place" test "$(stat -c %i "$PH/usr/local/bin/dash")" != "$OLD_INODE"
check "running binary: the open file still reads old" sh -c 'grep -q "echo old" <&9'
check "setuid bit on the helper" test "$(stat -c %a "$PH/usr/local/libexec/powermenu-helper")" = 4750
check "link" test "$(readlink "$PH/usr/local/bin/dropbear")" = dropbearmulti
check "name with a quote" test -f "$PH/Applications/New App.app/With space and 'quote.png"
check "launchd cache has no old job" sh -c "! grep -q usbnetcfg '$PH/System/Library/xpc/launchd.plist'"
check "old job plist removed" test ! -e "$OLD_JOB"
check "gone app removed" test ! -e "$PH/Applications/Old.app"
check "no temp left in the stage" test ! -e "$PH/private/var/root/laurel-update/stage"
check "manifest: first line says in-place" grep -qE '^abc123 .* missing 0 in-place [0-9TZ]+$' "$PH/usr/share/laurel/root-manifest"
check "manifest: line 1 under the kernel's 199" test "$(head -1 "$PH/usr/share/laurel/root-manifest" | wc -c)" -lt 199
check "root-files on the phone" cmp "$PH/usr/share/laurel/root-files" "$ROOT/usr/share/laurel/root-files"
check "register list has the new apps" grep -q 'R /Applications/New App.app' "$PH/private/var/root/laurel-update/register.list"
check "register list has the gone app" grep -q 'U /Applications/Old.app' "$PH/private/var/root/laurel-update/register.list"
# /private/var: what stays
P=$PH/private/var/preferences/SystemConfiguration/preferences.plist
expect_v() { local name=$1 want=$2 f=$3 e=$4 got; got=$(pget "$f" "$e" 2>&1); if [ "$got" = "$want" ]; then pass "$name"; else echo "got $got, wanted $want" > "$T/o"; bad "$name"; fi; }
expect_v "Wi-Fi service kept" "Wi-Fi" "$P" "d['NetworkServices']['$WIFI']['UserDefinedName']"
expect_v "old router gone from the USB service" "False" "$P" "'Router' in d['NetworkServices']['$SVC'].get('IPv4', {})"
expect_v "old DNS gone from the USB service" "False" "$P" "'DNS' in d['NetworkServices']['$SVC']"
expect_v "USB service last in the order" "['$WIFI', '$SVC']" "$P" "d['Sets']['$SET']['Network']['Global']['IPv4']['ServiceOrder']"
expect_v "Wi-Fi stays in the set" "True" "$P" "'$WIFI' in d['Sets']['$SET']['Network']['Service']"
N=$PH/private/var/preferences/SystemConfiguration/NetworkInterfaces.plist
expect_v "en0 kept, one ue0 ours" "['en0', 'ue0'] 0" "$N" "str([i['BSD Name'] for i in d['Interfaces']]) + ' ' + str(d['Interfaces'][-1]['IOInterfaceUnit'])"
SB=$PH/private/var/mobile/Library/Preferences/com.apple.springboard.plist
expect_v "our key in" "True" "$SB" "d['BKNoWatchdogs']"
expect_v "owner's key kept" "mine" "$SB" "d['OwnerKey']"
expect_v "stock key the phone changed stays" "5" "$SB" "d['StockKey']"
G=$PH/private/var/mobile/Library/Preferences/.GlobalPreferences.plist
expect_v "language kept" "['de']" "$G" "d['AppleLanguages']"
expect_v "our key beside the language" "FixedSplit" "$G" "d['UIStatusBarVisualProviderClassName']"
check "known networks untouched" test "$(pget "$PH/private/var/preferences/SystemConfiguration/com.apple.wifi.known-networks.plist" "d['wifi.network.ssid.Home']['SSID']")" = Home
check "photo untouched" test "$(cat "$PH/private/var/mobile/Media/DCIM/photo.jpg")" = photo
check "Metal clients of the phone stay" test "$(cat "$PH/private/var/db/negronimetal/clients")" = "owner clients"
check "profile of the phone stays" test "$(cat "$PH/private/var/root/.profile")" = "owner profile"
check "gone var state stays" test -f "$PH/private/var/db/lsd/stock-state"
check "new var file installed" test "$(cat "$PH/private/var/db/negronimetal/build.txt")" = "new build"
check "key installed, mode 600" test "$(stat -c %a "$PH/private/var/root/.ssh/authorized_keys")" = 600
check "MobileGestalt cache dropped" test ! -e "$PH/private/var/mobile/Library/Caches/com.apple.MobileGestalt.plist"

## rollback: exactly the old tree, then again the update
tree_sum "$PH" > "$T/updated"
expect "--rollback" 0 "rolled back" up --rollback
tree_sum "$PH" > "$T/after"
grep -v 'authorized_keys\|/\.ssh$\|MobileGestalt\|/Library/Caches$' "$T/before" > "$T/b"; grep -v 'authorized_keys\|/\.ssh$\|MobileGestalt\|/Library/Caches$' "$T/after" > "$T/a"
check "rollback: the same tree as before (no key, no cache)" diff "$T/b" "$T/a"
# the link drops during the transfer and twice during the commit: the transfer goes again, the commit does not stop
touch "$T/drop-tar"; echo 2 > "$T/drop-status"
expect "update again after a rollback, lost link in the transfer and the commit" 0 "root-update: OK:" up
check "the transfer went again" grep -q 'stage: try 2' "$T/last"
rm -f "$T/drop-status"
expect "second run: nothing to do" 0 "already has this root" up
rmdir "$PH/private/var/db/negronicam"     # the phone removes a state folder by itself: no reason for an update
expect "a folder gone from /private/var alone: nothing to do" 0 "already has this root" up
mkdir "$PH/private/var/db/negronicam"
expect "--after-boot" 0 "paths differ" env ROOT_UPDATE_WAIT_S=5 python3 -I "$MAIN" --dir "$D" --after-boot
check "after boot: 0 paths differ" grep -q 'after boot: 0 paths differ' "$T/last"
check "after boot: register off (no pmregister in the fake)" grep -qE 'register: (off|R |FAILED)' "$T/last"

## a later build: a file no longer installed goes, a stock file reverted needs a flash
cp -a "$D" "$T/delta.keep"
python3 -I - "$F" <<'EOF'
import sys
p = sys.argv[1]
keep = [s for s in open(p) if '\tusr/local/bin/usbnetcfg\t' not in s]
open(p, 'w').write(''.join(keep))
EOF
sed -i 's/^abc123 /abc124 /' "$D/manifest"; sed -i 's/abc123/abc124/' "$D/meta.json"
expect "later build: a dropped file goes" 0 "root-update: OK:" up
check "dropped file gone" test ! -e "$PH/usr/local/bin/usbnetcfg"
rm -rf "$D"; cp -a "$T/delta.keep" "$D"
rm -rf "$PH/private/var/root/laurel-update"
python3 -I - "$PH/usr/share/laurel/root-files" <<'EOF'
import sys
open(sys.argv[1], 'a').write('f\tusr/share/stock-data\n')
EOF
sed -i 's/^abc123 /abc125 /' "$D/manifest"; sed -i 's/abc123/abc125/' "$D/meta.json"
expect "reverted stock file: refuse" 3 "REFLASH NEEDED: /usr/share/stock-data was changed by an older build" up
sed -i '$d' "$PH/usr/share/laurel/root-files"
rm -rf "$D"; cp -a "$T/delta.keep" "$D"

## refusals: one line, nothing written. Change the file list or meta, keep the phone.
tree_sum "$PH" > "$T/before2"
refuse_case() { # NAME TEXT PY: edit meta (m) ; a change of the phone comes before
  python3 -I - "$D/meta.json" "$3" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
exec(sys.argv[2])
json.dump(m, open(sys.argv[1], 'w'))
EOF
  expect "$1" 3 "$2" up
  rm -rf "$D"; cp -a "$T/delta.keep" "$D"
}
refuse_case "refuse: another iOS build" "iOS build changed" "m['build']='20H999'; m['first']='abc126'"
refuse_case "refuse: another stock root" "the stock root changed" "m['base']='0000000000000000'; m['first']='abc126'"
refuse_case "refuse: partition layout" "volume size changed" "m['volume_bytes']=1024*1024; m['first']='abc126'"
sed -i -E "s#^(f\ti\t[0-9]+\t[0-9]+\t[0-9]+\t)[0-9]+(.*usr/share/laurel/root-files)#\11152921504606846976\2#" "$F"
refuse_case "refuse: no space" "not enough free space" "m['first']='abc126'"
if [ "$(grep -c 'REFLASH NEEDED' "$T/last")" = 1 ]; then pass "refusal is one line"; else bad "refusal is one line"; fi
tree_sum "$PH" > "$T/after"; check "refusals wrote nothing" cmp "$T/before2" "$T/after"
# a change in the cryptex or the shared cache
python3 -I - "$F" "$D" <<'EOF'
import hashlib, os, sys
f, d = sys.argv[1:]
data = b'new cryptex file\n'
sha = hashlib.sha256(data).hexdigest()
open(os.path.join(d, 'store', sha), 'wb').write(data)
open(f, 'a').write('f\ti\t644\t%d\t%d\t%d\t0\t%s\tprivate/preboot/Cryptexes/OS/thing\t\n' % (os.getuid(), os.getgid(), len(data), sha))
EOF
sed -i 's/^abc123 /abc127 /' "$D/manifest"; sed -i 's/abc123/abc127/' "$D/meta.json"
expect "refuse: cryptex" 3 "REFLASH NEEDED: /private/preboot/Cryptexes/OS/thing would change" up
rm -rf "$D"; cp -a "$T/delta.keep" "$D"
# a root build this payload does not belong to
printf 'something else\n' > "$T/side"
expect "payload of another build: stop" 1 "is not from the root build of the sidecar" up --sidecar "$T/side"
expect "no payload: says so" 1 "no update payload" python3 -I "$MAIN" --dir "$T/nothing"

expect "merge rules on plain data" 0 "ok" python3 -I "$REPO/scripts/laurel/rootupdate/merge_test.py"

echo "root-update-test: $((n - fails)) of $n pass${ROOT_UPDATE_TOOLS:+ (phone tools)}"
[ "$fails" = 0 ] || exit 1
[ -z "${ROOT_UPDATE_TOOLS:-}" ] || exit 0
H=$REPO/out/ssh/host
[ -x "$H/toybox" ] || H=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')/out/ssh/host
if [ -x "$H/toybox" ] && [ -x "$H/dash" ] && "$H/toybox" true 2>/dev/null; then
  ROOT_UPDATE_TOOLS=$H "$0"
else
  echo "root-update-test: note: no host toybox + dash in out/ssh/host (userland/ssh/build.sh): phone tools not tested"
fi
