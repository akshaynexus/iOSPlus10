#!/usr/bin/env python3
"""Install SSH + the USB network service into a mounted iOS 16 root (docs/usb-network.md).

    root-add-ssh.py MOUNTED_ROOT        (called by scripts/net/root-add-ssh.sh, as root)

Reads the iOS binaries from out/ssh/ios (userland/ssh/build.sh). Steps (all idempotent):
 1. /usr/local/bin: dropbearmulti (+ dropbear, dropbearkey, dbclient, scp links), dash, toybox
    (+ applet links that do not shadow a stock command), usbnetcfg, laurelnet, usbreboot, oslogstream. /bin/sh = dash
    (stock iOS has no /bin/sh). /private/etc/shells lists /bin/sh.
 2. Login: /private/var/root/.ssh/authorized_keys gets the repo key out/ssh/phone_ed25519 (made once with
    ssh-keygen, kept across rebuilds; scripts/net/ssh-phone.sh uses it, so SSH works with no setup) and the host
    user's public key if there is one (SSH_PUBKEY=FILE, else ~/.ssh/id_ed25519.pub, id_ecdsa.pub, id_rsa.pub of SUDO_USER).
    With a key, dropbear runs with -s (no passwords). No ssh-keygen and no user key: password logins are on and
    root's password is the stock iOS one from /etc/master.passwd ("alpine").
    SSH_PASSWORD_AUTH=1 allows passwords also when a key is installed.
 3. Host key: out/ssh/hostkeys/dropbear_ed25519_host_key (generated once with the host
    dropbearkey, kept across image rebuilds) -> /private/etc/dropbear/. out/ssh/known_hosts gets
    the public key for scripts/net/ssh-phone.sh. No host dropbearkey: dropbear -R makes the
    key on the phone at the first connection.
 4. launchd jobs (plist file + entry in /System/Library/xpc/launchd.plist under the
    /System/Library/LaunchDaemons/ key, the only path launchd reads on these ports):
    dev.iosplus10.dropbear (192.168.7.2:22, KeepAlive) and dev.iosplus10.laurelnet (the LAUREL NET
    line). dev.iosplus10.usbnetcfg (default route + DNS through the host at each boot) only with
    USBNET_INTERNET=1: without host NAT it takes names and routes from Wi-Fi (docs/usb-network.md
    "ue0 and Wi-Fi"); scripts/net/share-internet.sh runs usbnetcfg when the NAT is on.
    Logs: /private/var/log/iosplus10-*.log.
 5. configd preferences: "USB Ethernet" service on ue0, manual 192.168.7.2/24, PrimaryRank Last, last in
    the service order, no router and no DNS (USBNET_INTERNET=1: router 192.168.7.1, DNS 1.1.1.1 8.8.8.8);
    ue0 in NetworkInterfaces.plist (phone MAC 02:00:5e:77:ee:02, patch 0075).
"""
import os, plistlib, pwd, shutil, subprocess, sys, tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
OUT = os.path.join(REPO, 'out', 'ssh')
IOS = os.path.join(OUT, 'ios')
HOSTKEYS = os.path.join(OUT, 'hostkeys')
KNOWN_HOSTS = os.path.join(OUT, 'known_hosts')
PHONE = '192.168.7.2'
SERVICE = '1F05B0E7-0000-4000-8000-0000000000E0'   # same as usbnetcfg.c DEFAULT_SERVICE
LABEL_SSH = 'dev.iosplus10.dropbear'
LABEL_NET = 'dev.iosplus10.usbnetcfg'
LABEL_STATUS = 'dev.iosplus10.laurelnet'
REPO_KEY = os.path.join(OUT, 'phone_ed25519')
USB_INTERNET = os.environ.get('USBNET_INTERNET') == '1'
PATH = '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
IS_ROOT = os.geteuid() == 0
TOOLS = ('dropbearmulti', 'dash', 'toybox', 'usbnetcfg', 'laurelnet', 'usbreboot', 'oslogstream')


def own(path, uid=0, gid=0, mode=None):
    if IS_ROOT:
        os.lchown(path, uid, gid)
    if mode is not None:
        os.chmod(path, mode)


