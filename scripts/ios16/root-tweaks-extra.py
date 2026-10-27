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
     (slop commit b4766ca, HackiOS, UniXNU-zeta lite list). [V 2026-10-26] The launchd cache of our root has no
     bluetoothd job (only BlueTool, bluetoothuiservice, bluetoothuserd), so this entry removes nothing today.
     BT=1 roots add the job from /System/Library/LaunchDaemons/com.apple.bluetoothd.plist (scripts/bt/root-add-bt.sh,
     run later by root-finish.sh, with BT_HCI_TRANSPORT and the BlueTool stand-in); the default root is unchanged.
   - com.apple.activityawardsd: Fitness awards; aborts (sig 6) at launch, relaunched every 10 s
     (14 crashes in logs/usblog-20261024-195455.txt, first NE2211 boot).
2. ExtensionKit feature flag enforce_xpc_cache_code_signing = off, else installd rejects every
   app extension (sailfish feature_flags(), lines 138-143).
3. Preferences: FBLaunchWatchdogScale 3 (frontboard, springboard; was 20: a hung launch such as Camera
   held the foreground slot ~400 s and no other app could launch, 2026-10-26), DMLastMigrationResults
   success (HackiOS userland/var/mobile/Library/Preferences).
4. Migration: "skip" (default) keeps slop's LastSystemVersion (fast first boot, fewer app
   extensions registered); "once" uses sailfish's sentinel /private/var/datamigrator/migrate and
   removes LastSystemVersion (DataMigration runs one time; widgets/wallpapers register).
5. backboardd EnvironmentVariables CA_HEARTBEAT_RATE (env CA_HEARTBEAT, default 120, empty = off):
   QuartzCore 20H392 (AppleCLCDDisplay::heartbeat_rate) takes 1/CA_HEARTBEAT_RATE as its base quantum
   before the IOMFBDisplayRefresh property and the 1/60 s default (docs/notes.md section 15). The job
   lives in System/Library/xpc/launchd.plist (launchd reads only that cache, docs/usb-network.md).
   Phone-side test without a new root: scripts/metal/phone-heartbeat.sh.
6. WidgetKit extension jetsam limit (env WIDGET_JETSAM_MB, default 64, empty = off): iOS 16 limits every
   com.apple.widgetkit-extension to 30 MiB (com.apple.jetsamproperties.<model>.plist, read by runningboardd); our
   Metal device needs ~15-20 MiB more, FitnessWidget was jetsam-killed (docs/metal-widgets-2026-10-27.md).
   scripts/ios16/jetsam_widgets.py patches every jetsamproperties plist. Live phone: scripts/metal/phone-widget-jetsam.sh.
7. Location Services switch on (env LOCATION_SWITCH; default 1 = on, LOCATION_SWITCH=0 leaves the root as is;
   docs/location-plan.md step L0, proven on the live phone 2026-10-27, docs/notes.md section 80):
   LocationServicesEnabledIn8.0 = true in /private/var/mobile/Library/Preferences/com.apple.locationd.plist
   (owner mobile 501:501, 0600). [V] 20H392 locationd reads the switch with CFPreferencesCopyValue(
   "LocationServicesEnabledIn8.0", "com.apple.locationd", "mobile", kCFPreferencesAnyHost) and takes a CFBoolean
   true or a non-zero CFNumber as "on". [V] cfprefsd keeps it in that file: after the SPI call the key is there
   (501:501, 0600), and a restarted locationd reads it (BigSwitch 1). The owner's later Settings choice stays until
   the next root image (this tweak runs only when an image is built). Live phone: `negroni-locd enable|disable`
   (scripts/location/phone-location.sh); Settings > Privacy & Security > Location Services uses the same SPI.
