#!/usr/bin/env python3
"""Mi A3 root: what the root steps add or change on top of the stock root, for an update in place. docs/laurel_sprout/root-update.md.

  root-delta.py snapshot ROOT DIR     after mkiosroot, before the first tweak: DIR/stock.tsv (stat of every path), DIR/base/ (the stock plists of /private/var)
  root-delta.py make ROOT DIR         after the feature table: DIR/files.tsv, DIR/store/<sha256>, DIR/meta.json, DIR/stock-paths.gz, ROOT/usr/share/laurel/root-files
  root-delta.py seal DIR FINAL        the run ended well: DIR becomes FINAL, owned by the user (sudo run); an older FINAL goes away
  root-delta.py clean DIR...          remove old output at the start of a run

Same path + same kind, mode, owner, size, mtime and ctime = not ours. So a step needs no list of its own: a new step is in the delta by itself.
files.tsv: kind class mode uid gid size mtime sha256 path [target]
  kind:  f file, l link, d folder, g gone (only the top path of a removed tree)
  class: i install (replace what the phone has), m plist (merge the keys our steps set), a authorized_keys (union of lines),
         k keep (the phone's copy wins; only a missing one is made), s skip (a gone path in /private/var stays on the phone)
The classes are the rule "keep /private/var except what we install". A new state file in /private/var: one line in KEEP.
"""
import concurrent.futures
import gzip
import hashlib
import json
import os
import plistlib
import shutil
import stat
import sys
import time

VAR = 'private/var/'
FILES = 'usr/share/laurel/root-files'
MANIFEST = 'usr/share/laurel/root-manifest'
KEYS = 'private/var/root/.ssh/authorized_keys'
# State that the phone owns once it runs: the gate and the owner edit the Metal lists (docs/metal-management.md), .profile is only "if missing" at the build
KEEP = {'private/var/db/negronimetal/clients', 'private/var/db/negronimetal/env', 'private/var/db/negronimetal/metal.log', 'private/var/root/.profile'}
# A sentinel of --migration once must not start a migration on a phone with data
KEEP_NOT_MADE = ('private/var/datamigrator/',)
# Gone paths in /private/var that do go: root-system-features.py moved them to /Applications
GONE_OK = ('private/var/staged_system_apps/',)
# An older root had these and no root-files, so nothing else names them. Removed when the new root has none.
LEGACY = ('System/Library/LaunchDaemons/dev.iosplus10.usbnetcfg.plist',)
VERSION = 'System/Library/CoreServices/SystemVersion.plist'
DYLD = 'System/Library/Caches/com.apple.dyld/'


def kind_of(mode):
    return 'd' if stat.S_ISDIR(mode) else 'l' if stat.S_ISLNK(mode) else 'f' if stat.S_ISREG(mode) else ''


def walk(root):
    """(relative path, lstat) of everything under root but root itself; no special files. Depth first, parents first."""
    stack = ['']
    while stack:
        rel = stack.pop()
        with os.scandir(os.path.join(root, rel) if rel else root) as it:
            for e in it:
                p = rel + '/' + e.name if rel else e.name
                if '\t' in p or '\n' in p:
                    sys.exit('root-delta: FAILED: a tab or line end in a name: %r' % p)
                st = e.stat(follow_symlinks=False)
                if not kind_of(st.st_mode):
                    continue
                yield p, st
                if stat.S_ISDIR(st.st_mode):
                    stack.append(p)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def snapshot(root, d):
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, 'base'))
    lines, dyld = [], {}
    for p, st in walk(root):
        k = kind_of(st.st_mode)
        lines.append('%s %o %d %d %d %d %d %s\n' % (k, stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, st.st_size, st.st_mtime_ns, st.st_ctime_ns, p))
        if p.startswith(VAR) and k == 'f' and p.endswith('.plist') and st.st_size < 1 << 22:
            q = os.path.join(d, 'base', p)
            os.makedirs(os.path.dirname(q), exist_ok=True)
            shutil.copyfile(os.path.join(root, p), q)
        if k == 'f' and p.startswith(DYLD):
            dyld[p] = st.st_size
    lines.sort()
    with open(os.path.join(d, 'stock.tsv'), 'w', encoding='utf-8', errors='surrogateescape') as fh:
        fh.writelines(lines)
    build = ''
    try:
        with open(os.path.join(root, VERSION), 'rb') as fh:
            build = plistlib.load(fh).get('ProductBuildVersion', '')
    except (OSError, ValueError, plistlib.InvalidFileException):
        pass
    st = os.statvfs(root)
    with open(os.path.join(d, 'stock.json'), 'w') as fh:
        json.dump({'build': build, 'dyld': dyld, 'volume_bytes': st.f_blocks * st.f_frsize}, fh)
    print('root-delta: snapshot: %d paths, build %s' % (len(lines), build or 'unknown'))
    return 0


