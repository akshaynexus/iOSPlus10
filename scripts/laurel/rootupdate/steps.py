"""The writing steps of the update: stage, key, rollback tar + commit, verify, reboot. docs/laurel_sprout/root-update.md."""
import os
import subprocess
import time

import link
import order
import plan
from link import say

KEYS = 'private/var/root/.ssh/authorized_keys'
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def good_in_stage(a, st, got):
    if a.kind == 'l':
        return a.path in st and st[a.path][0] == 'l' and st[a.path][4] == len(a.target.encode('utf-8', 'surrogateescape'))
    return got.get(a.path) == (a.sha or plan.sha256_bytes(a.data))


def stage(ph, puts, d):
    """Send what the stage does not hold yet. A lost link costs only the rest: the next try finds the good files by hash."""
    store = lambda sha: os.path.join(d, 'store', sha)  # noqa: E731
    for attempt in range(3):
        files = [a for a in puts if a.kind == 'f']
        st = plan.parse_stat(ph.call('p_stat "$S"', [a.path for a in puts]), ph.S)
        same = [a.path for a in files if a.path in st and st[a.path][4] == a.size]
        got = plan.parse_hash(ph.call('p_hash "$S"', same), ph.S) if same else {}
        send = [a for a in puts if not good_in_stage(a, st, got)]
        if not send:
            break
        say('stage: try %d: %d files, %d bytes' % (attempt + 1, len(send), sum(a.size for a in send)))
        ph.stage_put(send, store, say)
    else:
        raise link.LinkDown('stage: the files did not arrive whole after 3 tries')
    st = plan.parse_stat(ph.call('p_stat "$S"', [a.path for a in puts]), ph.S)
    fix = ['%o\t%d\t%d\t%s' % (a.mode, a.uid, a.gid, a.path) for a in puts if a.kind == 'f' and st.get(a.path, (0, -1, -1, -1))[1:4] != (a.mode, a.uid, a.gid)]
    bad_links = [a.path for a in puts if a.kind == 'l' and st.get(a.path, ('',))[0] != 'l']
    if bad_links:
        raise RuntimeError('stage: links missing: %s' % bad_links[:5])
    if fix:
        ph.call('p_fixmeta', fix)
    tools = [a.path for a in puts if a.path in plan.SMOKE]
    if tools:
        ph.call('p_smoke', tools)


def key_step(ph, puts, acts, rows):
    """The key must work before the job that turns password logins off (-s) can come. Nothing else has changed yet. A root with no key file keeps passwords: no check."""
    if not any(r.path == KEYS for r in rows):
        return
    key = [a for a in puts if a.path == KEYS]
    if key:
        parents = [a for a in acts if a.op == 'mkdir' and KEYS.startswith(a.path + '/')]
        ph.write_file(ph.W + '/key.tsv', ''.join(order.plan_lines(parents + key)).encode())
        ph.call('p_apply "$W/key.tsv"')
        puts.remove(key[0])
        say('ssh: key in /%s' % KEYS)
    check = os.environ.get('ROOT_UPDATE_KEYCHECK')
    if check:
        ok = subprocess.run(check, shell=True, check=False).returncode == 0
    else:
        ok = subprocess.run(ph.tr + ['true'], env=dict(os.environ, PHONE_PASSWORD='not-the-password'), check=False).returncode == 0
    if not ok:
        raise RuntimeError('key login does not work (out/ssh/phone_ed25519): stop before the new root starts dropbear with -s. Only authorized_keys changed')
    say('ssh: key login works')


def commit(ph, acts, rb_id):
    """Rollback tar, then the commit detached from SSH: a lost link does not stop it, this loop reads its status."""
    save, new = order.rollback_lists(acts, skip=plan.CACHES)
    ph.write_file(ph.W + '/rb.replace', ''.join(p + '\n' for p in save).encode('utf-8', 'surrogateescape'))
    ph.write_file(ph.W + '/rb.new', ''.join(p + '\n' for p in new).encode('utf-8', 'surrogateescape'))
    ph.call('p_rollback_make %s' % rb_id)
    say('rollback: %d old files in /private/var/root/laurel-rollback/%s' % (len(save), rb_id))
    ph.write_file(ph.W + '/plan.tsv', ''.join(order.plan_lines(acts)).encode('utf-8', 'surrogateescape'))
    ph.write_file(ph.W + '/phone.sh', ('R=%s\n%s' % (link.shlex.quote(ph.R), ph.lib)).encode())
    ph.write_file(ph.W + '/register.list', ''.join(order.registrations(acts)).encode('utf-8', 'surrogateescape'))
    ph.call('p_start')
    down = 0
    while down < 40:
        try:
            s = ph.call('p_status', tries=1).strip()
            down = 0
        except link.LinkDown:
            down += 1
            s = 'link down'
        if s.startswith('done'):
            say('commit: %s lines' % s.split()[1])
            return True
        if s.startswith('failed'):
            say('FAILED: commit: %s' % s)
            return False
        time.sleep(3)
    say('FAILED: commit: no answer for 2 minutes; the commit runs on by itself. Read /private/var/root/laurel-update/plan.tsv.status when SSH is back')
    raise link.LinkDown('commit status')


def verify(ph, acts):
    """Hash of every written file on the phone, owner and mode too. Empty list = good."""
    bad = []
    puts = [a for a in acts if a.op == 'put']
    st = plan.parse_stat(ph.call('p_stat', [a.path for a in acts if a.op != 'del']), ph.R)
    got = plan.parse_hash(ph.call('p_hash', [a.path for a in puts if a.kind == 'f']), ph.R) if puts else {}
    for a in acts:
        h = st.get(a.path)
        if a.op == 'del':
            continue
        if h is None:
            bad.append('/%s is missing' % a.path)
        elif a.op == 'put' and a.kind == 'f' and got.get(a.path) != (a.sha or plan.sha256_bytes(a.data)):
            bad.append('/%s has the wrong hash' % a.path)
        elif a.kind != 'l' and a.op != 'mkdir' and h[1:4] != (a.mode, a.uid, a.gid):
            bad.append('/%s has mode or owner %o %d:%d' % (a.path, h[1], h[2], h[3]))
    gone = plan.parse_stat(ph.call('p_stat', [a.path for a in acts if a.op == 'del' and not a.clash]), ph.R)
    return bad + ['/%s is still there' % p for p in gone]


def reboot(ph):
    """The kernel's command server: it works with any user space. A hard reset, so p_apply's sync came first."""
    ph.call('sync')
    for op in (os.path.join(REPO, 'out/bin/op10tool'), os.path.join(subprocess.run(['git', '-C', REPO, 'rev-parse', '--path-format=absolute', '--git-common-dir'], capture_output=True, text=True, check=False).stdout.strip(), '..', 'out/bin/op10tool')):
        if os.access(op, os.X_OK) and subprocess.run([op, 'ctl', 'reboot'], check=False).returncode == 0:
            say('reboot: ctl reboot sent')
            return True
    say('reboot: no op10tool ctl answer: usbreboot over SSH')
    subprocess.run(ph.tr + ['/usr/local/bin/usbreboot normal'], check=False)
    return True


def restore(ph, rb_id, why):
    say('FAILED: %s. Rolling back.' % why)
    try:
        say(ph.call('p_rollback %s' % rb_id).strip())
        say('FAILED: the phone is back on the old root files; no reboot needed: nothing restarted')
    except (RuntimeError, link.LinkDown) as e:
        say('FAILED: the rollback failed too: %s. Do not reboot; run root-update.sh --rollback %s' % (e, rb_id))
    return 1
