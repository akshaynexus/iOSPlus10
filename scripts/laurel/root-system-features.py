#!/usr/bin/env python3
"""Mi A3 root: system apps and jobs back where the old reason no longer holds (docs/laurel_sprout/system-features.md).

    root-system-features.py MOUNTED_ROOT     (root.sh runs it after root-tweaks-perf.py)
    root-system-features.py --self-test      (host check on a made-up root)

1. Stock apps (STAGED_APPS=0 skips). 20H392 keeps 32 apps in /private/var/staged_system_apps: Calendar, Clock, Mail, Notes,
   Maps, Weather, Contacts, Music, Files, Health, ... A real phone installs them during the first-boot data migration
   (SystemAppMigrator). Our root skips that migration (LastSystemVersion, topaz sweet-root-tweaks.py), so these apps never
   showed on the Mi A3 [V 7z list of laurel-ios16-root.img of 2026-11-01 19:51: all 32 are still staged]. Same fix as negroni
   (scripts/ios16/root-finish.sh), slop (install-staged-apps.sh), ios-flame and ios-apollo: move them to /Applications and
   remove the /System/Library/AppPlaceholders stub of the same name. LaunchServices registers /Applications at its first
   seed; a root that already has a LaunchServices store does not see them (fresh root only, as root.sh makes).
2. launchd jobs (RESTORE_JOBS, labels; default com.apple.aggregated; empty: none). root-tweaks-extra.py removes aggregated
   because ios-sailfish did. In 20H392 it holds the power log (com.apple.powerlog.plxpclogger.xpc) that Settings > Battery
   waits for, and hackios-scion runs it for a whole session without a crash loop [V hackios-scion userland/mkjobs.py DENY note].
   The job comes back from System/Library/LaunchDaemons (launchd reads only the cache, docs/usb-network.md).
3. Its memory limit (AGGREGATED_JETSAM_MB, default 32; empty: stock). The stock limit is 16-20 MiB and the job is KeepAlive:
   a kill at the limit would become a restart loop. Same helper as lsd (root-tweaks-extra.py item 7b).

Every step prints one line; a missing part is a note, not an error. Kept off, with reasons: system-features.md.
"""
import glob, os, plistlib, shutil, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'ios16'))
import jetsam_widgets  # noqa: E402

CACHE = 'System/Library/xpc/launchd.plist'
STAGED = 'private/var/staged_system_apps'
PLACEHOLDERS = 'System/Library/AppPlaceholders'
DAEMONS = 'System/Library/LaunchDaemons'


def staged_apps(root):
    d = os.path.join(root, STAGED)
    if not os.path.isdir(d):
        print(f'laurel system: staged apps: note: no /{STAGED}')
        return []
    apps = os.path.join(root, 'Applications')
    moved = []
    for name in sorted(os.listdir(d)):
        src = os.path.join(d, name)
        if not name.endswith('.app') or not os.path.isdir(src):
            continue
        dst = os.path.join(apps, name)
        if os.path.lexists(dst):
            shutil.rmtree(dst)
        ph = os.path.join(root, PLACEHOLDERS, name)
        if os.path.isdir(ph):
            shutil.rmtree(ph)
        os.rename(src, dst)     # same volume: owners, modes and hard links stay
        moved.append(name)
    total = len([n for n in os.listdir(apps) if n.endswith('.app')])
    print(f'laurel system: staged apps: {len(moved)} moved to /Applications, {total} apps there')
    return moved


def restore_jobs(root, labels):
    path = os.path.join(root, CACHE)
    with open(path, 'rb') as f:
        plist = plistlib.load(f)
    jobs = plist['LaunchDaemons']
    done = []
    for label in labels:
        src = os.path.join(root, DAEMONS, label + '.plist')
        key = '/' + DAEMONS + '/' + label + '.plist'
        if key in jobs:
            print(f'laurel system: job {label}: already in launchd.plist')
        elif not os.path.isfile(src):
            print(f'laurel system: job {label}: note: no stock plist, not restored')
        else:
            with open(src, 'rb') as f:
                job = plistlib.load(f)
            if '_PanicOnCrash' in job:      # same rule as topaz sweet-root-tweaks.py: a crash must not panic the phone
                job['_PanicOnCrasX'] = job.pop('_PanicOnCrash')
            jobs[key] = job
            done.append(label)
            print(f'laurel system: job {label}: back in launchd.plist')
    if done:
        st = os.stat(path)
        with open(path, 'wb') as f:
            plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
        try:
            os.chown(path, st.st_uid, st.st_gid)
        except PermissionError:
            pass
        os.chmod(path, st.st_mode & 0o7777)
    return done


