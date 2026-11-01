#!/usr/bin/env python3
"""Copy every Mach-O file of a mounted volume to another tree, keeping the path. No Apple file is executed.
Usage: python3 -I macho-copy.py SRC DST. Writes one line per file on stdout: magic, size, path."""
import os
import shutil
import stat
import struct
import sys

MAGICS = {0xfeedfacf, 0xcefaedfe, 0xcafebabe, 0xbebafeca, 0xfeedface}
SKIP = ('System/Library/Caches/com.apple.dyld',)


def main():
    src, dst = sys.argv[1:3]
    seen, errors = 0, 0
    for root, dirs, names in os.walk(src):
        rel = os.path.relpath(root, src)
        if rel.startswith(SKIP):
            dirs[:] = []
            continue
        for name in names:
            path = os.path.join(root, name)
            try:
                info = os.lstat(path)
                if not stat.S_ISREG(info.st_mode) or info.st_size < 32:
                    continue
                with open(path, 'rb') as handle:
                    head = handle.read(4)
                if struct.unpack('<I', head)[0] not in MAGICS:
                    continue
                out = os.path.normpath(os.path.join(dst, rel, name))
                os.makedirs(os.path.dirname(out), exist_ok=True)
                if not os.path.exists(out) or os.path.getsize(out) != info.st_size:
                    shutil.copyfile(path, out)
                print(f'{head.hex()} {info.st_size} {os.path.relpath(out, dst)}')
                seen += 1
            except OSError as error:
                errors += 1
                print(f'error {error}', file=sys.stderr)
    print(f'{seen} Mach-O files, {errors} read errors', file=sys.stderr)


if __name__ == '__main__':
    main()
