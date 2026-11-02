#!/usr/bin/env python3
"""The registry of AppleARMBacklight as plist, for the replay of scripts/laurel/test-ios26-bbd-emu.sh. Same numbers as patches/laurel/xnu-12377/post/9005-laurel-backlight-calibration.patch.

    ios26-backlight-props.py before|after OUT.plist       before: the kernel of boot 9. after: with 9005
"""
import plistlib, struct, sys

NITS, LEVEL_MIN, LEVEL_MAX, POINTS = 430, 4, 2047, 17     # LAUREL_BL_NITS, LAUREL_BL_MIN, Samsung s6e8fco


def table():
    low = (NITS << 16) * LEVEL_MIN // LEVEL_MAX
    return [max((NITS << 16) * i * i // ((POINTS - 1) ** 2), low) for i in range(POINTS)]


def props(after):
    p = {'backlight-control': True, 'max-nits': NITS, 'min-nits': 1, 'IODisplayParameters': {'brightness': {'min': 0, 'max': 255, 'value': 128}}, 'brightness-nits': 108}
    if after:
        t = table()
        p['backlight-marketing-table'] = struct.pack(f'<{POINTS}I', *t)
        p['backlight-calibration-parameters'] = {
            'lMaxProduct': t[-1], 'lMidProduct': t[POINTS // 2], 'lMinProduct': t[0], 'lMaxPanel': t[-1], 'lMidPanel': t[POINTS // 2], 'lMinPanel': t[0],
            'current-for-max-backlight': 0, 'current-for-mid-backlight': 0, 'hardware-max-current-limit': 0,
        }
    return p


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] not in ('before', 'after'):
        sys.exit(__doc__)
    with open(sys.argv[2], 'wb') as f:
        plistlib.dump(props(sys.argv[1] == 'after'), f)
