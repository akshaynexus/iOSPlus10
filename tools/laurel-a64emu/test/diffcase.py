#!/usr/bin/env python3
"""Show one case in both modes, only what differs: diffcase.py HARNESS CLASS SEED CASE"""
import subprocess, sys
H, cls, seed, case = sys.argv[1:5]
def run(cpu, mode):
    return subprocess.run(['qemu-aarch64', '-cpu', cpu, H, 'dump', mode, cls, case, seed], capture_output=True, text=True, timeout=120).stdout
a, b = run('neoverse-v1', 'native'), run('cortex-a53', 'emu')
def parse(t):
    out = {}
    head = t.splitlines()[0] if t else ''
    part = None
    for tok in t.replace('\n', ' \n ').split():
        if tok in ('in', 'out'):
            part = tok
        elif '=' in tok and part:
            k, v = tok.split('=')
            out[part + ':' + k] = v
        elif tok == 'mark':
            part = 'mark'
    return head, out, t
ha, oa, ta = parse(a)
hb, ob, tb = parse(b)
print(ha)
print('word disassembly:', subprocess.run(['llvm-mc', '--disassemble', '--triple=aarch64', '--mattr=+v8.6a,+fullfp16,+sha3,+fp16fml,+complxnum,+dotprod,+rcpc-immo,+lse'], input=' '.join('0x%02x,' % ((int(ha.split()[1], 16) >> (8 * i)) & 255) for i in range(4)).rstrip(','), capture_output=True, text=True).stdout.strip().splitlines()[-1:])
for k in sorted(set(oa) | set(ob), key=lambda s: (s.split(':')[0], len(s), s)):
    if k.startswith('out:') and oa.get(k) != ob.get(k):
        print(k, 'native', oa.get(k), 'emu', ob.get(k), ' in:', oa.get('in:' + k[4:]))
for t in (ta, tb):
    for ln in t.splitlines():
        if ln.startswith('mark'):
            print(ln)
print('in fpcr', oa.get('in:fpcr'))
w=int(ha.split()[1],16)
for r in sorted({w&31,(w>>5)&31,(w>>16)&31,(w>>16)&15,(w>>10)&31}):
    print(f' in x{r}=', oa.get(f'in:x{r}'), f'v{r}=', oa.get(f'in:v{r}'))
