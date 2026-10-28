#!/usr/bin/env python3
"""STUB: iOS 26 root tweaks for negroni (run as root on the mounted 26.5.2 root; called by scripts/ios26/root-macos.sh).

    root-tweaks.py MOUNTED_ROOT [--report]

Each iOS 16 tweak (scripts/ios16/root-tweaks-extra.py, external/slop sweet-root-tweaks.py) is listed with its iOS 26
state. Only the items marked "apply" run; "audit" items print what to check in the 26.5.2 root and change nothing.
--report prints the table only. Nothing here is tested on a 26.x root yet ([U] for every item until the first
fetch-os.sh image exists).
"""
import argparse, os, plistlib, sys

# (name, action, note)
TWEAKS = [
    ('launchd jobs removed', 'audit',
     '26.x launchd reads System/Library/xpc/launchd.plist (cache) like 16.x [I]; check the 9 job labels of the iOS 16 '
     'DROP list (fairplayd.H2, vmd, ReportCrash, spindump, tailspind, aggregated(.addaily), bluetoothd, '
     'activityawardsd) and look for new jobs that need AOP/SEP/ANE/DCP (A13 donor: no DCP, but AOP and ANE jobs)'),
    ('ExtensionKit enforce_xpc_cache_code_signing off', 'audit',
     'feature flag domain/name may have moved; check /System/Library/FeatureFlags/Domain/ExtensionKit.plist'),
    ('FBLaunchWatchdogScale 3, DMLastMigrationResults', 'apply', 'plain preference keys, harmless if unused'),
    ('migration skip (LastSystemVersion)', 'audit', 'DataMigrator in 26.x; keep "skip" default'),
    ('backboardd CA_HEARTBEAT_RATE', 'audit',
     'QuartzCore 26 heartbeat logic; AppleCLCDDisplay::heartbeat_rate symbol must be re-found'),
    ('WidgetKit / lsd jetsam limits', 'audit',
     'jetsamproperties plist name is per device: com.apple.jetsamproperties.D421.plist [I]; jetsam_widgets.py '
     'reads every jetsamproperties plist, so it may work unchanged'),
    ('Location Services switch', 'audit', 'locationd prefs key LocationServicesEnabledIn8.0 still used? [U]'),
    ('InterfaceNamer WaitStackTimeout', 'audit', 'configd InterfaceNamer.bundle Info.plist key; our kernel still has no IONetworkStack'),
    ('keybag stand-in systembag.kb', 'apply', 'written by root-macos.sh; AKS emulation must answer the 26.x selector set'),
    ('AMX: hw.cpufamily without AMX', 'kernel', 'kernel side (identity sysctl patch), not a root tweak'),
]


def apply_prefs(root):
    p = os.path.join(root, 'private/var/mobile/Library/Preferences/com.apple.springboard.plist')
    os.makedirs(os.path.dirname(p), exist_ok=True)
    d = {}
    if os.path.exists(p):
        with open(p, 'rb') as f:
            d = plistlib.load(f)
    d['FBLaunchWatchdogScale'] = 3
    with open(p, 'wb') as f:
        plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
    os.chown(p, 501, 501)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('root', nargs='?')
    ap.add_argument('--report', action='store_true')
    a = ap.parse_args()
    for name, action, note in TWEAKS:
        print(f'{action:7} {name}: {note}')
    if a.report or not a.root:
        return
    if os.geteuid() != 0:
        sys.exit('run as root')
    apply_prefs(a.root)


if __name__ == '__main__':
    main()
