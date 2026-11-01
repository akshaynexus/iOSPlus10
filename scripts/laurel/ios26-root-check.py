#!/usr/bin/env python3
"""The iOS 26 root, read through a real read-only mount of the image: ios26-root-check.py MOUNT MANIFEST.

Walks the mounted tree, an independent reader of the volume (Linux hfsplus): every entry of the manifest must be there, with type, mode, owner and size; nothing
more than the volume's own files. Then the layout the boot needs, and SHA-256 of the cache, of launchd and dyld, and of a fixed sample. Exit 1 on any difference.
"""
import hashlib
import os
import random
import stat
import sys
import unicodedata

root, manifest = sys.argv[1], sys.argv[2]
rootb = root.encode()
want = {}
for line in open(manifest, 'rb'):
    if line.startswith(b'#'):
        continue
    f = line.rstrip(b'\n').split(b'\0')
    want[f[7]] = f
bad = []
seen = 0
own = {b'.journal', b'.journal_info_block', b'\xe2\x90\x80\xe2\x90\x80\xe2\x90\x80\xe2\x90\x80HFS+ Private Data', b'.HFS+ Private Directory Data\r'}


def nfd(p):
    return unicodedata.normalize('NFD', p.decode()).encode()


byform = {nfd(k): k for k in want}
extra = []
for dirp, dirs, files in os.walk(rootb):
    rel = os.path.relpath(dirp, rootb)
    rel = b'' if rel == b'.' else rel
    for name in dirs + files:
        p = os.path.join(rel, name) if rel else name
        if not rel and (name in own or b'HFS+ Private' in name):
            continue
        k = byform.get(nfd(p))
        if k is None:
            extra.append(p)
            continue
        seen += 1
        st = os.lstat(os.path.join(rootb, p))
        f = want[k]
        if st.st_mode != int(f[1], 8) or st.st_uid != int(f[2]) or st.st_gid != int(f[3]):
            bad.append(f'{p!r}: mode {st.st_mode:o} uid {st.st_uid} gid {st.st_gid}, manifest {f[1]} {f[2]} {f[3]}')
        elif f[0] == b'f' and st.st_size != int(f[5]):
            bad.append(f'{p!r}: size {st.st_size}, manifest {f[5]}')
        elif f[0] == b'l' and os.readlink(os.path.join(rootb, p)) != f[6]:
            bad.append(f'{p!r}: link {os.readlink(os.path.join(rootb, p))!r}, manifest {f[6]!r}')
print(f'mount check: {seen} of {len(want)} manifest entries found with type, mode, owner, size or target; {len(extra)} extra; {len(bad)} differ')
if extra:
    print(' extra:', extra[:5])
for b in bad[:20]:
    print(' ', b)


def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest().encode()


# layout
checks = [
    (b'sbin/launchd', stat.S_ISREG), (b'usr/lib/dyld', stat.S_ISREG), (b'System/Library/xpc/launchd.plist', stat.S_ISREG),
    (b'System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e', stat.S_ISREG), (b'private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld', stat.S_ISLNK),
    (b'System/Cryptexes/OS', stat.S_ISLNK), (b'System/Cryptexes/App', stat.S_ISLNK), (b'private/var/keybags/systembag.kb', stat.S_ISREG), (b'private/var/db/uuidtext/.migrated', stat.S_ISREG),
    (b'usr/share/laurel/ios26-merged.trustcache', stat.S_ISREG), (b'usr/share/laurel/ios26-root-audit.txt', stat.S_ISREG),
]
fail = 0
for p, test in checks:
    try:
        ok = test(os.lstat(os.path.join(rootb, p)).st_mode)
    except OSError:
        ok = False
    if not ok:
        fail += 1
        print('  layout missing or wrong type:', p)
print(f'layout: {len(checks) - fail} of {len(checks)} paths good')
dyld_seen = os.path.isfile(os.path.join(rootb, b'private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e'))
print('the cryptex path of the cache reaches the file through its link:', dyld_seen)
for must in (b'System/Library/LaunchDaemons', b'System/Library/Frameworks', b'Applications'):
    if not os.path.isdir(os.path.join(rootb, must)):
        fail += 1
# hashes
files = [k for k, f in want.items() if f[0] == b'f']
cache = [k for k in files if k.startswith(b'System/Library/Caches/com.apple.dyld/')]
head = [k for k in (b'sbin/launchd', b'usr/lib/dyld', b'System/Library/xpc/launchd.plist') if k in want]
random.seed(26)
sample = random.sample(sorted(files), min(3000, len(files)))
hbad = 0
hmb = 0
for k in cache + head + sample:
    got = sha(os.path.join(rootb, k))
    hmb += int(want[k][5])
    if got != want[k][6]:
        hbad += 1
        print('  SHA-256 differs:', k)
print(f'SHA-256 through the mount: {len(cache)} cache files, launchd, dyld, launchd.plist, {len(sample)} sample files: {hmb >> 20} MiB, {hbad} differ')
sys.exit(1 if bad or extra or fail or hbad or not dyld_seen or seen != len(want) else 0)
