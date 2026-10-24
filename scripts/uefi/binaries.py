#!/usr/bin/env python3
"""Build Mu-Silicium Binaries/negroni from our unpacked uefi.img (same idea as
external/slop/uefi/negroni/mkbinaries.py, which reads UEFIExtract output instead).

    mu-binaries.py REF_R0Q MODULES PATCHED OUT

REF_R0Q  Device-Binaries/r0q (INF templates, matched by FILE_GUID)
MODULES  `op10tool uefi-unpack` output (<GUID>/pe32.efi, depex.bin, ...)
PATCHED  scripts/uefi/patch-dxe.sh output (<name>.efi, used where an INF names <name>.patched.efi)
OUT      Binaries/negroni

Files without a FILE_GUID match (r0q-only drivers) are listed and skipped. Raw files whose UI name
has a dot (panel XMLs, configs) go to OUT/RawFiles/<name>.
"""
import re, shutil, sys
from pathlib import Path

ref, mods, patched, out = map(Path, sys.argv[1:5])
have = {d.name.upper(): d for d in mods.iterdir() if d.is_dir()}
SECTION = {'PE32': ('pe32.efi',), 'TE': ('te.efi', 'pe32.efi'), 'DXE_DEPEX': ('depex.bin',),
           'PEI_DEPEX': ('depex.bin',), 'RAW': ('raw.bin', 'file.bin'), 'UI': ()}

if out.exists():
    shutil.rmtree(out)
missing, problems, done = [], [], 0
for inf in sorted(ref.rglob('*.inf')):
    text = inf.read_text()
    m = re.search(r'FILE_GUID\s*=\s*(\S+)', text)
    if not m:
        continue
    rel = inf.relative_to(ref)
    d = have.get(m.group(1).upper())
    if d is None:
        missing.append(str(rel)); continue
    dst = out / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(text)
    for kind, fname in re.findall(r'^\s*(\w+)\|([^|]+)\|', text, re.M):
        name = Path(fname).name
        data = None
        if name.endswith('.patched.efi'):
            pf = patched / name.replace('.patched.efi', '.efi')
            if pf.exists():
                data = pf.read_bytes()
            else:
                problems.append(f'{rel}: no ported patch for {name}')
        else:
            for cand in SECTION.get(kind, ()):
                if (d / cand).exists():
                    data = (d / cand).read_bytes(); break
            if kind == 'UI' and (d / 'name.txt').exists():
                data = (d / 'name.txt').read_text().strip().encode('utf-16le') + b'\0\0'
        if data is None:
            problems.append(f'{rel}: no {kind} section for {name}'); continue
        (dst.parent / name).write_bytes(data)
    done += 1

raw = out / 'RawFiles'
raw.mkdir(parents=True, exist_ok=True)
nraw = 0
for d in have.values():
    nf = d / 'name.txt'
    if not nf.exists():
        continue
    nm = nf.read_text().strip()
    if '.' in nm:
        for cand in ('raw.bin', 'file.bin'):
            if (d / cand).exists():
                (raw / nm).write_bytes((d / cand).read_bytes()); nraw += 1; break

print(f'{done} drivers, {nraw} raw files -> {out}')
print(f'r0q-only (skipped): {len(missing)}')
for x in missing: print('  ', x)
if problems:
    print('PROBLEMS:')
    for x in problems: print('  ', x)
    sys.exit(1)
