#!/usr/bin/env python3
"""Raise the jetsam memory limit of WidgetKit extensions (docs/metal-widgets-2026-10-27.md).

    jetsam_widgets.py [--mb N] PLIST...                 patch com.apple.jetsamproperties.<model>.plist files in place
    jetsam_widgets.py --daemon NAME [--mb N] PLIST...   raise one daemon's limits (Version4 > Daemon > Override > NAME)
    jetsam_widgets.py --extensions N [--posters M] PLIST...   a floor of N MiB for every extension point, M for posters

Daemons (2026-10-27, t26): com.apple.lsd has ActiveSoftMemoryLimit 16 / InactiveHardMemoryLimit 12 (D22). On the
first boot of a fresh root lsd rebuilds the LaunchServices database, crosses 16 MiB and is jetsam-killed (reason
namespace 1 code 7 = per-process limit) again and again, so no app opens. launchd applies daemon limits at spawn
from this file (read at boot): a change needs a reboot. --daemon sets every *MemoryLimit key of NAME to N (default
64) when lower; never lowers.

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



def patch_daemon(path, name, mb):
    """Raise the memory limits of one daemon in place. Returns a short report line."""
    st = os.stat(path)
    with open(path, 'rb') as fh:
        data = plistlib.load(fh)
    try:
        ent = data['Version4']['Daemon']['Override'][name]
    except (KeyError, TypeError):
        return f'{os.path.basename(path)}: no Daemon/Override/{name}, left as is'
    keys = [k for k in ent if k.endswith('MemoryLimit')] or ['ActiveSoftMemoryLimit', 'InactiveHardMemoryLimit']
    old = {k: ent.get(k) for k in keys}
    changed = False
    for k in keys:
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
    return f'{os.path.basename(path)}: {name} {old} -> {mb} MiB' if changed else f'{os.path.basename(path)}: {name} already >= {mb} MiB'


def patch_extensions(path, floor, poster_mb):
    """Metal in every extension (docs/laurel_sprout/metal.md 6.3): raise each *MemoryLimit of Version4 > Extension > Override below
    FLOOR MiB to FLOOR, those of com.apple.posterkit.provider to POSTER_MB. -1 (no limit) stays; never lowers. The device costs
    15-20 MiB; a poster that has none aborts (AegirPoster), and its 15 MiB inactive hard limit kills one that has it."""
    st = os.stat(path)
    with open(path, 'rb') as fh:
        data = plistlib.load(fh)
    over = data.get('Version4', {}).get('Extension', {}).get('Override', {})
    raised = 0
    for point, ent in over.items():
        want = poster_mb if point == 'com.apple.posterkit.provider' else floor
        for k, v in list(ent.items()):
            if k.endswith('MemoryLimit') and isinstance(v, int) and 0 <= v < want:
                ent[k] = want
                raised += 1
    if raised:
        with open(path, 'wb') as fh:
            plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
        try:
            os.chown(path, st.st_uid, st.st_gid)
        except PermissionError:
            pass
        os.chmod(path, st.st_mode & 0o7777)
    return f'{os.path.basename(path)}: {raised} extension limits raised (floor {floor} MiB, posters {poster_mb} MiB)'


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
    ap.add_argument('--daemon', default='')
    ap.add_argument('--extensions', type=int, default=0, help='floor in MiB for every extension point')
    ap.add_argument('--posters', type=int, default=128, help='with --extensions: MiB for com.apple.posterkit.provider')
    ap.add_argument('plist', nargs='+')
    a = ap.parse_args()
    if a.mb <= 0:
        sys.exit('jetsam_widgets: --mb must be > 0')
    for p in a.plist:
        if a.extensions:
            print(patch_extensions(p, a.extensions, a.posters))
        else:
            print(patch_daemon(p, a.daemon, a.mb) if a.daemon else patch(p, a.mb))


if __name__ == '__main__':
    main()
