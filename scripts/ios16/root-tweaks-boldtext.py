#!/usr/bin/env python3
"""Set the known Bold Text preference off in a mounted iOS 16 root.

    root-tweaks-boldtext.py MOUNTED_ROOT

This is a rollback/default safeguard for roots built after the Bold Text crash.
It does not remove or lock the Settings switch. Do not enable Bold Text on this
port until a captured reproduction identifies and fixes the underlying fault.
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
    root = sys.argv[1]
    prefs = os.path.join(root, "private/var/mobile/Library/Preferences")
    if not os.path.isdir(prefs):
        raise SystemExit(f"not an iOS root (missing {prefs})")
    path = os.path.join(prefs, DOMAIN + ".plist")
    data = plistlib.load(open(path, "rb")) if os.path.exists(path) else {}
    data[KEY] = False
    with open(path, "wb") as fh:
        plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
    os.chown(path, MOBILE, MOBILE)
    os.chmod(path, 0o600)
    print(f"{DOMAIN}: {KEY}=false (mobile:mobile, 0600)")
    print("This resets the saved state; it does not disable the Settings control.")


if __name__ == "__main__":
    main()
