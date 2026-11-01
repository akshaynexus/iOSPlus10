#!/usr/bin/env python3
"""Mi A3 root: one table of every feature, from what the files say. docs/laurel_sprout/build-honest.md.

  root-manifest.py preflight [--inputs FILE]   before the slow steps: every stage of a wanted feature exists and is newer than its
                                               sources, the kernel stamp matches the patches. Prints the inputs; exit 1 = do not start.
  root-manifest.py inputs-check FILE           the inputs are still the ones of FILE (a script changed during the run = exit 1)
  root-manifest.py finish ROOT --steps DIR --inputs FILE --sidecar PATH
                                               table of ROOT: state from the files in ROOT, reason from the step's log. Writes
                                               ROOT/usr/share/laurel/root-manifest and PATH. Exit 1 when a feature is missing.
  root-manifest.py begin PATH | fail PATH WHY  the sidecar says "building" or "failed": no flash from an unfinished run
  root-manifest.py seal PATH SIMG              the run ended well: the sidecar records status ok and the sparse image's size and time
  root-manifest.py flash-check PATH SIMG BOOTIMG   the image can go to the phone (exit 1 = stale or incomplete, reasons listed)
  root-manifest.py switches                    "AUDIO=1 BT=1 ..." for `sudo env` (sudo drops the caller's environment)

A new feature = one row in FEATURES. State: installed | off (its own NAME=0) | missing (with the reason). Only NAME=0 may leave a
feature out: anything else ends the build with exit 1. The sidecar next to the image is the same text + the image's size and time.
"""
import glob
import hashlib
import importlib.util
import os
import plistlib
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get('LAUREL_REPO') or os.path.dirname(os.path.dirname(HERE))
_s = importlib.util.spec_from_file_location('build_stamp', os.path.join(HERE, 'build-stamp.py'))
bs = importlib.util.module_from_spec(_s)
_s.loader.exec_module(bs)

MANIFEST = 'usr/share/laurel/root-manifest'
JOBS = 'System/Library/LaunchDaemons/'
LAUNCHD = 'System/Library/xpc/launchd.plist'
HAL = 'System/Library/Audio/Plug-Ins/HAL/'
GPU = 'out/laurel/gpu/root/'
METAL = 'out/metal/stage/System/Library/Extensions/NegroniMetal.bundle/'
SB = 'usr/local/libexec/laurel-springboard'
XNU = 'out/laurel/xnutils/root/'
UIKIT = 'private/var/mobile/Library/Preferences/com.apple.UIKit.plist'
BACKBOARD = 'private/var/mobile/Library/Preferences/com.apple.backboardd.plist'
# Every script the root run reads. A change during the run means the image is not what this list says.
SCRIPTS = ['scripts/laurel/root*.sh', 'scripts/laurel/root*.py', 'scripts/laurel/metal-gate-job.py', 'scripts/laurel/metal-job-env.py',
           'scripts/laurel/camera-tables.py', 'scripts/laurel/camera-tuning.py', 'scripts/ios16/root-tweaks-extra.py', 'scripts/ios16/root-tweaks-boldtext.py',
           'scripts/ios16/jetsam_widgets.py', 'scripts/metal/root-add-metal.sh', 'scripts/bt/bt-launchd.py', 'scripts/net/root-add-ssh.*',
           'external/ios-topaz/tools/mkiosroot.sh', 'external/ios-topaz/tools/sweet-root-tweaks.py']


NOT_INPUTS = ('root-flash-test.sh', 'root-dry-run.sh')     # they do not make the image


def plist(root, rel):
    try:
        with open(os.path.join(root, rel), 'rb') as fh:
            return plistlib.load(fh)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return {}


def job(root, name):
    return plist(root, LAUNCHD).get('LaunchDaemons', {}).get('/' + JOBS + name + '.plist')


def has(root, rel):
    return glob.glob(os.path.join(root, rel)) != []


