#!/usr/bin/env python3
"""Driver of scripts/laurel/root-update.sh: update the running phone's root in place, keep /private/var. docs/laurel_sprout/root-update.md.

  main.py --dir UPDATE [--sidecar FILE] [--dry-run | --list | --rollback [ID] | --after-boot]
Exit 0 = done (or nothing to do), 1 = failed (the phone is as before, or rolled back; the line says), 3 = refused: only a full flash can do this.
"""
import os
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import facts  # noqa: E402
import link  # noqa: E402
import order  # noqa: E402
import plan  # noqa: E402
import steps  # noqa: E402
from link import say  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
FLASH = 'scripts/laurel/root-flash-test.sh erases /private/var'


def refuse(reasons):
    say('REFLASH NEEDED: %s (%s). Nothing changed.' % ('; '.join(reasons), FLASH))
    return 3


def show(acts, n, meta, first_run):
    for a in sorted(acts, key=order.rank):
        print('%-5s %10d  /%s  (%s)' % (a.op, a.size, a.path, a.why))
    k = {o: sum(a.op == o for a in acts) for o in ('put', 'mkdir', 'meta', 'del')}
    say('plan: %d files to write (%d bytes), %d folders, %d owner or mode, %d removals; %d same, %d kept on the phone, %d gone paths in /private/var left alone%s' % (
        k['put'], plan.bytes_put(acts), k['mkdir'], k['meta'], k['del'], n['same'], n['kept'], n['var_skipped'], '; first update of a root without root-files' if first_run else ''))
    say('new root: %s' % meta.get('first'))


def manifest_act(d, row, on_phone, phone_first, n_write, nbytes):
    """The root's manifest with the truth: `LAUREL BUILD: root` prints the first line. The kernel stops at 199 characters and looks only for kernel-series."""
    with open(os.path.join(d, 'manifest'), 'rb') as fh:
        text = fh.read().decode()
    utc = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    first, _, rest = text.partition('\n')
    new = '%s in-place %s\n%supdate\t%s\t%d files\t%d bytes\tfrom\t%s\n' % (first, utc, rest, utc, n_write, nbytes, phone_first or 'unknown')
    data = new.encode()
    return plan.Act('put', plan.MANIFEST, 'in-place mark', mode=row.mode, uid=row.uid, gid=row.gid, size=len(data), mtime=int(time.time()), data=data, old=on_phone)


