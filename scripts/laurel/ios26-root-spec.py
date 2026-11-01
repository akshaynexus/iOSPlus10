#!/usr/bin/env python3
"""Mi A3 iOS 26 root: from the donor volumes (read-only mounts) + the lowered files to the spec of `op10tool hfs-build`. Nothing here needs root access.

    ios26-root-spec.py --os OS --sys SYS --app APP --tree TREE --lowered L --osdir DIR --work W [--heartbeat 60]

Writes W/spec (for hfs-build), W/overlay/ (files the tweaks changed), W/audit.txt (one line per tweak: what it did or why not), W/trust/merged.trustcache.
Same input, same output: run it again and the spec is the same. scripts/laurel/ios26-root.sh calls it. docs/laurel_sprout/ios26-root.md.

Layout, as scripts/ios16 mkiosroot.sh makes it for iOS 16, with two differences because the volume is written without a mount:
  /                                         OS volume
  /private/preboot/Cryptexes/OS             SystemOS volume
  /private/preboot/Cryptexes/App            AppOS volume
  /System/Library/Caches/com.apple.dyld     the lowered shared cache, real files; the place dyld looks when libignition is skipped (kernel: dyld_flags 0x8)
  /private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld   symlink to it (iOS 16: hard links)
  a file only in a cryptex                  symlink at its root path (iOS 16: a hard link). dyld does not search the cryptexes with ignition skipped
A file with more than one APFS link: one copy per path (the image has no hard links). Extended attributes are not copied, the same as rsync -aH on iOS 16.
"""
import argparse
import hashlib
import os
import plistlib
import stat
import struct
import sys

BUILD, VERSION = '23F84', '26.5.2'
MOBILE = 501
PRE = b'private/preboot/Cryptexes'
DYLD = b'System/Library/Caches/com.apple.dyld'
XPC = 'System/Library/xpc/launchd.plist'
BACKBOARDD = '/System/Library/LaunchDaemons/com.apple.backboardd.plist'
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

DROP_TOPAZ = ['com.apple.CommCenter']
DROP_EXTRA = ['com.apple.fairplayd.H2', 'com.apple.voicemail.vmd', 'com.apple.ReportCrash', 'com.apple.spindump', 'com.apple.tailspind',
              'com.apple.aggregated', 'com.apple.aggregated.addaily', 'com.apple.bluetoothd', 'com.apple.activityawardsd']
# new for this CPU: no Neural Engine here [I]; nothing it serves can run
DROP_N104 = ['com.apple.aned']
DROP_PROGRAMS = 'nanotimekitcompaniond wifip2pd syncdefaultsd'.split()


class Node:
    __slots__ = ('kind', 'mode', 'uid', 'gid', 'mtime', 'src', 'flags')

    def __init__(self, kind, mode, uid, gid, mtime, src, flags=0):
        self.kind, self.mode, self.uid, self.gid, self.mtime, self.src, self.flags = kind, mode, uid, gid, mtime, src, flags


