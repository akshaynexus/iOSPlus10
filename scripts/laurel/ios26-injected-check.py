#!/usr/bin/env python3
"""ios26-injected-check.py BIN...: can a binary of ours run on the lowered iOS 26.5.2 23F84 userland? Host check, read-only. docs/laurel_sprout/ios26-airdrop.md.
   ios26-injected-check.py --self-test     the parts with no Apple file, on made-up Mach-O bytes.

Each line of the result is a fact of the file, each failure ends with exit 1:
  1. thin Mach-O, CPU_TYPE_ARM64, subtype ALL: plain arm64, not arm64e (lowered root files are ARM64_ALL, docs/laurel_sprout/ios26-userland.md section 7 item 3);
  2. no instruction newer than ARMv8.0 (scripts/laurel/armv80-check.py);
  3. every LC_LOAD_DYLIB is an image of the 23F84 cache or a file of the donor root;
  4. every imported symbol is a symbol of the cache (ipsw dyld symaddr); a wrong cache (UUID in the header) stops the check;
  5. a code signature with a CodeDirectory, its page size and cdhash: the trust list of the root needs this hash, and a rebuilt binary has a new one.
Needs: out/bin/ipsw, llvm-nm, the tree of scripts/ios26/sysos-tree.sh. Works on macOS and Linux.
"""
import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
TREE = os.path.expanduser('~/op10-apple/ios26/23F84-n104ap/tree')
DSC = TREE + '/cache/dyld_shared_cache_arm64e'
# The cache of 23F84 N104AP (header uuid at 0x58, read here on 2026-11-02): a check against another cache says nothing about this target
CACHE_UUID = '6ef96c18823433e0a1fae8aac6342568'
CPU_ARM64 = 0x0100000c
LC_LOAD_DYLIB = 0xc
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001f
LC_CODE_SIGNATURE = 0x1d


def parse(data):
    magic, cpu, sub = struct.unpack('<III', data[:12])
    if magic != 0xfeedfacf:
        raise ValueError('not a thin 64-bit Mach-O')
    if cpu != CPU_ARM64:
        raise ValueError(f'cpu type {cpu:#x}')
    if sub & 0xff != 0:
        raise ValueError(f'cpu subtype {sub & 0xff}: not ARM64_ALL (arm64e is 2)')
    ncmds = struct.unpack('<I', data[16:20])[0]
    off = 32
    dylibs, cs = [], None
    for _ in range(ncmds):
        cmd, size = struct.unpack('<II', data[off:off + 8])
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            name = struct.unpack('<I', data[off + 8:off + 12])[0]
            dylibs.append(data[off + name:off + size].split(b'\0')[0].decode())
        elif cmd == LC_CODE_SIGNATURE:
            cs = struct.unpack('<II', data[off + 8:off + 16])
        off += size
    return dylibs, cs


def code_directory(data, cs):
    """(page shift, hash name, cdhash) of the best CodeDirectory."""
    base, _ = cs
    magic, _, count = struct.unpack('>III', data[base:base + 12])
    if magic != 0xfade0cc0:
        raise ValueError('no SuperBlob')
    best = None
    for i in range(count):
        _, off = struct.unpack('>II', data[base + 12 + i * 8:base + 20 + i * 8])
        m, length = struct.unpack('>II', data[base + off:base + off + 8])
        if m != 0xfade0c02:
            continue
        blob = data[base + off:base + off + length]
        hash_type, page = blob[37], blob[39]
        if best is None or hash_type > best[0]:
            best = (hash_type, page, blob)
    if best is None:
        raise ValueError('no CodeDirectory')
    hash_type, page, blob = best
    name = {1: 'sha1', 2: 'sha256', 3: 'sha256-truncated', 4: 'sha384'}.get(hash_type, str(hash_type))
    h = hashlib.sha1(blob) if hash_type == 1 else hashlib.sha384(blob) if hash_type == 4 else hashlib.sha256(blob)
    return page, name, h.hexdigest()[:40]


