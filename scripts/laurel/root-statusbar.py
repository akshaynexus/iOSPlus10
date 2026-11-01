#!/usr/bin/env python3
"""Mi A3 root: the top bar for the native 720x1560 @2x screen (360x780 pt) with its waterdrop. Called by scripts/laurel/root.sh.

  root-statusbar.py ROOT            install (env: STATUSBAR=0 skips all; NOTCH=0 skips part 2 and gives SpringBoard back
                                    its own start program; STATUSBAR_PROVIDER=<class> picks another provider class)
  root-statusbar.py --check ROOT    read-only dump of what parts 1 and 2 left in a root (a mounted root or a copy)
  root-statusbar.py --expect        the geometry the phone should show (from the Lineage cutout and the 20H392 formulas)

Docs: docs/laurel_sprout/rtc-statusbar.md "B" (red bar, part 1) and "C" (waterdrop, part 2). [V] = read in the 20H392
iPhone10,3 shared cache with scripts/debug/statusbar-re.sh.

Part 1, status bar layout class (all processes): UIKit picks a notched layout only for 828/1080/1125/1170/1242/1284 px wide
  screens; 720 px gets nil -> the red rdar:45025538 bar [V]. UIKit's own override, NSUserDefaults suite com.apple.UIKit key
  UIStatusBarVisualProviderClassName, names _UIStatusBarVisualProvider_FixedSplit: Apple's split layout for any width, it
  reads the notch from UIScreen _exclusionArea [V]. Written to com.apple.UIKit.plist and .GlobalPreferences.plist (every
  process, also sandboxed apps, reads the global domain) of mobile (501) and root, 0600, other keys kept.
Part 2, the waterdrop as the notch (SpringBoard -> every app): SpringBoard's notch rect comes from a fixed screen-type table;
  360x780 @2 matches no entry and falls back to D22Zoomed: the iPhone X notch {70.8, 0, 178.4, 25.6} pt, centred for a
  320 pt screen [V]. out/laurel/notch/root (scripts/laurel/notch-build.sh) holds liblaurel-notch.dylib (returns the Mi A3
  waterdrop {135.2, 0, 89.6, 26.5} pt) and laurel-springboard (inserts it, execs Apple's SpringBoard; crash guard; boot-arg
  notch=0). This part installs both (root:wheel 755, after a Mach-O check) and sets ProgramArguments[0] of the launchd job
  com.apple.SpringBoard to laurel-springboard. Without the build output: a note, Apple's start program stays (part 1 alone
  still gives a working split bar with the D22Zoomed spacing).
The kernel canvas (2103) and the touch map (2200) do not change.
"""
import hashlib
import os
import plistlib
import shutil
import struct
import sys

KEY = 'UIStatusBarVisualProviderClassName'
DEFAULT = '_UIStatusBarVisualProvider_FixedSplit'
USERS = (('private/var/mobile', 501), ('private/var/root', 0))
PREFS = ('com.apple.UIKit.plist', '.GlobalPreferences.plist')
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STAGE = os.path.join(REPO, 'out/laurel/notch/root')
DYLIB = 'usr/local/lib/liblaurel-notch.dylib'
WRAP = 'usr/local/libexec/laurel-springboard'
SB = '/System/Library/CoreServices/SpringBoard.app/SpringBoard'
SB_JOB = '/System/Library/LaunchDaemons/com.apple.SpringBoard.plist'
LAUNCHD = 'System/Library/xpc/launchd.plist'