def check_gpu(root):
    p = os.path.join(root, 'usr/libexec/backboardd')
    return [] if os.path.isfile(p) and b'/usr/libexec/real/backboardd' in open(p, 'rb').read() else ['/usr/libexec/backboardd is not the GL wrapper']


def check_bt(root):
    return [] if job(root, 'com.apple.bluetoothd') else ['no com.apple.bluetoothd job in the launchd cache']


def check_camera(root):
    d = plist(root, JOBS + 'com.apple.mediaserverd.plist').get('MachServices', {})
    return [] if 'com.apple.coremedia.capturesource' in d and 'com.apple.coremedia.capturesession' in d else ['the mediaserverd job has no capture services']


def check_torch(root):
    if has(root, HAL + 'NegroniCamera.driver/NegroniCamera') or has(root, HAL + 'LaurelFlashlight.driver/LaurelFlashlight'):
        return []
    return ['no owner: neither NegroniCamera.driver nor LaurelFlashlight.driver']


def check_statusbar(root):
    return [] if plist(root, UIKIT).get('UIStatusBarVisualProviderClassName') else ['no status bar provider in com.apple.UIKit.plist']


def check_notch(root):
    j = job(root, 'com.apple.SpringBoard') or {}
    return [] if (j.get('ProgramArguments') or [''])[0] == '/' + SB else ['the SpringBoard job does not start laurel-springboard']


def check_brightness(root):
    return [] if plist(root, BACKBOARD).get('BKEnableALS') is False else ['BKEnableALS is not false']


def check_xnutils(root):
    # the helper's setuid bit is the point of it; a run as the user (a test on a copy) cannot set it
    p = os.path.join(root, 'usr/local/libexec/powermenu-helper')
    if os.geteuid() == 0 and os.path.isfile(p) and not os.stat(p).st_mode & 0o4000:
        return ['powermenu-helper is not setuid']
    return []


def check_airplay(root):
    bad = []
    if '/System/Library/LaunchDaemons/com.laurel.airplay.plist' not in plist(root, 'System/Library/xpc/launchd.plist').get('LaunchDaemons', {}):
        bad.append('no job com.laurel.airplay')
    if os.environ.get('AIRDROP_LAN', '1') != '0' and not plist(root, 'private/var/Managed Preferences/mobile/com.apple.Sharing.plist').get('BrowseAllInterfaces'):
        bad.append('no BrowseAllInterfaces in the managed preferences')
    return bad


def check_ssh(root):
    bad = [] if job(root, 'dev.iosplus10.dropbear') else ['no dev.iosplus10.dropbear job in the launchd cache']
    if not job(root, 'dev.iosplus10.laurelnet'):
        bad.append('no dev.iosplus10.laurelnet job in the launchd cache: no LAUREL NET line')
    if job(root, 'dev.iosplus10.usbnetcfg') and os.environ.get('USBNET_INTERNET') != '1':
        bad.append('dev.iosplus10.usbnetcfg job in the launchd cache: USB takes the default route and DNS from Wi-Fi')
    return bad


def need_flashlight():
    return os.environ.get('CAMERA', '1') == '0'


