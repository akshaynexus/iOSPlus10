#!/usr/bin/env python3
"""One command for a Mi A3 with no picture (iOS 26 first boot). Reads the kernel log, processes, crash list, GPU and Metal state and the last panic over the USB link, and writes a state summary. Only reads: no reboot, no write on the phone.
    scripts/bg.sh ios26-diag python3 -I scripts/laurel/ios26-diag.py        then: scripts/bg.sh -s ios26-diag 40        (make laurel-ios26-diag)
    ios26-diag.py [--out DIR] [--no-ssh] [--log-wait S]     collect and summarize; default DIR logs/ios26-diag-<time>
    ios26-diag.py --from DIR     summarize a folder again         ios26-diag.py --self-test     the rules on made-up boots, no phone
Output: DIR/state.txt (the summary), usb.txt, ping.txt, kstate.txt, kps.txt, kernel-log.txt, ssh-*.txt. Exit 0 when the tool ran, whatever the phone's state.
Needs: the host address 192.168.7.1 on the phone's USB interface (make usblog; it asks for sudo once). Over that link the kernel answers with no SSH and no launchd (patch 2951). SSH (scripts/net/ssh-phone.sh) adds what only
userland knows. docs/laurel_sprout/ios26-first-boot.md tells what each state means. Python, stdlib only: macOS and Linux."""
import argparse
import glob
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
PHONE, HOST, CTL, LOGP = '192.168.7.2', '192.168.7.1', 5141, 5140
ECM_MAC = '02:00:5e:77:ee:01'
# Read-only commands of the SSH step: file name, remote command. /usr/local/bin is in the job's PATH. Each has its own time limit
SSH_STEPS = [
    ('ps', 'ps axww -o pid,ppid,stat,etime,command || ps ax'),
    ('mount', 'mount; df'),
    ('net', 'ifconfig ue0; usbnetcfg show'),
    ('stats', 'ksysctl kern.laurel_stats kern.bootargs kern.laurel_dualboot kern.laurel_reboot_mode'),
    ('crashes', 'ls -lR /private/var/mobile/Library/Logs/CrashReporter /private/var/logs/CrashReporter 2>&1 | head -300'),
    ('launchd', 'ls -l /private/var/log/com.apple.xpc.launchd; cat /private/var/log/com.apple.xpc.launchd/launchd_cache_loader.log; tail -n 300 /private/var/log/com.apple.xpc.launchd/launchd.log'),
    ('metal', 'cd /private/var/db/negronimetal && ls -lR . | head -80; cat build.txt clients env; tail -n 300 metal.log'),
    ('root', 'cat /usr/share/laurel/ios26-root-audit.txt /usr/share/laurel/ios26-debug-manifest /usr/share/laurel/ios26-debug-cdhashes'),
]
BOOT_TASKS = ('mount', 'fsck', 'init_data_protec', 'launchd_cache_lo', 'cc_fips_test', 'dirs_cleaner')


def write(d, name, text):
    with open(os.path.join(d, name), 'w') as f:
        f.write(text)