def mkdirs(root, rel, mode=0o755):
    """Create ROOT/rel; new folders get root:wheel and MODE."""
    p = root
    for part in rel.strip('/').split('/'):
        p = os.path.join(p, part)
        if not os.path.lexists(p):
            os.mkdir(p)
            own(p, 0, 0, mode)
    return p


def host_user():
    """(uid, gid, home) of the user who ran sudo, else of the current user."""
    name = os.environ.get('SUDO_USER')
    try:
        pw = pwd.getpwnam(name) if name else pwd.getpwuid(os.getuid())
        return pw.pw_uid, pw.pw_gid, pw.pw_dir
    except KeyError:
        return os.getuid(), os.getgid(), os.path.expanduser('~')


def host_owned(path):
    """Files in out/ belong to the host user, not root."""
    uid, gid, _ = host_user()
    if IS_ROOT:
        os.lchown(path, uid, gid)


def install(src, dst, mode=0o755):
    tmp = dst + '.new'
    shutil.copyfile(src, tmp)
    own(tmp, 0, 0, mode)
    os.replace(tmp, dst)


def link(target, path):
    if os.path.islink(path) or os.path.isfile(path):
        os.unlink(path)
    os.symlink(target, path)
    own(path)


def load_plist(path, default):
    if os.path.exists(path):
        with open(path, 'rb') as f:
            return plistlib.load(f)
    return default


def save_plist(path, data, fmt=plistlib.FMT_BINARY, mode=0o644, uid=0, gid=0):
    tmp = path + '.new'
    with open(tmp, 'wb') as f:
        plistlib.dump(data, f, fmt=fmt)
    own(tmp, uid, gid, mode)
    os.replace(tmp, path)


def binaries(root):
    b = mkdirs(root, 'usr/local/bin')
    for n in TOOLS:
        install(os.path.join(IOS, n), os.path.join(b, n))
    for n in ('dropbear', 'dropbearkey', 'dbclient', 'scp'):
        link('dropbearmulti', os.path.join(b, n))

    # toybox applets, unless a stock command of that name exists
    stock = set()
    for d in ('bin', 'sbin', 'usr/bin', 'usr/sbin'):
        p = os.path.join(root, d)
        if os.path.isdir(p):
            stock.update(os.listdir(p))
    ours = set(TOOLS) | {'dropbear', 'dropbearkey', 'dbclient', 'scp', 'sh'}
    applets = open(os.path.join(IOS, 'toybox.applets')).read().split()
    n = 0
    for a in applets:
        if a in stock or a in ours:
            continue
        p = os.path.join(b, a)
        if os.path.lexists(p) and not (os.path.islink(p) and os.readlink(p) == 'toybox'):
            continue
        link('toybox', p)
        n += 1

    sh = os.path.join(mkdirs(root, 'bin'), 'sh')
    if os.path.islink(sh) or not os.path.exists(sh):
        link('/usr/local/bin/dash', sh)
        shnote = '/bin/sh -> /usr/local/bin/dash'
    else:
        shnote = '/bin/sh exists (kept; dash is /usr/local/bin/dash)'
    print(f'ssh: /usr/local/bin: dropbear, dash, toybox (+{n} applet links), usbnetcfg, laurelnet, usbreboot, oslogstream; {shnote}')

    shells = os.path.join(mkdirs(root, 'private/etc'), 'shells')
    lines = open(shells).read().splitlines() if os.path.exists(shells) else []
    add = [s for s in ('/bin/sh', '/usr/local/bin/dash') if s not in lines]
    if add:
        with open(shells, 'w') as f:
            f.write('\n'.join(lines + add) + '\n')
        own(shells, 0, 0, 0o644)
        print('ssh: /private/etc/shells +=', ' '.join(add))

    for f in ('private/etc/master.passwd', 'private/etc/passwd'):
        p = os.path.join(root, f)
        ent = next((l for l in open(p).read().splitlines() if l.startswith('root:')), None) \
            if os.path.exists(p) and os.access(p, os.R_OK) else None
        if ent is None or not ent.endswith(':/var/root:/bin/sh'):
            print(f'warning: root entry in /{f} is not ...:/var/root:/bin/sh: {ent}')


def find_pubkey():
    env = os.environ.get('SSH_PUBKEY')
    if env:
        if not os.path.isfile(env):
            sys.exit(f'SSH_PUBKEY={env}: no such file')
        return env
    _, _, home = host_user()
    for n in ('id_ed25519.pub', 'id_ecdsa.pub', 'id_rsa.pub'):
        p = os.path.join(home, '.ssh', n)
        if os.path.isfile(p):
            return p
    return None