# name, switch, step log, build command, stage files (glob = at least one), stage trees (hashed), sources (stage must be newer),
# root files (glob = at least one), root check
FEATURES = [
    dict(name='gpu', switch='GPU', build='scripts/laurel/gpu-firmware.sh + gpu-userland.sh',
         stage=[GPU + 'topaz/lib/libOSMesa.8.dylib', GPU + 'topaz/lib/libtopaz-gl.dylib', GPU + 'topaz/lib/libtopaz-inject.dylib',
                GPU + 'usr/libexec/backboardd.wrap', GPU + 'usr/share/firmware/laurel/a610_zap.mdt', GPU + 'usr/share/firmware/laurel/a610_zap.b0*'],
         trees=[GPU], sources=['userland/laurel/gpu', 'userland/laurel/metal/metal_gate.c'],
         root=['topaz/lib/libOSMesa.8.dylib', 'topaz/lib/libtopaz-gl.dylib', 'topaz/lib/libtopaz-inject.dylib', 'usr/libexec/real/backboardd',
               'usr/share/firmware/laurel/a610_zap.mdt'], check=check_gpu),
    dict(name='metal', switch='METAL', build='scripts/laurel/metal-build.sh',
         stage=[METAL + 'NegroniMetal', METAL + 'libvulkan_freedreno.dylib', METAL + 'Info.plist', 'out/metal/stage/var/db/negronimetal/clients',
                GPU + 'usr/libexec/laurel-metal-gate'],
         trees=['out/metal/stage'], sources=['userland/laurel/metal', 'userland/metal'],
         root=['System/Library/Extensions/NegroniMetal.bundle/NegroniMetal', 'System/Library/Extensions/NegroniMetal.bundle/libvulkan_freedreno.dylib',
               'private/var/db/negronimetal/clients', 'usr/libexec/laurel-metal-gate']),
    dict(name='hevc', switch='HEVC', build='scripts/laurel/hevc-build.sh',
         stage=['out/laurel/hevc/HEVCH8.videodecoder', 'out/laurel/hevc/SHA256SUMS'], trees=['out/laurel/hevc/HEVCH8.videodecoder'], sources=['userland/laurel/hevc'],
         root=['System/Library/VideoDecoders/HEVCH8.videodecoder']),
    dict(name='audio', switch='AUDIO', build='userland/laurel/audio/build.sh',
         stage=['out/laurel/audio/RedwoodAudio.driver/RedwoodAudio'], trees=['out/laurel/audio/RedwoodAudio.driver'], sources=['userland/laurel/audio'],
         root=[HAL + 'RedwoodAudio.driver/RedwoodAudio', 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin', 'Library/Audio/Tunings/D22',
               'System/Library/Audio/UISounds', 'Library/Ringtones']),
    dict(name='bluetooth', switch='BT', step='bt', build='userland/laurel/bt/build.sh',
         stage=['out/laurel/bt/negroni-bluetool'], trees=['out/laurel/bt/negroni-bluetool'], sources=['userland/laurel/bt', 'userland/bluetooth'],
         root=['usr/libexec/negroni-bluetool'], check=check_bt),
    dict(name='camera', switch='CAMERA', build='scripts/laurel/camera-inventory.sh + userland/laurel/camera/build.sh',
         stage=['out/laurel/camera/ios/NegroniCamera.driver/NegroniCamera', 'out/laurel/camera/lib/libmmcamera_laurus_imx586_*.so',
                'out/laurel/camera/lib/libactuator_dw9800.so', 'out/laurel/camera/lib/libactuator_laurus_dw9800w_qtech.so'],
         trees=['out/laurel/camera/ios/NegroniCamera.driver', 'out/laurel/camera/lib'], sources=['userland/laurel/camera', 'userland/camera'],
         root=[HAL + 'NegroniCamera.driver/NegroniCamera', 'usr/share/firmware/laurel-camera/libmmcamera_laurus_imx586_*.so',
               'usr/share/firmware/laurel-camera/libactuator_dw9800.so', 'usr/share/firmware/laurel-camera/libactuator_laurus_dw9800w_qtech.so',
               HAL + 'NegroniCamera.driver/camera-imx586-sunny.isp', HAL + 'NegroniCamera.driver/camera-imx586-qtech.isp'], check=check_camera),
    dict(name='flashlight', switch='TORCH', step='torch', build='userland/laurel/flashlight/build.sh',
         stage=['out/laurel/flashlight/LaurelFlashlight.driver/LaurelFlashlight'], only_if=need_flashlight, trees=['out/laurel/flashlight/LaurelFlashlight.driver'],
         sources=['userland/laurel/flashlight'], root=[], check=check_torch),
    dict(name='statusbar', switch='STATUSBAR', build='-', stage=[], trees=[], sources=[], root=[], check=check_statusbar),
    dict(name='notch', switch='NOTCH', also_off='STATUSBAR', step='statusbar', build='scripts/laurel/notch-build.sh',
         stage=['out/laurel/notch/root/usr/local/lib/liblaurel-notch.dylib', 'out/laurel/notch/root/' + SB], trees=['out/laurel/notch/root'], sources=['userland/laurel/notch'],
         root=['usr/local/lib/liblaurel-notch.dylib', SB], check=check_notch),
    dict(name='cell', switch='CELL', also_off=('NOTCH', 'STATUSBAR'), build='scripts/laurel/cell-build.sh',
         stage=['out/laurel/cell/root/usr/local/lib/liblaurel-cellbar.dylib', 'out/laurel/cell/root/usr/local/libexec/laurel-celld'], trees=['out/laurel/cell/root'], sources=['userland/laurel/cell'],
         root=['usr/local/lib/liblaurel-cellbar.dylib', 'usr/local/libexec/laurel-celld'], check=check_notch),
    dict(name='brightness', switch='BRIGHTNESS', build='-', stage=[], trees=[], sources=[], root=[], check=check_brightness),
    dict(name='xnutils', switch='XNUTILS', build='scripts/laurel/xnutils-build.sh',
         stage=[XNU + 'Applications/XNUtils.app/XNUtils', XNU + 'usr/local/libexec/powermenu-helper', XNU + 'usr/local/bin/pmregister'],
         trees=[XNU], sources=['userland/laurel/xnutils', 'userland/rebootapp'],
         root=['Applications/XNUtils.app/XNUtils', 'Applications/XNUtils.app/Info.plist', 'usr/local/libexec/powermenu-helper', 'usr/local/bin/pmregister'], check=check_xnutils),
    dict(name='airplay', switch='AIRPLAY', build='scripts/laurel/airplay-build.sh', stage=['out/laurel/airplay/root/usr/libexec/laurel-airplay'],
         trees=['out/laurel/airplay/root'], sources=['userland/laurel/airplay'], root=['usr/libexec/laurel-airplay'], check=check_airplay),
    dict(name='ssh', switch='SSH', build='userland/ssh/fetch.sh, fetch-sdk.sh, build.sh', stage=['out/ssh/ios/dropbearmulti', 'out/ssh/ios/laurelnet'], trees=['out/ssh/ios'],
         sources=['userland/ssh'], root=['usr/local/bin/dropbearmulti', 'usr/local/bin/laurelnet'], check=check_ssh),
]