def jetsam(root, mb):
    for path in sorted(glob.glob(os.path.join(root, DAEMONS, 'com.apple.jetsamproperties.*.plist'))):
        print('laurel system: jetsam:', jetsam_widgets.patch_daemon(path, 'com.apple.aggregated', mb))


def apply(root, env):
    if env.get('STAGED_APPS', '1') == '0':
        print('laurel system: staged apps: off: STAGED_APPS=0')
    else:
        staged_apps(root)
    labels = env.get('RESTORE_JOBS', 'com.apple.aggregated').split()
    done = restore_jobs(root, labels)
    mb = env.get('AGGREGATED_JETSAM_MB', '32')
    if 'com.apple.aggregated' in done and mb:
        jetsam(root, int(mb))


def self_test():
    with tempfile.TemporaryDirectory() as root:
        def mk(rel):
            os.makedirs(os.path.join(root, rel), exist_ok=True)

        def dump(rel, data):
            mk(os.path.dirname(rel))
            with open(os.path.join(root, rel), 'wb') as f:
                plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
        mk('Applications/Preferences.app')
        mk(STAGED + '/MobileCal.app')
        mk(STAGED + '/MobileNotes.app')
        mk(PLACEHOLDERS + '/MobileCal.app')
        dump(CACHE, {'LaunchDaemons': {'/' + DAEMONS + '/com.apple.wifid.plist': {'Label': 'com.apple.wifid'}}})
        dump(DAEMONS + '/com.apple.aggregated.plist', {'Label': 'com.apple.aggregated', 'KeepAlive': True, '_PanicOnCrash': {}})
        jp = DAEMONS + '/com.apple.jetsamproperties.D22.plist'
        dump(jp, {'Version4': {'Daemon': {'Override': {'com.apple.aggregated':
             {'JetsamPriority': 180, 'ActiveSoftMemoryLimit': 20, 'InactiveHardMemoryLimit': 16}}}}})
        apply(root, {})
        assert sorted(os.listdir(os.path.join(root, 'Applications'))) == ['MobileCal.app', 'MobileNotes.app', 'Preferences.app']
        assert os.listdir(os.path.join(root, STAGED)) == [] and os.listdir(os.path.join(root, PLACEHOLDERS)) == []
        jobs = plistlib.load(open(os.path.join(root, CACHE), 'rb'))['LaunchDaemons']
        job = jobs['/' + DAEMONS + '/com.apple.aggregated.plist']
        assert len(jobs) == 2 and job['KeepAlive'] is True and '_PanicOnCrasX' in job and '_PanicOnCrash' not in job
        lim = plistlib.load(open(os.path.join(root, jp), 'rb'))['Version4']['Daemon']['Override']['com.apple.aggregated']
        assert lim == {'JetsamPriority': 180, 'ActiveSoftMemoryLimit': 32, 'InactiveHardMemoryLimit': 32}, lim
        apply(root, {})     # twice gives the same root
        assert len(plistlib.load(open(os.path.join(root, CACHE), 'rb'))['LaunchDaemons']) == 2
        print('root-system-features: empty staged list and repeated run: ok')
    print('root-system-features: self-test passed (host only)')


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    if sys.argv[1] == '--self-test':
        self_test()
        return
    if not os.path.isfile(os.path.join(sys.argv[1], CACHE)):
        sys.exit(f'root-system-features: {sys.argv[1]} is not an iOS root')
    apply(sys.argv[1], os.environ)


if __name__ == '__main__':
    main()
