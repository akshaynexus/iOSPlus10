#!/usr/bin/env python3
"""The table of docs/laurel_sprout/ios26-parity.md, from the source and the images: every root stage and tweak of the iOS 16 root, every userland program, every laurel kernel patch.

  ios26-parity-audit.py --before ROOT_DIR --after ROOT_DIR [--kernel-dir DIR] [--write DOC]

ROOT_DIR has ios26-root.img.manifest and work/overlay of a root of scripts/laurel/ios26-root.sh. --before: the root before this table's hooks. --after: the root to judge.
It takes the lists from the files, not from this file: `feature` lines of root-features.sh, FEATURES of root-manifest.py, the tweak scripts of root.sh and the items in them, userland/laurel/*, patches/laurel/xnu/*.
Exit 1 when:
  an item of those lists is in no row below (a new feature cannot be missed silently);
  a row says it is in the root and the image does not have it.
State of a row: present (the root before had it, or the kernel alone does it) | ported now | not portable before a boot | not applicable. Nothing here proves it runs on the phone.
"""
import argparse
import ast
import glob
import os
import plistlib
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
XPC = 'System/Library/xpc/launchd.plist'
HAL = 'System/Library/Audio/Plug-Ins/HAL/'
BEGIN = '<!-- ios26-parity-audit.py: begin -->'
END = '<!-- ios26-parity-audit.py: end -->'


def row(name, ios16, patches='', paths=(), jobs=(), gone=(), prefs=(), kind='port', action='', claims=()):
    return dict(name=name, ios16=ios16, patches=patches.split(), paths=paths, jobs=jobs, gone=gone, prefs=prefs, kind=kind, action=action, claims=claims)