def after_boot(ph, d, meta, rows, wait=None):
    """SSH back? Then the apps for lsd, the check that the root still is what was written, the new line."""
    wait = int(os.environ.get('ROOT_UPDATE_WAIT_S', '420') if wait is None else wait)
    t0 = time.time()
    while subprocess.run(ph.tr + ['true'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode != 0:
        if time.time() - t0 > wait:
            say('FAILED: no SSH %d s after the reboot. Read the USB log (make usblog). The rollback needs SSH; without SSH only a full flash helps: %s' % (wait, FLASH))
            return 1
        time.sleep(5)
    say('SSH is back after %d s' % (time.time() - t0))
    print(ph.call('p_register'), end='', flush=True)
    print(ph.call('p_net'), end='', flush=True)
    got = facts.read_phone(ph, d, meta, rows)
    acts = facts.build_plan(d, meta, rows, got)[0]
    acts = [a for a in acts if not plan.trivial(a)]
    say('after boot: root says: %s' % ph.call('p_first_line').strip())
    for a in acts[:20]:
        print('differs: /%s (%s)' % (a.path, a.why))
    say('after boot: %d paths differ from the new root%s' % (len(acts), '' if not acts else ' (a plist that a daemon wrote is normal; run root-update.sh again for the rest)'))
    return 0


def rollback(ph, rb_id):
    out = ph.call('p_rollback %s' % (rb_id or ''))
    say(out.strip())
    say('reboot to run the old files: out/bin/op10tool ctl reboot')
    return 0


def run(a, ph, d):
    meta, rows = plan.read_update(d)
    if a.get('list'):
        for r in rows:
            print('%s %s %o %d:%d %10d  /%s' % (r.kind, r.cls, r.mode, r.uid, r.gid, r.size, r.path))
        say('delta: %d paths, %d bytes; new root: %s' % (len(rows), sum(r.size for r in rows if r.kind == 'f'), meta.get('first')))
        return 0
    if a.get('rollback') is not None:
        return rollback(ph, a['rollback'])
    if a.get('after_boot'):
        return after_boot(ph, d, meta, rows)
    if a.get('sidecar'):
        with open(a['sidecar']) as fh:
            if fh.readline().strip() != meta.get('first'):
                say('FAILED: %s is not from the root build of the sidecar: run root.sh again' % d)
                return 1
    info = ph.info()
    got = facts.read_phone(ph, d, meta, rows)
    acts, n, stale_problems, phone_first, first_run, have, pulled, prev_base = facts.build_plan(d, meta, rows, got)
    real_first = meta.get('first')
    if all(plan.trivial(x) for x in acts) and phone_first == real_first:
        say('OK: the phone already has this root (%s). Nothing to do.' % real_first)
        return 0
    n_write = sum(x.op == 'put' for x in acts)
    row = next(r for r in rows if r.path == plan.MANIFEST)
    acts.append(manifest_act(d, row, plan.MANIFEST in pulled, phone_first, n_write, plan.bytes_put(acts)))
    show(acts, n, meta, first_run)
    bad = facts.problems(meta, info, acts, stale_problems, have, pulled, prev_base)
    if bad:
        return refuse(bad)
    if a.get('dry_run'):
        say('dry run: nothing changed on the phone')
        return 0
    puts = [x for x in acts if x.op == 'put']
    steps.stage(ph, puts, d)
    steps.key_step(ph, puts, acts, rows)
    rest = [x for x in acts if x.path != steps.KEYS]
    rb_id = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    if not steps.commit(ph, rest, rb_id):
        return steps.restore(ph, rb_id, 'the commit failed')
    bad = steps.verify(ph, rest)
    if bad:
        for s in bad[:20]:
            print('verify: ' + s)
        return steps.restore(ph, rb_id, '%d paths differ after the commit' % len(bad))
    ph.call('p_clean; sync')
    k = {o: sum(x.op == o for x in rest) for o in ('put', 'mkdir', 'meta', 'del')}
    nb = plan.bytes_put(acts)
    reboot_now = os.environ.get('REBOOT', '1') != '0'
    say('OK: %d files (%d bytes), %d folders, %d owner or mode, %d removed, %d kept on the phone, %d same; hashes checked; rollback %s; %s' % (
        k['put'], nb, k['mkdir'], k['meta'], k['del'], n['kept'], n['same'], rb_id, 'reboot now' if reboot_now else 'REBOOT=0: no reboot, the new root runs after the next one'))
    if reboot_now:
        steps.reboot(ph)
        time.sleep(int(os.environ.get('ROOT_UPDATE_DOWN_S', '25')))    # the link must drop first
        return after_boot(ph, d, meta, rows)
    return 0


def main(argv):
    a, i = {}, 0
    while i < len(argv):
        s = argv[i]
        i += 1
        if s in ('--dir', '--sidecar'):
            a[s[2:]] = argv[i]
            i += 1
        elif s == '--dry-run':
            a['dry_run'] = True
        elif s == '--list':
            a['list'] = True
        elif s == '--after-boot':
            a['after_boot'] = True
        elif s == '--rollback':
            a['rollback'] = argv[i] if i < len(argv) and not argv[i].startswith('-') else ''
            i += 1 if a['rollback'] else 0
        else:
            sys.exit(__doc__)
    if 'dir' not in a or not os.path.isfile(os.path.join(a['dir'], 'meta.json')):
        say('FAILED: no update payload in %s: run scripts/laurel/root.sh (it writes it)' % a.get('dir'))
        return 1
    ph = link.Phone(REPO)
    try:
        return run(a, ph, a['dir'])
    except (RuntimeError, link.LinkDown) as e:
        say('FAILED: %s' % e)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