def off_by_switch(f):
    also = f.get('also_off')
    for s in (f['switch'],) + (also if isinstance(also, tuple) else (also,)):
        if s and os.environ.get(s, '1') == '0':
            return '%s=0' % s
    return None


def newest(path):
    """Time of the newest file under path (a file or a directory)."""
    if os.path.isfile(path):
        return os.stat(path).st_mtime, path
    best = (0, path)
    for d, _dirs, names in os.walk(path):
        for n in names:
            p = os.path.join(d, n)
            if not os.path.islink(p) and n != '.DS_Store' and '__pycache__' not in p:
                best = max(best, (os.stat(p).st_mtime, p))
    return best


def tree_hash(path):
    """Names and contents of a file or tree; 'absent' when there is none."""
    full = os.path.join(REPO, path)
    if os.path.isfile(full):
        return bs.sha256_file(full)[:16]
    if not os.path.isdir(full):
        return 'absent'
    h = hashlib.sha256()
    for d, dirs, names in sorted(os.walk(full)):
        dirs.sort()
        for n in sorted(names):
            p = os.path.join(d, n)
            h.update(('%s\0%s\n' % (os.path.relpath(p, full), os.readlink(p) if os.path.islink(p) else bs.sha256_file(p))).encode())
    return h.hexdigest()[:16]


def inputs():
    """name -> hash of everything this root is made from. A feature that is off has no stage input."""
    out = {'patches': bs.series_hash(bs.repo_series_items())}
    for pat in SCRIPTS:
        for p in sorted(glob.glob(os.path.join(REPO, pat))):
            if os.path.basename(p) in NOT_INPUTS:
                continue
            out['script:' + os.path.relpath(p, REPO)] = bs.sha256_file(p)[:16]
    for f in FEATURES:
        if not off_by_switch(f) and (f.get('only_if') is None or f['only_if']()):
            for t in f['trees']:
                out['stage:%s:%s' % (f['name'], t.rstrip('/'))] = tree_hash(t)
    return out


