#!/usr/bin/env python3
"""qc-selectors.py LISTING [FUNCTION_REGEX]: Objective-C selectors a cache image sends, from a dsc-image.py lst listing.
Output: "COUNT SELECTOR" sorted by name; with FUNCTION_REGEX only functions whose name matches (mangled or not)."""
import collections
import re
import sys
sel = collections.Counter()
want = re.compile(sys.argv[2]) if len(sys.argv) > 2 else None
on = want is None
for line in open(sys.argv[1], errors="replace"):
    if line.endswith(":\n") and not line[0].isdigit() and line.strip():
        on = want is None or bool(want.search(line))
        continue
    if on:
        m = re.search(r"_objc_msgSend\$([^\s]+)", line)
        if m:
            sel[m.group(1)] += 1
for k in sorted(sel):
    print(sel[k], k)
