"""How the host talks to the phone for scripts/laurel/root-update.sh: phone.sh + one call through `sh -s`, and tar on a pipe. docs/laurel_sprout/root-update.md.

ROOT_UPDATE_TRANSPORT: another command instead of phone-ssh.sh (the host test); it gets the remote command as one argument. ROOT_UPDATE_PHONE_ROOT: a folder as the phone's / (the test).
"""
import io
import os
import shlex
import subprocess
import tarfile
import time

ENC = dict(encoding='utf-8', errors='surrogateescape')
END = '__LAUREL_UPDATE_LIST_END__'


def say(text):
    print('root-update: ' + text, flush=True)


class LinkDown(Exception):
    pass


class Phone:
    def __init__(self, repo):
        self.repo = repo
        self.R = os.environ.get('ROOT_UPDATE_PHONE_ROOT', '')
        self.tr = shlex.split(os.environ.get('ROOT_UPDATE_TRANSPORT', '')) or [os.path.join(repo, 'scripts/laurel/phone-ssh.sh')]
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'phone.sh')) as fh:
            self.lib = fh.read()
        self.W = self.R + '/private/var/root/laurel-update'
        self.S = self.W + '/stage'
        self.user_path = 'PATH=${ROOT_UPDATE_PHONE_PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH}; export PATH; '

    def text(self, call, data=None):
        """The whole script of one call. The list goes in as a here-document: nothing is written on the phone."""
        s = 'R=%s\n%s\n%s' % (shlex.quote(self.R), self.lib, call)
        if data is not None:
            s += " <<'%s'\n%s%s\n" % (END, ''.join(x + '\n' for x in data), END)
        return (s + '\n').encode('utf-8', 'surrogateescape')

    def call(self, call, data=None, tries=3, binary=False, check=True):
        """Output of one call. A lost link (exit 255) is tried again: every call that uses this is safe to repeat."""
        for i in range(tries):
            p = subprocess.run(self.tr + ['sh -s'], input=self.text(call, data), stdout=subprocess.PIPE, check=False)
            if p.returncode != 255:
                break
            if i + 1 < tries:
                time.sleep(3 * (i + 1))
        if p.returncode == 255:
            raise LinkDown(call)
        if check and p.returncode != 0:
            raise RuntimeError('%s: exit %d: %s' % (call.split()[0], p.returncode, p.stdout.decode('utf-8', 'replace').strip()[-300:]))
        return p.stdout if binary else p.stdout.decode(**ENC)

    def write_file(self, path, data):
        """Write one small control file in the update folder (not atomic: nothing else reads it)."""
        cmd = '%smkdir -p %s && cat > %s' % (self.user_path, shlex.quote(os.path.dirname(path)), shlex.quote(path))
        p = subprocess.run(self.tr + [cmd], input=data, check=False)
        if p.returncode != 0:
            raise LinkDown('write ' + path)

    def info(self):
        out = {}
        for line in self.call('p_info').splitlines():
            k, _, v = line.partition(' ')
            if k == 'df':
                f = v.split()
                out['df_total'], out['df_avail'] = int(f[1]) << 10, int(f[3]) << 10
            else:
                out[k] = v
        return out

    def pull(self, paths):
        """Small files from the phone -> path -> bytes."""
        if not paths:
            return {}
        data = self.call('p_pull', paths, binary=True, check=False)
        got = {}
        if data:
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as t:
                for m in t:
                    if m.isfile():
                        got[m.name.removeprefix('./')] = t.extractfile(m).read()
        return got

    def stage_put(self, acts, store, log, step=256 << 20):
        """One tar stream, in the stage folder. mtime, mode and owner in the headers (names are empty: --numeric-owner)."""
        cmd = '%smkdir -p %s && tar xpf - -C %s --numeric-owner' % (self.user_path, shlex.quote(self.S), shlex.quote(self.S))
        p = subprocess.Popen(self.tr + [cmd], stdin=subprocess.PIPE)
        sent = mark = 0
        try:
            with tarfile.open(fileobj=p.stdin, mode='w|', format=tarfile.GNU_FORMAT, bufsize=1 << 16) as t:
                for a in acts:
                    ti = tarfile.TarInfo(a.path)
                    ti.mode, ti.uid, ti.gid, ti.mtime = a.mode, a.uid, a.gid, a.mtime
                    if a.kind == 'l':
                        ti.type, ti.linkname = tarfile.SYMTYPE, a.target
                        t.addfile(ti)
                        continue
                    ti.size = a.size
                    if a.data is not None:
                        t.addfile(ti, io.BytesIO(a.data))
                    else:
                        with open(store(a.sha), 'rb') as fh:
                            t.addfile(ti, fh)
                    sent += a.size
                    if sent - mark >= step:
                        mark = sent
                        log('stage: %d MiB sent' % (sent >> 20))
            p.stdin.close()
        except BrokenPipeError:
            pass
        return p.wait() == 0