# Geometry. Waterdrop: LineageOS laurel_sprout overlay config_mainBuiltInDisplayCutout (px, origin top centre).
CUTOUT = 'M -89.6 0 C -65.1 0 -51.2 0.2 -37 31.3 C -29.3 44.1 -15.5 53 0 53 C 15.5 53 29.3 44.1 37 31.3 C 51.2 0.2 65.1 0 89.6 0 L -89.6 0 Z'
CUTOUT_SRC = 'external/laurel-device-los/overlay/frameworks/base/core/res/res/values/config.xml'
PANEL = (720, 1560)
SCALE = 2
# [V 20H392] D22Zoomed (screen type 4, 320x693 @3, native scale 3 * 375 / 320): notch 627x90 px at x 249 px;
# edge info: safe area top 38, bottom 29, home affordance 21; _Split +height 47 (FixedSplit inherits it).
D22Z_NATIVE_SCALE = 3 * 375 / 320
D22Z_NOTCH = (249 / D22Z_NATIVE_SCALE, 0.0, 627 / D22Z_NATIVE_SCALE, 90 / D22Z_NATIVE_SCALE)
SAFE_TOP, SAFE_BOTTOM, HOME_ALLOWANCE, BAR_HEIGHT = 38.0, 29.0, 21.0, 47.0
CORNER_IPHONEX = 39.0     # [I] MobileGestalt DeviceCornerRadius of iPhone10,3 (UIScreen _displayCornerRadius)
CORNER_MIA3 = 75 / SCALE  # Lineage overlay rounded_corner_radius 75px


def own(path, uid, gid=None):
    if os.geteuid() == 0:
        os.chown(path, uid, uid if gid is None else gid)


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
        own(d, uid)
    with open(path, 'wb') as fh:
        plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
    own(path, uid)
    os.chmod(path, 0o600)
    return old


def macho_check(path, filetype):
    """thin arm64 Mach-O of FILETYPE (2 = executable, 6 = dylib) with LC_CODE_SIGNATURE; returns an error or None"""
    with open(path, 'rb') as fh:
        hdr = fh.read(32)
        if len(hdr) < 32:
            return 'too short'
        magic, cpu, _sub, ftype, ncmds, sizeofcmds = struct.unpack('<IiiIII', hdr[:24])
        if magic != 0xfeedfacf or cpu != 0x0100000c:
            return 'not a thin arm64 Mach-O'
        if ftype != filetype:
            return 'Mach-O type %d, not %d' % (ftype, filetype)
        cmds, off = fh.read(sizeofcmds), 0
    found = False
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', cmds, off)
        found |= cmd == 0x1d
        off += size
    return None if found else 'no LC_CODE_SIGNATURE (ldid -S)'


def sb_job(root):
    path = os.path.join(root, LAUNCHD)
    with open(path, 'rb') as fh:
        data = plistlib.load(fh)
    return path, data, data.get('LaunchDaemons', {}).get(SB_JOB)


def write_launchd(path, data):
    st = os.stat(path)
    with open(path + '.new', 'wb') as fh:
        plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
    if os.geteuid() == 0:
        os.chown(path + '.new', st.st_uid, st.st_gid)
    os.chmod(path + '.new', st.st_mode & 0o7777)
    os.replace(path + '.new', path)


def part1(root):
    value = os.environ.get('STATUSBAR_PROVIDER', DEFAULT)
    if not value.startswith('_UIStatusBarVisualProvider_'):
        sys.exit('statusbar: STATUSBAR_PROVIDER must be a _UIStatusBarVisualProvider_* class')
    for home, uid in USERS:
        if not os.path.isdir(os.path.join(root, home)):
            print('statusbar: no %s in the root: skipped' % home)
            continue
        for name in PREFS:
            old = set_key(os.path.join(root, home, 'Library/Preferences', name), uid, value)
            print('statusbar: /%s/Library/Preferences/%s %s = %s%s' % (home, name, KEY, value, '' if old is None else ' (was %s)' % old))


