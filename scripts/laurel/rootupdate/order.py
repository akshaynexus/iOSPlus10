"""Order of the commit, the phone's plan file, what the rollback saves, which apps lsd must learn. docs/laurel_sprout/root-update.md."""

VAR = 'private/var/'
FILES = 'usr/share/laurel/root-files'
MANIFEST = 'usr/share/laurel/root-manifest'
LAUNCHD = 'System/Library/xpc/launchd.plist'


def rank(a):
    """Order of the commit: new folders, then data and libraries, the tools SSH needs, then what runs at the next boot. Each step is atomic, so the running system and the
    link survive every state. launchd.plist comes near the end: it starts the new jobs, and only after a reboot."""
    p = a.path
    if a.op == 'mkdir':
        return (0, p.count('/'))
    if a.op == 'del' and a.clash:
        return (-1, 0)
    if p == MANIFEST:
        return (99, 0)
    if p == FILES:
        return (98, 0)
    if p == LAUNCHD:
        return (90, 0)
    if a.op == 'del':
        return (80, -p.count('/'))
    if p.startswith('System/Library/LaunchDaemons/'):
        return (70, 0)
    if p.startswith(VAR):
        return (60, 0)
    if p == 'bin/sh' or p.startswith('usr/local/bin/'):
        return (50, 0)
    if p.startswith('private/etc/'):
        return (40, 0)
    if p.startswith(('usr/libexec/', 'usr/local/libexec/')):
        return (20, 0)
    return (10, 0)


def plan_lines(acts):
    """The phone's plan.tsv (p_apply in phone.sh). A folder that must go before a file comes gets its X just before."""
    lines = []
    for a in sorted(acts, key=rank):
        if a.op == 'mkdir':
            lines.append('D\t%o\t%d\t%d\t%s\n' % (a.mode, a.uid, a.gid, a.path))
        elif a.op == 'meta':
            lines.append('M\t%o\t%d\t%d\t%s\n' % (a.mode, a.uid, a.gid, a.path))
        elif a.op == 'del':
            lines.append('%s\t-\t-\t-\t%s\n' % ('X' if a.clash else 'G', a.path))
        else:
            if a.clash:
                lines.append('X\t-\t-\t-\t%s\n' % a.path)
            lines.append('F\t-\t-\t-\t%s\n' % a.path)
    return lines


def rollback_lists(acts, skip=()):
    """(paths to save, paths that are new). A cache in skip is not saved: it is made again."""
    save, new = [], []
    for a in sorted(acts, key=rank):
        if a.path in skip or (a.op == 'meta' and a.kind == 'd'):    # no folder tree in the tar for a mode change
            continue
        if a.op == 'mkdir' and not a.old:
            new.append(a.path)
        elif a.op == 'put' and not a.old:
            new.append(a.path)
        elif a.op in ('put', 'del', 'meta') and a.path not in save:
            save.append(a.path)
    return save, new


def registrations(acts):
    """Apps that lsd must learn at the next boot (it keeps its store on a root that booted before; docs/laurel_sprout/xnutils.md)."""
    out = []
    for a in acts:
        parts = a.path.split('/')
        if parts[0] != 'Applications' or len(parts) < 2 or not parts[1].endswith('.app'):
            continue
        if a.op == 'del' and len(parts) == 2:
            out.append('U /Applications/%s\n' % parts[1])
        elif a.op == 'put' and len(parts) == 3 and parts[2] == 'Info.plist':
            out.append('R /Applications/%s\n' % parts[1])
    return sorted(set(out))