def read_stock(d):
    stock = {}
    with open(os.path.join(d, 'stock.tsv'), encoding='utf-8', errors='surrogateescape') as fh:
        for line in fh:
            k, mode, uid, gid, size, mt, ct, p = line.rstrip('\n').split(' ', 7)
            stock[p] = (k, int(mode, 8), int(uid), int(gid), int(size), int(mt), int(ct))
    return stock


def base_id(stock):
    h = hashlib.sha256()
    for p in sorted(stock):
        k, mode, uid, gid, size = stock[p][:5]
        if not p.startswith(VAR):
            h.update(('%s %o %d %d %d %s\n' % (k, mode, uid, gid, 0 if k == 'd' else size, p)).encode('utf-8', 'surrogateescape'))
    return h.hexdigest()[:16]


def is_plist(path):
    try:
        with open(path, 'rb') as fh:
            plistlib.load(fh)
        return True
    except (OSError, ValueError, plistlib.InvalidFileException):
        return False


def klass(root, p, k):
    if not p.startswith(VAR):
        return 'i'
    if k == 'd':
        return 'k'
    if k == 'g':
        return 'i' if p.startswith(GONE_OK) else 's'
    if p == KEYS:
        return 'a'
    if p in KEEP:
        return 'k'
    if p.startswith(KEEP_NOT_MADE):
        return 's'
    if k == 'f' and p.endswith('.plist') and is_plist(os.path.join(root, p)):
        return 'm'
    return 'i'


def store_file(root, d, p):
    src = os.path.join(root, p)
    digest = sha256(src)
    q = os.path.join(d, 'store', digest)
    if not os.path.exists(q):
        tmp = '%s.%d.%d' % (q, os.getpid(), hash(p) & 0xffffff)
        shutil.copyfile(src, tmp)
        os.chmod(tmp, 0o600)
        os.replace(tmp, q)
    return p, digest