def write_inputs(path, values):
    with open(path, 'w') as fh:
        for k, v in values.items():
            fh.write('%s %s\n' % (k, v))


def read_inputs(path):
    with open(path) as fh:
        return dict(line.split(None, 1) if ' ' in line else (line.strip(), '') for line in fh.read().splitlines())


def kernel_path():
    return os.environ.get('KERNEL') or os.path.join(REPO, 'out/laurel-kernel/out/kernel.development.sweet.' + os.environ.get('PAGES', '4k'))


def preflight(a):
    fail = []
    for f in FEATURES:
        why = off_by_switch(f)
        if why:
            print('laurel-root: preflight: %-10s off: %s' % (f['name'], why))
            continue
        if f.get('only_if') is not None and not f['only_if']():
            print('laurel-root: preflight: %-10s no stage needed' % f['name'])
            continue
        lack = [s for s in f['stage'] if not has(REPO, s)]
        if lack:
            fail.append('%s: no %s (%s; or %s=0 to leave it out)' % (f['name'], ', '.join(lack), f['build'], f['switch']))
            continue
        stale = None
        if f['stage'] and f['sources']:
            stage_t = max(newest(os.path.join(REPO, t))[0] for t in f['trees'])
            src_t, src = max(newest(os.path.join(REPO, s)) for s in f['sources'])
            if src_t > stage_t:
                stale = '%s: stage is older than %s (%s)' % (f['name'], os.path.relpath(src, REPO), f['build'])
        if stale:
            fail.append(stale)
        else:
            print('laurel-root: preflight: %-10s stage ok' % f['name'])
    why = bs.kernel_check(kernel_path())
    if why:
        fail.append('kernel: %s' % why)
    now = inputs()
    for k, v in now.items():
        print('laurel-root: input %s %s' % (k, v))
    if a.get('--inputs'):
        write_inputs(a['--inputs'], now)
    for s in fail:
        print('laurel-root: FAILED: %s' % s)
    if fail:
        print('laurel-root: FAILED: %d stage problem(s): scripts/laurel/build-all.sh builds them all; no root started' % len(fail))
    return 1 if fail else 0


def inputs_changed(old):
    now = inputs()
    return sorted(k for k in set(now) | set(old) if now.get(k) != old.get(k))


def reason_from_log(steps, f):
    """The step's own words: the last line that says why, else the exit code."""
    name = f.get('step') or f['name']
    text, rc = '', '0'
    try:
        with open(os.path.join(steps, name + '.log'), errors='replace') as fh:
            text = fh.read()
    except OSError:
        return 'the step did not run'
    try:
        with open(os.path.join(steps, name + '.rc')) as fh:
            rc = fh.read().strip()
    except OSError:
        pass
    said = [s for s in text.splitlines() if re.search(r'WARNING|FAILED|off:|skipped|failed|Traceback|rror:', s)]
    return (('exit %s: ' % rc) if rc != '0' else '') + (said[-1].strip()[:150] if said else (text.strip().splitlines() or ['no output'])[-1][:150])


def table(root, steps):
    rows = []
    for f in FEATURES:
        why = off_by_switch(f)
        if why:
            rows.append((f['name'], 'off', why))
            continue
        lack = [r for r in f['root'] if not has(root, r)]
        lack += f['check'](root) if f.get('check') else []
        rc = '0'
        try:
            with open(os.path.join(steps, (f.get('step') or f['name']) + '.rc')) as fh:
                rc = fh.read().strip()
        except OSError:
            rc = 'none'
        if lack or rc != '0':
            rows.append((f['name'], 'missing', '%s; %s' % (', '.join(lack)[:120] or 'step failed', reason_from_log(steps, f))))
            continue
        first = next((g for r in f['root'] for g in sorted(glob.glob(os.path.join(root, r))) if os.path.isfile(g)), None)
        rows.append((f['name'], 'installed', '/%s sha256 %s' % (os.path.relpath(first, root), bs.sha256_file(first)[:16]) if first else 'checked'))
    return rows


