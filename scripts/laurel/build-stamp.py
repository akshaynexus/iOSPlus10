#!/usr/bin/env python3
"""Mi A3: proof of which build a kernel or boot image is. docs/laurel_sprout/build-honest.md.

  build-stamp.py kernel-stamp WORK PAGES            the stamp text of this run: "<commit> <n> patches, series <16 hex>, <pages>"
                                                    (series = names + contents of WORK/patches, WORK/linux/fixes, known-skips.txt)
  build-stamp.py kernel-header STAMP                the C header for bsd/dev/laurel_build.c (kernel patch 2912), on stdout
  build-stamp.py kernel-verify --kernel K --work W --stamp S --t0 EPOCH   a finished kernel build is really this run's; else one
                                                    "FAILED:" line per reason, exit 1
  build-stamp.py kernel-seal K OUT S                write OUT.stamp (stamp, series, sha256, time) for the copied kernel
  build-stamp.py kernel-check K [--no-repo]         K has its stamp, its sha256, its embedded line; series = the patches in the repo now
  build-stamp.py repo-series                        the series hash of the patches in the repo now
  build-stamp.py image-line K FD                    the text of /chosen laurel-image-build (kernel 2912 prints it at boot)
  build-stamp.py image-seal IMG LINE K FD CMDLINE   write IMG.stamp
  build-stamp.py image-check IMG K FD               IMG has its stamp and its sha256; kernel and FD are the ones it was built from
"""
import hashlib
import os
import re
import subprocess
import sys
import time

REPO = os.environ.get('LAUREL_REPO') or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SWEET_FIXES = ('0001-kalloc-stock-clang-void-ptr.patch', '0003-corecrypto-sha256-asm-operands.patch')
DIRTY_PATHS = ('patches/laurel', 'scripts/laurel', 'scripts/ios16', 'scripts/bt', 'scripts/net', 'scripts/metal', 'userland')


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def git(*args):
    # safe.directory: root.sh runs as root in a tree the user owns
    r = subprocess.run(['git', '-c', 'safe.directory=*', '-C', REPO] + list(args), capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def commit():
    """Short commit of the repo, '-dirty' when a build input differs from it. 'nogit' when git cannot tell."""
    head = git('rev-parse', '--short=10', 'HEAD')
    if head is None:
        return 'nogit'
    dirty = git('status', '--porcelain', '--ignore-submodules=all', '--', *DIRTY_PATHS)
    return head + ('-dirty' if dirty else '')


def series_hash(items):
    """items: (kind, name, path). The order of the disk does not count; a name or a byte that changes does."""
    h = hashlib.sha256()
    for kind, name, path in sorted(items):
        h.update(('%s\0%s\0%s\n' % (kind, name, sha256_file(path))).encode())
    return h.hexdigest()[:16]


def listdir_files(d):
    return sorted(n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n))) if os.path.isdir(d) else []


def external(name):
    """external/NAME of this checkout, or of the main checkout (a worktree has no reference repos)."""
    d = os.path.join(REPO, 'external', name)
    if os.path.isdir(d) and os.listdir(d):
        return d
    out = git('worktree', 'list', '--porcelain')
    return os.path.join(out.splitlines()[0].split(' ', 1)[1], 'external', name) if out else d


def ios26_files():
    """iOS 26 kernel (scripts/laurel/kernel-ios26-linux.sh, LAUREL_STAMP_IOS26=1): the same series + the 12377 parts."""
    t, lp, p26 = os.path.join(external('ios-topaz'), 'xnu/patches'), os.path.join(REPO, 'patches/laurel/xnu'), os.path.join(REPO, 'patches/laurel/xnu-12377')
    files = {n: os.path.join(t, n) for n in listdir_files(t) if n.endswith(('.patch', '.sh'))}
    files.update({n: os.path.join(lp, n) for n in listdir_files(lp) if n.endswith('.patch')})
    for d in (p26, os.path.join(p26, 'stage'), os.path.join(p26, 'post')):
        files.update({n: os.path.join(d, n) for n in listdir_files(d) if n.endswith(('.patch', '.sh', '.txt'))})
    files['0001-non-apple-soc-base.patch'] = os.path.join(REPO, 'patches/xnu-12377/0001-non-apple-soc-base.patch')
    for s in ('scripts/laurel/ios26-series.py', 'scripts/laurel/ios26-env.sh', 'scripts/ios26/apply-series.py'):
        files[os.path.basename(s)] = os.path.join(REPO, s)
    return files


def used_series(work):
    """What this run copied and applied: the copies, so a later edit of the sources does not change it."""
    items = []
    if os.environ.get('LAUREL_STAMP_IOS26') == '1':
        d = os.path.join(work, 'patches')
        return [('patch', n, os.path.join(d, n)) for n in listdir_files(d)]
    p, f = os.path.join(work, 'patches'), os.path.join(work, 'linux/fixes')
    items += [('patch', n, os.path.join(p, n)) for n in listdir_files(p) if n.endswith(('.patch', '.sh'))]
    items += [('fix', n, os.path.join(f, n)) for n in listdir_files(f) if n.endswith('.patch')]
    items.append(('skip', 'known-skips.txt', os.path.join(work, 'linux/known-skips.txt')))
    return items


