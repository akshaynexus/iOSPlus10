#!/usr/bin/env python3
"""awdl-patch-refresh.py TREE: write the new files of patches/laurel/xnu/2932-laurel-awdl-radio.patch again from a patched tree, and count every hunk again.
   Dev tool, as crad-patch.sh: change LaurelWifiAwdlRadio*.{h,inc} and bsd/dev/laurel_awdl_ctl.c in TREE (out/laurel-kernel/xnu-src/xnu-8796.141.3 after AUDIT=1), run this,
   then AUDIT=1 and STAGE=tree must apply it on both kernels. Hand edits of the hunks on existing files stay as they are; only their @@ counts change. Works on macOS and Linux."""
import os
import re
import sys

PATCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../patches/laurel/xnu/2932-laurel-awdl-radio.patch')


def main():
    tree = sys.argv[1]
    parts = re.split(r'(?m)^(?=diff --git )', open(PATCH).read())
    out = [parts[0]]
    for sec in parts[1:]:
        path = re.match(r'diff --git a/(\S+) ', sec).group(1)
        head, body = sec.split('@@', 1) if '@@' in sec else (sec, '')
        if 'new file mode' in head:
            with open(os.path.join(tree, path)) as f:
                text = f.read()
            lines = text.split('\n')
            if lines[-1] == '':
                lines.pop()
            out.append(head + f'@@ -0,0 +1,{len(lines)} @@\n' + ''.join('+' + x + '\n' for x in lines))
            continue
        hunks = re.split(r'(?m)^(?=@@ )', sec)
        new = [hunks[0]]
        for h in hunks[1:]:
            first, rest = h.split('\n', 1)
            m = re.match(r'@@ -(\d+),\d+ \+(\d+),\d+ @@(.*)', first)
            ls = rest.split('\n')
            if ls and ls[-1] == '':
                ls.pop()
            old = sum(1 for x in ls if x[:1] in (' ', '-'))
            add = sum(1 for x in ls if x[:1] in (' ', '+'))
            new.append(f'@@ -{m.group(1)},{old} +{m.group(2)},{add} @@{m.group(3)}\n' + ''.join(x + '\n' for x in ls))
        out.append(''.join(new))
    with open(PATCH, 'w') as f:
        f.write(''.join(out))
    print('awdl-patch-refresh: 2932 written')


if __name__ == '__main__':
    main()
