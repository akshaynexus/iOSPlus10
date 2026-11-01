# Sourced by scripts/laurel/root-update-test.sh: a fake stock root ($STOCK) and the root our steps make of it ($ROOT), as root.sh does: snapshot, then the steps.
## stock root
SVC=1F05B0E7-0000-4000-8000-0000000000E0; SET=1F05B0E7-0000-4000-8000-00000000005E
mkdir -p "$STOCK"/{bin,System/Library/xpc,System/Library/LaunchDaemons,System/Library/CoreServices,System/Library/Caches/com.apple.dyld,usr/local,usr/share,Applications/Old.app,Applications/Stock.app,private/etc}
mkdir -p "$STOCK"/private/var/{root/.ssh,db/lsd,mobile/Library/Preferences,staged_system_apps/Mail.app,preferences/SystemConfiguration}
mkdir -p "$STOCK"/private/preboot/Cryptexes/OS
plist "$STOCK/System/Library/CoreServices/SystemVersion.plist" "{'ProductBuildVersion': '20H392'}"
plist "$STOCK/System/Library/xpc/launchd.plist" "{'LaunchDaemons': {'/System/Library/LaunchDaemons/com.apple.a.plist': {'Label': 'com.apple.a'}}}"
mk "$STOCK/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e" cache
mk "$STOCK/private/preboot/Cryptexes/OS/thing" cryptex
mk "$STOCK/usr/libexec/backboardd" real-bbd
mk "$STOCK/usr/share/stock-data" unchanged
mkdir -p "$STOCK/usr/share/addons"
mk "$STOCK/Applications/Old.app/Info.plist" old
mk "$STOCK/Applications/Stock.app/Info.plist" stock
mk "$STOCK/private/var/staged_system_apps/Mail.app/Info.plist" mail
mk "$STOCK/private/var/db/lsd/stock-state" stock-state
plist "$STOCK/private/var/mobile/Library/Preferences/com.apple.springboard.plist" "{'StockKey': 1}"
sleep 1.1   # second-granular file systems: the steps below must show as newer
python3 -I "$DELTA" snapshot "$STOCK" "$T/snap0" > "$T/o" 2>&1 || bad "snapshot of the stock tree"

## build a root on top of the stock tree, as root.sh does
cp -a "$STOCK" "$ROOT"
expect "snapshot before the steps" 0 "root-delta: snapshot" python3 -I "$DELTA" snapshot "$ROOT" "$D.new"
sleep 1.1
plist "$ROOT/System/Library/xpc/launchd.plist" "{'LaunchDaemons': {'/System/Library/LaunchDaemons/com.apple.a.plist': {'Label': 'com.apple.a'}, '/System/Library/LaunchDaemons/dev.iosplus10.dropbear.plist': {'Label': 'dev.iosplus10.dropbear', 'ProgramArguments': ['/usr/local/bin/dropbear', '-s']}}}"
mk "$ROOT/System/Library/LaunchDaemons/dev.iosplus10.dropbear.plist" job
mkdir -p "$ROOT/usr/libexec/real" "$ROOT/usr/local/bin" "$ROOT/usr/local/libexec" "$ROOT/usr/share/laurel" "$ROOT/Applications/New App.app"
mv "$ROOT/usr/libexec/backboardd" "$ROOT/usr/libexec/real/backboardd"
mk "$ROOT/usr/libexec/backboardd" wrapper
mk "$ROOT/usr/share/addons/new.dat" addon
for t in toybox dash dropbearmulti usbnetcfg; do printf '#!/bin/sh\nexit 0\n' > "$ROOT/usr/local/bin/$t"; chmod 755 "$ROOT/usr/local/bin/$t"; done
ln -s dropbearmulti "$ROOT/usr/local/bin/dropbear"
ln -s /usr/local/bin/dash "$ROOT/bin/sh"
mk "$ROOT/usr/local/libexec/powermenu-helper" helper; chmod 4750 "$ROOT/usr/local/libexec/powermenu-helper"
mk "$ROOT/Applications/New App.app/Info.plist" newapp
mk "$ROOT/Applications/New App.app/With space and 'quote.png" png
rm -rf "$ROOT/Applications/Old.app"
mv "$ROOT/private/var/staged_system_apps/Mail.app" "$ROOT/Applications/Mail.app"
# /private/var: prefs, configd, key file, Metal state, an own data file
plist "$ROOT/private/var/mobile/Library/Preferences/com.apple.springboard.plist" "{'StockKey': 1, 'BKNoWatchdogs': True}"
plist "$ROOT/private/var/mobile/Library/Preferences/.GlobalPreferences.plist" "{'AppleLanguages': ['en'], 'AppleLocale': 'en_US', 'UIStatusBarVisualProviderClassName': 'FixedSplit'}"
plist "$ROOT/private/var/preferences/SystemConfiguration/preferences.plist" "{'CurrentSet': '/Sets/$SET', 'NetworkServices': {'$SVC': {'IPv4': {'Addresses': ['192.168.7.2']}, 'PrimaryRank': 'Last'}}, 'Sets': {'$SET': {'Network': {'Service': {'$SVC': {'__LINK__': '/NetworkServices/$SVC'}}, 'Global': {'IPv4': {'ServiceOrder': ['$SVC']}}}}}}"
plist "$ROOT/private/var/preferences/SystemConfiguration/NetworkInterfaces.plist" "{'Interfaces': [{'BSD Name': 'ue0', 'IOInterfaceUnit': 0}]}"
mk "$ROOT/private/var/root/.ssh/authorized_keys" "ssh-ed25519 REPOKEY iosplus10-phone"; chmod 600 "$ROOT/private/var/root/.ssh/authorized_keys"
mk "$ROOT/private/var/root/.profile" "image profile"
mkdir -p "$ROOT/private/var/db/negronimetal/cache" "$ROOT/private/var/db/negronicam"
mk "$ROOT/private/var/db/negronimetal/clients" "image clients"
mk "$ROOT/private/var/db/negronimetal/build.txt" "new build"
rm -f "$ROOT/private/var/db/lsd/stock-state"
mk "$ROOT/usr/share/laurel/root-manifest" "abc123 20261101T000000Z kernel-series 0011223344556677 features 1 installed 1 off 0 missing 0"
