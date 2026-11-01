#!/bin/bash
# Host test of scripts/laurel/root-air-ios26.sh on a made-up root (no Apple file, no sudo, no phone). Needs the two binaries (awdl-build.sh, airplay-build.sh).
#   scripts/laurel/root-air-ios26-test.sh       exit 0 = all pass
# Shows: the files and jobs are there, a second run changes no byte, the switches, the first-try file, a root that is not iOS 26 and a non-arm64 binary are refused.
# Does not show: that launchd, dyld or the kernel accept any of it.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=$REPO/scripts/laurel/root-air-ios26.sh
T=$(mktemp -d "$REPO/out/air26-test.XXXXXX")
trap 'rm -rf -- "$T"' EXIT
fail=0; ok() { echo "root-air-ios26-test: ok: $1"; }; no() { echo "root-air-ios26-test: FAIL: $1"; fail=1; }
mk() {  # dir with-audiomxd
  mkdir -p "$1/System/Library/xpc" "$1/System/Library/LaunchDaemons"
  python3 -I - "$1" "$2" <<'PY'
import plistlib, sys
j = {'/System/Library/LaunchDaemons/com.apple.wifip2pd.plist': {'Program': '/usr/libexec/wifip2pd'}, '/x/other.plist': {'Program': '/x'}}
if sys.argv[2] == '1':
    j['/System/Library/LaunchDaemons/com.apple.audiomxd.plist'] = {'Program': '/usr/libexec/audiomxd'}
plistlib.dump({'LaunchDaemons': j}, open(sys.argv[1] + '/System/Library/xpc/launchd.plist', 'wb'), fmt=plistlib.FMT_BINARY)
PY
  touch "$1/System/Library/LaunchDaemons/com.apple.wifip2pd.plist"
}
sum() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs -d '\n' sha256sum | sha256sum); }
R=$T/a; mk "$R" 1
if "$S" "$R" > "$T/out1" 2>&1; then ok "first run: $(tail -1 "$T/out1")"; else no "first run: $(tail -3 "$T/out1")"; fi
python3 -I - "$R" <<'PY' && ok "jobs, preferences, wifip2pd out, no first try allowed" || no "contents"
import os, plistlib, sys
r = sys.argv[1]
j = plistlib.load(open(r + '/System/Library/xpc/launchd.plist', 'rb'))['LaunchDaemons']
d = '/System/Library/LaunchDaemons/'
assert d + 'com.laurel.awdl.plist' in j and d + 'com.laurel.airplay.plist' in j and d + 'com.apple.audiomxd.plist' in j and '/x/other.plist' in j
assert d + 'com.apple.wifip2pd.plist' not in j and not os.path.exists(r + d + 'com.apple.wifip2pd.plist')
assert j[d + 'com.laurel.awdl.plist']['KeepAlive'] is False
m = r + '/private/var/Managed Preferences/mobile/'
assert plistlib.load(open(m + 'com.apple.Sharing.plist', 'rb')) == {'BrowseAllInterfaces': True, 'RegisterAllInterfaces': True}
assert plistlib.load(open(m + 'com.apple.airplay.plist', 'rb')) == {'sessionProtocolOverride': 'legacy'}
assert os.access(r + '/usr/libexec/laurel-awdld', os.X_OK) and os.access(r + '/usr/libexec/laurel-airplay', os.X_OK)
assert not os.path.exists(r + '/private/var/db/laurel-awdl.allow')
assert len(open(r + '/usr/share/laurel/ios26-air-cdhashes').read().splitlines()) == 2
assert 'first try waits for the owner' in open(r + '/usr/share/laurel/ios26-air-manifest').read()
PY
a=$(sum "$R"); "$S" "$R" > /dev/null 2>&1; [ "$a" = "$(sum "$R")" ] && ok "idempotent: a second run changes no byte" || no "second run changed the root"
AWDL_FIRST_TRY=alone "$S" "$R" > /dev/null 2>&1; [ "$(cat "$R/private/var/db/laurel-awdl.allow" 2>/dev/null)" = alone ] && ok "AWDL_FIRST_TRY writes the allow file" || no "allow file"
"$S" "$R" > /dev/null 2>&1; [ ! -e "$R/private/var/db/laurel-awdl.allow" ] && ok "without the value the allow file goes" || no "allow file stayed"
AWDL_FIRST_TRY=yes "$S" "$R" > /dev/null 2>&1 && no "a bad AWDL_FIRST_TRY passed" || ok "a bad AWDL_FIRST_TRY stops"
M=$T/manifest; echo "other: line" > "$M"; MANIFEST=$M "$S" "$R" > /dev/null 2>&1; MANIFEST=$M "$S" "$R" > /dev/null 2>&1
[ "$(grep -c '^air-ios26: ' "$M")" = 1 ] && grep -q '^other: line' "$M" && ok "one manifest line after two runs" || no "manifest line"
AWDL=0 AIRPLAY=0 "$S" "$R" > /dev/null 2>&1
python3 -I - "$R" <<'PY' && ok "AWDL=0 AIRPLAY=0: all ours gone, wifip2pd stays out" || no "switches"
import os, plistlib, sys
r = sys.argv[1]
j = plistlib.load(open(r + '/System/Library/xpc/launchd.plist', 'rb'))['LaunchDaemons']
assert not any('laurel' in k or 'wifip2pd' in k for k in j)
assert not os.path.exists(r + '/usr/libexec/laurel-awdld') and not os.path.exists(r + '/usr/libexec/laurel-airplay')
assert not os.path.exists(r + '/private/var/Managed Preferences/mobile/com.apple.airplay.plist')
PY
R2=$T/b; mk "$R2" 0; b=$(sum "$R2")
"$S" "$R2" > /dev/null 2>&1 && no "an iOS 16 root passed" || { [ "$b" = "$(sum "$R2")" ] && ok "a root with no audiomxd is refused and not changed" || no "refused, but changed"; }
exit $fail