def make(root, d):
    stock = read_stock(d)
    with open(os.path.join(d, 'stock.json')) as fh:
        meta = json.load(fh)
    now = dict(walk(root))
    now.pop(FILES, None)
    os.makedirs(os.path.join(d, 'store'), exist_ok=True)
    rows = []
    for p in sorted(now):
        st = now[p]
        k = kind_of(st.st_mode)
        mode = stat.S_IMODE(st.st_mode)
        old = stock.get(p)
        if k == 'd':
            same = old is not None and old[:4] == (k, mode, st.st_uid, st.st_gid)
        else:
            same = old == (k, mode, st.st_uid, st.st_gid, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        if not same:
            rows.append(dict(kind=k, cls=klass(root, p, k), mode=mode, uid=st.st_uid, gid=st.st_gid, size=0 if k == 'd' else st.st_size,
                             mtime=int(st.st_mtime), sha='-', path=p, target=os.readlink(os.path.join(root, p)) if k == 'l' else ''))
    for p in sorted(stock):
        parent = os.path.dirname(p)
        if p not in now and (parent not in stock or parent in now):   # only the top path of a removed tree
            rows.append(dict(kind='g', cls=klass(root, p, 'g'), mode=0, uid=0, gid=0, size=0, mtime=0, sha='-', path=p, target=''))
    for p in LEGACY:
        if p not in now and p not in stock:
            rows.append(dict(kind='g', cls='i', mode=0, uid=0, gid=0, size=0, mtime=0, sha='-', path=p, target=''))
    want = [r['path'] for r in rows if r['kind'] == 'f']
    with concurrent.futures.ThreadPoolExecutor(os.cpu_count() or 4) as pool:
        digests = dict(pool.map(lambda p: store_file(root, d, p), want))
    for r in rows:
        if r['kind'] == 'f':
            r['sha'] = digests[r['path']]
    with open(os.path.join(root, MANIFEST)) as fh:
        first = fh.readline().strip()
    meta.update(first=first, base=base_id(stock), utc=time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()), format=1)
    # the list the next update reads on the phone: what a later build may no longer install
    text = 'base\t%s\nfirst\t%s\n' % (meta['base'], first)
    text += ''.join('%s\t%s\n' % (r['kind'], r['path']) for r in rows if r['kind'] in 'fl' and not r['path'].startswith(VAR))
    p = os.path.join(root, FILES)
    with open(p + '.new', 'w', encoding='utf-8', errors='surrogateescape') as fh:
        fh.write(text)
    os.chmod(p + '.new', 0o644)
    if os.geteuid() == 0:
        os.chown(p + '.new', 0, 0)
    os.replace(p + '.new', p)
    st = os.stat(p)
    _, digest = store_file(root, d, FILES)
    rows.append(dict(kind='f', cls='i', mode=0o644, uid=st.st_uid, gid=st.st_gid, size=st.st_size, mtime=int(st.st_mtime), sha=digest, path=FILES, target=''))
    with open(os.path.join(d, 'files.tsv'), 'w', encoding='utf-8', errors='surrogateescape') as fh:
        for r in rows:
            fh.write('%(kind)s\t%(cls)s\t%(mode)o\t%(uid)d\t%(gid)d\t%(size)d\t%(mtime)d\t%(sha)s\t%(path)s\t%(target)s\n' % r)
    with gzip.open(os.path.join(d, 'stock-paths.gz'), 'wt', encoding='utf-8', errors='surrogateescape') as fh:
        fh.writelines(p + '\n' for p in sorted(stock) if not p.startswith(VAR))
    with open(os.path.join(d, 'manifest'), 'wb') as fh, open(os.path.join(root, MANIFEST), 'rb') as src:
        fh.write(src.read())
    with open(os.path.join(d, 'meta.json'), 'w') as fh:
        json.dump(meta, fh, indent=1, sort_keys=True)
    os.remove(os.path.join(d, 'stock.tsv'))
    os.remove(os.path.join(d, 'stock.json'))
    n = {c: sum(r['cls'] == c for r in rows) for c in 'imaks'}
    gb = sum(r['size'] for r in rows if r['kind'] == 'f')
    print('root-delta: %d paths (%d install, %d plist, %d key file, %d keep, %d skip), %d bytes, base %s' % (len(rows), n['i'], n['m'], n['a'], n['k'], n['s'], gb, meta['base']))
    return 0


def seal(d, final):
    if os.path.exists(final):
        shutil.rmtree(final)
    os.rename(d, final)
    user = os.environ.get('SUDO_USER')
    if user and os.geteuid() == 0:
        shutil.chown(final, user)
        for top, dirs, names in os.walk(final):
            for n in dirs + names:
                shutil.chown(os.path.join(top, n), user)
    print('root-delta: update payload %s' % final)
    return 0


def main(argv):
    if len(argv) >= 2 and argv[0] == 'clean':
        for d in argv[1:]:
            shutil.rmtree(d, ignore_errors=True)
        return 0
    if len(argv) != 3:
        sys.exit(__doc__)
    cmd = {'snapshot': snapshot, 'make': make, 'seal': seal}.get(argv[0])
    if cmd is None:
        sys.exit(__doc__)
    return cmd(argv[1], argv[2])


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
