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
            r1 = jetsam_widgets.patch(tf.name, 64)
            r2 = jetsam_widgets.patch_daemon(tf.name, 'com.apple.lsd', 64)
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
    if struct.unpack('<I', p[:4])[0] != 1:
        raise SystemExit(f'{path}: trust cache version {struct.unpack("<I", p[:4])[0]}')
    count = struct.unpack('<I', p[20:24])[0]
    if len(p) != 24 + 22 * count:
        raise SystemExit(f'{path}: {count} entries, {len(p)} bytes')
    return {p[24 + i * 22:44 + i * 22]: p[44 + i * 22:46 + i * 22] for i in range(count)}


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
                attr = b'\x02\x00'
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
                    attr = b'\x02\x00'
                for h in nhs:
                    if h not in ent:
                        added += 1
                    ent[h] = attr
                    new.append(h)
    blob = struct.pack('<I', 1) + b'\0' * 16 + struct.pack('<I', len(ent))
    for h in sorted(ent):
        blob += h + ent[h]
    os.makedirs(os.path.join(work, 'trust'), exist_ok=True)
    out = os.path.join(work, 'trust', 'merged.trustcache')
    with open(out, 'wb') as f:
        f.write(blob)
    t.mkdirs(b'usr/share/laurel')
    t.write('usr/share/laurel/ios26-merged.trustcache', blob, 0o644, 0, 0)
    t.audit('trust data', 'built', f'{"; ".join(srcs)}; merged {len(ent)} entries, {added} new from the lowering, {missing_attr} without an original attribute. The kernel does not read this file: trust caches are off, built-in AMFI marks every signed file on the root (ios26-kernel.md 3). It is the input if the kernel ever loads one')


def main():
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
    linked = 0
    for c in (b'OS', b'App'):
        pre = PRE + b'/' + c + b'/'
        for k in sorted(k for k in t.n if k.startswith(pre)):
            rel = k[len(pre):]
            n = t.n[k]
            if n.kind == 'd' or rel in t.n or rel == DYLD:
                continue
            t.mkdirs(os.path.dirname(rel))
            if n.kind == 'l':
                t.n[rel] = Node('l', n.mode, n.uid, n.gid, n.mtime, n.src)
            else:
                t.n[rel] = Node('l', 0o755, 0, 0, n.mtime, b'/' + k)
            linked += 1
    print(f'{linked} cryptex-only paths linked at the root')
    print('tweaks:')
    tweaks(t, a)
    trust(t, a, work)
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
