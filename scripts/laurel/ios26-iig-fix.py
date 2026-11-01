#!/usr/bin/env python3
"""Fix our copy of the xnu-linux-toolchain iig for xnu-12377 .iig files (external/ stays unchanged).
1. A parameter like `const char reason[kMax]`: the name is before the [ (the tool took kMax).
2. iokit/Tests/TestServices has .iig files outside DriverKit: the generated .cpp includes its header by a quote path."""
import sys

p = sys.argv[1]
t = open(p).read()
for a, b in [
    ("""        part = part.strip()
        if not part or part == 'void':
            continue
        ident = re.findall""", """        part = re.sub(r'\\[[^\\]]*\\]', '', part.strip())
        if not part or part == 'void':
            continue
        ident = re.findall"""),
    ("""           f'#include <DriverKit/{stem}.h>\\n',
""", """           f'#include "{stem}.h"\\n',
"""),
    ("""               else f'<DriverKit/{stem}.h>')
""", """               else f'"{stem}.h"')
"""),
]:
    if a not in t:
        raise SystemExit("ios26-iig-fix: iig changed: " + a[:60])
    t = t.replace(a, b)
open(p, "w").write(t)