def part2(root):
    path, data, job = sb_job(root)
    if job is None:
        print('statusbar: notch: off: no %s job in %s: nothing changed' % (SB_JOB, LAUNCHD))
        return
    args = job.get('ProgramArguments') or [SB]
    wrap = '/' + WRAP
    if args[0] not in (SB, wrap) or 'Program' in job:
        print('statusbar: notch: off: SpringBoard job starts %r (not Apple\'s or ours): left as it is' % (job.get('Program') or args[0]))
        return
    if os.environ.get('NOTCH', '1') == '0':
        if args[0] == wrap:
            job['ProgramArguments'] = [SB] + args[1:]
            write_launchd(path, data)
        print('statusbar: notch: off: NOTCH=0 (SpringBoard job starts %s; D22Zoomed notch spacing)' % SB)
        return
    errs = []
    for rel, ftype in ((DYLIB, 6), (WRAP, 2)):
        src = os.path.join(STAGE, rel)
        e = 'missing' if not os.path.isfile(src) else macho_check(src, ftype)
        if e:
            errs.append('%s: %s' % (rel, e))
    if not errs and SB.encode() not in open(os.path.join(STAGE, WRAP), 'rb').read():
        errs.append('%s does not name %s' % (WRAP, SB))
    if errs:
        if args[0] == wrap:                 # never leave the job on a start program we did not install now
            job['ProgramArguments'] = [SB] + args[1:]
            write_launchd(path, data)
        print('statusbar: notch: off: %s (scripts/laurel/notch-build.sh first); SpringBoard job starts %s' % ('; '.join(errs), SB))
        return
    for rel in (DYLIB, WRAP):
        dst = os.path.join(root, rel)
        d, missing = os.path.dirname(dst), []
        while not os.path.isdir(d):
            missing.append(d)
            d = os.path.dirname(d)
        for d in reversed(missing):
            os.mkdir(d, 0o755)
            own(d, 0, 0)
        shutil.copyfile(os.path.join(STAGE, rel), dst + '.new')
        own(dst + '.new', 0, 0)
        os.chmod(dst + '.new', 0o755)
        os.replace(dst + '.new', dst)
        print('statusbar: notch: /%s sha256 %s' % (rel, hashlib.sha256(open(dst, 'rb').read()).hexdigest()))
    if args[0] != wrap:
        job['ProgramArguments'] = [wrap] + args[1:]
        write_launchd(path, data)
    print('statusbar: notch: on: SpringBoard job starts %s (inserts /%s, then execs %s)' % (wrap, DYLIB, SB))


def check(root):
    """read-only dump (host check)"""
    ok = True
    print('== part 1: %s' % KEY)
    for home, _uid in USERS:
        for name in PREFS:
            p = os.path.join(root, home, 'Library/Preferences', name)
            if not os.path.exists(p):
                print('  /%s/Library/Preferences/%s: absent' % (home, name))
                ok = False
                continue
            st = os.stat(p)
            v = plistlib.load(open(p, 'rb')).get(KEY)
            print('  /%s/Library/Preferences/%s: %s = %s (uid %d, mode %o)' % (home, name, KEY, v, st.st_uid, st.st_mode & 0o7777))
            ok &= v == DEFAULT
    print('== part 2: SpringBoard job and files')
    try:
        _path, _data, job = sb_job(root)
    except FileNotFoundError:
        job = None
    if job is None:
        print('  no %s job' % SB_JOB)
        ok = False
    else:
        print('  %s ProgramArguments = %r, Program = %r, env = %r' % (SB_JOB, job.get('ProgramArguments'), job.get('Program'),
                                                                        job.get('EnvironmentVariables')))
        on = (job.get('ProgramArguments') or [''])[0] == '/' + WRAP
        print('  waterdrop dylib: %s' % ('on (job starts laurel-springboard)' if on else 'off (job starts Apple\'s SpringBoard)'))
    for rel, ftype in ((DYLIB, 6), (WRAP, 2)):
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            st = os.stat(p)
            print('  /%s: %s, uid %d gid %d mode %o, sha256 %s' % (rel, macho_check(p, ftype) or 'arm64 Mach-O, signed', st.st_uid,
                                                                  st.st_gid, st.st_mode & 0o7777, hashlib.sha256(open(p, 'rb').read()).hexdigest()))
        else:
            print('  /%s: absent' % rel)
    print('check: %s' % ('part 1 ok' if ok else 'part 1 NOT complete'))
    return ok