def repo_key():
    """The key of this repo for the phone: out/ssh/phone_ed25519(.pub), made once. None without ssh-keygen."""
    pub = REPO_KEY + '.pub'
    if not os.path.isfile(pub):
        exe = shutil.which('ssh-keygen')
        if exe is None:
            return None
        os.makedirs(OUT, exist_ok=True)
        host_owned(OUT)
        if os.path.exists(REPO_KEY):   # the private key alone: keep it, a phone may have it
            out = subprocess.run([exe, '-y', '-f', REPO_KEY], check=True, capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
            with open(pub, 'w') as f:
                f.write(out)
        else:
            subprocess.run([exe, '-q', '-t', 'ed25519', '-N', '', '-C', 'iosplus10-phone', '-f', REPO_KEY], check=True, stdin=subprocess.DEVNULL)
            print('ssh: phone key generated:', os.path.relpath(REPO_KEY, REPO))
    # the host user runs ssh with it, also after a run with sudo
    host_owned(REPO_KEY)
    host_owned(pub)
    os.chmod(REPO_KEY, 0o600)
    return pub


def public_key_line(keyfile):
    key = open(keyfile).read().strip().splitlines()[0].strip()
    if not key.startswith(('ssh-', 'ecdsa-')) or 'PRIVATE KEY' in key:
        sys.exit(f'{keyfile} does not look like a public key')
    return key


def login(root):
    """Returns True for key-only logins."""
    keyfiles = [k for k in (repo_key(), find_pubkey()) if k is not None]
    d = mkdirs(root, 'private/var/root/.ssh', 0o700)
    own(d, 0, 0, 0o700)
    profile = os.path.join(root, 'private/var/root/.profile')
    if not os.path.exists(profile):
        with open(profile, 'w') as f:
            f.write(f'# iOSPlus10 (scripts/net/root-add-ssh.py)\nexport PATH={PATH}\nexport HOME=/var/root\n'
                    'export PS1="$(hostname -s 2>/dev/null || echo iPhone):\\$PWD# "\n')
        own(profile, 0, 0, 0o644)
    if not keyfiles:
        print('ssh: no ssh-keygen and no public key (SSH_PUBKEY or ~/.ssh/id_ed25519.pub): password login, '
              'root password = stock iOS "alpine" (scripts/net/ssh-phone.sh gives it)')
        return False
    ak = os.path.join(d, 'authorized_keys')
    have = open(ak).read().splitlines() if os.path.exists(ak) else []
    for keyfile in keyfiles:
        key = public_key_line(keyfile)
        if key not in have:
            have.append(key)
        print('ssh: authorized_keys <-', keyfile)
    with open(ak, 'w') as f:
        f.write('\n'.join(have) + '\n')
    own(ak, 0, 0, 0o600)
    return True


def host_dropbearkey():
    """A dropbearkey that runs on this host: out/ssh/host (userland/ssh/build.sh: a macOS build on macOS,
    a Linux build on Linux) or one in PATH."""
    mine = os.path.join(OUT, 'host', 'dropbearmulti')
    if os.access(mine, os.X_OK):
        with open(mine, 'rb') as f:
            magic = f.read(4)
        if (sys.platform == 'darwin' and magic in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe')) or \
           (sys.platform.startswith('linux') and magic == b'\x7fELF'):
            return [mine, 'dropbearkey']
    exe = shutil.which('dropbearkey')
    return [exe] if exe else None


def hostkey(root):
    """Returns True if a host key was installed (else dropbear -R makes one on the phone)."""
    name = 'dropbear_ed25519_host_key'
    src = os.path.join(HOSTKEYS, name)
    tool = host_dropbearkey()
    if not os.path.exists(src):
        if tool is None:
            print('ssh: no host dropbearkey (out/ssh/host from userland/ssh/build.sh, or dropbearkey in PATH): '
                  'the phone generates its host key at the first connection (-R)')
            return False
        os.makedirs(HOSTKEYS, exist_ok=True)
        host_owned(HOSTKEYS)
        os.chmod(HOSTKEYS, 0o700)
        with tempfile.TemporaryDirectory() as tmp:   # dropbearmulti picks the tool by argv[0]
            exe = tool
            if len(tool) == 2:
                exe = [os.path.join(tmp, 'dropbearkey')]
                os.symlink(tool[0], exe[0])
            subprocess.run(exe + ['-t', 'ed25519', '-f', src], check=True, capture_output=True)
        host_owned(src)
        os.chmod(src, 0o600)
        print('ssh: host key generated:', os.path.relpath(src, REPO))
    kd = mkdirs(root, 'private/etc/dropbear', 0o700)
    own(kd, 0, 0, 0o700)
    install(src, os.path.join(kd, name), 0o600)
    print('ssh: host key -> /private/etc/dropbear/' + name)

    if tool is not None:
        with tempfile.TemporaryDirectory() as tmp:
            exe = tool
            if len(tool) == 2:
                exe = [os.path.join(tmp, 'dropbearkey')]
                os.symlink(tool[0], exe[0])
            out = subprocess.run(exe + ['-y', '-f', src], check=True, capture_output=True, text=True).stdout
        pub = next(l for l in out.splitlines() if l.startswith('ssh-ed25519 '))
        pub = ' '.join(pub.split()[:2])
        with open(KNOWN_HOSTS, 'w') as f:
            f.write(f'{PHONE} {pub}\n')
        host_owned(KNOWN_HOSTS)
        fp = next((l for l in out.splitlines() if l.startswith('Fingerprint')), '')
        print('ssh: host key', fp.strip(), '-> out/ssh/known_hosts')
    return True


def add_job(root, label, job):
    rel = f'System/Library/LaunchDaemons/{label}.plist'
    mkdirs(root, 'System/Library/LaunchDaemons')
    save_plist(os.path.join(root, rel), job, fmt=plistlib.FMT_XML)
    lp = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(lp)
    data = load_plist(lp, None)
    data.setdefault('LaunchDaemons', {})['/' + rel] = job
    save_plist(lp, data, mode=st.st_mode & 0o7777, uid=st.st_uid, gid=st.st_gid)


def drop_job(root, label):
    """A job of an older run of this script on the same root goes away."""
    rel = f'System/Library/LaunchDaemons/{label}.plist'
    p = os.path.join(root, rel)
    if os.path.exists(p):
        os.unlink(p)
    lp = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(lp)
    data = load_plist(lp, None)
    if data.get('LaunchDaemons', {}).pop('/' + rel, None) is not None:
        save_plist(lp, data, mode=st.st_mode & 0o7777, uid=st.st_uid, gid=st.st_gid)


def jobs(root, key_only, have_hostkey):
    mkdirs(root, 'private/var/log')
    args = ['/usr/local/bin/dropbear', '-F', '-E', '-p', f'{PHONE}:22']
    if have_hostkey:
        args += ['-r', '/private/etc/dropbear/dropbear_ed25519_host_key']
    else:
        mkdirs(root, 'private/etc/dropbear', 0o700)
        args += ['-R']
    if key_only and os.environ.get('SSH_PASSWORD_AUTH') != '1':
        args += ['-s']
    env = {'PATH': PATH, 'HOME': '/var/root'}
    add_job(root, LABEL_SSH, {
        'Label': LABEL_SSH, 'ProgramArguments': args, 'RunAtLoad': True, 'KeepAlive': True,
        'ThrottleInterval': 10, 'UserName': 'root', 'EnvironmentVariables': env,
        'StandardErrorPath': '/private/var/log/iosplus10-dropbear.log'})
    add_job(root, LABEL_STATUS, {
        'Label': LABEL_STATUS, 'ProgramArguments': ['/usr/local/bin/laurelnet'], 'RunAtLoad': True,
        'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 60, 'UserName': 'root',
        'EnvironmentVariables': env,
        'StandardOutPath': '/private/var/log/iosplus10-laurelnet.log',
        'StandardErrorPath': '/private/var/log/iosplus10-laurelnet.log'})
    if USB_INTERNET:
        add_job(root, LABEL_NET, {
            'Label': LABEL_NET, 'ProgramArguments': ['/usr/local/bin/usbnetcfg', 'up'], 'RunAtLoad': True,
            'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 10, 'UserName': 'root',
            'EnvironmentVariables': env,
            'StandardOutPath': '/private/var/log/iosplus10-usbnetcfg.log',
            'StandardErrorPath': '/private/var/log/iosplus10-usbnetcfg.log'})
    else:
        drop_job(root, LABEL_NET)
    print(f'ssh: launchd jobs {LABEL_SSH} ({" ".join(args)}), {LABEL_STATUS}' + (f', {LABEL_NET}' if USB_INTERNET else ''))


def configd(root):
    base = mkdirs(root, 'private/var/preferences/SystemConfiguration')
    path = os.path.join(base, 'preferences.plist')
    prefs = load_plist(path, {'__VERSION__': 20191120})
    ipv4 = {'ConfigMethod': 'Manual', 'Addresses': [PHONE], 'SubnetMasks': ['255.255.255.0']}
    service = {
        'UserDefinedName': 'USB Ethernet',
        'PrimaryRank': 'Last',
        'Interface': {'DeviceName': 'ue0', 'Hardware': 'Ethernet', 'Type': 'Ethernet',
                      'UserDefinedName': 'USB Ethernet'},
        'IPv4': ipv4,
        'IPv6': {'ConfigMethod': 'Automatic'},
        'Proxies': {'ExceptionsList': ['*.local', '169.254/16'], 'FTPPassive': 1},
    }
    if USB_INTERNET:
        ipv4['Router'] = '192.168.7.1'
        service['DNS'] = {'ServerAddresses': ['1.1.1.1', '8.8.8.8']}
    prefs.setdefault('NetworkServices', {})[SERVICE] = service
    sets = prefs.setdefault('Sets', {})
    cur = prefs.get('CurrentSet', '').rsplit('/', 1)[-1] or next(iter(sets), '1F05B0E7-0000-4000-8000-00000000005E')
    s = sets.setdefault(cur, {'UserDefinedName': 'Automatic', 'Network': {}})
    net = s.setdefault('Network', {})
    net.setdefault('Service', {})[SERVICE] = {'__LINK__': '/NetworkServices/' + SERVICE}
    order = net.setdefault('Global', {}).setdefault('IPv4', {}).setdefault('ServiceOrder', [])
    if SERVICE in order:
        order.remove(SERVICE)
    order.append(SERVICE)
    net.setdefault('Interface', {})
    prefs['CurrentSet'] = '/Sets/' + cur
    save_plist(path, prefs)

    path = os.path.join(base, 'NetworkInterfaces.plist')
    ifs = load_plist(path, {'__VERSION__': 20191120})
    lst = [i for i in ifs.get('Interfaces', []) if i.get('BSD Name') != 'ue0']
    lst.append({'BSD Name': 'ue0', 'IOBuiltin': True, 'IOInterfaceNamePrefix': 'ue', 'IOInterfaceType': 6,
                'IOInterfaceUnit': 0, 'IOMACAddress': bytes.fromhex('02005e77ee02'),
                'SCNetworkInterfaceType': 'Ethernet',
                'SCNetworkInterfaceInfo': {'UserDefinedName': 'USB Ethernet'}})
    ifs['Interfaces'] = lst
    save_plist(path, ifs)
    print(f'usbnet: configd service {SERVICE} "USB Ethernet": ue0 {PHONE}/24, last in the order, ' +
          ('router 192.168.7.1, DNS 1.1.1.1 8.8.8.8' if USB_INTERNET else 'no router and no DNS (default route and names stay with Wi-Fi)'))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = os.path.abspath(sys.argv[1])
    if not os.path.isfile(os.path.join(root, 'System/Library/xpc/launchd.plist')):
        sys.exit(f'{root} is not an iOS root (no System/Library/xpc/launchd.plist)')
    need = [os.path.join(IOS, n) for n in TOOLS + ('toybox.applets',)]
    missing = [os.path.basename(p) for p in need if not os.path.isfile(p)]
    if missing:
        sys.exit('ssh: out/ssh/ios is missing ' + ', '.join(missing) + ' (run userland/ssh/build.sh on a Mac)')
    if not IS_ROOT:
        print('warning: not root: files keep your owner (only for tests on a scratch folder)')
    binaries(root)
    key_only = login(root)
    have_hostkey = hostkey(root)
    jobs(root, key_only, have_hostkey)
    configd(root)


if __name__ == '__main__':
    main()
