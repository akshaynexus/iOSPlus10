#!/usr/bin/env python3
"""Our root changes on top of external/slop/tools/sweet-root-tweaks.py (run as root on the mounted root).

    root-tweaks-extra.py MOUNTED_ROOT [--migration skip|once]

1. launchd jobs removed (missing hardware / loops / CPU), from the reference ports:
   - com.apple.fairplayd.H2: exits at launch, relaunched every 10 s; Mach messages to
     com.apple.fairplayd.versioned never get a reply, so locationd (CLMescalSigner) and every
     synchronous CoreLocation client deadlock (ios-sailfish tools/sweet-root-tweaks.py:15-18,
     ios-flame HANDOFF.md:238-245).
   - com.apple.voicemail.vmd: retries the missing CommCenter XPC ~29k times per boot (sailfish).
   - com.apple.ReportCrash, spindump, tailspind: ReportCrash alone used ~60 % of a core (sailfish).
   - com.apple.aggregated(.addaily): sailfish removes them (note: Settings > Battery waits on its
     power log, UniXNU-pong mkjobs.py:216-224).
   - com.apple.bluetoothd: no transport / no device-tree node -> relaunched every 10 s
     (slop commit b4766ca, HackiOS, UniXNU-zeta lite list).
   - com.apple.activityawardsd: Fitness awards; aborts (sig 6) at launch, relaunched every 10 s
     (14 crashes in logs/usblog-20261024-195455.txt, first NE2211 boot).
2. ExtensionKit feature flag enforce_xpc_cache_code_signing = off, else installd rejects every
   app extension (sailfish feature_flags(), lines 138-143).
3. Preferences: FBLaunchWatchdogScale 20 (frontboard, springboard), DMLastMigrationResults
   success (HackiOS userland/var/mobile/Library/Preferences).
4. Migration: "skip" (default) keeps slop's LastSystemVersion (fast first boot, fewer app
   extensions registered); "once" uses sailfish's sentinel /private/var/datamigrator/migrate and
   removes LastSystemVersion (DataMigration runs one time; widgets/wallpapers register).
5. backboardd EnvironmentVariables CA_HEARTBEAT_RATE (env CA_HEARTBEAT, default 120, empty = off):
   QuartzCore 20H392 (AppleCLCDDisplay::heartbeat_rate) takes 1/CA_HEARTBEAT_RATE as its base quantum
   before the IOMFBDisplayRefresh property and the 1/60 s default (docs/notes.md section 15). The job
   lives in System/Library/xpc/launchd.plist (launchd reads only that cache, docs/usb-network.md).
   Phone-side test without a new root: scripts/metal/phone-heartbeat.sh.
"""
import argparse, os, plistlib

BACKBOARDD = '/System/Library/LaunchDaemons/com.apple.backboardd.plist'

DROP = ['com.apple.fairplayd.H2', 'com.apple.voicemail.vmd', 'com.apple.ReportCrash',
        'com.apple.spindump', 'com.apple.tailspind', 'com.apple.aggregated',
        'com.apple.aggregated.addaily', 'com.apple.bluetoothd', 'com.apple.activityawardsd']
MOBILE = 501

def merge_pref(root, name, values):
    path = os.path.join(root, 'private/var/mobile/Library/Preferences', name + '.plist')
    data = plistlib.load(open(path, 'rb')) if os.path.exists(path) else {}
    data.update(values)
    with open(path, 'wb') as fh:
        plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
    os.chown(path, MOBILE, MOBILE); os.chmod(path, 0o600)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('root')
    ap.add_argument('--migration', choices=['skip', 'once'], default='skip')
    a = ap.parse_args()
    r = a.root

    path = os.path.join(r, 'System/Library/xpc/launchd.plist')
    st = os.stat(path)
    plist = plistlib.load(open(path, 'rb'))
    jobs = plist['LaunchDaemons']
    gone = [k for k, j in list(jobs.items()) if j.get('Label') in DROP]
    for k in gone:
        del jobs[k]
    hb = os.environ.get('CA_HEARTBEAT', '120')
    bb = jobs.get(BACKBOARDD)
    if hb and isinstance(bb, dict):
        bb.setdefault('EnvironmentVariables', {})['CA_HEARTBEAT_RATE'] = hb
        print(f'launchd.plist: backboardd CA_HEARTBEAT_RATE={hb}')
    elif hb:
        print('launchd.plist: no backboardd job, CA_HEARTBEAT_RATE not set')
    else:
        print('launchd.plist: CA_HEARTBEAT empty, backboardd heartbeat left as is')
    with open(path, 'wb') as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
    os.chown(path, st.st_uid, st.st_gid); os.chmod(path, st.st_mode & 0o7777)
    print(f'launchd.plist: removed {len(gone)} jobs:', ', '.join(sorted(j.split("/")[-1] for j in gone)))

    d = os.path.join(r, 'private/var/preferences/FeatureFlags/Domain')
    os.makedirs(d, exist_ok=True)
    f = os.path.join(d, 'ExtensionKit.plist')
    with open(f, 'wb') as fh:
        plistlib.dump({'enforce_xpc_cache_code_signing': {'Enabled': False}}, fh, fmt=plistlib.FMT_XML)
    os.chown(f, 0, 0); os.chmod(f, 0o644)
    print('feature flag: ExtensionKit enforce_xpc_cache_code_signing off')

    if a.migration == 'once':
        mp = os.path.join(r, 'private/var/mobile/Library/Preferences/com.apple.migration.plist')
        if os.path.exists(mp):
            data = plistlib.load(open(mp, 'rb'))
            data.pop('LastSystemVersion', None); data.pop('DMUserDataDisposition', None)
            with open(mp, 'wb') as fh:
                plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
            os.chown(mp, MOBILE, MOBILE); os.chmod(mp, 0o600)
        s = os.path.join(r, 'private/var/datamigrator')
        os.makedirs(s, exist_ok=True)
        open(os.path.join(s, 'migrate'), 'w').close()
        os.chown(os.path.join(s, 'migrate'), MOBILE, MOBILE)
        print('migration: once (sentinel /private/var/datamigrator/migrate)')
    else:
        # HackiOS userland/var/mobile/Library/Preferences/com.apple.migration.plist
        merge_pref(r, 'com.apple.migration', {
            'DMLastMigrationResults': {'buildVersion': '20H392', 'success': True}})
        print('migration: skip (LastSystemVersion kept, DMLastMigrationResults success)')

    # HackiOS: a slow app launch on this CPU-rendered UI must not be killed by FrontBoard
    for dom in ('com.apple.frontboard', 'com.apple.springboard'):
        merge_pref(r, dom, {'FBLaunchWatchdogScale': 20})
    print('FBLaunchWatchdogScale 20 (frontboard, springboard)')

if __name__ == '__main__':
    main()
