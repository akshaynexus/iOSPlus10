#!/usr/bin/env python3
# Regenerate patches/laurel/xnu/2950-laurel-dual-boot.patch from a driver file edited in a patched kernel tree, and from tools/laurel-dualboot/laurel_dualboot.h. Host only.
#   python3 -I scripts/laurel/dualboot-patch-refresh.py --save-base TREE/bsd/dev/sweet_ufs.c     once, before the edit: TREE: `AUDIT=1 scripts/laurel/kernel-linux.sh`, out/laurel-kernel/xnu-src/xnu-8796.141.3. 2950 is the last patch on this file
#   python3 -I scripts/laurel/dualboot-patch-refresh.py TREE/bsd/dev/sweet_ufs.c                 after the edit
# The first lines of the patch (its message) stay. Both series apply the result: kernel-linux.sh and kernel-ios26-linux.sh show it.
import os, subprocess, sys, tempfile
repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
patch = os.path.join(repo, 'patches/laurel/xnu/2950-laurel-dual-boot.patch')
hdr = os.path.join(repo, 'tools/laurel-dualboot/laurel_dualboot.h')
save = sys.argv[1] == '--save-base'
driver = sys.argv[-1]
base_file = driver + '.pre2950'
old = open(patch).read()
at = old.index('diff -ruN a/bsd/dev/laurel_dualboot.h')
message, body = old[:at], old[at:]
if save:
    # the driver before 2950: the hunks of the patch reversed out of the tree's copy
    drv = body[body.index('diff -ruN a/bsd/dev/sweet_ufs.c'):]
    with tempfile.TemporaryDirectory() as d:
        w = os.path.join(d, 'sweet_ufs.c')
        open(w, 'w').write(open(driver).read())
        subprocess.run(['patch', '-R', '-s', '-p0', w], input=drv.encode(), check=True)
        open(base_file, 'w').write(open(w).read())
    print(f'{base_file}: the driver before 2950')
    sys.exit(0)
new_driver = open(driver).read()
before = open(base_file).read()
def udiff(a, b, name):
    r = subprocess.run(['diff', '-U3', '--label', 'a/' + name, '--label', 'b/' + name, a, b], stdout=subprocess.PIPE)
    return f'diff -ruN a/{name} b/{name}\n' + r.stdout.decode()
with tempfile.TemporaryDirectory() as d:
    open(d + '/a', 'w').write(before)
    open(d + '/b', 'w').write(new_driver)
    open(d + '/e', 'w').close()
    out = udiff(d + '/e', hdr, 'bsd/dev/laurel_dualboot.h') + udiff(d + '/a', d + '/b', 'bsd/dev/sweet_ufs.c')
open(patch, 'w').write(message + out)
print(f'{patch}: {len(out.splitlines())} lines')
