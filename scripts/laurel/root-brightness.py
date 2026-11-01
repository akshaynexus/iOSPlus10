#!/usr/bin/env python3
"""Mi A3 root: auto-brightness off (no ambient light sensor for iOS). Called by scripts/laurel/root.sh.

Why: the Mi A3's light sensor (Sensortek stk3x3x, external/laurel-device-los proprietary-files.txt
nicobar_qrd_stk3x3x_0.json) sits on the ADSP sensor hub (sensors.qti / SEE over QMI); this port runs no sensor
hub, so iOS has no ALS service. [V 20H392 strings, Preferences + backboardd] the Auto-Brightness switch is the
key BKEnableALS in the com.apple.backboardd domain (shown when MobileGestalt answers ambient-light-sensor).
With it on and no sensor, CoreBrightness has no lux to follow; off is the honest state and keeps the slider
the only source of the level (kernel 2201: AppleARMBacklight brightness -> DBV).
Where: com.apple.backboardd of mobile (501) and root. Existing keys stay. BRIGHTNESS=0 (env of root.sh) skips.
"""
import os
import plistlib
import sys

KEY = 'BKEnableALS'
USERS = (('private/var/mobile', 501), ('private/var/root', 0))


def set_key(path, uid, value):
    data = {}
    if os.path.exists(path):
        with open(path, 'rb') as fh:
            data = plistlib.load(fh)
    old = data.get(KEY)
    data[KEY] = value
    d, missing = os.path.dirname(path), []
    while not os.path.isdir(d):
        missing.append(d)
        d = os.path.dirname(d)
    for d in reversed(missing):         # new directories belong to the user, as iOS makes them
        os.mkdir(d, 0o755)
        os.chown(d, uid, uid)
    with open(path, 'wb') as fh:
        plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
    os.chown(path, uid, uid)
    os.chmod(path, 0o600)
    return old


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit('usage: root-brightness.py <mounted root>')
    root = sys.argv[1]
    if os.environ.get('BRIGHTNESS', '1') == '0':
        print('brightness: off: BRIGHTNESS=0 (iOS keeps its Auto-Brightness default)')
        return
    for home, uid in USERS:
        if not os.path.isdir(os.path.join(root, home)):
            print('brightness: no %s in the root: skipped' % home)
            continue
        path = os.path.join(root, home, 'Library/Preferences/com.apple.backboardd.plist')
        old = set_key(path, uid, False)
        print('brightness: /%s/Library/Preferences/com.apple.backboardd.plist %s = false (no ambient light sensor)%s' %
              (home, KEY, '' if old is None else ' (was %s)' % old))


if __name__ == '__main__':
    main()
