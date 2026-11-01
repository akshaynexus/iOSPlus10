#!/usr/bin/env python3
"""Replace the new-file hunks of a `diff -ruN` patch with the current content of the files.

    scripts/laurel/patch-refresh-new.py PATCH TREE FILE...
    e.g. scripts/laurel/patch-refresh-new.py patches/laurel/xnu/2600-laurel-bluetooth-wcn3990.patch \
             out/laurel-kernel/xnu-src/xnu-8796.141.3 bsd/dev/laurel_bt_clk.c bsd/dev/laurel_bt_geni.h

Only files that the patch makes new (--- a/... 1970-01-01) are replaced; the hunks of changed files (conf lines)
and the description paragraph stay as they are. A FILE that is not a new file of the patch stops the script.
"""
import re
import sys


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    patch, tree, files = sys.argv[1], sys.argv[2], sys.argv[3:]
    text = open(patch).read()
    parts = re.split(r'(?m)^(?=diff -ruN )', text)
    done = set()
    for i, part in enumerate(parts):
        m = re.match(r'diff -ruN a/(\S+) b/\S+\n', part)
        if not m or m.group(1) not in files:
            continue
        head = part.split('\n')[:3]
        if not (head[1].startswith('--- ') and '1970-01-01' in head[1] and head[2].startswith('+++ ')):
            sys.exit(f'patch-refresh-new: {m.group(1)} is not a new file in {patch}')
        body = open(f'{tree}/{m.group(1)}').read()
        if not body.endswith('\n'):
            sys.exit(f'patch-refresh-new: {m.group(1)} has no newline at the end')
        lines = body[:-1].split('\n')
        parts[i] = '\n'.join(head) + f'\n@@ -0,0 +1,{len(lines)} @@\n' + ''.join(f'+{l}\n' for l in lines)
        done.add(m.group(1))
    missing = set(files) - done
    if missing:
        sys.exit(f'patch-refresh-new: not in {patch}: {" ".join(sorted(missing))}')
    open(patch, 'w').write(''.join(parts))
    for f in files:
        print(f'patch-refresh-new: {f}')


if __name__ == '__main__':
    main()
