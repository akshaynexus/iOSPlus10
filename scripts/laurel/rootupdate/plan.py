"""Compare the delta of a root build with the phone: what to write, what to keep, and when only a full flash can help. docs/laurel_sprout/root-update.md.

No phone access here: the driver (main.py) reads the phone and gives the facts in. So the test can run every rule on plain data.
"""
import gzip
import hashlib
import json
import os
import stat

import merge

VAR = 'private/var/'
FILES = 'usr/share/laurel/root-files'
MANIFEST = 'usr/share/laurel/root-manifest'
LAUNCHD = 'System/Library/xpc/launchd.plist'
VERSION = 'System/Library/CoreServices/SystemVersion.plist'
# Cannot change under a running system: dyld maps the cache in every process, and a cryptex is the OS itself
NO_UPDATE = ('private/preboot/', 'System/Library/Caches/com.apple.dyld/', 'System/Cryptexes/')
# Only a cache: made again at the next boot (root-camera.sh removes them for a new root too); it may hold answers from the old kernel or plug-ins
CACHES = ('private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist',
          'private/var/mobile/Library/Caches/com.apple.MobileGestalt.plist')
# The tools the update itself needs: they must start from the stage first
SMOKE = ('usr/local/bin/toybox', 'usr/local/bin/dash', 'usr/local/bin/dropbearmulti')
SPARE = 256 << 20


class Row:
    __slots__ = ('kind', 'cls', 'mode', 'uid', 'gid', 'size', 'mtime', 'sha', 'path', 'target')

    def __init__(self, line):
        k, c, mode, uid, gid, size, mt, sha, path, target = line.rstrip('\n').split('\t')
        self.kind, self.cls, self.mode, self.uid, self.gid = k, c, int(mode, 8), int(uid), int(gid)
        self.size, self.mtime, self.sha, self.path, self.target = int(size), int(mt), sha, path, target


class Act:
    """op: mkdir | meta | put | del. A put comes from the store (sha) or from bytes (data). old: the phone has this path now."""
    __slots__ = ('op', 'path', 'mode', 'uid', 'gid', 'size', 'mtime', 'sha', 'data', 'target', 'kind', 'old', 'clash', 'why')

    def __init__(self, op, path, why, **kw):
        self.op, self.path, self.why = op, path, why
        self.mode = self.uid = self.gid = self.size = self.mtime = 0
        self.sha = self.data = None
        self.target = ''
        self.kind = 'f'
        self.old = self.clash = False
        for k, v in kw.items():
            setattr(self, k, v)


def read_update(d):
    with open(os.path.join(d, 'meta.json')) as fh:
        meta = json.load(fh)
    with open(os.path.join(d, 'files.tsv'), encoding='utf-8', errors='surrogateescape') as fh:
        rows = [Row(s) for s in fh]
    return meta, rows


def stock_paths(d):
    with gzip.open(os.path.join(d, 'stock-paths.gz'), 'rt', encoding='utf-8', errors='surrogateescape') as fh:
        return {s.rstrip('\n') for s in fh}


def previous(root_files):
    """Text of the phone's root-files -> (base, first line, paths). No file (a root from before this tool): (None, None, [])."""
    if root_files is None:
        return None, None, []
    base = first = None
    paths = []
    for line in root_files.decode('utf-8', 'surrogateescape').splitlines():
        k, _, v = line.partition('\t')
        if k == 'base':
            base = v
        elif k == 'first':
            first = v
        elif k in ('f', 'l'):
            paths.append(v)
    return base, first, paths


def strip_update(first):
    """The first line of a manifest without what an update added."""
    return (first or '').split(' in-place ')[0].strip()


def info_problems(meta, info, need):
    """Layout of the phone against the root build, from p_info and the delta."""
    out = []
    if 'hfs' not in info.get('mount', ''):
        out.append('the root is not HFS+ (%s)' % info.get('mount', 'no mount line'))
    if 'read-only' in info.get('mount', ''):
        out.append('the root is mounted read-only')
    if info.get('dev_var') != info.get('dev_root'):
        out.append('/private/var is on another volume than / (renames are not atomic there)')
    total, avail = info.get('df_total', 0), info.get('df_avail', 0)
    vol = meta.get('volume_bytes', 0)
    if vol and total and abs(total - vol) > vol // 50:
        out.append('volume size changed: phone %d MiB, new root %d MiB' % (total >> 20, vol >> 20))
    if need + SPARE > avail:
        out.append('not enough free space: need %d MiB + 256 MiB spare, phone has %d MiB' % (need >> 20, avail >> 20))
    return out


def base_problems(meta, phone_build, prev_base, dyld_have):
    out = []
    if meta.get('build') and phone_build and meta['build'] != phone_build:
        out.append('iOS build changed: phone %s, new root %s' % (phone_build, meta['build']))
    if prev_base is not None and meta.get('base') != prev_base:
        out.append('the stock root changed: phone base %s, new root %s (other DMGs or mkiosroot.sh)' % (prev_base, meta.get('base')))
    if prev_base is None:   # first update: the old root has no base id. The shared cache is the one file that must be the same.
        for p, size in meta.get('dyld', {}).items():
            if dyld_have.get(p) != size:
                out.append('the dyld shared cache differs: /%s' % p)
                break
    return out