class Tree:
    def __init__(self, work):
        self.n = {}
        self.overlay = os.path.join(work, 'overlay').encode()
        self.mtime = 0
        self.audit_lines = []
        self.skipped = 0
        self.links_extra = 0

    def scan(self, base, prefix):
        """All entries under BASE (bytes path) into the tree at PREFIX."""
        stack = [b'']
        while stack:
            rel = stack.pop()
            cur = os.path.join(base, rel) if rel else base
            with os.scandir(cur) as it:
                for e in it:
                    r = os.path.join(rel, e.name) if rel else e.name
                    st = e.stat(follow_symlinks=False)
                    p = os.path.join(prefix, r) if prefix else r
                    if stat.S_ISDIR(st.st_mode):
                        self.n[p] = Node('d', stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, st.st_mtime_ns // 10**9, b'')
                        stack.append(r)
                    elif stat.S_ISLNK(st.st_mode):
                        self.n[p] = Node('l', stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, st.st_mtime_ns // 10**9, os.readlink(os.path.join(base, r)))
                    elif stat.S_ISREG(st.st_mode):
                        if st.st_nlink > 1:
                            self.links_extra += 1
                        self.n[p] = Node('f', stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, st.st_mtime_ns // 10**9, os.path.join(base, r))
                    else:
                        self.skipped += 1
                    self.mtime = max(self.mtime, st.st_mtime_ns // 10**9)

    def mkdirs(self, p, mode=0o755, uid=0, gid=0):
        parts = p.split(b'/')
        for i in range(1, len(parts) + 1):
            q = b'/'.join(parts[:i])
            if q not in self.n:
                self.n[q] = Node('d', mode, uid, gid, self.mtime, b'')
            elif self.n[q].kind != 'd':
                raise SystemExit(f'{q!r}: a file where a folder must be')

    def remove(self, p):
        pre = p + b'/'
        for k in [k for k in self.n if k == p or k.startswith(pre)]:
            del self.n[k]

    def read(self, p):
        n = self.n[p.encode() if isinstance(p, str) else p]
        with open(n.src, 'rb') as f:
            return f.read()

    def write(self, p, data, mode=None, uid=None, gid=None):
        p = p.encode() if isinstance(p, str) else p
        old = self.n.get(p)
        self.mkdirs(os.path.dirname(p))
        dst = os.path.join(self.overlay, p)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'wb') as f:
            f.write(data)
        self.n[p] = Node('f', mode if mode is not None else old.mode, uid if uid is not None else old.uid, gid if gid is not None else old.gid, old.mtime if old else self.mtime, dst)

    def exists(self, p):
        return (p.encode() if isinstance(p, str) else p) in self.n

    def audit(self, item, state, note):
        self.audit_lines.append(f'{state:9} {item}: {note}')
        print(f'  {state:9} {item}: {note}')


def plist_load(t, p):
    return plistlib.loads(t.read(p))


def merge_pref(t, name, values):
    p = f'private/var/mobile/Library/Preferences/{name}.plist'
    d = plist_load(t, p) if t.exists(p) else {}
    d.update(values)
    t.write(p, plistlib.dumps(d, fmt=plistlib.FMT_BINARY), 0o600, MOBILE, MOBILE)
    return sorted(values)


def program(job):
    prog = job.get('Program')
    if not prog:
        args = job.get('ProgramArguments') or ['']
        prog = args[0]
    return os.path.basename(prog)


def tweaks(t, a):
    if not t.exists(XPC):
        raise SystemExit(f'no {XPC} in the OS volume')
    plist = plist_load(t, XPC)
    jobs = plist['LaunchDaemons']
    renamed = 0
    for job in jobs.values():
        if '_PanicOnCrash' in job:
            job['_PanicOnCrasX'] = job.pop('_PanicOnCrash')
            renamed += 1
    t.audit('launchd _PanicOnCrash', 'applied', f'{renamed} jobs: a crash of a daemon must not panic the system (iOS 16 tweak; same key in 23F84 [V])')

    def drop(labels, why):
        gone, none = [], []
        for lab in labels:
            ks = [k for k, j in jobs.items() if j.get('Label') == lab]
            for k in ks:
                del jobs[k]
            (gone if ks else none).append(lab)
        t.audit('launchd drop ' + why, 'applied', f'removed {gone or "none"}; not in 23F84: {none or "none"}')
    drop(DROP_TOPAZ, 'no baseband service')
    drop(DROP_EXTRA, 'missing hardware or restart loops, iOS 16 list')
    drop(DROP_N104, 'no Neural Engine on this SoC')
    ks = [k for k, j in jobs.items() if isinstance(j, dict) and program(j) in DROP_PROGRAMS]
    for k in ks:
        del jobs[k]
    t.audit('launchd drop by program', 'applied', f'{sorted(k.split("/")[-1] for k in ks)}: iOS 16 restart loops on this phone; same programs in 23F84 [V]. Their loop on iOS 26: [U]')
    bb = jobs.get(BACKBOARDD)
    if a.heartbeat and isinstance(bb, dict):
        bb.setdefault('EnvironmentVariables', {})['CA_HEARTBEAT_RATE'] = a.heartbeat
        t.audit('backboardd CA_HEARTBEAT_RATE', 'applied', f'{a.heartbeat}: string present in 23F84 QuartzCore [V]; what it does there: [U] (20H392 logic was read, not 23F84)')
    else:
        t.audit('backboardd CA_HEARTBEAT_RATE', 'not-found', 'no backboardd job, or empty value')
    t.write(XPC, plistlib.dumps(plist, fmt=plistlib.FMT_BINARY))
    t.audit('launchd.plist.sig', 'kept', 'the signature file stays and does not match the edited plist, the same as on the iOS 16 root that boots [V: 20H392 has it too]')
    t.audit('launchd security.cryptexd', 'kept', 'com.apple.security.cryptexd stays: its behaviour without an Apple manifest is [U]; first look at the first boot')

    # containers
    for sub, uid in (('Bundle', 33), ('Data/System', 0), ('Shared/SystemGroup', 0), ('Temp', 0)):
        t.mkdirs(os.path.join(b'private/var/containers', sub.encode()), 0o755, uid, uid)
    t.audit('containers', 'applied', '/private/var/containers/{Bundle,Data/System,Shared/SystemGroup,Temp}: on an iPhone they are on the data volume')

    # activation seed: only when a system container exists in the image
    found = None
    pre = b'private/var/containers/Data/System/'
    for k in t.n:
        if k.startswith(pre) and k.endswith(b'.com.apple.mobile_container_manager.metadata.plist'):
            try:
                if plist_load(t, k).get('MCMMetadataIdentifier') == 'com.apple.mobileactivationd':
                    found = os.path.dirname(k)
            except Exception:
                pass
    if found:
        t.write(os.path.join(found, b'Library/internal/data_ark.plist'), plistlib.dumps({
            '-ActivationState': 'Activated', '-BrickState': False, '-BuildVersion': BUILD, '-ProductVersion': VERSION,
            '-DataMigrationCompleted': True, '-PreSydroDataMigrationCompleted': True}, fmt=plistlib.FMT_BINARY), 0o600, MOBILE, MOBILE)
        t.audit('activation data ark', 'applied', 'mobileactivationd container in the image')
    else:
        t.audit('activation data ark', 'not-found', 'no mobileactivationd system container in the 23F84 OS volume; the kernel path (ADT security-status) stays. Whether that is enough on 26: [U]')

    # audio
    if t.exists('Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin'):
        t.remove(b'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin')
        t.audit('VirtualAudio HAL plug-in', 'applied', 'removed (iOS 16: mediaserverd crash); on 26 [U]')
    else:
        t.audit('VirtualAudio HAL plug-in', 'not-found', 'not in the OS volume')
    confs = [k for k in t.n if k.startswith(b'System/Library/Frameworks/MediaToolbox.framework/') and k.endswith(b'/SubServerConfiguration.plist')]
    for c in confs:
        d = plist_load(t, c)
        d['StartRecorderServer'] = False
        t.write(c, plistlib.dumps(d, fmt=plistlib.FMT_XML))
    t.audit('MediaToolbox StartRecorderServer', 'applied' if confs else 'not-found', f'{len(confs)} files')

    # preferences
    t.audit('migration prefs', 'applied', 'keys ' + str(merge_pref(t, 'com.apple.migration', {
        'LastSystemVersion': BUILD, 'DMUserDataDisposition': {'SyntheticDidUpgrade': False, 'buildVersion': BUILD},
        'DMLastMigrationResults': {'buildVersion': BUILD, 'success': True}})) + f': build {BUILD}. DataMigrator of 26 and these keys: [U]')
    t.audit('springboard prefs', 'applied', 'keys ' + str(merge_pref(t, 'com.apple.springboard', {
        'BKNoWatchdogs': True, 'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0}, 'MCForceShowCloudConfigurationUI': False, 'FBLaunchWatchdogScale': 3})))
    merge_pref(t, 'com.apple.frontboard', {'FBLaunchWatchdogScale': 3})
    t.audit('purplebuddy prefs', 'applied', 'keys ' + str(merge_pref(t, 'com.apple.purplebuddy', {
        'SetupDone': True, 'SetupFinishedAllSteps': True, 'SetupVersion': 11, 'daemonizeNeedsToRun': False})) + '. SetupVersion of 26: [U], the iOS 16 value')
    merge_pref(t, 'com.apple.purplebuddy.notbackedup', {k: False for k in (
        'ShouldRunDiagnosticsMiniBuddy', 'ShouldRunHSA2MiniBuddy', 'ShouldRunKeychainSyncMiniBuddy', 'ShouldRunMesaMiniBuddy',
        'ShouldRunPaymentMiniBuddy', 'ShouldRunStandardMiniBuddy', 'SilentICDPUpgrade')})
    merge_pref(t, 'com.apple.managedconfiguration.notbackedup', {'LockdownActivationIndicatesCloudConfigurationAvailable': False})
    t.audit('location switch', 'applied', 'keys ' + str(merge_pref(t, 'com.apple.locationd', {'LocationServicesEnabledIn8.0': True})) + ': key name on 26: [U]')

    # feature flag
    f = 'private/var/preferences/FeatureFlags/Domain/ExtensionKit.plist'
    t.mkdirs(os.path.dirname(f).encode())
    t.write(f, plistlib.dumps({'enforce_xpc_cache_code_signing': {'Enabled': False}}, fmt=plistlib.FMT_XML), 0o644, 0, 0)
    t.audit('ExtensionKit flag', 'applied', 'enforce_xpc_cache_code_signing off; the flag name on 26: [U]')

    # jetsam
    sys.path.insert(0, os.path.join(REPO, 'scripts', 'ios16'))
    import jetsam_widgets
    import tempfile
    jets = [k for k in t.n if k.startswith(b'System/Library/LaunchDaemons/com.apple.jetsamproperties.') and k.endswith(b'.plist')]
    for j in jets:
        with tempfile.NamedTemporaryFile(suffix='.plist') as tf:
            tf.write(t.read(j))
            tf.flush()
            short = os.path.basename(tf.name)
            r1 = jetsam_widgets.patch(tf.name, 64).replace(short, '')
            r2 = jetsam_widgets.patch_daemon(tf.name, 'com.apple.lsd', 64).replace(short, '')
            with open(tf.name, 'rb') as g:
                t.write(j, g.read())
        t.audit('jetsam ' + os.path.basename(j).decode(), 'applied', f'{r1}; {r2}')
    if not jets:
        t.audit('jetsam', 'not-found', 'no jetsamproperties plist')

    # InterfaceNamer
    n = 'System/Library/SystemConfiguration/InterfaceNamer.bundle/Info.plist'
    if t.exists(n):
        d = plist_load(t, n)
        d['WaitStackTimeout'] = 10.0
        t.write(n, plistlib.dumps(d, fmt=plistlib.FMT_BINARY))
        t.audit('InterfaceNamer WaitStackTimeout', 'applied', '10 s: this kernel has no IONetworkStack')
    else:
        t.audit('InterfaceNamer WaitStackTimeout', 'not-found', f'no {n}')

    # logd stores: owner _logd and a .migrated marker, or logd asks a helper and crashes (mkiosroot.sh)
    db = b'private/var/db'
    for d, mode in ((b'diagnostics', 0o751), (b'uuidtext', 0o755), (b'diagnostics/timesync', 0o755)):
        q = os.path.join(db, d)
        t.mkdirs(q, mode, 272, 272)
        t.n[q].mode, t.n[q].uid, t.n[q].gid = mode, 272, 272
        t.write(os.path.join(q, b'.migrated'), b'', 0o644, 272, 272)
    t.audit('logd stores', 'applied', 'private/var/db/{diagnostics,uuidtext,diagnostics/timesync}, owner 272, .migrated')

    # the system keybag: our AppleKeyStore reads this plain plist (mkiosroot.sh)
    t.mkdirs(b'private/var/keybags', 0o700, 0, 0)
    t.n[b'private/var/keybags'].mode = 0o700
    t.write('private/var/keybags/systembag.kb', ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>\n').encode(), 0o600, 0, 0)
    t.audit('system keybag', 'applied', 'plain plist; kernel AppleKeyStore selector numbers of 26 are the same for its stand-in [V, ios26-userland.md 8.2]')


# ---- trust data ----
def der_len(b, o):
    n = b[o]
    if n < 0x80:
        return n, o + 1
    k = n & 0x7f
    return int.from_bytes(b[o + 1:o + 1 + k], 'big'), o + 1 + k


def im4p_payload(b):
    """The payload of IM4P: SEQUENCE { IA5 'IM4P', IA5 type, IA5 desc, OCTET payload ... }"""
    if b[0] != 0x30:
        return b
    _, o = der_len(b, 1)
    for _ in range(3):
        _, o2 = der_len(b, o + 1)
        n, o2 = der_len(b, o + 1)
        o = o2 + n
    if b[o] != 0x04:
        raise SystemExit('trust cache: no payload in IM4P')
    n, o2 = der_len(b, o + 1)
    return b[o2:o2 + n]


def trust_entries(path):
    p = im4p_payload(open(path, 'rb').read())
    ver = struct.unpack('<I', p[:4])[0]
    # version 1: cdhash, hash type, flags. Version 2 (23F84): also constraint category and a reserved byte
    size = {1: 22, 2: 24}.get(ver)
    if size is None:
        raise SystemExit(f'{path}: trust cache version {ver}')
    count = struct.unpack('<I', p[20:24])[0]
    if len(p) != 24 + size * count:
        raise SystemExit(f'{path}: {count} entries, {len(p)} bytes')
    return {p[24 + i * size:44 + i * size]: p[44 + i * size:24 + (i + 1) * size].ljust(4, b'\0') for i in range(count)}


def cd_hash_of(cd):
    ht = cd[37]
    if ht == 1:
        return hashlib.sha1(cd).digest()
    if ht in (2, 3):
        return hashlib.sha256(cd).digest()[:20]
    if ht == 4:
        return hashlib.sha384(cd).digest()[:20]
    raise SystemExit(f'code directory hash type {ht}')


def macho_cdhashes(data):
    """cdhash of the best code directory of each slice."""
    out = []

    def one(off):
        magic = struct.unpack('<I', data[off:off + 4])[0]
        if magic != 0xfeedfacf:
            return
        ncmds = struct.unpack('<I', data[off + 16:off + 20])[0]
        o = off + 32
        for _ in range(ncmds):
            cmd, sz = struct.unpack('<II', data[o:o + 8])
            if cmd == 0x1d:
                so, _ = struct.unpack('<II', data[o + 8:o + 16])
                s = off + so
                if struct.unpack('>I', data[s:s + 4])[0] != 0xfade0cc0:
                    return
                n = struct.unpack('>I', data[s + 8:s + 12])[0]
                best = None
                for i in range(n):
                    typ, bo = struct.unpack('>II', data[s + 12 + i * 8:s + 20 + i * 8])
                    if typ == 0 or 0x1000 <= typ < 0x1005:
                        b = s + bo
                        if struct.unpack('>I', data[b:b + 4])[0] != 0xfade0c02:
                            continue
                        ln = struct.unpack('>I', data[b + 4:b + 8])[0]
                        cd = data[b:b + ln]
                        if best is None or cd[37] > best[37]:
                            best = cd
                if best:
                    out.append(cd_hash_of(best))
                return
            o += sz
    m = data[:4]
    if m == b'\xca\xfe\xba\xbe':
        n = struct.unpack('>I', data[4:8])[0]
        for i in range(n):
            ca = struct.unpack('>IIIII', data[8 + i * 20:28 + i * 20])
            one(ca[2])
    else:
        one(0)
    return out


def trust(t, a, work):
    ent = {}
    srcs = []
    for f in sorted(os.listdir(a.osdir)):
        if f.endswith('.trustcache'):
            e = trust_entries(os.path.join(a.osdir, f))
            srcs.append(f'{f} {len(e)}')
            ent.update(e)
    orig_n = len(ent)
    added = 0
    missing_attr = 0
    new = []
    # cache
    with open(os.path.join(a.lowered, 'cdhashes.tsv')) as f:
        next(f)
        for line in f:
            p = line.split('\t')
            oh, nh = bytes.fromhex(p[1]), bytes.fromhex(p[2])
            attr = ent.get(oh)
            if attr is None:
                missing_attr += 1
                attr = b'\x02\x00\x00\x00'
            ent[nh] = attr
            new.append(nh)
            added += 1
    # root files
    ml = os.path.join(a.lowered, 'macho')
    for vol in ('os', 'sys'):
        for dirp, _, files in os.walk(os.path.join(ml, vol)):
            for fn in files:
                lp = os.path.join(dirp, fn)
                rel = os.path.relpath(lp, os.path.join(ml, vol))
                op = os.path.join(a.tree, 'root', vol, rel)
                if not os.path.exists(op):
                    raise SystemExit(f'no original of lowered {lp}')
                ohs = macho_cdhashes(open(op, 'rb').read())
                nhs = macho_cdhashes(open(lp, 'rb').read())
                attr = None
                for h in ohs:
                    attr = ent.get(h, attr)
                if attr is None:
                    missing_attr += 1
                    attr = b'\x02\x00\x00\x00'
                for h in nhs:
                    if h not in ent:
                        added += 1
                    ent[h] = attr
                    new.append(h)
    blob = struct.pack('<I', 2) + b'\0' * 16 + struct.pack('<I', len(ent))
    for h in sorted(ent):
        blob += h + ent[h]
    os.makedirs(os.path.join(work, 'trust'), exist_ok=True)
    out = os.path.join(work, 'trust', 'merged.trustcache')
    with open(out, 'wb') as f:
        f.write(blob)
    t.mkdirs(b'usr/share/laurel')
    t.write('usr/share/laurel/ios26-merged.trustcache', blob, 0o644, 0, 0)
    t.audit('trust data', 'built', f'{"; ".join(srcs)}; merged {len(ent)} entries, {added} new from the lowering, {missing_attr} without an original attribute. The kernel does not read this file: trust caches are off, built-in AMFI marks every signed file on the root (ios26-kernel.md 3). It is the input if the kernel ever loads one')


def apply_stage(t, stage, keep_mode=()):
    """What a script left on a stage goes into the tree, owner 0:0: new folders and symlinks too. A file the tree has keeps its owner and mode (keep_mode: paths that keep them anyway)."""
    files = 0
    for dirp, dirs, names in os.walk(stage):
        dirs.sort()
        rel = os.path.relpath(dirp, stage).encode()
        rel = b'' if rel == b'.' else rel
        for n in sorted(dirs):
            q = os.path.join(rel, n.encode()) if rel else n.encode()
            full = os.path.join(dirp, n)
            if q not in t.n:
                t.mkdirs(rel) if rel else None
                t.n[q] = Node('d', stat.S_IMODE(os.stat(full).st_mode), 0, 0, t.mtime, b'')
        for n in sorted(names):
            q = os.path.join(rel, n.encode()) if rel else n.encode()
            full = os.path.join(dirp, n)
            if os.path.islink(full):
                t.n[q] = Node('l', 0o755, 0, 0, t.mtime, os.fsencode(os.readlink(full)))
            elif q in t.n and t.n[q].kind == 'f':
                with open(full, 'rb') as f:
                    t.write(q, f.read(), stat.S_IMODE(os.stat(full).st_mode) if q in keep_mode else None)
            else:
                with open(full, 'rb') as f:
                    t.write(q, f.read(), stat.S_IMODE(os.stat(full).st_mode), 0, 0)
            files += 1
    return files


def debug(t, work, script=None):
    """The debug path of the first boot: scripts/laurel/root-debug-ios26.sh on a stage with the launchd.plist of this tree (docs/laurel_sprout/ios26-first-boot.md). Before air() and metal(), and it
    needs neither: 23F84 has no GL path, so with no picture this is how the phone speaks. Its script fails or it is off: the root is built without it and with one audit line `off debug-ios26`,
    which ios26-root.sh prints at its end. Nothing else of the root changes then."""
    import shutil
    import subprocess
    script = script or os.path.join(REPO, 'scripts', 'laurel', 'root-debug-ios26.sh')
    if not os.path.exists(script):
        t.audit('debug-ios26', 'off', f'no {script}')
        return
    stage = os.path.join(work, 'debug-stage')
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(os.path.join(stage, os.path.dirname(XPC)))
    with open(os.path.join(stage, XPC), 'wb') as f:
        f.write(t.read(XPC))
    os.chmod(os.path.join(stage, XPC), 0o644)
    # the stock commands: a toybox applet must not shadow one. The volume paths, also the cryptex links of this tree
    names = os.path.join(work, 'debug-stock-names')
    with open(names, 'wb') as f:
        for k in sorted(t.n):
            if any(k.startswith(p) and b'/' not in k[len(p):] for p in (b'bin/', b'sbin/', b'usr/bin/', b'usr/sbin/')):
                f.write(os.path.basename(k) + b'\n')
    # the check of root-add-ssh.py: root's entry, its shell. Same bytes back
    for e in ('private/etc/master.passwd', 'private/etc/passwd'):
        if t.exists(e):
            os.makedirs(os.path.join(stage, os.path.dirname(e)), exist_ok=True)
            with open(os.path.join(stage, e), 'wb') as f:
                f.write(t.read(e))
    env = dict(os.environ, STOCK_NAMES=names)
    r = subprocess.run(['bash', script, stage], capture_output=True, text=True, env=env, preexec_fn=lambda: os.umask(0o022))
    tag = 'laurel-root: debug-ios26: '
    said = [x[len(tag):] for x in (r.stdout + r.stderr).strip().splitlines() if x.startswith(tag)]
    if r.returncode != 0:
        t.audit('debug-ios26', 'off', said[-1] if said else ((r.stderr or r.stdout).strip().splitlines() or ['no output'])[-1])
        shutil.rmtree(stage, ignore_errors=True)
        return
    files = apply_stage(t, stage)
    for x in said:
        item, _, note = x.partition(': ')
        t.audit('debug ' + item, 'applied', note)
    t.audit('debug-ios26', 'applied', f'{files} files and links; the same in a root with no compositor. Not proven until it runs on the phone')
    shutil.rmtree(stage, ignore_errors=True)


def air(t, work, script=None):
    """AirDrop and AirPlay parts of scripts/laurel/root-air-ios26.sh (branch t3/laurel-ios26-airdrop). That script edits a mounted root; this build has no writable mount, so it runs
    on a stage with the launchd.plist of this tree, and what it leaves there goes into the image. Not in this tree: nothing changes, and the image stays the same bytes. It fails: the
    root is built without these parts, with one audit line."""
    import shutil
    import subprocess
    script = script or os.path.join(REPO, 'scripts', 'laurel', 'root-air-ios26.sh')
    if not os.path.exists(script):
        print('  air-ios26: scripts/laurel/root-air-ios26.sh is not in this tree (not merged yet): no change to the root')
        return
    stage = os.path.join(work, 'air-stage')
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(os.path.join(stage, os.path.dirname(XPC)))
    before = t.read(XPC)
    with open(os.path.join(stage, XPC), 'wb') as f:
        f.write(before)
    os.chmod(os.path.join(stage, XPC), 0o644)
    r = subprocess.run(['bash', script, stage], capture_output=True, text=True, preexec_fn=lambda: os.umask(0o022))
    if r.returncode != 0:
        t.audit('air-ios26', 'off', ((r.stderr or r.stdout).strip().splitlines() or ['no output'])[-1])
        return
    files = 0
    for dirp, dirs, names in os.walk(stage):
        rel = os.path.relpath(dirp, stage).encode()
        rel = b'' if rel == b'.' else rel
        if rel:
            t.mkdirs(rel)
        for n in sorted(names):
            q = os.path.join(rel, n.encode()) if rel else n.encode()
            full = os.path.join(dirp, n)
            with open(full, 'rb') as f:
                data = f.read()
            if q == XPC.encode():
                t.write(q, data)
            else:
                t.write(q, data, stat.S_IMODE(os.stat(full).st_mode), 0, 0)
            files += 1
    # a job the script took out: its plist goes too, as the script does on a mounted root
    gone = set(plistlib.loads(before)['LaunchDaemons']) - set(plistlib.loads(t.read(XPC))['LaunchDaemons'])
    for k in sorted(gone):
        t.remove(k.lstrip('/').encode())
    said = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ''
    t.audit('air-ios26', 'applied', f'{files} files; jobs out: {sorted(k.split("/")[-1] for k in gone)}; {said}')
    shutil.rmtree(stage, ignore_errors=True)


def metal(t, work, script=None):
    """The default Metal stack: scripts/laurel/root-add-metal-ios26.sh (docs/laurel_sprout/ios26-metal.md section 9). That script writes to a root, and this build has no writable mount, so it runs on
    a stage that has the plists it edits, and what it leaves goes into the image, owner 0:0, modes as it set them. It fails or it is off: the root is built with no compositor and one audit line
    `off metal26`, and ios26-root.sh prints that line at its end. 23F84 has no GL path, so such a root shows no picture."""
    import shutil
    import subprocess
    script = script or os.path.join(REPO, 'scripts', 'laurel', 'root-add-metal-ios26.sh')
    stage = os.path.join(work, 'metal-stage')
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(os.path.join(stage, 'System/Library/Extensions'))
    os.makedirs(os.path.join(stage, 'usr/libexec'))
    marker = os.path.join(stage, 'usr/libexec/backboardd')      # the script's check that this is a root: the real one stays
    if not t.exists('usr/libexec/backboardd'):
        t.audit('metal26', 'off', 'no /usr/libexec/backboardd in the tree: no compositor on this root')
        return
    open(marker, 'wb').close()
    jets = [k for k in t.n if k.startswith(b'System/Library/LaunchDaemons/com.apple.jetsamproperties.') and k.endswith(b'.plist')]
    if jets:
        os.makedirs(os.path.join(stage, 'System/Library/LaunchDaemons'))
    for k in jets:
        with open(os.path.join(stage.encode(), k), 'wb') as f:
            f.write(t.read(k))
    r = subprocess.run(['sh', script, stage], capture_output=True, text=True, preexec_fn=lambda: os.umask(0o022))
    said = [x for x in (r.stdout + r.stderr).strip().splitlines() if 'laurel-root: metal26:' in x]
    bundle = os.path.join(stage, 'System/Library/Extensions/NegroniMetal.bundle/NegroniMetal')
    if r.returncode != 0 or not os.path.exists(bundle):
        t.audit('metal26', 'off', said[-1] if said else ((r.stderr or r.stdout).strip().splitlines() or ['no output'])[-1])
        shutil.rmtree(stage, ignore_errors=True)
        return
    os.unlink(marker)
    prefs = {}
    files = 0
    for dirp, dirs, names in os.walk(stage):
        dirs.sort()
        rel = os.path.relpath(dirp, stage).encode()
        rel = b'' if rel == b'.' else rel
        if rel and rel not in t.n:
            t.mkdirs(os.path.dirname(rel))
            t.n[rel] = Node('d', stat.S_IMODE(os.stat(dirp).st_mode), 0, 0, t.mtime, b'')
        for n in sorted(names):
            q = os.path.join(rel, n.encode()) if rel else n.encode()
            full = os.path.join(dirp, n)
            with open(full, 'rb') as f:
                data = f.read()
            if q.endswith(b'/Library/Preferences/com.apple.backboardd.plist'):
                prefs = plistlib.loads(data)    # the home folders have their own owners: merged below, not written from the stage
            elif q in t.n and t.n[q].kind == 'f':
                t.write(q, data)
                files += 1
            else:
                t.write(q, data, stat.S_IMODE(os.stat(full).st_mode), 0, 0)
                files += 1
    if prefs:
        merge_pref(t, 'com.apple.backboardd', prefs)
    t.audit('metal26', 'applied', f'{files} files; {said[-1] if said else "no line"}')
    shutil.rmtree(stage, ignore_errors=True)


def metal_self_test(d):
    """The hook with the real script on the real stage (out/ios26/metal/stage). None: no stage, not run."""
    import shutil
    S = os.environ.get('METAL_STAGE') or os.path.join(REPO, 'out/ios26/metal/stage')
    work = os.path.join(d, 'mw')
    os.makedirs(os.path.join(work, 'overlay'))
    t = Tree(work)
    src = os.path.join(d, 'bb')
    open(src, 'wb').close()
    t.mkdirs(b'usr/libexec')
    t.mkdirs(b'private/var/mobile/Library/Preferences', 0o755, MOBILE, MOBILE)
    t.n[b'usr/libexec/backboardd'] = Node('f', 0o755, 0, 0, 5, src.encode())
    # no backboardd in the tree: off, no change
    t0 = Tree(work)
    metal(t0, work)
    checks = [any(x.startswith('off') and 'metal26' in x for x in t0.audit_lines), not t0.n]
    # no stage: off, no bundle
    env = os.environ.get('METAL_STAGE')
    t1 = Tree(work)
    t1.mkdirs(b'usr/libexec')
    t1.n[b'usr/libexec/backboardd'] = Node('f', 0o755, 0, 0, 5, src.encode())
    os.environ['METAL_STAGE'] = os.path.join(d, 'absent')
    metal(t1, work)
    if env is None:
        del os.environ['METAL_STAGE']
    else:
        os.environ['METAL_STAGE'] = env
    checks += [any(x.startswith('off') and 'metal26' in x for x in t1.audit_lines), b'System/Library/Extensions/NegroniMetal.bundle/NegroniMetal' not in t1.n]
    if not os.path.isdir(S):
        print(f'metal hook self-test: {sum(checks)} of {len(checks)}; real stage not run: no {S}')
        return all(checks)
    metal(t, work)
    B = b'System/Library/Extensions/NegroniMetal.bundle/'
    db = b'private/var/db/negronimetal/'
    with open(os.path.join(S, 'System/Library/Extensions/NegroniMetal.bundle/NegroniMetal'), 'rb') as f:
        same = f.read() == t.read(B + b'NegroniMetal')
    pref = b'private/var/mobile/Library/Preferences/com.apple.backboardd.plist'
    checks += [
        same,
        t.n[B + b'NegroniMetal'].uid == 0,
        t.n[B + b'libvulkan_freedreno.dylib'].mode & 0o111 != 0 or t.n[B + b'libvulkan_freedreno.dylib'].mode & 0o444 == 0o444,
        t.n[db + b'cache'].mode == 0o1777 and t.n[db + b'strikes'].mode == 0o1777 and t.n[db + b'stack'].mode == 0o777,
        t.n[db + b'metal.log'].mode == 0o666,
        t.exists(db + b'clients') and t.exists(db + b'env') and t.exists(db + b'build.txt'),
        b'-PosterBoard' in t.read(db + b'clients'),
        t.n[b'usr/libexec/backboardd'].src == src.encode(),
        t.n[pref].uid == MOBILE and plistlib.loads(t.read(pref))['CAEnableFramebufferCompression'] is False,
        not t.exists(B + b'options') and not t.exists(b'Applications/XNUtils.app'),
        any(x.startswith('applied') and 'metal26' in x for x in t.audit_lines),
    ]
    print(f'metal hook self-test: {sum(checks)} of {len(checks)}, real stage {S}; {[x for x in t.audit_lines if "metal26" in x][-1]}')
    print('  ' + ' '.join(f'{i}:{"ok" if c else "FAIL"}' for i, c in enumerate(checks)))
    return all(checks)


def debug_self_test(d):
    """The debug hook with the real script: stage, jobs, owners, modes, links, no change on a failure; it stays when Metal and AirDrop fail. Its own scratch out/ssh, so no real key changes. Real binaries of
    out/ssh/ios when this host has them, else made-up plain arm64 files."""
    import shutil
    import subprocess
    MAIN = subprocess.run(['git', '-C', REPO, 'worktree', 'list', '--porcelain'], capture_output=True, text=True).stdout.splitlines()
    MAIN = MAIN[0].split(' ', 1)[1] if MAIN else REPO
    real = next((os.path.join(x, 'out/ssh/ios') for x in (REPO, MAIN) if os.path.isfile(os.path.join(x, 'out/ssh/ios/dropbearmulti'))), None)
    so = os.path.join(d, 'sshout')
    if real:
        os.makedirs(so)
        os.symlink(real, os.path.join(so, 'ios'))
    else:
        os.makedirs(os.path.join(so, 'ios'))
        for n in 'dropbearmulti dash toybox usbnetcfg laurelnet usbreboot oslogstream'.split():
            with open(os.path.join(so, 'ios', n), 'wb') as f:
                f.write(struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 0, 0))
            os.chmod(os.path.join(so, 'ios', n), 0o755)
        with open(os.path.join(so, 'ios', 'toybox.applets'), 'w') as f:
            f.write('ls cat ps tail\n')

    def tree():
        work = os.path.join(d, 'dw')
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(os.path.join(work, 'overlay'))
        t = Tree(work)
        src = os.path.join(d, 'dl.plist')
        with open(src, 'wb') as f:
            plistlib.dump({'LaunchDaemons': {'/System/Library/LaunchDaemons/com.apple.wifip2pd.plist': {'Label': 'p'}}}, f, fmt=plistlib.FMT_BINARY)
        t.mkdirs(os.path.dirname(XPC).encode())
        t.n[XPC.encode()] = Node('f', 0o644, 0, 0, 5, src.encode())
        t.mkdirs(b'bin')
        t.mkdirs(b'private/var/root')
        t.mkdirs(b'private/etc')
        t.n[b'bin/ps'] = Node('f', 0o755, 0, 0, 5, src.encode())
        pw = os.path.join(d, 'mp')
        with open(pw, 'w') as f:
            f.write('root:/smx7MYTQIi2M:0:0::0:0:System Administrator:/var/root:/bin/sh\n')
        t.n[b'private/etc/master.passwd'] = Node('f', 0o600, 0, 0, 5, pw.encode())
        return t, work
    env = {k: os.environ.get(k) for k in ('SSH_OUT', 'DEBUG26')}
    os.environ['SSH_OUT'] = so
    t, work = tree()
    debug(t, work)
    J = '/System/Library/LaunchDaemons/dev.iosplus10.dropbear.plist'
    jobs = plistlib.loads(t.read(XPC))['LaunchDaemons']
    job = jobs.get(J, {})
    a = job.get('ProgramArguments', [])
    prefs = plistlib.loads(t.read(b'private/var/preferences/SystemConfiguration/preferences.plist'))
    svc = prefs['NetworkServices']['1F05B0E7-0000-4000-8000-0000000000E0']
    n = t.n
    checks = [
        a[:5] == ['/usr/local/bin/dropbear', '-F', '-E', '-p', '192.168.7.2:22'],
        '-s' not in a and not any(x == '22' or x.startswith('0.0.0.0') for x in a),
        job.get('RunAtLoad') is True and job.get('KeepAlive') is True and job.get('MinimalBootProfile') is True and job.get('POSIXSpawnType') == 'Interactive' and job.get('EnablePressuredExit') is False,
        job.get('StandardErrorPath') == '/dev/console' and 'StandardOutPath' not in job,
        not any('Library/Logs' in str(v) or 'backboardd' in str(v) for v in job.values()),
        '/System/Library/LaunchDaemons/dev.iosplus10.usbnetcfg.plist' not in jobs and 'Router' not in svc['IPv4'] and svc['IPv4']['Addresses'] == ['192.168.7.2'],
        n[XPC.encode()].mode == 0o644 and n[XPC.encode()].uid == 0,
        n[b'usr/local/bin/dropbearmulti'].mode == 0o755 and n[b'usr/local/bin/dropbearmulti'].uid == 0,
        n[b'usr/local/bin/dropbear'].kind == 'l' and n[b'usr/local/bin/dropbear'].src == b'dropbearmulti',
        n[b'bin/sh'].kind == 'l' and n[b'bin/sh'].src == b'/usr/local/bin/dash',
        b'usr/local/bin/ps' not in n and n[b'usr/local/bin/ls'].kind == 'l',
        n[b'private/var/root/.ssh'].mode == 0o700 and n[b'private/var/root/.ssh/authorized_keys'].mode == 0o600 and b'ssh-' in t.read(b'private/var/root/.ssh/authorized_keys'),
        b'/bin/sh' in t.read(b'private/etc/shells'),
        n[b'private/etc/master.passwd'].mode == 0o600 and b'/smx7MYTQIi2M' in t.read(b'private/etc/master.passwd'),
        any(x.startswith('applied') and 'debug ssh' in x and '192.168.7.2:22' in x for x in t.audit_lines),
        any(x.startswith('applied') and 'debug-ios26' in x for x in t.audit_lines),
    ]
    # no secret of the scratch out/ssh beyond its keys, and the private key is never on the root
    checks.append(not any(b'phone_ed25519' in k for k in n))
    # Metal and AirDrop fail: the job and the binaries stay
    os.environ['METAL_STAGE'] = os.path.join(d, 'absent')
    t.mkdirs(b'usr/libexec')
    t.n[b'usr/libexec/backboardd'] = Node('f', 0o755, 0, 0, 5, b'/dev/null')
    metal(t, work)
    del os.environ['METAL_STAGE']
    bad = os.path.join(d, 'bad-air.sh')
    with open(bad, 'w') as f:
        f.write('#!/bin/bash\necho "laurel-root: air-ios26: no" >&2; exit 1\n')
    air(t, work, bad)
    checks += [J in plistlib.loads(t.read(XPC))['LaunchDaemons'], any(x.startswith('off') and 'metal26' in x for x in t.audit_lines), any(x.startswith('off') and 'air-ios26' in x for x in t.audit_lines), b'usr/local/bin/dropbearmulti' in t.n]
    # the same with no compositor job at all and a tree with no bundle: nothing here reads them
    checks.append(not any(b'NegroniMetal' in k for k in t.n))
    root_manifest(t, os.path.join(d, 'no-stamp'))
    first = t.read(b'usr/share/laurel/root-manifest').decode().splitlines()
    import re
    checks += [bool(re.fullmatch(r'\S+ \S+ kernel-series none features 3 installed 1 off 2 missing 0', first[0])), t.n[b'usr/share/laurel/root-manifest'].mode == 0o644]
    # kill switch and a missing tool: off, the tree stays
    os.environ['DEBUG26'] = '0'
    t, work = tree()
    before = set(t.n)
    debug(t, work)
    checks += [set(t.n) == before, any(x.startswith('off') and 'DEBUG26=0' in x for x in t.audit_lines)]
    os.environ.pop('DEBUG26')
    os.environ['SSH_OUT'] = os.path.join(d, 'no-ssh')
    t, work = tree()
    before = set(t.n)
    debug(t, work)
    checks.append(set(t.n) == before and any(x.startswith('off') and 'no-ssh' in x for x in t.audit_lines))
    for k, v in env.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    print(f'debug hook self-test: {sum(checks)} of {len(checks)}, binaries {"real " + real if real else "made up"}')
    print('  ' + ' '.join(f'{i}:{"ok" if c else "FAIL"}' for i, c in enumerate(checks)))
    return all(checks)


def root_manifest(t, stamp=None):
    """/usr/share/laurel/root-manifest: the kernel prints its first line, `LAUREL BUILD: root ...` (patch 2912). The time is the commit's, so the same commit gives the same bytes. Features: the hooks of this root, from their audit lines."""
    import importlib.util
    import subprocess
    sp = importlib.util.spec_from_file_location('build_stamp', os.path.join(REPO, 'scripts', 'laurel', 'build-stamp.py'))
    bs = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(bs)
    stamp = stamp or os.path.join(REPO, 'out/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k.stamp')
    series = (bs.read_stamp(stamp) or {}).get('series', 'none')
    when = subprocess.run(['git', '-C', REPO, 'log', '-1', '--format=%cd', '--date=format:%Y%m%dT%H%M%S'], capture_output=True, text=True).stdout.strip() or 'none'
    rows = []
    for name in ('debug-ios26', 'air-ios26', 'metal26'):
        hit = [x for x in t.audit_lines if x.split(None, 1)[1].startswith(name + ':')]
        rows.append((name, 'installed' if hit and hit[-1].startswith('applied') else 'off', hit[-1].split(': ', 1)[1] if hit else 'no audit line'))
    n = {w: sum(r[1] == w for r in rows) for w in ('installed', 'off')}
    text = '%s %s kernel-series %s features %d installed %d off %d missing 0\n' % (bs.commit(), when, series, len(rows), n['installed'], n['off'])
    text += ''.join('feature\t%s\t%s\t%s\n' % r for r in rows)
    t.write('usr/share/laurel/root-manifest', text.encode(), 0o644, 0, 0)
    t.audit('root-manifest', 'built', text.splitlines()[0])


def self_test():
    """The air hook with a stand-in script: its files, owners, a removed job, a failure, a missing script. Host only, no donor files."""
    import shutil
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        def tree():
            work = os.path.join(d, 'w')
            shutil.rmtree(work, ignore_errors=True)
            os.makedirs(os.path.join(work, 'overlay'))
            t = Tree(work)
            src = os.path.join(d, 'launchd.plist')
            jobs = {'LaunchDaemons': {'/System/Library/LaunchDaemons/com.apple.wifip2pd.plist': {'Label': 'p'}, '/System/Library/LaunchDaemons/a.plist': {'Label': 'a'}}}
            with open(src, 'wb') as f:
                plistlib.dump(jobs, f, fmt=plistlib.FMT_BINARY)
            t.mkdirs(os.path.dirname(XPC).encode())
            t.n[XPC.encode()] = Node('f', 0o644, 0, 0, 5, src.encode())
            t.mkdirs(b'System/Library/LaunchDaemons')
            t.n[b'System/Library/LaunchDaemons/com.apple.wifip2pd.plist'] = Node('f', 0o644, 0, 0, 5, src.encode())
            return t, work
        good = os.path.join(d, 'good.sh')
        with open(good, 'w') as f:
            f.write('''#!/bin/bash
set -e
R=$1
mkdir -p "$R/usr/libexec" "$R/private/var/Managed Preferences/mobile"
printf x > "$R/usr/libexec/laurel-awdld"; chmod 755 "$R/usr/libexec/laurel-awdld"
printf y > "$R/private/var/Managed Preferences/mobile/com.apple.Sharing.plist"
python3 -I - "$R/System/Library/xpc/launchd.plist" <<'E'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, 'rb'))
del d['LaunchDaemons']['/System/Library/LaunchDaemons/com.apple.wifip2pd.plist']
plistlib.dump(d, open(p, 'wb'), fmt=plistlib.FMT_BINARY)
E
echo "laurel-root: air-ios26: fake"
''')
        t, w = tree()
        air(t, w, good)
        checks = [
            t.n[b'usr/libexec/laurel-awdld'].mode == 0o755 and t.n[b'usr/libexec/laurel-awdld'].uid == 0,
            t.read(b'private/var/Managed Preferences/mobile/com.apple.Sharing.plist') == b'y',
            b'System/Library/LaunchDaemons/com.apple.wifip2pd.plist' not in t.n,
            list(plistlib.loads(t.read(XPC))['LaunchDaemons']) == ['/System/Library/LaunchDaemons/a.plist'],
            t.n[XPC.encode()].mode == 0o644,
            any('applied' in x and 'fake' in x for x in t.audit_lines),
        ]
        bad = os.path.join(d, 'bad.sh')
        with open(bad, 'w') as f:
            f.write('#!/bin/bash\necho "laurel-root: air-ios26: missing x" >&2; exit 1\n')
        t, w = tree()
        n = dict(t.n)
        air(t, w, bad)
        checks += [set(t.n) == set(n), any(x.startswith('off') and 'missing x' in x for x in t.audit_lines)]
        t, w = tree()
        n = dict(t.n)
        air(t, w, os.path.join(d, 'absent.sh'))
        checks += [set(t.n) == set(n), not t.audit_lines]
        print(f'air hook self-test: {sum(checks)} of {len(checks)}')
        ok_metal = metal_self_test(d)
        ok_debug = debug_self_test(d)
    sys.exit(0 if all(checks) and ok_metal and ok_debug else 1)


def main():
    if sys.argv[1:] == ['--self-test']:
        self_test()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for n in ('os', 'sys', 'app', 'tree', 'lowered', 'osdir', 'work'):
        ap.add_argument('--' + n, required=True)
    ap.add_argument('--heartbeat', default='60')
    a = ap.parse_args()
    work = a.work
    import shutil
    shutil.rmtree(os.path.join(work, 'overlay'), ignore_errors=True)
    os.makedirs(os.path.join(work, 'overlay'), exist_ok=True)
    t = Tree(work)
    print('scan OS volume')
    t.scan(a.os.encode(), b'')
    print('scan SystemOS volume')
    t.mkdirs(PRE)
    t.mkdirs(PRE + b'/OS')
    t.scan(a.sys.encode(), PRE + b'/OS')
    print('scan AppOS volume')
    t.mkdirs(PRE + b'/App')
    t.scan(a.app.encode(), PRE + b'/App')
    print(f'{len(t.n)} entries; {t.skipped} not file, folder or symlink (not copied); {t.links_extra} paths of files with more than one link')
    # lowered Mach-O files
    ml = os.path.join(a.lowered, 'macho').encode()
    nl = 0
    for vol, prefix in ((b'os', b''), (b'sys', PRE + b'/OS')):
        base = os.path.join(ml, vol)
        for dirp, _, files in os.walk(base):
            for fn in files:
                lp = os.path.join(dirp, fn)
                rel = os.path.relpath(lp, base)
                p = os.path.join(prefix, rel) if prefix else rel
                if p not in t.n or t.n[p].kind != 'f':
                    raise SystemExit(f'lowered file without a place in the volume: {p!r}')
                t.n[p].src = lp
                nl += 1
    print(f'{nl} Mach-O files from the lowered tree')
    # the shared cache
    cdir = PRE + b'/OS/' + DYLD
    cn = 0
    meta = None
    atlas = None
    for k in [k for k in t.n if k.startswith(cdir + b'/')]:
        node = t.n[k]
        meta = node
        if k.endswith(b'.atlas'):
            atlas = node.src
    if meta is None:
        raise SystemExit(f'no cache in the SystemOS volume at {cdir!r}')
    dirmeta = t.n[cdir]
    t.remove(cdir)
    t.mkdirs(DYLD)
    for f in sorted(os.listdir(a.lowered)):
        if f.startswith('dyld_shared_cache_arm64e'):
            t.n[os.path.join(DYLD, f.encode())] = Node('f', meta.mode, meta.uid, meta.gid, meta.mtime, os.path.join(a.lowered, f).encode())
            cn += 1
    if atlas:
        t.n[os.path.join(DYLD, b'dyld_shared_cache_arm64e.atlas')] = Node('f', meta.mode, meta.uid, meta.gid, meta.mtime, atlas)
    t.n[cdir] = Node('l', 0o755, dirmeta.uid, dirmeta.gid, dirmeta.mtime, b'/' + DYLD)
    print(f'{cn} cache files at /{DYLD.decode()}')
    # cryptex-only paths at their root path
    linked = through = 0
    for c in (b'OS', b'App'):
        pre = PRE + b'/' + c + b'/'
        for k in sorted(k for k in t.n if k.startswith(pre)):
            rel = k[len(pre):]
            n = t.n[k]
            if n.kind == 'd' or rel in t.n or rel == DYLD:
                continue
            # a parent that is a symlink in the OS volume: it points into the cryptex, so the root path works already
            parts = rel.split(b'/')
            if any(b'/'.join(parts[:i]) in t.n and t.n[b'/'.join(parts[:i])].kind != 'd' for i in range(1, len(parts))):
                through += 1
                continue
            t.mkdirs(os.path.dirname(rel))
            if n.kind == 'l':
                t.n[rel] = Node('l', n.mode, n.uid, n.gid, n.mtime, n.src)
            else:
                t.n[rel] = Node('l', 0o755, 0, 0, n.mtime, b'/' + k)
            linked += 1
    print(f'{linked} cryptex-only paths linked at the root; {through} reached through a symlink of the OS volume')
    print('tweaks:')
    tweaks(t, a)
    debug(t, work)
    air(t, work)
    metal(t, work)
    trust(t, a, work)
    root_manifest(t)
    # a place for the reader of the first boot
    with open(os.path.join(work, 'audit.txt'), 'w') as f:
        f.write('\n'.join(t.audit_lines) + '\n')
    t.write('usr/share/laurel/ios26-root-audit.txt', open(os.path.join(work, 'audit.txt'), 'rb').read(), 0o644, 0, 0)
    # /private/var and /var: the donor image has them; new writes on the phone land in the free space of this one volume
    spec = os.path.join(work, 'spec')
    n_f = n_d = n_l = 0
    with open(spec, 'wb') as out:
        for p in sorted(t.n):
            n = t.n[p]
            n_f += n.kind == 'f'
            n_d += n.kind == 'd'
            n_l += n.kind == 'l'
            out.write(b'\0'.join([n.kind.encode(), b'%o' % n.mode, b'%d' % n.uid, b'%d' % n.gid, b'%d' % n.mtime, b'%d' % n.flags, p, n.src]) + b'\n')
    print(f'spec: {n_f} files, {n_l} symlinks, {n_d} folders')


if __name__ == '__main__':
    main()
