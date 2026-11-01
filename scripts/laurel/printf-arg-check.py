#!/usr/bin/env python3
"""Fail if a kernel printf in the applied tree has more values than os_log's 256-byte buffer holds.
   scripts/laurel/printf-arg-check.py XNU_TREE
Each value costs 2 + 8 bytes in the buffer (log_encode.c), so about 24 values is the limit: over it, printf panics with
log_encode.c:121 'log_fits_cmd' (phone 2026-11-01). A limit of 22 keeps a margin."""
import glob
import os
import re
import sys

LIMIT = 22
CALL = re.compile(r'\b(printf|IOLog|kprintf|LBT_SAY)\s*\(')
SPEC = re.compile(r'%(?!%)[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:ll|l|z|hh|h|q|t|j)?[a-zA-Z]')
tree = sys.argv[1]
bad = 0
for d in ('bsd/dev', 'iokit/Kernel/arm', 'iokit/Kernel/arm/hid', 'osfmk/arm64', 'pexpert/arm'):
    for path in glob.glob(f'{tree}/{d}/*'):
        if not path.endswith(('.c', '.cpp', '.h')) or not os.path.isfile(path):
            continue
        s = open(path, errors='replace').read()
        for m in CALL.finditer(s):
            i, depth, quoted = m.end(), 1, False
            while i < len(s) and depth:
                c = s[i]
                if quoted:
                    if c == '\\':
                        i += 1
                    elif c == '"':
                        quoted = False
                elif c == '"':
                    quoted = True
                elif c == '(':
                    depth += 1
                elif c == ')':
                    depth -= 1
                i += 1
            fmt = ''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', s[m.end():i - 1]))
            n = len(SPEC.findall(fmt))
            if n > LIMIT:
                line = s.count('\n', 0, m.start()) + 1
                print(f'printf-arg-check: {os.path.relpath(path, tree)}:{line}: {n} values, limit {LIMIT}: {fmt[:50]}')
                bad += 1
if bad:
    sys.exit(1)
print(f'printf-arg-check: OK (limit {LIMIT} values)')