def compare(rows, have, links, hashes, pulled, base_of, store_of):
    """rows: of the delta. have: path -> (kind, mode, uid, gid, size); links: path -> target; hashes: path -> sha256; pulled: path -> phone's bytes;
    base_of(path), store_of(sha): bytes of the stock and new file. Returns (acts, counts)."""
    acts, n = [], dict(same=0, kept=0, var_skipped=0)
    for r in rows:
        h = have.get(r.path)
        if r.path == MANIFEST:      # the driver writes this one last, with the in-place mark
            continue
        if r.cls == 's':
            n['var_skipped'] += 1
            continue
        if r.kind == 'g':
            if h:
                acts.append(Act('del', r.path, 'gone', old=True))
            else:
                n['same'] += 1
            continue
        if r.kind == 'd':
            if h is None:
                acts.append(Act('mkdir', r.path, 'new folder', mode=r.mode, uid=r.uid, gid=r.gid))
            elif h[0] != 'd':
                acts.append(Act('del', r.path, 'a folder comes here', old=True, clash=True))
                acts.append(Act('mkdir', r.path, 'new folder', mode=r.mode, uid=r.uid, gid=r.gid))
            elif r.cls == 'k' or h[1:4] == (r.mode, r.uid, r.gid):
                n['same'] += 1
            else:
                acts.append(Act('meta', r.path, 'folder owner or mode', mode=r.mode, uid=r.uid, gid=r.gid, kind='d'))
            continue
        if r.cls == 'k' and h is not None:
            n['kept'] += 1
            continue
        if r.cls in 'ma' and h is not None:
            new = merged(r, pulled.get(r.path), base_of, store_of)
            if new is None:
                n['same'] += 1
            else:
                acts.append(Act('put', r.path, 'merge', mode=h[1], uid=h[2], gid=h[3], size=len(new), mtime=r.mtime, data=new, old=True))
            continue
        put = dict(mode=r.mode, uid=r.uid, gid=r.gid, size=r.size, mtime=r.mtime, sha=None if r.kind == 'l' else r.sha, target=r.target, kind=r.kind)
        if h is None:
            acts.append(Act('put', r.path, 'new', **put))
        elif h[0] != r.kind:
            acts.append(Act('put', r.path, 'another kind', old=True, clash=True, **put))
        elif r.kind == 'l':
            if links.get(r.path) != r.target:
                acts.append(Act('put', r.path, 'link target', old=True, **put))
            else:
                n['same'] += 1
        elif h[4] != r.size or hashes.get(r.path) != r.sha:
            acts.append(Act('put', r.path, 'changed', old=True, **put))
        elif h[1:4] != (r.mode, r.uid, r.gid):
            acts.append(Act('meta', r.path, 'owner or mode', mode=r.mode, uid=r.uid, gid=r.gid))
        else:
            n['same'] += 1
    return acts, n


def merged(r, phone, base_of, store_of):
    final = store_of(r.sha)
    if phone is None:       # the phone has this file and it did not come: never overwrite owner data without reading it
        raise RuntimeError('cannot read /%s from the phone' % r.path)
    if r.cls == 'a':
        return merge.merge_lines(final, phone)
    return merge.merge_file(os.path.basename(r.path), base_of(r.path), final, phone)


def no_update_problems(acts):
    """A change that an update in place must not make."""
    return ['/%s would change' % a.path for a in acts if a.path.startswith(NO_UPDATE)]


def stale(prev_paths, rows, stock, have):
    """Paths an older build installed and this one does not. Not in stock: remove. In stock: the stock file is gone from the phone and not in the delta: a full flash."""
    now = {r.path for r in rows}
    acts, problems = [], []
    for p in prev_paths:
        if p in now or p.startswith(VAR) or p not in have:
            continue
        if p in stock:
            problems.append('/%s was changed by an older build and is stock now' % p)
        else:
            acts.append(Act('del', p, 'an older build installed it', old=True))
    return acts, problems


def bytes_put(acts):
    return sum(a.size for a in acts if a.op == 'put' and a.kind == 'f')


def rollback_bytes(acts, have):
    """Upper bound: the old copies. A removed folder counts only its own line: the spare covers it."""
    return sum(have[a.path][4] for a in acts if a.old and a.op in ('put', 'del') and a.path in have and have[a.path][0] == 'f')


def trivial(a):
    """No reason to write or reboot: a folder in /private/var that the phone removed by itself (read on the phone: containers/Temp is not there after a boot), a cache."""
    return (a.op == 'mkdir' and a.path.startswith(VAR)) or a.path in CACHES


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def parse_stat(text, prefix):
    """Lines of p_stat -> path -> (kind, mode, uid, gid, size)."""
    out = {}
    cut = len(prefix) + 1
    for line in text.splitlines():
        hexmode, uid, gid, size, full = line.split(' ', 4)
        m = int(hexmode, 16)
        k = 'd' if stat.S_ISDIR(m) else 'l' if stat.S_ISLNK(m) else 'f' if stat.S_ISREG(m) else 'o'
        out[full[cut:]] = (k, stat.S_IMODE(m), int(uid), int(gid), int(size))
    return out


def parse_hash(text, prefix):
    out = {}
    cut = len(prefix) + 1
    for line in text.splitlines():
        digest, full = line.split('  ', 1)
        out[full[cut:]] = digest
    return out