def read(d, name):
    try:
        with open(os.path.join(d, name), errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def usb_state():
    """(interface or '', has 192.168.7.1). Reads only."""
    try:
        if sys.platform == 'darwin':
            o = subprocess.run(['ifconfig', '-a'], capture_output=True, text=True).stdout
            for blk in re.split(r'\n(?=\S)', o):
                if ECM_MAC in blk.lower():
                    return blk.split(':', 1)[0], f'inet {HOST} ' in blk
            return '', False
        o = subprocess.run(['ip', '-o', 'link'], capture_output=True, text=True).stdout
        for line in o.splitlines():
            if ECM_MAC in line.lower():
                name = line.split(': ')[1].split('@')[0]
                a = subprocess.run(['ip', '-o', 'addr', 'show', 'dev', name], capture_output=True, text=True).stdout
                return name, f'{HOST}/' in a
    except OSError:
        pass
    return '', False


def ask(sock, word, many=False, tries=3):
    """One command. many: replies until the line "end"."""
    for _ in range(tries):
        try:
            sock.sendto(word.encode(), (PHONE, CTL))
            text = ''
            while True:
                b = sock.recv(2048).decode('utf-8', 'replace')
                text += b
                if not many or text.endswith('end\n') or text.startswith('error'):
                    return text
        except OSError:
            continue
    return ''


def newest_usblog():
    main = subprocess.run(['git', '-C', REPO, 'worktree', 'list', '--porcelain'], capture_output=True, text=True).stdout.splitlines()
    roots = [REPO] + ([main[0].split(' ', 1)[1]] if main else [])
    files = [f for r in roots for f in glob.glob(os.path.join(r, 'logs', 'usblog-*.txt'))]
    return max(files, key=os.path.getmtime) if files else None


def capture_log(ctl, out, wait):
    """All of the console ring. usblog.sh holds port 5140: then its file grows, and the new part is ours. Else this tool listens itself."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind((HOST, LOGP))
    except OSError:
        f = newest_usblog()
        if f is None:
            write(out, 'kernel-log.txt', '')
            return 'port 5140 is in use and no logs/usblog-*.txt was found'
        pos = os.path.getsize(f)
        said = ask(ctl, 'logall').strip()
        end = time.time() + wait
        last, still = pos, time.time()
        while time.time() < end and time.time() - still < 4:
            time.sleep(0.5)
            n = os.path.getsize(f)
            if n != last:
                last, still = n, time.time()
        with open(f, errors='replace') as g:
            whole = g.read()
        with open(f, errors='replace') as g:
            g.seek(pos)
            part = g.read()
        # the file holds the whole run, also earlier boots: what logall sent again, else the end of the file
        write(out, 'kernel-log.txt', part if len(part) > 1000 else whole[-4 << 20:])
        return f'usblog owns the port: {f}; {said or "no answer to logall"}; {len(part)} new bytes'
    s.settimeout(1)
    chunks = []
    said = ask(ctl, 'logall').strip()
    end = time.time() + wait
    idle = 0
    while time.time() < end and idle < 4:
        try:
            chunks.append(s.recv(2048))
            idle = 0
        except OSError:
            idle += 1
    text = b''.join(chunks).decode('utf-8', 'replace')
    write(out, 'kernel-log.txt', text)
    return f'this tool listened on {LOGP}: {said or "no answer to logall"}; {len(text)} bytes'


def ssh_step(out, name, cmd):
    try:
        r = subprocess.run([os.path.join(REPO, 'scripts/net/ssh-phone.sh'), cmd], capture_output=True, text=True, errors='replace', timeout=40, stdin=subprocess.DEVNULL)
        write(out, f'ssh-{name}.txt', r.stdout + r.stderr)
        return r.returncode
    except subprocess.TimeoutExpired:
        write(out, f'ssh-{name}.txt', 'time limit of 40 s\n')
        return 255


def collect(out, use_ssh, wait):
    os.makedirs(out, exist_ok=True)
    name, addr = usb_state()
    usb = 'none' if not name else ('address' if addr else 'no-address')
    write(out, 'usb.txt', f'{usb} {name}\n')
    if usb != 'address':
        print(f'ios26-diag: USB interface: {name or "none"}, host address {"set" if addr else "not set"}. ' + ('Start the link: make usblog' if name else 'No phone on USB: the kernel did not reach its USB start, or the cable, or Android'))
        return
    ctl = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ctl.bind((HOST, 0))
    ctl.settimeout(1)
    pong = ask(ctl, 'ping')
    write(out, 'ping.txt', pong + '\n')
    if not pong:
        print('ios26-diag: no answer to ping')
        return
    write(out, 'kstate.txt', ask(ctl, 'state', many=True))
    write(out, 'kps.txt', ask(ctl, 'ps', many=True))
    write(out, 'ktime.txt', ask(ctl, 'time') + '\n')
    print('ios26-diag: log:', capture_log(ctl, out, wait))
    if not use_ssh or 'panic' in pong:
        return
    rc = ssh_step(out, 'ping', 'true')
    write(out, 'ssh-rc.txt', f'{rc}\n')
    if rc == 0:
        for n, c in SSH_STEPS:
            ssh_step(out, n, c)


def parse_state(text):
    st = {'run': {}, 'bad': [], 'exec': [], 'launchd': None, 'ssh': None, 'root': None, 'build': None, 'up': None}
    for line in text.splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == 'run' and len(p) >= 2:
            st['run'][p[1]] = dict(x.split('=', 1) for x in p[2:] if '=' in x)
        elif p[0] == 'bad' and len(p) >= 4:
            st['bad'].append(p[2:])
        elif p[0] == 'exec' and len(p) >= 3:
            st['exec'].append(p[2])
        elif p[0] == 'state' and len(p) >= 3 and p[2].startswith('up='):
            st['up'] = p[2][3:]
        elif p[0] == 'build':
            st['build'] = line[6:]
        elif p[0] == 'root':
            st['root'] = line[5:]
        elif p[0].startswith('launchd='):
            st['launchd'] = p[0].split('=')[1]
            st['ssh'] = p[1].split('=')[1] if len(p) > 1 else None
    return st


def first(log, pat):
    m = re.search(pat, log, re.M)
    if not m:
        return None
    s = log.rfind('\n', 0, m.start()) + 1
    e = log.find('\n', m.start())
    return log[s:e if e >= 0 else len(log)].strip()[:220]


def summarize(d):
    """The rules: one line per stage, then one sentence. A stage with no evidence says so; a guess is not a state."""
    usb = read(d, 'usb.txt').split()
    pong = read(d, 'ping.txt').strip()
    log = read(d, 'kernel-log.txt')
    st = parse_state(read(d, 'kstate.txt'))
    L, S = [], []

    def stage(name, value):
        L.append(f'{name:12} {value}')

    if not usb or usb[0] == 'none':
        stage('usb', 'no phone interface on this host')
        S.append('no USB device: the kernel did not reach its USB start, or Android runs, or the cable. Read the panel')
        return L, S
    if usb[0] == 'no-address':
        stage('usb', f'{usb[1]} is there, host address not set: make usblog')
        S.append('USB device up, host address missing: make usblog, then run this again')
        return L, S
    stage('usb', f'{usb[1]} {HOST} <-> {PHONE}')
    if not pong:
        stage('kernel', 'no answer to ping')
        S.append('USB interface up, the kernel does not answer')
        return L, S
    panic = 'panic' in pong or re.search(r'^(\S+ )?panic\(cpu', log, re.M)
    stage('kernel', 'PANIC held' if 'panic' in pong else f'up: {pong.split(" from")[0]}, {st["up"] or "?"} s')
    if st['build']:
        stage('build', st['build'])
    elif first(log, r'LAUREL BUILD: '):
        stage('build', first(log, r'LAUREL BUILD: '))
    if panic:
        p = first(log, r'panic\(cpu')
        stage('panic', p or 'the kernel says panic: no panic line in the log yet')
        S.append('kernel PANIC: ' + (p or 'read kernel-log.txt'))
    else:
        S.append('kernel up')
    if st['root']:
        stage('root', st['root'])
    laun = st['launchd'] == 'up' or bool(re.search(r'exec launchd\s*$', log, re.M))
    stage('launchd', 'up' if laun else ('no: ' + (first(log, r'load_init_program') or 'no exec launchd in the log')))
    if laun:
        S.append('launchd up')
    elif not panic:
        S.append('no launchd: root mount or exec: ' + (first(log, r'SWEET HFS|root device|mountroot') or 'read kernel-log.txt'))
    done = first(log, r'Early boot complete')
    failed = [b for b in st['bad'] if b[0].split('[')[0] in BOOT_TASKS]
    failure = first(log, r'[Bb]oot task (failed|failure)|Panicking in 3 seconds')
    if failure or failed:
        stage('boot tasks', 'FAILED: ' + (failure or ' '.join(failed[0])))
        S.append('boot task failed: ' + (failure or ' '.join(failed[0])))
    elif done:
        stage('boot tasks', 'done')
    elif laun:
        last = re.findall(r'\[Event: ([^\]]+)\] Doing boot task', log)
        stage('boot tasks', f'not finished; last: {last[-1] if last else "no line"}; last exec: {st["exec"][-1] if st["exec"] else "?"}')
        if last:
            S.append(f'boot tasks stop after {last[-1]}')
    rc = read(d, 'ssh-rc.txt').strip()
    db = st['run'].get('dropbearmulti') or st['run'].get('dropbear')
    if rc == '0':
        stage('ssh', 'answers on 192.168.7.2:22')
        S.append('SSH up')
    elif laun:
        how = f'dropbear n={db["n"]} x={db["x"]} rv={db["rv"]}, port does not answer' if db else 'launchd did not start dropbear'
        off = first(log, r'LAUREL SSH: off')
        stage('ssh', how + (f'; {off}' if off else ''))
        S.append('no SSH: ' + how)
    bb = st['run'].get('backboardd')
    nbb = len(re.findall(r'exec backboardd\s*$', log, re.M))
    n = int(bb['n']) if bb else nbb
    x = int(bb['x']) if bb else len(re.findall(r'CRASH backboardd\[', log))
    if n == 0:
        stage('backboardd', 'not started')
        if laun:
            S.append('backboardd not started')
    else:
        word = 'loop' if n >= 3 and x >= 2 else 'running' if bb is None or bb.get('pid') != '0' else 'stopped'
        stage('backboardd', f'{word}: {n} starts, {x} exits' + (f', last rv {bb["rv"]}' if bb else ''))
        S.append(f'backboardd {word}' + (f' ({n} starts)' if word == 'loop' else ''))
    metal = first(log, r'LAUREL METAL26: off|LAUREL METAL26: .*no frame on a screen|LAUREL METAL26: screen: 0 of 64|LAUREL METAL: off|NegroniMetal.*(failed|refused)|NMTL\[.*(device (open )?failed|fatal)')
    on = first(log, r'LAUREL METAL26: on|LAUREL METAL: on')
    sf = read(d, 'ssh-metal.txt')
    stage('metal', ('first error: ' + metal) if metal else (on or 'no line') + (' (metal.log read over SSH)' if sf else ''))
    if metal:
        S.append('first Metal error: ' + metal)
    gpu = first(log, r'LAUREL GPU WATCHDOG|GPU hang|LAUREL GPU: off')
    if gpu:
        stage('gpu', gpu)
    sb = st['run'].get('SpringBoard')
    nsb = int(sb['n']) if sb else len(re.findall(r'exec SpringBoard\s*$', log, re.M))
    stage('springboard', f'{nsb} starts' + (f', {sb["x"]} exits, pid {sb["pid"]}' if sb else ''))
    if nsb:
        S.append(f'SpringBoard {"running" if sb is None or sb.get("pid") != "0" else "stopped"}')
    frame = first(log, r'first frame on the panel')
    # SWEET FPS prints only while backboardd draws with GL (patch 2152): on 23F84 expect LAUREL FRAME and the screen lines of the plug-in
    fps = re.findall(r'SWEET FPS: (\d+) frames', log)
    lit = re.findall(r'^.*LAUREL METAL26: screen: \d+ of 64 samples lit.*$', log, re.M)
    rate = re.findall(r'^.*LAUREL FRAME: \d+ ticks.*$', log, re.M)
    stage('picture', (frame or 'no "first frame on the panel" line') + (f'; last SWEET FPS {fps[-1]}' if fps else ''))
    if lit:
        stage('lit', lit[-1].strip()[:200])
    if rate:
        stage('frames', rate[-1].strip()[:200])
    if frame:
        S.append('first frame on the panel')
    elif laun:
        S.append('no frame on the panel')
    crashes = {}
    for m in re.finditer(r'CRASH (\S+)\[\d+\] sig (\d+)', log):
        crashes[m.group(1)] = crashes.get(m.group(1), 0) + 1
    top = sorted(crashes.items(), key=lambda kv: -kv[1])[:8]
    stage('crashes', ', '.join(f'{k} {v}' for k, v in top) if top else 'no CRASH line in the log')
    if st['bad']:
        stage('bad exits', '; '.join(' '.join(b) for b in st['bad'][-4:]))
    for k in ('LAUREL EMU:', 'LAUREL CE:', 'SWEET AMFI: syscall'):
        v = first(log, k)
        if v:
            stage(k.lower(), v)
    return L, S


def report(d):
    L, S = summarize(d)
    text = 'STATE: ' + ', '.join(S) + '\n\n' + '\n'.join(L) + '\n\n' + f'Files: {d}. Meaning of each state: docs/laurel_sprout/ios26-first-boot.md\n'
    write(d, 'state.txt', text)
    print(text, end='')
    return S


def self_test():
    """Made-up boots with the real line forms of the USB log of 2026-11-01 and of patch 2951."""
    def boot(**f):
        d = tempfile.mkdtemp(prefix='ios26-diag-test')
        for k, v in f.items():
            write(d, k.replace('_', '-').replace('-txt', '.txt'), v)
        return d
    usb = 'address enx0\n'
    good = 'state 1 up=90.0\nbuild 85f03caf14 318 patches, series x, ios26_4k\nroot /dev/ufsroot0 rw\nlaunchd=up ssh=started\ncount exec=9 exit=1 bad=0 sig=0\nrun launchd pid=1 n=1 x=0 rv=0x0 t=2.1\nrun dropbearmulti pid=50 n=1 x=0 rv=0x0 t=6.0\nrun backboardd pid=61 n=1 x=0 rv=0x0 t=8.0\nrun SpringBoard pid=70 n=1 x=0 rv=0x0 t=9.0\nend\n'
    loop = good.replace('run backboardd pid=61 n=1 x=0 rv=0x0', 'run backboardd pid=0 n=7 x=7 rv=0x6') + 'bad 30.1 backboardd[99] rv=0x6\n'
    table = [
        ('no usb', boot(usb_txt='none \n'), ['no USB device']),
        ('no address', boot(usb_txt='no-address enx0\n'), ['host address missing']),
        ('no pong', boot(usb_txt=usb, ping_txt='\n'), ['the kernel does not answer']),
        ('panic', boot(usb_txt=usb, ping_txt='pong (panic)\n', kernel_log_txt='12:00:00 panic(cpu 0 caller 0xfffffff0): "x"\n'), ['kernel PANIC: 12:00:00 panic(cpu 0']),
        ('no launchd', boot(usb_txt=usb, ping_txt='pong\n', kstate_txt='state early: no ue0 yet\nend\n', kernel_log_txt='LAUREL BUILD: a\n'), ['kernel up', 'no launchd']),
        ('boot task', boot(usb_txt=usb, ping_txt='pong\n', kstate_txt='state 1 up=9.0\nlaunchd=up ssh=no\nrun launchd pid=1 n=1 x=0 rv=0x0 t=2.1\nrun mount pid=0 n=1 x=1 rv=0x100 t=2.5\nbad 2.7 mount[5] rv=0x100\nend\n', kernel_log_txt='[Event: mount-phase-1] Doing boot task\n'), ['launchd up', 'boot task failed: mount[5]', 'no SSH: launchd did not start dropbear']),
        ('stuck', boot(usb_txt=usb, ping_txt='pong\n', kstate_txt='state 1 up=99.0\nlaunchd=up ssh=no\nexec 3.0 keybagd[9]\nend\n', kernel_log_txt='[System Event] [1] [INFO] [Subsystem: launchd] [Event: keybag] Doing boot task\n'), ['boot tasks stop after keybag']),
        ('loop', boot(usb_txt=usb, ping_txt='pong\n', ssh_rc_txt='0\n', kstate_txt=loop, kernel_log_txt='exec backboardd\nLAUREL METAL26: off: device open failed: no renderer\nCRASH backboardd[99] sig 6 code 0x0\n'), ['SSH up', 'backboardd loop (7 starts)', 'first Metal error: LAUREL METAL26: off']),
        ('loop no ssh', boot(usb_txt=usb, ping_txt='pong\n', ssh_rc_txt='255\n', kstate_txt=loop.replace('run dropbearmulti pid=50 n=1 x=0', 'run dropbearmulti pid=0 n=9 x=9'), kernel_log_txt=''), ['no SSH: dropbear n=9 x=9', 'backboardd loop']),
        ('good', boot(usb_txt=usb, ping_txt='pong\n', ssh_rc_txt='0\n', kstate_txt=good, kernel_log_txt='LAUREL METAL26: on: x\nLAUREL FB CANVAS: first frame on the panel: swap 1\nSWEET FPS: 43 frames in 1004 ms\nEarly boot complete. Continuing system boot.\n'), ['SSH up', 'backboardd running', 'SpringBoard running', 'first frame on the panel']),
    ]
    bad = 0
    for name, d, want in table:
        L, S = summarize(d)
        whole = ', '.join(S)
        miss = [w for w in want if w not in whole]
        print(f'{"ok  " if not miss else "FAIL"} {name}: {whole[:150]}')
        bad += bool(miss)
        subprocess.run(['rm', '-rf', d])
    print(f'ios26-diag self-test: {len(table) - bad} of {len(table)}')
    return 1 if bad else 0


def wire_test():
    """collect() against a fake kernel on loopback: several datagrams, the line "end", the log on its port. And `op10tool ctl state` when this host has it. The real kernel code ran on no phone."""
    import threading
    global PHONE, HOST, LOGP, usb_state
    PHONE, HOST, LOGP = '127.0.0.2', '127.0.0.1', 15140       # another log port: a usblog of the owner may run on this host
    usb_state = lambda: ('lo', True)
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind((PHONE, CTL))
    srv.settimeout(0.2)
    stop = []
    st = ('state 1 up=90.0\nlaunchd=up ssh=no\nrun launchd pid=1 n=1 x=0 rv=0x0 t=2.1\n' + ''.join(f'exec 3.{i} x[{i}]\n' for i in range(120)) + 'end\n').encode()
    assert len(st) > 1400

    def kernel():
        while not stop:
            try:
                w, src = srv.recvfrom(64)
            except OSError:
                continue
            w = w.decode()
            if w == 'ping':
                srv.sendto(b'pong', src)
            elif w in ('state', 'ps'):
                body = st if w == 'state' else b'1 0 launchd\nend\n'
                for o in range(0, len(body), 1400):
                    srv.sendto(body[o:o + 1400], src)
            elif w == 'logall':
                srv.sendto(b'ok logall', src)
                for i in range(3):
                    srv.sendto(f'LAUREL BUILD: fake {i}\nexec launchd\n'.encode(), (HOST, LOGP))
            else:
                srv.sendto(b'time 1 rtc 2 offset 3 source x', src)
    th = threading.Thread(target=kernel, daemon=True)
    th.start()
    d = tempfile.mkdtemp(prefix='ios26-diag-wire')
    collect(d, False, 6)
    S = summarize(d)[1]
    checks = [read(d, 'kstate.txt').endswith('end\n'), 'exec 3.119 x[119]' in read(d, 'kstate.txt'), read(d, 'kps.txt') == '1 0 launchd\nend\n', read(d, 'kernel-log.txt').count('LAUREL BUILD: fake') == 3, 'launchd up' in ', '.join(S)]
    op = os.path.join(REPO, 'out/bin/op10tool')
    if os.access(op, os.X_OK):
        r = subprocess.run([op, 'ctl', 'state', '--host', PHONE], capture_output=True, text=True, timeout=10)
        checks.append(r.returncode == 0 and r.stdout.encode() == st)
        r = subprocess.run([op, 'ctl', 'logall', '--host', PHONE], capture_output=True, text=True, timeout=10)
        checks.append(r.returncode == 0 and 'ok logall' in r.stdout)
    stop.append(1)
    th.join()
    srv.close()
    subprocess.run(['rm', '-rf', d])
    print(f'ios26-diag wire test: {sum(checks)} of {len(checks)}: ' + ' '.join('ok' if c else 'FAIL' for c in checks))
    return 0 if all(checks) else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out')
    ap.add_argument('--from', dest='src')
    ap.add_argument('--no-ssh', action='store_true')
    ap.add_argument('--log-wait', type=int, default=90)
    ap.add_argument('--self-test', action='store_true')
    a = ap.parse_args()
    if a.self_test:
        rc = self_test()
        sys.exit(rc or wire_test())
    if a.src:
        report(a.src)
        return
    out = a.out or os.path.join(REPO, 'logs', time.strftime('ios26-diag-%Y%m%d-%H%M%S'))
    collect(out, not a.no_ssh, a.log_wait)
    report(out)


if __name__ == '__main__':
    main()