def cutout_bbox(path_text):
    nums = [float(t) for t in path_text.replace(',', ' ').split() if t not in ('M', 'C', 'L', 'Z')]
    xs, ys = nums[0::2], nums[1::2]
    return min(xs), max(xs), min(ys), max(ys)


def expect():
    src = os.path.join(REPO, CUTOUT_SRC)    # make references; else the built-in copy
    text, where = CUTOUT, 'built-in copy'
    if os.path.exists(src):
        import re
        m = re.search(r'name="config_mainBuiltInDisplayCutout">\s*(.*?)\s*</string>', open(src).read(), re.S)
        if m:
            text, where = ' '.join(m.group(1).split()), src
    x0, x1, y0, y1 = cutout_bbox(text)
    W, H = PANEL[0] / SCALE, PANEL[1] / SCALE
    drop = ((W - (x1 - x0) / SCALE) / 2, 0.0, (x1 - x0) / SCALE, (y1 - y0) / SCALE)
    print('cutout (%s): %s' % (where, text))
    print('  bounding box %.1f x %.1f px -> %.1f x %.2f pt at @%d; screen %d x %d pt' % (x1 - x0, y1 - y0, drop[2], drop[3], SCALE, W, H))
    print('  waterdrop rect (dylib): {%.1f, %.1f, %.1f, %.2f} pt' % drop)
    print('  D22Zoomed rect (Apple fallback): {%.1f, %.1f, %.1f, %.1f} pt (centre x %.1f, screen centre %.1f)'
          % (D22Z_NOTCH + (D22Z_NOTCH[0] + D22Z_NOTCH[2] / 2, W / 2)))

    def px(v):          # UIKit rounds to the pixel grid (scale 2)
        return round(v * SCALE) / SCALE
    print('FixedSplit layout [V formulas: leadingCenteringEdgeInset = notch.x / 2 + 0.15 * corner radius (pixel-rounded);')
    print('  regions end at (referenceWidth - notch width) / 2; trailing = mirror; height = _Split +height %.0f]:' % BAR_HEIGHT)
    for name, r in (('with the dylib (waterdrop)', drop), ('without it (D22Zoomed)', D22Z_NOTCH)):
        c = px(r[0] / 2 + 0.15 * CORNER_IPHONEX)
        inner = (W - r[2]) / 2
        print('  %-28s time centred at x %.1f, battery/signal centred at x %.1f; regions [.., %.1f] and [%.1f, ..] (%.1f pt free in the centre)'
              % (name, c, W - c, inner, W - inner, r[2]))
    print('  corner radius: %.1f pt (MobileGestalt iPhone10,3 [I]); Mi A3 panel %.1f pt (rounded_corner_radius 75px): 0.15 x %.1f = %.2f pt '
          'difference, not changed' % (CORNER_IPHONEX, CORNER_MIA3, CORNER_IPHONEX - CORNER_MIA3, 0.15 * (CORNER_IPHONEX - CORNER_MIA3)))
    print('safe area (D22Zoomed edge info, not changed): top %.0f pt (= drop %.1f + %.1f), bottom %.0f pt, home affordance %.0f pt'
          % (SAFE_TOP, drop[3], SAFE_TOP - drop[3], SAFE_BOTTOM, HOME_ALLOWANCE))
    print('status bar view height %.0f pt (FixedSplit, all processes); apps lay out from the safe top %.0f pt [I: the time glyphs end above it]'
          % (BAR_HEIGHT, SAFE_TOP))


def main():
    if len(sys.argv) == 2 and sys.argv[1] == '--expect':
        expect()
        return
    if len(sys.argv) == 3 and sys.argv[1] == '--check':
        sys.exit(0 if check(sys.argv[2]) else 1)
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit(__doc__)
    root = sys.argv[1]
    if os.environ.get('STATUSBAR', '1') == '0':
        print('statusbar: off: STATUSBAR=0 (UIKit keeps its own choice: red rdar:45025538 bar at 360x780 pt; SpringBoard job unchanged)')
        return
    part1(root)
    part2(root)


if __name__ == '__main__':
    main()
