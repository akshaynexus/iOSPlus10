#!/usr/bin/env python3
"""Raise the jetsam memory limit of WidgetKit extensions (docs/metal-widgets-2026-10-27.md).

    jetsam_widgets.py [--mb N] PLIST...      patch com.apple.jetsamproperties.<model>.plist files in place

iOS 16 (20H392) gives every com.apple.widgetkit-extension a 30 MiB hard limit, active and inactive:
/System/Library/LaunchDaemons/com.apple.jetsamproperties.D22.plist (and .D221), Version4 > Extension > Override >
com.apple.widgetkit-extension = {ActiveHardMemoryLimit 30, InactiveHardMemoryLimit 30}. runningboardd reads the file
at its start (RunningBoard.framework RBJetsamPropertyManager, "Loaded jetsamproperties from %@") and applies the limit
to each extension it launches. Our Metal device (NegroniMetal + Turnip + the Vulkan device) adds about 15-20 MiB, so
FitnessWidget (VFX rings renderer) was killed at 30 MiB. N (default 64) is written to both keys; a limit that is
already >= N is not lowered. Idempotent. Used by root-tweaks-extra.py (root image) and
scripts/metal/phone-widget-jetsam.sh (live phone).
"""
import argparse, os, plistlib, sys

POINT = 'com.apple.widgetkit-extension'
KEYS = ('ActiveHardMemoryLimit', 'InactiveHardMemoryLimit')


def patch(path, mb):
    """Patch one plist in place. Returns a short report line."""
    st = os.stat(path)
    with open(path, 'rb') as fh:
        data = plistlib.load(fh)
    try:
        ent = data['Version4']['Extension']['Override'][POINT]
    except (KeyError, TypeError):
        return f'{os.path.basename(path)}: no Extension/Override/{POINT}, left as is'
    old = {k: ent.get(k) for k in KEYS}
    changed = False
    for k in KEYS:
        if not isinstance(ent.get(k), int) or ent[k] < mb:
            ent[k] = mb
            changed = True
    if changed:
        with open(path, 'wb') as fh:
            plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
        try:
            os.chown(path, st.st_uid, st.st_gid)
        except PermissionError:
            pass
        os.chmod(path, st.st_mode & 0o7777)
    new = {k: ent.get(k) for k in KEYS}
    return f'{os.path.basename(path)}: {POINT} {old} -> {new}' + ('' if changed else ' (unchanged)')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mb', type=int, default=64)
    ap.add_argument('plist', nargs='+')
    a = ap.parse_args()
    if a.mb <= 0:
        sys.exit('jetsam_widgets: --mb must be > 0')
    for p in a.plist:
        print(patch(p, a.mb))


if __name__ == '__main__':
    main()