def repo_series_items():
    """The same list from the sources in the repo (the copy steps of kernel-linux.sh: a laurel name overrides a topaz name)."""
    if os.environ.get('LAUREL_STAMP_IOS26') == '1':
        return [('patch', n, p) for n, p in sorted(ios26_files().items())]
    t = os.path.join(REPO, 'external/ios-topaz/xnu/patches')
    sl = os.path.join(REPO, 'external/ios-sweet-linux/linux/fixes')
    lp = os.path.join(REPO, 'patches/laurel/xnu')
    lf = os.path.join(REPO, 'patches/laurel/xnu-linux-fixes')
    for d in (t, sl):
        if not os.path.isdir(d):
            sys.exit('build-stamp: FAILED: no %s (scripts/setup/get-references.sh ios-topaz ios-sweet-linux)' % d)
    patches = {n: os.path.join(t, n) for n in listdir_files(t) if n.endswith(('.patch', '.sh'))}
    patches.update({n: os.path.join(lp, n) for n in listdir_files(lp) if n.endswith('.patch')})
    fixes = {n: os.path.join(sl, n) for n in SWEET_FIXES}
    fixes.update({n: os.path.join(lf, n) for n in listdir_files(lf) if n.endswith('.patch')})
    return ([('patch', n, p) for n, p in patches.items()] + [('fix', n, p) for n, p in fixes.items()] +
            [('skip', 'known-skips.txt', os.path.join(REPO, 'patches/laurel/known-skips.txt'))])


def read_stamp(path):
    try:
        with open(path) as fh:
            return dict(line.rstrip('\n').split('=', 1) for line in fh if '=' in line)
    except OSError:
        return None


def write_stamp(path, values):
    with open(path + '.new', 'w') as fh:
        for k, v in values.items():
            fh.write('%s=%s\n' % (k, v))
    os.replace(path + '.new', path)


def utc():
    return time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())


def kernel_line(stamp):
    return ('LAUREL BUILD: %s\n' % stamp).encode()


def holds(path, needle):
    # The string can stand across a read boundary: keep the tail of each block.
    tail = b''
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 22), b''):
            if needle in tail + chunk:
                return True
            tail = chunk[-len(needle):]
    return False


def kernel_verify(a):
    k, work, stamp, t0 = a['--kernel'], a['--work'], a['--stamp'], float(a['--t0'])
    src = a.get('--xnu') or os.path.join(work, 'xnu-src/xnu-8796.141.3')
    log = os.path.join(work, 'build.log')
    fail = []
    if not os.path.isfile(k) or os.path.getsize(k) == 0:
        print('kernel-linux: FAILED: no kernel at %s' % k)
        return 1
    km = os.stat(k).st_mtime
    if km < t0:
        fail.append('the kernel is from %s, before this run started: an old file, not this build' % time.ctime(km))
    # the last relink: build-with-iig.sh touches this file just before each make round. A kernel older than it was linked in an
    # earlier round (DriverKit wrappers all "unsupported"), and make -k may print no linker line when a compile stops it first.
    stub = os.path.join(src, 'iokit/DriverKit/OSObject.iig.cpp')
    if os.path.exists(stub) and km < os.stat(stub).st_mtime:
        fail.append('the kernel is older than the last DriverKit stub round: the last relink did not make it')
    try:
        with open(log, errors='replace') as fh:
            lines = fh.read().splitlines()
    except OSError:
        lines = None
    if lines is None:
        fail.append('no %s' % log)
    else:
        last_fail = max((i for i, s in enumerate(lines) if 'linker command failed' in s), default=-1)
        last_ok = max((i for i, s in enumerate(lines) if 'built kernel at' in s), default=-1)
        if last_ok < 0:
            fail.append("XNU never printed 'built kernel at'")
        elif last_fail > last_ok:
            fail.append('the last link round failed (build.log line %d), after the last good one (line %d)' % (last_fail + 1, last_ok + 1))
        n = sum('linker command failed' in s for s in lines)
        print('kernel-linux: linker failures in build.log: %d (0 to 4 are the DriverKit stub rounds of build-with-iig.sh, all before the last good link)' % n)
    if not holds(k, kernel_line(stamp)):
        fail.append('the kernel does not hold the line "LAUREL BUILD: %s"' % stamp)
    # Each source patch must be older than the kernel, and the same as the copy this run applied
    used, now = used_series(work), repo_series_items()
    if series_hash(used) != series_hash(now):
        u = {(i[0], i[1], sha256_file(i[2])) for i in used}
        r = {(i[0], i[1], sha256_file(i[2])) for i in now}
        fail.append('patches changed during this run: %s' % ' '.join(sorted({x[1] for x in u ^ r}))[:400])
    newer = sorted(i[1] for i in now if os.stat(i[2]).st_mtime > km)
    if newer:
        fail.append('newer than the kernel: %s' % ' '.join(newer)[:400])
    for f in fail:
        print('kernel-linux: FAILED: %s' % f)
    return 1 if fail else 0


