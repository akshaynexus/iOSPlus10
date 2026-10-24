#!/usr/bin/env python3
"""Keep Bold Text off in a mounted iOS 16 root (run as root by scripts/ios16/root-finish.sh).

    root-tweaks-boldtext.py MOUNTED_ROOT

Bold Text on = SpringBoard crash loop on this port: UIKit styles glyph images through CoreUI ->
CoreImage, and CoreImage's OpenGL ES backend calls a NULL GL pointer (no GL driver). See
docs/boldtext-crash.md. The switch reads com.apple.Accessibility EnhancedTextLegibilityEnabled
(libAccessibility.dylib, kAXSEnhanceTextLegibilityPreference) for the mobile user.

This writes the key as false into private/var/mobile/Library/Preferences/com.apple.Accessibility.plist
(binary plist, other keys kept, 501:501, mode 0600). Running it twice gives the same file. It does
not lock or hide the Settings switch: turning Bold Text on still crashes until CoreImage has a
working backend (userland/cifix/ or the GPU driver).
"""
import os
import plistlib
import sys

MOBILE = 501
DOMAIN = "com.apple.Accessibility"
KEY = "EnhancedTextLegibilityEnabled"


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    prefs = os.path.join(sys.argv[1], "private/var/mobile/Library/Preferences")
    if not os.path.isdir(prefs):
        raise SystemExit(f"not an iOS root (missing {prefs})")
    path = os.path.join(prefs, DOMAIN + ".plist")
    data = {}
    if os.path.exists(path):
        with open(path, "rb") as fh:
            data = plistlib.load(fh)
    old = data.get(KEY)
    data[KEY] = False
    with open(path, "wb") as fh:
        plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
    os.chown(path, MOBILE, MOBILE)
    os.chmod(path, 0o600)
    print(f"{DOMAIN}: {KEY} {old!r} -> False (501:501, 0600, {len(data)} keys)")


if __name__ == "__main__":
    main()