NOTE_KERNEL = 'Kernel only: no file on the root'
# kind: port = must be in --after; kernel = kernel alone; np = not portable before a boot (action = the reason and the evidence); na = not applicable (action = the evidence)
ROWS = [
    row('Wi-Fi: join, 5 GHz, signal bars', 'kernel series; stock wifid', '2400 2401 2402 2403 2405 2406 2407 2408 2409 2410 2411 2880 2881 2882 2883 2884 2885 2886 2887 2888',
        jobs=('com.apple.wifid',), kind='port', action='None. 23F84 sizes of Apple80211: kernel post/9000, ios26-userland.md 8.3, host test only'),
    row('Wi-Fi settings service', 'stock wifid (com.apple.wifi-xpc), configd; root-tweaks-extra.py InterfaceNamer', '2411',
        paths=('System/Library/SystemConfiguration/InterfaceNamer.bundle/Info.plist',), jobs=('com.apple.wifid', 'com.apple.wifianalyticsd'), kind='port',
        action='None new: wifid stays with its MachServices. Its load key needs the ADT node wlan: mkadt.py. wifiFirmwareLoader stays as on a stock root [U on this phone]', claims=('tweak:WaitStackTimeout',)),
    row('Cellular: SIM, bars, name in iOS', 'root-cell.sh, userland/laurel/cell/laurel_cellbar.c', '2760 2786',
        paths=('usr/local/lib/liblaurel-cellbar.dylib',), action='Hook cell. Classes and selectors in the 23F84 cache [V names]. Method types: its self-check. CommCenter stays out, as iOS 16', claims=('feature:cell', 'manifest:cell', 'userland:cell')),
    row('Cellular: data session (laurel-celld)', 'root-cell.sh, celld-job.py, userland/laurel/cell/laurel_celld.c', '2940 2941 2942 2943',
        paths=('usr/local/libexec/laurel-celld',), jobs=('com.laurel.celld',), action='Hook cell. KeepAlive false, exits at once with no kern.laurel_cell_net'),
    row('Cellular: dual SIM', 'kernel 2760 (nas1, nas2); cellbar shows both slots', '2786', paths=('usr/local/lib/liblaurel-cellbar.dylib',), action='Hook cell: the same two-slot code. Default SIM: not built on iOS 16 either'),
    row('Cellular: network search, SMS, voice, Settings > Cellular', 'not built on iOS 16 (cellular.md 11.6)', kind='na', action='iOS 16 has no such stage, so nothing to port. IOS-26-Hot has CoreTelephony XPC in its cellulard on 23F84 [self-reported]: a new feature, not parity'),
    row('Cellular: IPA data path', 'kernel; boot-arg ipa=0 by default (uefi-image.sh)', '2775 2780 2782 2941', kind='kernel', action='Same boot-arg path: ios26-image.sh calls uefi-image.sh. IPA_TEST=1 is the test image'),
    row('Audio out: speaker', 'root-audio.sh, external/ios-topaz/userland/audio', '2500', paths=(HAL + 'RedwoodAudio.driver/RedwoodAudio', 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio'),
        action='Hook audio: audiomxd loads the plug-in from the same folder [V strings; Hot self-reported]. 5 devices: Speaker, Hawking, Actuator, Codec, Baseband Voice (ios26-devices.patch). VirtualAudio stays, BTAudio to HAL.disabled', claims=('feature:audio', 'manifest:audio', 'userland:audio')),
    row('Microphone', 'userland/laurel/audio/mic-input.patch', '2920', paths=(HAL + 'RedwoodAudio.driver/RedwoodAudio',), action='Hook audio. Codec has 4 channels, the one microphone in each. Kernel: audiomxd is on its name list [V 2920]'),
    row('Voice input: Siri, Dictation', 'not tested on iOS 16 (audio.md): needs assistantd and Apple services', kind='na', action='iOS 16 has no stage for it; the microphone row is the part we own'),
    row('Mute switch answer', 'none on iOS 16', paths=('usr/local/lib/liblaurel-ringer.dylib',), action='Hook ringer: new for 23F84 (IOS-26-Hot 504d74c, self-reported). SpringBoard part only: backboardd has no wrapper on 26'),
    row('Haptics', 'kernel 2700 + Actuator device of the plug-in', '2700', paths=(HAL + 'RedwoodAudio.driver/RedwoodAudio',), action='Hook audio'),
    row('Bluetooth', 'root-bt.sh, scripts/bt/bt-launchd.py, userland/laurel/bt', '2600', paths=('usr/libexec/negroni-bluetool',), jobs=('com.apple.bluetoothd', 'com.apple.BlueTool'),
        action='Hook bluetooth: job with BT_HCI_TRANSPORT, stand-in. Strings of the transport in 23F84 bluetoothd [V]; the BlueTool XPC of 26: [U]', claims=('feature:bt', 'manifest:bluetooth', 'userland:bt')),
    row('Camera: kernel, sensor tables', 'root-camera.sh steps 1, 5', '2770 2771 2772 2773 2784 2913', paths=('usr/share/firmware/laurel-camera/libmmcamera_laurus_imx586_sunny.so', 'usr/share/firmware/laurel-camera/libactuator_dw9800.so'),
        action='Hook camera-tables: the kernel reads them, on any iOS', claims=('feature:camera', 'manifest:camera')),
    row('Camera: iOS plug-in', 'root-camera.sh step 2, userland/camera, userland/laurel/camera', kind='np',
        action='See "Camera" below: 20H392 hook table, capture moved to cameracaptured, vendor init changed, ABI not read, no frame with light on iOS 16 to compare', claims=('userland:camera',)),
    row('Flashlight', 'root-flashlight.sh, userland/laurel/flashlight', '2781 2783', paths=(HAL + 'LaurelFlashlight.driver/LaurelFlashlight', 'usr/local/libexec/laurel-cameracaptured'),
        action='Hook flashlight: LF_IOS26 build with the 23F84 vendor messages; laurel-cameracaptured inserts it', claims=('feature:torch', 'manifest:flashlight', 'userland:flashlight')),
    row('HEVC, HEIC, wallpapers', 'root-hevc.sh, userland/laurel/hevc', paths=('System/Library/VideoDecoders/HEVCH8.videodecoder',), action='Hook hevc: same slot in 23F84 VTLoadVideoDecoders, same decoder class shape [V]. Runs in videocodecd', claims=('feature:hevc', 'manifest:hevc', 'userland:hevc')),
    row('Brightness', 'root-brightness.py', '2201 2871 2872', prefs=(('com.apple.backboardd', 'BKEnableALS'),), action='Hook brightness', claims=('feature:brightness', 'manifest:brightness')),
    row('Touch', 'kernel', '2017 2200 2914', kind='kernel', action=NOTE_KERNEL),
    row('Keys', 'kernel', '2202', kind='kernel', action=NOTE_KERNEL),
    row('Top bar (status bar provider)', 'root-statusbar.py part 1', prefs=(('com.apple.UIKit', 'UIStatusBarVisualProviderClassName'),), action='Hook statusbar: same override; no iPhone model in it', claims=('feature:statusbar', 'manifest:statusbar')),
    row('Notch: waterdrop in SpringBoard', 'root-statusbar.py part 2, userland/laurel/notch', paths=('usr/local/lib/liblaurel-notch.dylib', 'usr/local/libexec/laurel-springboard'), jobs=('com.apple.SpringBoard',),
        action='Hook notch: asks the screen type in force and needs 360x780 @2, no iPhone10,3 in the code [V]. Safe areas: the type the N104AP ladder picks: read on the phone', claims=('manifest:notch', 'userland:notch')),
    row('Resolution 720x1560 @2', 'kernel 2103 + mkadt.py', '2001 2002 2008 2101 2103 2104 2870 2915', kind='kernel', action='ADT donor N104AP has artwork 0x700; the panel size is in /chosen display-scale. ios26-kernel.md 5'),
    row('Battery, charging', 'kernel', '2300 2301 2302 2710', kind='kernel', action=NOTE_KERNEL),
    row('Thermal, CPU clocks', 'kernel', '2303 2890 2891', kind='kernel', action=NOTE_KERNEL),
    row('RTC', 'kernel', '2720', paths=('private/var/db',), kind='port', action='The kernel writes /private/var/db/laurel_rtc; the folder is on the root'),
    row('XNUtils, stats', 'root-xnutils.sh, userland/laurel/xnutils', '2911', paths=('Applications/XNUtils.app/XNUtils', 'usr/local/libexec/powermenu-helper', 'usr/local/bin/pmregister'),
        action='Hook xnutils: XNUTILS_IOS26=1 copy; helper root:mobile 4750 in the catalog', claims=('feature:xnutils', 'manifest:xnutils', 'userland:xnutils')),
    row('Bench', 'none on iOS 16 stage (ios26-metal.md 10)', paths=('Applications/XNUtils.app/XNUtils',), action='Hook xnutils: bench.m is in the iOS 26 copy'),
    row('Widgets, posters: jetsam', 'root-tweaks-extra.py, jetsam_widgets.py', paths=('System/Library/LaunchDaemons/com.apple.jetsamproperties.N104.plist',), action='In tweaks() and root-add-metal-ios26.sh', claims=('tweak:WIDGET_JETSAM', 'tweak:LSD_JETSAM')),
    row('System apps', 'root-system-features.py', paths=('Applications/MobileCal.app/Info.plist', 'Applications/MobileNotes.app/Info.plist'), action='Hook staged-apps: 49 apps; the first LaunchServices seed registers them', claims=('tweak:STAGED_APPS', 'script:root-system-features.py')),
    row('aggregated job and its limit', 'root-system-features.py', kind='na', action='com.apple.aggregated is not in 23F84: launchd.plist has only .addaily [V]', claims=('tweak:RESTORE_JOBS',)),
    row('No-wipe update', 'root-update.sh, root-delta.py, rootupdate/', kind='np', action='See "No-wipe update" below: the path needs SSH on a booted root, and has never written on a phone on iOS 16'),
    row('GPU firmware', 'root-add-gpu.sh, gpu-firmware.sh', '2150 2151 2153 2154 2155 2156 2157 2158 2159 2160 2161 2892 2895', paths=('usr/share/firmware/laurel/a610_zap.mdt', 'usr/share/firmware/laurel/a630_sqe.fw'),
        action='Hook gpu-firmware. **The root before this table had none: `LAUREL GPU: off`, so no Metal device and no picture** [V code + manifest]', claims=('feature:gpu', 'manifest:gpu', 'userland:gpu')),
    row('Mesa, EAGL shim, backboardd GL wrapper', 'root-add-gpu.sh, gpu-userland.sh', '2152', kind='na', action='23F84: CA::WindowServer::AccelServer::renderer is Metal or nothing; the server path reaches no GLESContext [V ios26-userland.md 8.1]. Not missing'),
    row('Metal stack, compositor', 'root-add-metal.sh; iOS 26: root-add-metal-ios26.sh', '2850 2851', paths=('System/Library/Extensions/NegroniMetal.bundle/NegroniMetal',), action='Hook metal26', claims=('feature:metal', 'feature:bbdmetal', 'manifest:metal', 'userland:metal')),
    row('SSH, debug tools, USB network', 'scripts/net/root-add-ssh.sh; iOS 26: root-debug-ios26.sh', '2005 2006 2007 2013 2014 2162 2905 2951 2955 2956', paths=('usr/local/bin/dropbearmulti',), jobs=('dev.iosplus10.dropbear',), action='Hook debug-ios26', claims=('feature:ssh', 'manifest:ssh')),
    row('AirPlay', 'root-airplay.sh', paths=('usr/libexec/laurel-airplay',), jobs=('com.laurel.airplay',), action='Hook air-ios26', claims=('feature:airplay', 'manifest:airplay', 'userland:airplay')),
    row('AirDrop, AWDL', 'root-awdl.sh', '2930 2931 2932', paths=('usr/libexec/laurel-awdld',), jobs=('com.laurel.awdl',), gone=('com.apple.wifip2pd',), action='Hook air-ios26', claims=('feature:awdl', 'manifest:awdl', 'userland:awdl')),
    row('Bold text off', 'root-tweaks-boldtext.py', prefs=(('com.apple.Accessibility', 'EnhancedTextLegibilityEnabled'),), action='Hook bold-text', claims=('script:root-tweaks-boldtext.py',)),
    row('Jobs that only burn CPU', 'root-tweaks-perf.py', gone=('com.apple.syncdefaultsd',), action='In tweaks(). Program list unchanged; their loop on 26: [U]', claims=('script:root-tweaks-perf.py',)),
    row('launchd tweaks', 'sweet-root-tweaks.py, root-tweaks-extra.py', gone=('com.apple.CommCenter', 'com.apple.fairplayd.H2', 'com.apple.voicemail.vmd', 'com.apple.ReportCrash', 'com.apple.spindump', 'com.apple.tailspind', 'com.apple.activityawardsd'),
        action='In tweaks(), one audit line each', claims=('script:sweet-root-tweaks.py', 'script:root-tweaks-extra.py')),
    row('Root layout: containers, logd stores, keybag, dyld', 'external/ios-topaz/tools/mkiosroot.sh', '2904', paths=('private/var/keybags/systembag.kb', 'private/var/db/diagnostics/.migrated', 'private/var/containers/Bundle', 'System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e'),
        action='ios26-root-spec.py main() and tweaks()', claims=('script:mkiosroot.sh',)),
    row('Kernel base: CPU, RAM, UFS, boot, power off', 'kernel', '2000 2003 2004 2009 2011 2012 2015 2016 2018 2100 2404 2902 2906 2916', kind='kernel', action=NOTE_KERNEL),
    row('Sandbox grants, entitlements', 'kernel', '2903 2910', kind='kernel', action='Grants by entitlement, not by process name [V 2910]; 23F84 ops: post/9000'),
    row('Dual boot, build stamp', 'kernel; dual-boot.sh; root-manifest', '2912 2950', paths=('usr/share/laurel/root-manifest',), action='The manifest has one row per hook here'),
]


def manifest_paths(root):
    p = os.path.join(root, 'ios26-root.img.manifest')
    out = {}
    with open(p, 'rb') as f:
        for line in f:
            if line.startswith(b'#'):
                continue
            x = line.rstrip(b'\n').split(b'\0')
            if len(x) >= 8:
                out[x[7].decode('utf-8', 'surrogateescape')] = x
    return out


def load_overlay(root, rel):
    p = os.path.join(root, 'work/overlay', rel)
    if not os.path.exists(p):
        return {}
    with open(p, 'rb') as f:
        return plistlib.load(f)


def jobs_by_label(root):
    return {j.get('Label'): j for j in load_overlay(root, XPC).get('LaunchDaemons', {}).values() if isinstance(j, dict)}


def source_items():
    """What the iOS 16 root has, from its files."""
    items = []
    t = open(os.path.join(HERE, 'root-features.sh')).read()
    items += ['feature:' + x for x in re.findall(r'^\s*(?:if .*?; then )?feature (\w+) ', t, re.M)]
    t = open(os.path.join(HERE, 'root-manifest.py')).read()
    items += ['manifest:' + x for x in re.findall(r"dict\(name='(\w+)'", t)]
    t = open(os.path.join(HERE, 'root.sh')).read()
    items += ['script:' + os.path.basename(x) for x in re.findall(r'"\$(?:REPO|TOPAZ)[^"]*/((?:root-|sweet-|mkiosroot)[\w.-]+\.(?:py|sh))"', t) if os.path.basename(x) not in ('root-delta.py', 'root-manifest.py', 'root-fsck.sh', 'root-features.sh')]
    items += ['userland:' + x for x in sorted(os.listdir(os.path.join(REPO, 'userland/laurel')))]
    return list(dict.fromkeys(items))


def tweak_items():
    """Per item of the tweak scripts: (script, item, how to check on the image)."""
    out = []
    ext = os.path.join(HERE, '..', 'ios16', 'root-tweaks-extra.py')
    tree = ast.parse(open(ext).read())
    for n in tree.body:
        if isinstance(n, ast.Assign) and getattr(n.targets[0], 'id', '') == 'DROP':
            out += [('root-tweaks-extra.py', 'drop ' + v.value, ('gone', v.value)) for v in n.value.elts]
    for call in ast.walk(tree):
        if isinstance(call, ast.Call) and getattr(call.func, 'id', '') == 'merge_pref' and isinstance(call.args[1], ast.Constant) and isinstance(call.args[2], ast.Dict):
            out += [('root-tweaks-extra.py', f'{call.args[1].value} {k.value}', ('pref', call.args[1].value, k.value)) for k in call.args[2].keys]
    for call in ast.walk(tree):
        # the domains of the for loop: FBLaunchWatchdogScale
        if isinstance(call, ast.For) and isinstance(call.iter, ast.Tuple):
            for v in call.iter.elts:
                if isinstance(v, ast.Constant) and str(v.value).startswith('com.apple.'):
                    out.append(('root-tweaks-extra.py', f'{v.value} FBLaunchWatchdogScale', ('pref', v.value, 'FBLaunchWatchdogScale')))
    out.append(('root-tweaks-extra.py', 'InterfaceNamer WaitStackTimeout', ('plistkey', 'System/Library/SystemConfiguration/InterfaceNamer.bundle/Info.plist', 'WaitStackTimeout')))
    out.append(('root-tweaks-extra.py', 'ExtensionKit enforce_xpc_cache_code_signing', ('plistkey', 'private/var/preferences/FeatureFlags/Domain/ExtensionKit.plist', 'enforce_xpc_cache_code_signing')))
    out.append(('root-tweaks-extra.py', 'backboardd CA_HEARTBEAT_RATE', ('jobenv', 'com.apple.backboardd', 'CA_HEARTBEAT_RATE')))
    out.append(('root-tweaks-extra.py', 'widget + lsd jetsam', ('jetsam',)))
    top = os.path.join(REPO, 'external/ios-topaz/tools/sweet-root-tweaks.py')
    if not os.path.exists(top):
        top = os.path.join(os.path.dirname(REPO), 'external/ios-topaz/tools/sweet-root-tweaks.py')
    tree = ast.parse(open(top).read())
    for call in ast.walk(tree):
        if isinstance(call, ast.Call) and getattr(call.func, 'id', '') == 'merge_pref' and isinstance(call.args[1], ast.Constant):
            a = call.args[2]
            keys = [k.value for k in a.keys if isinstance(k, ast.Constant)] if isinstance(a, ast.Dict) else []
            if isinstance(a, ast.DictComp):
                keys = [e.value for e in a.generators[0].iter.elts]
            out += [('sweet-root-tweaks.py', f'{call.args[1].value} {k}', ('pref', call.args[1].value, k)) for k in keys]
    out.append(('sweet-root-tweaks.py', 'launchd _PanicOnCrash renamed', ('nopanic',)))
    out.append(('sweet-root-tweaks.py', 'drop com.apple.CommCenter', ('gone', 'com.apple.CommCenter')))
    out.append(('sweet-root-tweaks.py', 'MediaToolbox StartRecorderServer', ('audit', 'MediaToolbox StartRecorderServer')))
    out.append(('sweet-root-tweaks.py', 'activation data ark', ('audit', 'activation data ark')))
    out.append(('sweet-root-tweaks.py', 'containers', ('path', 'private/var/containers/Bundle')))
    t = open(os.path.join(HERE, 'root-tweaks-perf.py')).read()
    for prog in re.search(r"DEFAULT = '([^']+)'", t).group(1).split():
        out.append(('root-tweaks-perf.py', 'drop by program ' + prog, ('gone-program', prog)))
    out.append(('root-tweaks-boldtext.py', 'com.apple.Accessibility EnhancedTextLegibilityEnabled', ('pref', 'com.apple.Accessibility', 'EnhancedTextLegibilityEnabled')))
    out.append(('root-brightness.py', 'com.apple.backboardd BKEnableALS', ('pref', 'com.apple.backboardd', 'BKEnableALS')))
    t = open(os.path.join(HERE, 'root-statusbar.py')).read()
    out.append(('root-statusbar.py', 'com.apple.UIKit ' + re.search(r"KEY = '(\w+)'", t).group(1), ('pref', 'com.apple.UIKit', re.search(r"KEY = '(\w+)'", t).group(1))))
    out.append(('root-system-features.py', 'staged apps', ('path', 'Applications/MobileCal.app/Info.plist')))
    out.append(('root-system-features.py', 'aggregated back', ('na', 'not in 23F84: only com.apple.aggregated.addaily [V]')))
    return out


def judge_tweak(item, root, paths, labels, audit):
    k = item[0]
    if k == 'gone':
        if item[1] == 'com.apple.bluetoothd':       # dropped by the tweak, back by root-bt.sh on iOS 16 too
            return ('BT_HCI_TRANSPORT' in (labels.get(item[1]) or {}).get('EnvironmentVariables', {}), 'dropped, then back with BT_HCI_TRANSPORT from the bluetooth hook, as root-bt.sh on iOS 16')
        return (item[1] not in labels, 'job not in launchd.plist' if item[1] not in labels else 'JOB STILL THERE')
    if k == 'gone-program':
        left = [j for j in labels.values() if os.path.basename((j.get('Program') or (j.get('ProgramArguments') or [''])[0])) == item[1]]
        return (not left, 'no job runs it' if not left else 'JOB STILL THERE')
    if k == 'pref':
        d = load_overlay(root, f'private/var/mobile/Library/Preferences/{item[1]}.plist')
        return (item[2] in d, f'{item[2]} = {d.get(item[2])!r}' if item[2] in d else f'NO KEY in /var/mobile/Library/Preferences/{item[1]}.plist')
    if k == 'plistkey':
        d = load_overlay(root, item[1])
        return (item[2] in d, 'key present' if item[2] in d else 'NO KEY')
    if k == 'jobenv':
        v = (labels.get(item[1]) or {}).get('EnvironmentVariables', {}).get(item[2])
        return (v is not None, f'{item[2]}={v}' if v is not None else 'NOT SET')
    if k == 'jetsam':
        return ('System/Library/LaunchDaemons/com.apple.jetsamproperties.N104.plist' in paths and any(x.startswith('applied   jetsam') for x in audit), 'audit line, file in the overlay')
    if k == 'nopanic':
        d = load_overlay(root, XPC).get('LaunchDaemons', {})
        left = [n for n, j in d.items() if isinstance(j, dict) and '_PanicOnCrash' in j]
        return (not left, 'no job has the key' if not left else f'STILL: {left[:3]}')
    if k == 'audit':
        hit = [x for x in audit if x.split(None, 1)[1].startswith(item[1] + ':')]
        return (bool(hit), hit[0][:9].strip() + ' (audit line)' if hit else 'NO AUDIT LINE')
    if k == 'path':
        return (item[1] in paths, 'in the manifest' if item[1] in paths else 'NOT IN THE MANIFEST')
    if k == 'na':
        return (None, item[1])
    raise SystemExit(f'unknown tweak check {item}')


def patch_list():
    return sorted(os.path.basename(p)[:-6] for p in glob.glob(os.path.join(REPO, 'patches/laurel/xnu/*.patch')))


def kernel_facts(kdir):
    series = os.path.join(kdir, 'series-report.txt')
    report = {}
    if os.path.exists(series):
        with open(series) as f:
            for line in f:
                m = re.match(r'(\d{4}-laurel\S*)\.patch\s+(.*)', line)
                if m:
                    report[m.group(1)] = m.group(2).strip()
    k = os.path.join(kdir, 'out/kernel.ios26.development.sweet.4k.unstripped')
    blob = open(k, 'rb').read() if os.path.exists(k) else b''
    return report, blob


def marker(patch):
    with open(os.path.join(REPO, 'patches/laurel/xnu', patch + '.patch'), errors='replace') as f:
        added = [x for x in f if x.startswith('+')]
    for line in added:
        m = re.search(r'"(LAUREL [A-Z0-9 ]+:)', line)
        if m:
            return m.group(1)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--before', required=True)
    ap.add_argument('--after', required=True)
    ap.add_argument('--kernel-dir', default=os.path.join(REPO, 'out/laurel-kernel-ios26'))
    ap.add_argument('--write')
    a = ap.parse_args()
    before, after = manifest_paths(a.before), manifest_paths(a.after)
    jb, ja = jobs_by_label(a.before), jobs_by_label(a.after)
    with open(os.path.join(a.after, 'work/audit.txt')) as f:
        audit = f.read().splitlines()
    report, blob = kernel_facts(a.kernel_dir)
    # completeness: every item of the source lists is in a row
    claimed = {c for r in ROWS for c in r['claims']}
    fail = []
    for it in source_items():
        if it not in claimed:
            fail.append(f'UNCLAIMED source item {it}: no row in {os.path.basename(__file__)}')
    patches = patch_list()
    by_num = {p[:4]: p for p in patches}
    rowed = {n for r in ROWS for n in r['patches']}
    for n in sorted(by_num):
        if n not in rowed:
            fail.append(f'UNCLAIMED kernel patch {by_num[n]}: no row')
    for n in sorted(rowed - set(by_num)):
        fail.append(f'row names patch {n}: no such file')
    lines = ['| Feature | iOS 16 path | In kernel-ios26 | In iOS 26 root | State | Action |', '|---|---|---|---|---|---|']
    count = {'present': 0, 'ported now': 0, 'not portable before a boot': 0, 'not applicable': 0}
    for r in ROWS:
        ks = []
        kyes = True
        for n in r['patches']:
            p = by_num.get(n)
            st = report.get(p, 'no line')
            good = st.startswith(('applied', 'base'))
            if st.startswith('skipped: upstream'):
                good = True
            kyes &= good
            ks.append(n if good else f'{n}: {st[:40]}')
        mk = [marker(by_num[n]) for n in r['patches'] if n in by_num]
        mk = [m for m in mk if m]
        found = [m for m in dict.fromkeys(mk) if m.encode() in blob]
        missing = [m for m in dict.fromkeys(mk) if m.encode() not in blob]
        kcol = '-'
        if r['patches']:
            kcol = ('yes: ' if kyes and not missing else 'NO: ') + ' '.join(ks) + ('; strings ' + ', '.join(f'`{m}`' for m in found[:3]) if found else '')
            if missing:
                kcol += '; not in the binary: ' + ', '.join(missing)
        ev_after, ev_before = [], []
        ok_after = ok_before = True
        for p in r['paths']:
            ok_after &= p in after
            ok_before &= p in before
            ev_after.append(('' if p in after else 'NO ') + '`/' + p + '`')
        for j in r['jobs']:
            ok_after &= j in ja
            ok_before &= j in jb
            ev_after.append(('job ' if j in ja else 'NO job ') + j)
        for g in r['gone']:
            ok_after &= g not in ja
            ok_before &= g not in jb
            ev_after.append(('no job ' if g not in ja else 'JOB STILL ') + g)
        for dom, key in r['prefs']:
            d = load_overlay(a.after, f'private/var/mobile/Library/Preferences/{dom}.plist')
            e = load_overlay(a.before, f'private/var/mobile/Library/Preferences/{dom}.plist')
            ok_after &= key in d
            ok_before &= key in e
            ev_after.append((f'pref {dom} {key}={d[key]!r}') if key in d else f'NO pref {dom} {key}')
        kind = r['kind']
        if kind == 'kernel':
            state = 'present'
            rcol = 'not needed'
            if not kyes or missing:
                fail.append(f'{r["name"]}: kernel: {kcol}')
        elif kind == 'na':
            state = 'not applicable'
            rcol = 'no: nothing to port'
        elif kind == 'np':
            state = 'not portable before a boot'
            rcol = 'no: one audit line `off`'
        else:
            if not ok_after:
                fail.append(f'{r["name"]}: not in the --after root: {ev_after}')
            state = 'present' if ok_before else 'ported now'
            rcol = ('yes: ' if ok_after else 'NO: ') + ', '.join(ev_after)
            if r['patches'] and (not kyes or missing):
                fail.append(f'{r["name"]}: kernel: {kcol}')
        count[state] += 1
        lines.append(f'| {r["name"]} | {r["ios16"]} | {kcol} | {rcol} | {state} | {r["action"]} |')
    tw = ['| Script | Item | iOS 26 root | Evidence |', '|---|---|---|---|']
    tn = {'same': 0, 'na': 0, 'differs': 0}
    labels = ja
    for script, item, how in tweak_items():
        good, ev = judge_tweak(how, a.after, after, labels, audit)
        tn['na' if good is None else 'same' if good else 'differs'] += 1
        tw.append(f'| {script} | {item} | {"n/a" if good is None else "yes" if good else "NO"} | {ev} |')
    # the hooks' lines of this root, as they are
    hooks = [x for x in audit if x.split(None, 1)[0] in ('off', 'applied') and x.split(None, 1)[1].split(':')[0] in
             ('debug-ios26', 'air-ios26', 'metal26', 'gpu-firmware', 'statusbar', 'notch', 'cell', 'ringer', 'audio', 'bluetooth', 'camera-tables', 'camera-plugin', 'flashlight', 'hevc', 'xnutils', 'brightness', 'bold-text', 'staged-apps', 'root-update')]
    text = [BEGIN, '', f'Generated by `scripts/laurel/ios26-parity-audit.py`. Counts: **{count["present"]} present, {count["ported now"]} ported now, {count["not portable before a boot"]} not portable before a boot, {count["not applicable"]} not applicable**, of {len(ROWS)} rows. '
            f'{len(source_items())} source items and {len(patches)} kernel patches, each in a row. Tweak items: {tn["same"]} same, {tn["na"]} not applicable, {tn["differs"]} differ.', '', '### Features', ''] + lines
    text += ['', '### Tweaks of the iOS 16 root, per item', ''] + tw + ['', '### Audit lines of the hooks in the judged root', '', '```'] + [x[:230] for x in hooks] + ['```', '', END]
    out = '\n'.join(text) + '\n'
    print(f'rows {len(ROWS)}: {count}')
    print(f'source items {len(source_items())}, kernel patches {len(patches)}, tweak items {tn}')
    if tn['differs']:
        for x in tw[2:]:
            if ' | NO | ' in x:
                print('tweak differs:', x)
    for x in fail:
        print('FAILED: ' + x)
    if a.write:
        d = open(a.write).read() if os.path.exists(a.write) else BEGIN + '\n' + END + '\n'
        i, j = d.index(BEGIN), d.index(END) + len(END) + 1
        with open(a.write, 'w') as f:
            f.write(d[:i] + out + d[j:])
        print('written:', a.write)
    sys.exit(1 if fail else 0)


if __name__ == '__main__':
    main()