def manifest_text(rows, ins, status):
    st = bs.read_stamp(kernel_path() + '.stamp') or {}
    n = {s: sum(r[1] == s for r in rows) for s in ('installed', 'off', 'missing')}
    lines = ['%s %s kernel-series %s features %d installed %d off %d missing %d' % (bs.commit(), bs.utc(), st.get('series', 'none'), len(rows), n['installed'], n['off'], n['missing'])]
    lines += ['feature\t%s\t%s\t%s' % r for r in rows]
    lines += ['input\t%s\t%s' % kv for kv in ins.items()]
    lines.append('status\t%s' % status)
    return '\n'.join(lines) + '\n'


def finish(a, root):
    rows = table(root, a['--steps'])
    ins = read_inputs(a['--inputs'])
    w = max(len(r[0]) for r in rows)
    print('laurel-root: %-*s  %-9s  %s' % (w, 'feature', 'state', 'detail'))
    for r in rows:
        print('laurel-root: %-*s  %-9s  %s' % (w, r[0], r[1], r[2]))
    miss = [r[0] for r in rows if r[1] == 'missing']
    print('laurel-root: %d installed, %d off by their own switch, %d missing%s' % (sum(r[1] == 'installed' for r in rows), sum(r[1] == 'off' for r in rows),
                                                                                  len(miss), ': ' + ' '.join(miss) if miss else ''))
    text = manifest_text(rows, ins, 'ok' if not miss else 'missing ' + ' '.join(miss))
    p = os.path.join(root, MANIFEST)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'w') as fh:
        fh.write(text)
    os.chmod(p, 0o644)
    os.chmod(os.path.dirname(p), 0o755)
    if os.geteuid() == 0:
        os.chown(p, 0, 0)
        os.chown(os.path.dirname(p), 0, 0)
    with open(a['--sidecar'], 'w') as fh:
        fh.write(text.replace('status\tok\n', 'status\tbuilding\n'))
    print('laurel-root: /%s: %s' % (MANIFEST, text.splitlines()[0]))
    return 1 if miss else 0


def set_status(path, status, extra=()):
    """Replace the sidecar's status line. No sidecar yet: one line says what is known."""
    try:
        with open(path) as fh:
            lines = [s for s in fh.read().splitlines() if not s.startswith(('status\t', 'simg-'))]
    except OSError:
        lines = []
    lines += list(extra) + ['status\t%s' % status]
    with open(path + '.new', 'w') as fh:
        fh.write('\n'.join(lines) + '\n')
    os.replace(path + '.new', path)
    return 0


def read_sidecar(path):
    side = {'features': [], 'inputs': {}, 'first': ''}
    with open(path) as fh:
        for i, line in enumerate(fh.read().splitlines()):
            p = line.split('\t')
            if i == 0 and p[0] not in ('status',):
                side['first'] = line
            if p[0] == 'feature' and len(p) >= 4:
                side['features'].append(p[1:4])
            elif p[0] == 'input' and len(p) >= 3:
                side['inputs'][p[1]] = p[2]
            elif p[0] in ('status', 'simg-size', 'simg-mtime') and len(p) >= 2:
                side[p[0]] = p[1]
    return side


