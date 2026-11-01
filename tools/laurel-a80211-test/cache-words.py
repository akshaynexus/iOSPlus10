#!/usr/bin/env python3
"""The code the 23F84 Apple80211 layouts were read from, word by word: cache-words.py CACHE CACHE_DIS. No cache on this host: says so (exit 0), and only the source checks count."""
import os
import subprocess
import sys

cache, dis = sys.argv[1], sys.argv[2]
if not os.path.exists(cache):
    print(f'cache words: skipped, no {cache}')
    sys.exit(0)
WORDS = [
    (0x25ca8d114, 'mov w1, #5528', 'SCAN_REQ size, __getScanData'),
    (0x25ca8c8d8, 'mov w25, #5452', 'SCAN_REQ scan_uuid at 0x154c'),
    (0x25ca8d7f8, 'str x8, [x26, #5520]', 'SCAN_REQ last u64 at 0x1590'),
    (0x25ca79334, 'mov w19, #2272', 'CURRENT_NETWORK size'),
    (0x25ca91054, 'strh w26, [sp, #186]', 'SCAN_RESULT elements_length +138 (sp+48), __dispatchAsyncScanEvent'),
    (0x25ca91064, 'add x0, x8, #2188', 'SCAN_RESULT scan_uuid +2188'),
    (0x25ca81ed4, 'ldrb w19, [x27, #2264]', 'SCAN_RESULT byte +2264, __addScanResultToList'),
    (0x25ca81ed8, 'ldr w23, [x27, #2268]', 'SCAN_RESULT word +2268'),
    (0x25ca81e6c, 'add x2, x27, #2256', 'SCAN_RESULT TIMESTAMP +2256'),
    (0x25ca95070, 'mov w9, #908', 'ASSOCIATE size, __performAssociation'),
    (0x25ca9f348, 'cmp w2, #32', 'link event: __dispatchLinkChangedEvent'),
    (0x25ca90a7c, 'cmp w2, #44', 'the 44 of IOS-26-Hot 0146: __dispatchObssMitInfoEvent, not the link'),
    (0x25ca79cdc, 'mov w8, #21', 'CARD_CAPABILITIES 21 bytes'),
    (0x25ca79a38, 'mov w8, #3', 'COUNTRY_CODE 3 bytes'),
]
bad = 0
for addr, want, what in WORDS:
    out = subprocess.run(['python3', '-I', dis, cache, hex(addr), '0', '1'], capture_output=True, text=True).stdout
    line = next((ln for ln in out.splitlines() if ln.startswith(hex(addr))), '')
    if want not in line:
        bad += 1
        print(f'  DIFFERS {hex(addr)}: want {want!r} ({what}), got {line!r}')
print(f'cache words: {len(WORDS) - bad} of {len(WORDS)} as read')
sys.exit(1 if bad else 0)