def check_cache():
    with open(DSC, 'rb') as f:
        h = f.read(0x68)
    if h[:7] != b'dyld_v1' or h[0x58:0x68].hex() != CACHE_UUID:
        raise SystemExit(f'ios26-injected-check: {DSC}: uuid {h[0x58:0x68].hex()}, not 23F84 N104AP: refused')


def images():
    """the dylibs of the cache (`dyld image` lists only apps): lines "  12: (5026.5.4)  /path"."""
    r = subprocess.run([REPO + '/out/bin/ipsw', 'dyld', 'info', DSC, '--dylibs'], capture_output=True, text=True, check=True)
    return {x.split()[-1] for x in r.stdout.splitlines() if x.strip().endswith(tuple('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789')) and '/' in x}


def cache_exports(names):
    """which of these names the cache has as a symbol."""
    with tempfile.TemporaryDirectory(dir=os.path.join(REPO, 'out')) as t:
        q = os.path.join(t, 'q.json')
        o = os.path.join(t, 'o.json')
        with open(q, 'w') as f:
            json.dump([{'pattern': '^' + n.replace('$', r'\$') + '$'} for n in names], f)
        r = subprocess.run([REPO + '/out/bin/ipsw', 'dyld', 'symaddr', DSC, '--in', q, '--output', o], capture_output=True, text=True)
        if not os.path.exists(o):
            raise RuntimeError('ipsw symaddr: ' + r.stderr[-300:])
        with open(o) as f:
            return {s.get('name') or s.get('pattern') for s in (json.load(f) or [])}


def check(path):
    bad = []
    with open(path, 'rb') as f:
        data = f.read()
    dylibs, cs = parse(data)
    print(f'{path}: thin arm64 subtype ALL, {len(data)} bytes')
    r = subprocess.run([sys.executable, '-I', HERE + '/armv80-check.py', path], capture_output=True, text=True)
    print('  ' + (r.stdout.strip().splitlines() or ['(no output)'])[-1])
    if r.returncode != 0:
        bad.append('instructions newer than ARMv8.0')
    have = images()
    miss = [d for d in dylibs if d not in have and not any(os.path.exists(os.path.join(TREE, 'root', v, d.lstrip('/'))) for v in ('os', 'sys'))]
    print(f'  {len(dylibs)} libraries, {len(miss)} not in 23F84: {miss}')
    bad += [f'library {m}' for m in miss]
    syms = subprocess.run(['llvm-nm', '-u', '--just-symbol-name', path], capture_output=True, text=True, check=True).stdout.split()
    syms = [s for s in syms if s != 'dyld_stub_binder']
    found = cache_exports(syms)
    miss = [s for s in syms if s not in found]
    print(f'  {len(syms)} imports, {len(miss)} not in the 23F84 cache: {miss[:12]}')
    bad += [f'symbol {m}' for m in miss]
    if cs is None:
        bad.append('no code signature')
    else:
        page, name, cd = code_directory(data, cs)
        print(f'  signature: CodeDirectory {name}, page size {1 << page}, cdhash {cd}')
    return bad


def self_test():
    head = struct.pack('<IIIIIIII', 0xfeedfacf, CPU_ARM64, 0, 2, 0, 0, 0, 0)
    assert parse(head) == ([], None)
    for bad in (struct.pack('<IIIIIIII', 0xfeedfacf, CPU_ARM64, 2, 2, 0, 0, 0, 0), struct.pack('<IIIIIIII', 0xfeedfacf, 7, 0, 2, 0, 0, 0, 0), b'\xca\xfe\xba\xbe' + head):
        try:
            parse(bad)
        except ValueError:
            continue
        raise AssertionError('an arm64e, foreign or fat file passed')
    print('ios26-injected-check: self-test passed (host only)')


def main():
    if sys.argv[1:] == ['--self-test']:
        return self_test()
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    check_cache()
    bad = []
    for p in sys.argv[1:]:
        bad += [f'{p}: {b}' for b in check(p)]
    for b in bad:
        print('ios26-injected-check: ' + b, file=sys.stderr)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