def kernel_seal(k, out, stamp):
    m = re.match(r'(\S+) (\d+) patches, series ([0-9a-f]{16}), (\w+)$', stamp)
    if not m:
        sys.exit('build-stamp: bad stamp %r' % stamp)
    write_stamp(out + '.stamp', {'stamp': stamp, 'commit': m[1], 'patches': m[2], 'series': m[3], 'pages': m[4], 'built': utc(), 'sha256': sha256_file(out)})
    return 0


def kernel_check(k, repo=True):
    """None when K is good, else the reason."""
    st = read_stamp(k + '.stamp')
    if not os.path.isfile(k):
        return 'no kernel %s (scripts/laurel/kernel-linux.sh)' % k
    if st is None or 'series' not in st:
        return 'no %s.stamp: not from a checked kernel-linux.sh run' % os.path.basename(k)
    if sha256_file(k) != st.get('sha256'):
        return '%s is not the file its stamp names (sha256 differs)' % os.path.basename(k)
    if not holds(k, kernel_line(st['stamp'])):
        return '%s does not hold the line "LAUREL BUILD: %s"' % (os.path.basename(k), st['stamp'])
    if repo:
        now = series_hash(repo_series_items())
        if now != st['series']:
            return 'kernel series %s, patches in the repo now %s: the kernel is stale (scripts/laurel/kernel-linux.sh)' % (st['series'], now)
    return None


def image_line(k, fd):
    st = read_stamp(k + '.stamp') or {}
    return '%s %s kernel-series %s fd %s' % (commit(), utc(), st.get('series', 'none'), sha256_file(fd)[:8])


def image_seal(img, line, k, fd, cmdline):
    st = read_stamp(k + '.stamp') or {}
    write_stamp(img + '.stamp', {'line': line, 'kernel_series': st.get('series', 'none'), 'kernel_sha256': sha256_file(k), 'fd_sha256': sha256_file(fd),
                                 'cmdline': cmdline, 'built': utc(), 'sha256': sha256_file(img)})
    return 0


def image_check(img, k, fd):
    st = read_stamp(img + '.stamp')
    if not os.path.isfile(img):
        return 'no boot image %s (scripts/laurel/uefi-image.sh)' % img
    if st is None or 'sha256' not in st:
        return 'no %s.stamp: not from a checked uefi-image.sh run' % os.path.basename(img)
    if sha256_file(img) != st['sha256']:
        return '%s is not the file its stamp names (sha256 differs)' % os.path.basename(img)
    if os.path.isfile(k) and sha256_file(k) != st.get('kernel_sha256'):
        return 'the kernel changed after this boot image was made (scripts/laurel/uefi-image.sh)'
    if os.path.isfile(fd) and sha256_file(fd) != st.get('fd_sha256'):
        return 'the Mu FD changed after this boot image was made (scripts/laurel/uefi-image.sh)'
    return None


def done(reason, ok):
    if reason:
        print('build-stamp: FAILED: %s' % reason)
        return 1
    print('build-stamp: %s' % ok)
    return 0


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd, a = argv[0], argv[1:]
    if cmd == 'kernel-stamp':
        items = used_series(a[0])
        print('%s %d patches, series %s, %s' % (commit(), sum(i[0] == 'patch' and i[1].endswith('.patch') for i in items), series_hash(items), a[1]))
        return 0
    if cmd == 'kernel-header':
        m = re.search(r'series ([0-9a-f]{16})', a[0])
        print('/* generated by scripts/laurel/kernel-linux.sh: kernel patch 2912 */')
        print('#define LAUREL_BUILD_STAMP "%s"' % a[0])
        print('#define LAUREL_BUILD_SERIES "%s"' % m[1])
        return 0
    if cmd == 'kernel-verify':
        return kernel_verify(dict(zip(a[0::2], a[1::2])))
    if cmd == 'kernel-seal':
        return kernel_seal(a[0], a[1], a[2])
    if cmd == 'kernel-check':
        st = read_stamp(a[0] + '.stamp') or {}
        return done(kernel_check(a[0], '--no-repo' not in a), 'kernel ok: %s' % st.get('stamp'))
    if cmd == 'repo-series':
        print(series_hash(repo_series_items()))
        return 0
    if cmd == 'image-line':
        print(image_line(a[0], a[1]))
        return 0
    if cmd == 'image-seal':
        return image_seal(*a)
    if cmd == 'image-check':
        st = read_stamp(a[0] + '.stamp') or {}
        return done(image_check(*a), 'boot image ok: %s' % st.get('line'))
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