8. InterfaceNamer WaitStackTimeout (env IFNAMER_WAIT_S, seconds; default 10, empty = off; proven t26 2026-10-27: wifid init 12 s after configd instead of 300 s): configd's InterfaceNamer
   publishes Plugin:InterfaceNamer *QUIET* only through the IONetworkStack user client, and our kernel has no
   IONetworkStack, so in about half of the boots the key gets *QUIET*/*TIMEOUT* only when the 300 s stack timer fires.
   wifid's first SCNetworkInterfaceCopyAll waits for that key (__wait_for_IOKit_to_quiesce), so wifid init and the
   Settings Wi-Fi page wait up to 5 min (logs/wifid-spindump-20261027-173347.txt, docs/notes.md section 71).
   Sets WaitStackTimeout (a real) in /System/Library/SystemConfiguration/InterfaceNamer.bundle/Info.plist; configd
   reads it at start. Live phone: scripts/wifi/phone-ifnamer-timeout.sh.
"""
import argparse, glob, os, plistlib, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jetsam_widgets

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


IFNAMER = 'System/Library/SystemConfiguration/InterfaceNamer.bundle/Info.plist'

def ifnamer_wait(root, seconds):
    """WaitStackTimeout = seconds (> 0) in configd's InterfaceNamer Info.plist; keeps owner, mode and binary format."""
    if not seconds > 0:
        raise SystemExit('IFNAMER_WAIT_S must be > 0')
    path = os.path.join(root, IFNAMER)
    st = os.stat(path)
    data = plistlib.load(open(path, 'rb'))
    data['WaitStackTimeout'] = float(seconds)
    with open(path, 'wb') as fh:
        plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
    os.chown(path, st.st_uid, st.st_gid); os.chmod(path, st.st_mode & 0o7777)
    return f'WaitStackTimeout {float(seconds)} s in {IFNAMER}'


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

    # HackiOS used 20 for the CPU-rendered UI. With the GPU path apps launch in 1-2 s; a launch that never
    # checks in (Camera: no capture service) must free the foreground slot fast, else no other app launches
    # until the watchdog fires (20 x 20 s = 400 s seen 2026-10-26). 3 = about 60 s.
    for dom in ('com.apple.frontboard', 'com.apple.springboard'):
        merge_pref(r, dom, {'FBLaunchWatchdogScale': 3})
    print('FBLaunchWatchdogScale 3 (frontboard, springboard)')

    wmb = os.environ.get('WIDGET_JETSAM_MB', '64')
    if wmb:
        for path in sorted(glob.glob(os.path.join(r, 'System/Library/LaunchDaemons/com.apple.jetsamproperties.*.plist'))):
            print('jetsam:', jetsam_widgets.patch(path, int(wmb)))
    else:
        print('jetsam: WIDGET_JETSAM_MB empty, widget limits left as is')
    # 7b. lsd jetsam limit (env LSD_JETSAM_MB, default 64, empty = off): lsd is killed at 16 MiB while it rebuilds
    # the LaunchServices database on a fresh root, so no app opens (jetsam_widgets.py --daemon, 2026-10-27 t26)
    lmb = os.environ.get('LSD_JETSAM_MB', '64')
    if lmb:
        for path in sorted(glob.glob(os.path.join(r, 'System/Library/LaunchDaemons/com.apple.jetsamproperties.*.plist'))):
            print('jetsam:', jetsam_widgets.patch_daemon(path, 'com.apple.lsd', int(lmb)))
    else:
        print('jetsam: LSD_JETSAM_MB empty, lsd limits left as is')

    ifw = os.environ.get('IFNAMER_WAIT_S', '10')
    if ifw:
        print('interface namer:', ifnamer_wait(r, float(ifw)))
    else:
        print('interface namer: WaitStackTimeout left as is (IFNAMER_WAIT_S=10 sets 10 s; default 300 s)')

    if os.environ.get('LOCATION_SWITCH', '1') == '1':
        merge_pref(r, 'com.apple.locationd', {'LocationServicesEnabledIn8.0': True})
        print('location: LocationServicesEnabledIn8.0 = true (com.apple.locationd, user mobile)')
    else:
        print('location: off: LOCATION_SWITCH=0, the switch is left as the root has it')

if __name__ == '__main__':
    main()