def flash_check(sidecar, simg, bootimg):
    """Reasons why this root and boot image must not go to the phone; prints what was used."""
    fail = []
    if not os.path.isfile(simg):
        return ['no root image %s (scripts/laurel/root.sh)' % simg]
    if not os.path.isfile(sidecar):
        return ['no %s: the image is not from a checked root.sh run' % os.path.basename(sidecar)]
    side = read_sidecar(sidecar)
    print('flash-check: root %s' % side['first'])
    print('flash-check: image %s, %d bytes, %s' % (simg, os.path.getsize(simg), bs.time.ctime(os.stat(simg).st_mtime)))
    if side.get('status') != 'ok':
        fail.append('the root run did not finish well: status %s' % side.get('status', 'none'))
    st = os.stat(simg)
    if side.get('simg-size') != str(st.st_size) or side.get('simg-mtime') != str(int(st.st_mtime)):
        fail.append('the image changed after root.sh sealed it (size or time differ from %s)' % os.path.basename(sidecar))
    fail += ['feature %s: %s' % (f[0], f[2]) for f in side['features'] if f[1] == 'missing']
    # the same inputs now? A rebuilt stage or an edited script makes the image old, whatever the times say.
    now = inputs()
    for k in sorted(set(now) | set(side['inputs'])):
        if now.get(k) != side['inputs'].get(k):
            fail.append('%s: image built from %s, now %s' % (k, side['inputs'].get(k, 'nothing'), now.get(k, 'nothing')))
    # one build: root, kernel and boot image
    kern = kernel_path()
    fd = os.environ.get('FD') or os.path.join(REPO, 'out/laurel/mu/SILICIUM_UEFI-DEBUG.fd')
    why = bs.kernel_check(kern)
    if why:
        fail.append('kernel: %s' % why)
    series = (bs.read_stamp(kern + '.stamp') or {}).get('series')
    m = re.search(r'kernel-series (\S+)', side['first'])
    if m and m[1] != series:
        fail.append('the root was built for kernel series %s, the kernel is %s' % (m[1], series))
    why = bs.image_check(bootimg, kern, fd)
    if why:
        fail.append('boot image: %s' % why)
    else:
        img = bs.read_stamp(bootimg + '.stamp') or {}
        print('flash-check: boot image %s' % img.get('line'))
        if img.get('kernel_series') != series:
            fail.append('the boot image holds kernel series %s, the kernel is %s' % (img.get('kernel_series'), series))
    print('flash-check: kernel %s' % (bs.read_stamp(kern + '.stamp') or {}).get('stamp'))
    return fail


def flags(argv):
    """--name VALUE pairs; the rest in order."""
    a, rest, i = {}, [], 0
    while i < len(argv):
        if argv[i].startswith('--'):
            a[argv[i]] = argv[i + 1]
            i += 2
        else:
            rest.append(argv[i])
            i += 1
    return a, rest


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd = argv[0]
    a, rest = flags(argv[1:])
    if cmd == 'preflight':
        return preflight(a)
    if cmd == 'inputs-check':
        changed = inputs_changed(read_inputs(rest[0]))
        for k in changed:
            print('laurel-root: FAILED: %s changed during this run' % k)
        return 1 if changed else 0
    if cmd == 'finish':
        return finish(a, rest[0])
    if cmd == 'begin':
        return set_status(rest[0], 'building')
    if cmd == 'fail':
        return set_status(rest[0], 'failed ' + ' '.join(rest[1:]))
    if cmd == 'seal':
        st = os.stat(rest[1])
        return set_status(rest[0], 'ok', ('simg-size\t%d' % st.st_size, 'simg-mtime\t%d' % int(st.st_mtime)))
    if cmd == 'flash-check':
        fail = flash_check(rest[0], rest[1], rest[2])
        for s in fail:
            print('flash-check: FAILED: %s' % s)
        if fail and os.environ.get('STALE_OK') == '1':
            print('flash-check: STALE_OK=1: the owner flashes this image with %d problem(s) listed above' % len(fail))
            return 0
        if fail:
            print('flash-check: nothing flashed. Rebuild (scripts/laurel/build-all.sh, then root.sh), or STALE_OK=1 for this image as it is')
            return 1
        print('flash-check: ok: root, kernel, boot image and stages are one build')
        return 0
    if cmd == 'switches':
        print(' '.join('%s=%s' % (s, os.environ[s]) for s in dict.fromkeys(f['switch'] for f in FEATURES) if s in os.environ))
        return 0
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
