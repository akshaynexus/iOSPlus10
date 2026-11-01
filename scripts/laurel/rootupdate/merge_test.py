#!/usr/bin/env python3
"""The merge rules on plain data (scripts/laurel/root-update-test.sh runs it)."""
import os
import plistlib
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import merge  # noqa: E402

final = plistlib.dumps({'A': 1, 'B': {'x': 1}})
assert merge.merge_file('p.plist', None, final, plistlib.dumps({'A': 1, 'B': {'x': 1, 'mine': 2}, 'C': 3})) is None
out = merge.merge_file('p.plist', plistlib.dumps({'old': 1}), final, plistlib.dumps({'old': 1, 'C': 3}, fmt=plistlib.FMT_BINARY))
assert out[:6] == b'bplist' and plistlib.loads(out) == {'A': 1, 'B': {'x': 1}, 'C': 3}, out
assert merge.merge_file('p.plist', None, final, b'not a plist') == final
assert merge.merge_lines(b'a\nb\n', b'b\nc\n') == b'b\nc\na\n' and merge.merge_lines(b'a\n', b'a\n') is None
# another current set on the phone: our service goes into that one
pref = {'CurrentSet': '/Sets/IMG', 'Sets': {'IMG': {'Network': {'Service': {'USB': 1}}}}}
got = merge.merge_plist('preferences.plist', {}, pref, {'CurrentSet': '/Sets/PH', 'Sets': {'PH': {'Network': {'Service': {'WIFI': 1}}}}})
assert got['Sets'] == {'PH': {'Network': {'Service': {'WIFI': 1, 'USB': 1}}}} and got['CurrentSet'] == '/Sets/PH', got
print('ok')
