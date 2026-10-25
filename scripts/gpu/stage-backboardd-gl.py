#!/usr/bin/env python3
"""Stage a copy of backboardd that loads negronigl.dylib (the EAGL shim) at start.

Port of ios-spes tools/stage-spes-eagl.py (the HackiOS EAGL bridge load on the Redmi Note 11):
an LC_LOAD_WEAK_DYLIB for /usr/lib/negronigl.dylib is written into the zero padding after the
load commands of the thin arm64 Mach-O, then the copy is signed ad hoc with the original
entitlements. launchd drops DYLD_INSERT_LIBRARIES for com.apple.* jobs on this root, so the load
command is the only user-space way in; weak = a root without the dylib still boots. Never installs
anything: scripts/gpu/phone-gl.sh backboardd pushes the copy.

    scripts/gpu/stage-backboardd-gl.py SOURCE_BACKBOARDD OUT_DIR
OUT_DIR gets backboardd (patched), backboardd.original, entitlements.plist and manifest.json.
Refuses when SOURCE already loads the dylib, is not thin arm64, or has no zero padding.
"""
import argparse
import hashlib
import json
import plistlib
import shutil
import struct
import subprocess
import sys
from pathlib import Path

LIB = '/usr/lib/negronigl.dylib'
LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_SEGMENT_64 = 0xc, 0x80000018, 0x19


def add_dependency(data, lib=LIB):
    b = bytearray(data)
    if len(b) < 32 or struct.unpack_from('<II', b) != (0xfeedfacf, 0x100000c):
        raise ValueError('expected a thin arm64 Mach-O')
    n, size = struct.unpack_from('<II', b, 16)
    end = 32 + size
    if end > len(b):
        raise ValueError('truncated load commands')
    pos, first = 32, len(b)
    for _ in range(n):
        if pos + 8 > end:
            raise ValueError('truncated command')
        cmd, length = struct.unpack_from('<II', b, pos)
        if length < 8 or length % 8 or pos + length > end:
            raise ValueError('invalid command size')
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            off = struct.unpack_from('<I', b, pos + 8)[0]
            if off < 24 or off >= length:
                raise ValueError('invalid dylib name offset')
            if b[pos + off:pos + length].split(b'\0')[0] == lib.encode():
                raise ValueError('%s is already a dependency' % lib)
        if cmd == LC_SEGMENT_64:
            ns = struct.unpack_from('<I', b, pos + 64)[0]
            if 72 + ns * 80 > length:
                raise ValueError('invalid section count')
            for j in range(ns):
                offset = struct.unpack_from('<I', b, pos + 72 + j * 80 + 48)[0]
                if offset:
                    first = min(first, offset)
        pos += length
    if pos != end:
        raise ValueError('command count mismatch')
    length = (24 + len(lib) + 1 + 7) & ~7
    if end + length > first or end + length > len(b) or any(b[end:end + length]):
        raise ValueError('no zero header padding; refusing to move existing data')
    command = struct.pack('<6I', LC_LOAD_WEAK_DYLIB, length, 24, 0, 0, 0) + lib.encode() + b'\0'
    b[end:end + length] = command.ljust(length, b'\0')
    struct.pack_into('<II', b, 16, n + 1, size + length)
    return bytes(b)


def sign(path, entitlements):
    if shutil.which('codesign'):
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(path)], check=True)
        subprocess.run(['codesign', '--verify', str(path)], check=True)
        return 'codesign'
    if shutil.which('ldid'):
        subprocess.run(['ldid', '-S' + str(entitlements), str(path)], check=True)
        return 'ldid'
    raise SystemExit('neither codesign nor ldid found')


def read_entitlements(path):
    if shutil.which('codesign'):
        return subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], check=True, capture_output=True).stdout
    return subprocess.run(['ldid', '-e', str(path)], check=True, capture_output=True).stdout


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('source', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--lib', default=LIB)
    a = p.parse_args()
    if a.output.exists() and any(a.output.iterdir()):
        p.error('%s exists and is not empty; use a fresh staging directory' % a.output)
    original = a.source.read_bytes()
    changed = add_dependency(original, a.lib)
    ent = read_entitlements(a.source)
    plistlib.loads(ent)
    a.output.mkdir(parents=True, exist_ok=True)
    (a.output / 'backboardd.original').write_bytes(original)
    dst = a.output / 'backboardd'
    dst.write_bytes(changed)
    dst.chmod(0o755)
    e = a.output / 'entitlements.plist'
    e.write_bytes(ent)
    tool = sign(dst, e)
    if tool == 'codesign':
        got = read_entitlements(dst)
        if plistlib.loads(got) != plistlib.loads(ent):
            raise SystemExit('entitlements changed by signing')
    manifest = {
        'original_sha256': hashlib.sha256(original).hexdigest(),
        'patched_sha256': hashlib.sha256(dst.read_bytes()).hexdigest(),
        'dependency': a.lib, 'weak': True, 'signed_with': tool, 'installed': False,
    }
    (a.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
