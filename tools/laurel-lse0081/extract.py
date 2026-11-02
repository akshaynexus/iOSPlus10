#!/usr/bin/env python3
"""The EL0 LSE emulation of the iOS 16 kernel, as text, for the host test (scripts/laurel/test-lse0081.sh).

  extract.py XNU_TREE OUTDIR [--before FIX_PATCH]

XNU_TREE is the tree that kernel-linux.sh patched, so the test runs the text the kernel compiled, not a copy.
Writes OUTDIR/sleh_frag.inc (the SWEET block before handle_uncategorized) and OUTDIR/asm_frag.inc (the SWEET block at the end of
machine_routines_asm.s and the line with copyio_recover_table_end, in the order of the file: the order is the first bug).
--before: first take FIX_PATCH back from a copy of the two files, for the run that shows what the test finds in the old code.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

SLEH = 'osfmk/arm64/sleh.c'
ASM = 'osfmk/arm64/machine_routines_asm.s'


def sections(patch):
    """Only the sections of FIX_PATCH for the two files: patch(1) has no other files to change in the copy."""
    out, keep = [], False
    for line in open(patch, encoding='latin-1'):
        if line.startswith('--- '):
            keep = line.split()[1][2:] in (SLEH, ASM)
        if keep:
            out.append(line)
    return ''.join(out)


def main(argv):
    if len(argv) not in (3, 5) or (len(argv) == 5 and argv[3] != '--before'):
        sys.exit(__doc__)
    tree, out = argv[1], argv[2]
    os.makedirs(out, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=out) as d:
        for f in (SLEH, ASM):
            os.makedirs(os.path.dirname(os.path.join(d, f)), exist_ok=True)
            shutil.copy(os.path.join(tree, f), os.path.join(d, f))
        if len(argv) == 5:
            r = subprocess.run(['patch', '-R', '-p1', '-s', '--fuzz=0', '--no-backup-if-mismatch'], cwd=d, input=sections(argv[4]), text=True, encoding='latin-1', capture_output=True)
            if r.returncode:
                sys.exit(f'extract: {argv[4]} does not come back from {tree}: stale tree? {r.stdout}{r.stderr}')
        c = open(os.path.join(d, SLEH), encoding='latin-1').read()
        s = open(os.path.join(d, ASM), encoding='latin-1').read()
    m = re.search(r'^#if defined\(SWEET\)\nextern int _sweet_lse_b\(.*?^#endif /\* SWEET \*/$', c, re.M | re.S)
    if not m:
        sys.exit(f'extract: no _sweet_lse block in {SLEH}')
    open(os.path.join(out, 'sleh_frag.inc'), 'w', encoding='latin-1').write(m.group(0) + '\n')
    i = re.search(r'^#if defined\(SWEET\)\n/\*\n \* topaz \(Cortex-A53/A73, ARMv8\.0\): emulate one LSE', s, re.M)
    e = re.search(r'^\s*COPYIO_RECOVER_TABLE_SYM\s+copyio_recover_table_end\s*$', s, re.M)
    if not i or not e:
        sys.exit(f'extract: no SWEET_LSE block or table end in {ASM}')
    open(os.path.join(out, 'asm_frag.inc'), 'w', encoding='latin-1').write(s[min(i.start(), e.start()):])
    print(f'extract: {len(m.group(0).splitlines())} lines of C, {len(s[min(i.start(), e.start()):].splitlines())} lines of asm, table end {"before" if e.start() < i.start() else "after"} the LSE code')


if __name__ == '__main__':
    main(sys.argv)
