#!/usr/bin/env python3
"""Mi A3 root: status bar layout for the native 720x1560 @2x screen (360x780 points). Called by scripts/laurel/root.sh.

Why (docs/laurel_sprout/rtc-statusbar.md "Status bar", read from the 20H392 iPhone10,3 UIKitCore with
scripts/debug/dsc-annotate.py):
  _UIStatusBarGetVisualProviderClassForScreen asks _UIStatusBarVisualProvider_iOS -> _Phone (idiom phone) ->
  _Split (an exclusion area at y <= 0) -> one of Split1125/1080/1080_Wide/1170/1170_Wide/1242/828/1284/1284_Wide,
  matched on +nativeDisplayWidth == UIScreen _nativeDisplayBounds.width (pixels) and +notchSize == the
  exclusion area. 720 px matches none; with the SpringBoard/Jindo feature on, _Split then returns nil and UIKit
  logs "No status bar visual provider for screen ... Please see rdar://45025538." and uses
  _UIStatusBarVisualProvider_Fallback: the red rdar:45025538 bar.
  UIKit has an override for embedded screens: NSUserDefaults suite "com.apple.UIKit", key
  UIStatusBarVisualProviderClassName (a class name; UIKit logs "WARNING: Using overridden status bar visual
  provider class: %@"). _UIStatusBarVisualProvider_FixedSplit is the generic split provider (Apple's own
  choice for an unmatched notched screen when Jindo is off): it takes its width from UIScreen nativeBounds
  and its notch from the screen's exclusion area, so it fits any width. This script sets that default.

Where: the com.apple.UIKit domain and the global domain (.GlobalPreferences: every process, also sandboxed
apps, reads it; an NSUserDefaults suite searches the global domain after the suite) of mobile (501) and root.
Existing keys stay. STATUSBAR=0 (env of root.sh) skips; STATUSBAR_PROVIDER=<class> picks another class.
The kernel canvas (2103, 720x1560 @2x) and the touch map (2200) do not change.
"""
import os
import plistlib
import sys

KEY = 'UIStatusBarVisualProviderClassName'
DEFAULT = '_UIStatusBarVisualProvider_FixedSplit'
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
        sys.exit('usage: root-statusbar.py <mounted root>')
    root = sys.argv[1]
    if os.environ.get('STATUSBAR', '1') == '0':
        print('statusbar: off: STATUSBAR=0 (UIKit keeps its own choice: red rdar:45025538 bar at 360x780 pt)')
        return
    value = os.environ.get('STATUSBAR_PROVIDER', DEFAULT)
    if not value.startswith('_UIStatusBarVisualProvider_'):
        sys.exit('statusbar: STATUSBAR_PROVIDER must be a _UIStatusBarVisualProvider_* class')
    for home, uid in USERS:
        prefs = os.path.join(root, home, 'Library/Preferences')
        if not os.path.isdir(os.path.join(root, home)):
            print('statusbar: no %s in the root: skipped' % home)
            continue
        for name in ('com.apple.UIKit.plist', '.GlobalPreferences.plist'):
            old = set_key(os.path.join(prefs, name), uid, value)
            print('statusbar: /%s/Library/Preferences/%s %s = %s%s' % (home, name, KEY, value, '' if old is None else ' (was %s)' % old))


if __name__ == '__main__':
    main()
