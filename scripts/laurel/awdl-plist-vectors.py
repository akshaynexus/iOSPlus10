#!/usr/bin/env python3
"""awdl-plist-vectors.py: the binary plists of the tests of userland/laurel/awdl/src/policy.rs, in the form cfprefsd writes. Our own made-up values, no Apple file. Works on macOS and Linux."""
import datetime
import os
import plistlib

T = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../userland/laurel/awdl/tests')
WHEN = datetime.datetime(2026, 11, 2)
for name, d in (('plist-everyone.bplist', {'DiscoverableMode': 'Everyone', 'EveryoneModeUpdateTime': WHEN}),
                ('plist-contacts-after-everyone.bplist', {'DiscoverableMode': 'Contacts Only', 'EveryoneModeUpdateTime': WHEN}),
                # more than 14 pairs and a long key first: the long length form of a dict and a string
                ('plist-long-keys.bplist', {**{f'K{i:02d}' + 'x' * 20: i for i in range(20)}, 'DiscoverableMode': 'Everyone'})):
    with open(os.path.join(T, name), 'wb') as f:
        plistlib.dump(d, f, fmt=plistlib.FMT_BINARY, sort_keys=True)
print('awdl-plist-vectors: 3 files')
