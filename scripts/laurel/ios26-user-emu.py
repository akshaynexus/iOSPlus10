#!/usr/bin/env python3
"""Run a lowered iOS 26 daemon on the host from dyld's first instruction: dyld, the lowered cache and the program under Unicorn
(cortex-a72, ARMv8.0 like the phone: no PAC, no LSE). The syscalls and Mach traps are a small fake of the kernel: enough for dyld and the initializers
of the libraries, not for a daemon's work. So it answers one question: does this program reach main()? Host only, nothing here touches a phone.

    scripts/laurel/ios26-user-emu.sh /usr/libexec/runningboardd
    scripts/laurel/test-ios26-user-emu.sh [LOWERED_DIR]      PASS when the programs reach main()

EMU_LOWERED=DIR selects the lowered folder (default: the shared one). Exit 0: reached main(). Exit 3: it did not. See docs/laurel_sprout/ios26-entry.md.
A stop after main() ("int 7" in libdispatch or libxpc, an abort) is normal: this fake kernel has no workqueue and no launchd. Read the first stop only if main() did not run.

--display-create PLIST: at main() of /usr/libexec/backboardd, run CoreBrightness' real DisplayCreateWithCapabilitiesAndID(service, 0, 0, 1) instead of main(). The plist is the registry of the
AppleARMBacklight it reads. IOKit and CFPreferences calls stop at their entry; a property comes from IOKit's real IOCFUnserialize. Blocks that the function queues do not run: it answers for the synchronous part only.
With --container: the frames of the phone's crash: -[CBDisplayContaineriOS handleDisplayArrival:] -> setupInternalModules -> -[CBDisplayModuleiOS initWithBacklight:queue:display:], with no CADisplay (nil).
scripts/laurel/test-ios26-bbd-emu.sh is the test (docs/laurel_sprout/ios26-backboardd.md)."""
import os, struct, sys, time, errno, collections, argparse, bisect, mmap as pymmap, hashlib
from unicorn import *
from unicorn.arm64_const import *

BASE = os.path.expanduser('~/op10-apple/ios26/23F84-n104ap')
LOW = os.environ.get('EMU_LOWERED', BASE + '/lowered')
MACHO = LOW + '/macho'
CACHE = LOW + '/dyld_shared_cache_arm64e'
TREE = BASE + '/tree/root'
ap = argparse.ArgumentParser()
ap.add_argument('exe')
ap.add_argument('--slide', type=lambda s: int(s, 0), default=0x10244000)
ap.add_argument('--exe-slide', type=lambda s: int(s, 0), default=0xf40000)
ap.add_argument('--max', type=int, default=0, help='instruction budget per start, 0 none')
ap.add_argument('--secs', type=int, default=1200)
ap.add_argument('--trace-after', type=int, default=-1, help='after syscall N keep a ring of basic blocks')
ap.add_argument('--trace-size', type=int, default=4000)
ap.add_argument('--verbose', action='store_true')
ap.add_argument('--inits', action='store_true', help='list the images whose initializers ran (slower: a hook on each basic block)')
ap.add_argument('--env', action='append', default=[])
ap.add_argument('--start-cost', action='store_true', help='at main(): instructions from dyld start, and pages written, per area, in 4 KiB and in 16 KiB pages (what a start costs a jetsam limit; slower)')
ap.add_argument('--display-create', metavar='PLIST', help='at main(): run CoreBrightness DisplayCreateWithCapabilitiesAndID, with this plist as the registry of AppleARMBacklight')
ap.add_argument('--hid-event', metavar='JSON', help='at main(): give what the kernel sends for a touch (tools/laurel-hid-test) to the real IOHIDEventCreateWithBytesInternal of IOKit, the call of IOHIDEventServicePlugin, and read it with the real getters')
ap.add_argument('--container', action='store_true', help='with --display-create: the frames of the crash, from [[CBDisplayContaineriOS alloc] initWithBacklightService:] and -start. No CADisplay here: messages to it answer nil')
ap.add_argument('--sandbox-self', action='store_true', help='answer the Sandbox op of sandbox_check(self, NULL, 0) as kernel post/9010 does for a BlastDoor service; log it and the state flag')
ap.add_argument('--blastdoor-gate', action='store_true', help='at main(): run the gate of BlastDoor/Sandbox.swift (0x21825d59c, 23F84): sandbox_check of itself, then the state flag blastdoor-post-launch. Exit 0: it returns. Exit 3: its fatal message')
ap.add_argument('--cpbitmap', metavar='FILE', help='at main(): the real AppSupport CPBitmapCreateImagesFromData on these bytes, as PBUIWallpaperDirectoryDataStore calls it (flags 1). Prints the images. Exit 0: one image, its width and height. Run it with a program that links PaperBoardUI')
args = ap.parse_args()

u32 = lambda b, o: struct.unpack_from('<I', b, o)[0]
u64 = lambda b, o: struct.unpack_from('<Q', b, o)[0]
def op(p):
    f = open(p, 'rb')
    return pymmap.mmap(f.fileno(), 0, access=pymmap.ACCESS_READ)

mu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
mu.ctl_set_cpu_model(UC_CPU_ARM64_A72)

# ---- cache regions ----
SLIDE = args.slide
regions = []  # (unslid addr, size, fileoff, buf, slideinfo buf offset or None, slide_size)
m0 = op(CACHE)
files = [m0]
def addmaps(b):
    so, sc = u32(b, 0x138), u32(b, 0x13c)
    for i in range(sc):
        e = so + i * 56
        a, s, fo, sio, sis, fl = struct.unpack_from('<QQQQQQ', b, e)
        regions.append((a, s, fo, b, sio if sis else None, sis))
addmaps(m0)
subo, subc = u32(m0, 0x188), u32(m0, 0x18c)
for i in range(subc):
    e = subo + i * 56
    suf = m0[e + 24:e + 56].split(b'\0')[0].decode() or '.%02d' % (i + 1)
    b = op(CACHE + suf)
    files.append(b)
    addmaps(b)
regions.sort(key=lambda r: r[0])
reg_start = [r[0] for r in regions]
SR_START = regions[0][0]
print('cache regions', len(regions), hex(SR_START), hex(regions[-1][0] + regions[-1][1]))

mapped = set()

def map_cache_page(addr):
    """Map the 16 KiB unit that holds addr (slid), slide applied. Returns True when it belongs to the cache."""
    un = addr - SLIDE
    i = bisect.bisect_right(reg_start, un) - 1
    if i < 0:
        return False
    a, s, fo, b, sio, sis = regions[i]
    if not (a <= un < a + s):
        return False
    pg = un & ~0x3fff
    if pg in mapped:
        return False
    # a unit can straddle two mappings only at 16 KiB borders: cache mappings are 16 KiB aligned
    off = pg - a
    data = bytearray(b[fo + off:fo + off + 0x4000])
    data += bytes(0x4000 - len(data))
    if sio is not None:
        ver, pgsz, cnt = struct.unpack_from('<III', b, sio)
        assert ver == 5, ver
        value_add = u64(b, sio + 16)
        idx = off // pgsz
        if idx < cnt:
            start = struct.unpack_from('<H', b, sio + 24 + idx * 2)[0]
            if start != 0xffff:
                p = start
                while True:
                    raw = struct.unpack_from('<Q', data, p)[0]
                    nxt = (raw >> 52) & 0x7ff
                    auth = raw >> 63
                    ro = raw & 0x3ffffffff
                    val = value_add + ro + SLIDE
                    if not auth:
                        val |= ((raw >> 34) & 0xff) << 56
                    struct.pack_into('<Q', data, p, val & 0xffffffffffffffff)
                    if nxt == 0:
                        break
                    p += nxt * 8
    mu.mem_map(pg + SLIDE, 0x4000, UC_PROT_ALL)
    mu.mem_write(pg + SLIDE, bytes(data))
    mapped.add(pg)
    return True

# ---- symbols of the cache images ----
images = []
io, ic = u32(m0, 0x1c0), u32(m0, 0x1c4)
for i in range(ic):
    e = io + i * 32
    p = m0[u32(m0, e + 24):u32(m0, e + 24) + 400].split(b'\0')[0].decode()
    images.append((u64(m0, e), p))
images.sort()
img_start = [a for a, _ in images]
def where(pc):
    un = pc - SLIDE
    if SR_START <= un < regions[-1][0] + regions[-1][1]:
        i = bisect.bisect_right(img_start, un) - 1
        return '%s+0x%x (unslid 0x%x)' % (os.path.basename(images[i][1]), un - images[i][0], un)
    if EXE <= pc < EXE + 0x4000000:
        return 'main+0x%x' % (pc - EXE)
    if DYLD <= pc < DYLD + 0x200000:
        return 'dyld+0x%x' % (pc - DYLD)
    return '?'

# ---- file system ----
def resolve(path):
    p = path.lstrip('/')
    if p.startswith('private/preboot') or p.startswith('private/var') or p.startswith('var/') or p.startswith('dev') or p.startswith('tmp'):
        return None
    if p.startswith('System/Library/Caches/com.apple.dyld/'):
        q = LOW + '/' + os.path.basename(p)
        return q if os.path.exists(q) else None
    if p.startswith('System/Cryptexes/OS/'):
        p = p[len('System/Cryptexes/OS/'):]
    for r in (MACHO + '/os', MACHO + '/sys', TREE + '/os', TREE + '/sys'):
        q = os.path.join(r, p)
        if os.path.exists(q):
            return q
    return None

# ---- load Mach-O ----
def macho_info(path):
    b = open(path, 'rb').read()
    n = u32(b, 16)
    off = 32
    segs = []
    entry = None
    for i in range(n):
        c, s = struct.unpack_from('<II', b, off)
        if c == 0x19:
            name = b[off + 8:off + 24].split(b'\0')[0].decode()
            vm, vs, fo, fs = struct.unpack_from('<QQQQ', b, off + 24)
            segs.append((name, vm, vs, fo, fs))
        elif c == 0x80000028:
            entry = u64(b, off + 8)
        off += s
    return b, segs, entry

def map_any(a, size):
    a0 = a & ~0xfff
    e = (a + size + 0xfff) & ~0xfff
    p = a0
    while p < e:
        try:
            mu.mem_map(p, 0x1000, UC_PROT_ALL)
        except UcError:
            pass
        p += 0x1000

def load(path, base):
    b, segs, entry = macho_info(path)
    for name, vm, vs, fo, fs in segs:
        if name == '__PAGEZERO':
            continue
        a = vm - segs[0 if segs[0][0] != '__PAGEZERO' else 1][1] + base
        map_any(a, vs)
        mu.mem_write(a, b[fo:fo + fs])
    return entry

EXE_PATH = args.exe
exe_host = resolve(EXE_PATH)
assert exe_host, EXE_PATH
EXE = 0x100000000 + args.exe_slide
main_entry = load(exe_host, EXE)
DYLD = 0x102000000 + args.exe_slide
load(resolve('/usr/lib/dyld'), DYLD)
print('main', hex(EXE), 'entryoff', main_entry, 'dyld', hex(DYLD))

# commpage
CP = 0xfffffc000
mu.mem_map(CP, 0x1000, UC_PROT_ALL)
cp = bytearray(0x1000)
cp[0:16] = b'commpage 64-bit\0'
struct.pack_into('<H', cp, 0x1e, 3)
cp[0x22] = 8
cp[0x24] = 12
cp[0x25] = 12
struct.pack_into('<H', cp, 0x26, 64)
cp[0x2f] = 2
cp[0x34] = 8; cp[0x35] = 8; cp[0x36] = 8; cp[0x37] = 12
struct.pack_into('<Q', cp, 0x38, 0x180000000)
struct.pack_into('<I', cp, 0x80, 0x07d34b9f)
struct.pack_into('<Q', cp, 0x160, 0x8)
mu.mem_write(CP, bytes(cp))
mu.mem_map(0xfffff4000, 0x1000, UC_PROT_ALL)
mu.mem_write(0xfffff4000, bytes(cp))

# dynamic region of the shared region: dyld of the first process writes it, the kernel maps it behind the cache
DYN = SR_START + SLIDE + u64(m0, 0x1f0)
mu.mem_map(DYN, 0x4000, UC_PROT_ALL)
d = bytearray(0x4000)
d[0:16] = b'dyld_data    v2\0'
struct.pack_into('<IIQ', d, 0x10, 0x1000004, 0, 12345)
struct.pack_into('<I', d, 0x24, 0x80)
d[0x80:0x80 + 64] = b'/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e\0\0'
mu.mem_write(DYN, bytes(d))

# stack
STACK_TOP = 0x16fe00000 - args.exe_slide
STACK_SIZE = 0x800000
mu.mem_map(STACK_TOP - STACK_SIZE, STACK_SIZE, UC_PROT_ALL)
sp = STACK_TOP
argv = [EXE_PATH]
envp = ['XPC_SERVICE_NAME=com.apple.runningboardd', 'XPC_FLAGS=1', 'PATH=/usr/bin:/bin:/usr/sbin:/sbin', 'HOME=/var/root', 'USER=root', 'LOGNAME=root', 'SHELL=/bin/sh', 'TMPDIR=/var/tmp/', '__CF_USER_TEXT_ENCODING=0x0:0:0'] + args.env
apple = ['executable_path=' + EXE_PATH, 'stack_guard=0x12345678abcd0000', 'malloc_entropy=0x1122334455667788,0x99aabbccddeeff00', 'ptr_munge=0x5566778899001122', 'main_stack=0x%x,0x800000,0x%x,0x200000' % (STACK_TOP, STACK_TOP - 0x800000 - 0x200000), 'executable_file=0x10,0x20', 'dyld_file=0x10,0x21', 'executable_cdhash=' + '11' * 20, 'th_port=0x103', 'executable_boothash=' + '22' * 20]
strs = {}
blob = b''
def put(s):
    global blob
    o = len(blob)
    blob += s.encode() + b'\0'
    return o
av = [put(x) for x in argv]
ev = [put(x) for x in envp]
pv = [put(x) for x in apple]
strbase = (STACK_TOP - len(blob) - 16) & ~0xf
mu.mem_write(strbase, blob)
words = [EXE, len(argv)] + [strbase + o for o in av] + [0] + [strbase + o for o in ev] + [0] + [strbase + o for o in pv] + [0]
sp = (strbase - 8 * len(words)) & ~0xf
mu.mem_write(sp, b''.join(struct.pack('<Q', w) for w in words))
mu.reg_write(UC_ARM64_REG_SP, sp)
print('sp', hex(sp), 'depth', hex(STACK_TOP - sp))
# enable FP
mu.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20)

# TSD and scratch arenas
ARENA = [0x300000000]
def anon(size, mask=0):
    size = (size + 0xfff) & ~0xfff
    a = ARENA[0]
    a = (a + mask) & ~mask
    ARENA[0] = a + size + 0x4000
    # A guarded malloc range can be many GiB: the first part now, the rest at its first access (hook_unmapped)
    mu.mem_map(a, min(size, 0x10000000), UC_PROT_ALL)
    return a

fds = {}
next_fd = [3]
ports = [0x1000]
sc_count = [0]
sc_hist = collections.Counter()
trace = collections.deque(maxlen=args.trace_size)
emu_undef = collections.Counter()
stop_reason = [None]
pending = [None]

def guest_write(a, data):
    mu.mem_write(a, data)

def rdstr(a, n=1024):
    out = b''
    while len(out) < n:
        try:
            c = bytes(mu.mem_read(a + len(out), 1))
        except UcError:
            map_cache_page(a + len(out))
            c = bytes(mu.mem_read(a + len(out), 1))
        if c == b'\0':
            break
        out += c
    return out.decode(errors='replace')

def x(i): return mu.reg_read(UC_ARM64_REG_X0 + i) if i <= 28 else None
def setx(i, v): mu.reg_write(UC_ARM64_REG_X0 + i, v & 0xffffffffffffffff)
NZCV_C = 1 << 29
def ret_ok(v=0, v1=None):
    setx(0, v)
    if v1 is not None:
        setx(1, v1)
    mu.reg_write(UC_ARM64_REG_NZCV, mu.reg_read(UC_ARM64_REG_NZCV) & ~NZCV_C)
def ret_err(e):
    setx(0, e)
    mu.reg_write(UC_ARM64_REG_NZCV, mu.reg_read(UC_ARM64_REG_NZCV) | NZCV_C)

def stat_buf(st):
    # struct stat64 darwin arm64: dev i32, mode u16, nlink u16, ino u64, uid, gid, rdev, pad, atime, mtime, ctime, birthtime (ts each 16), size i64, blocks i64, blksize i32, flags u32, gen u32, ...
    b = bytearray(144)
    struct.pack_into('<iHHQIIi', b, 0, 0x1000004, 0o100755 if os.path.isfile(st[0]) else 0o40755, 1, st[1].st_ino, 0, 0, 0)
    struct.pack_into('<q', b, 96, st[1].st_size)
    struct.pack_into('<q', b, 104, (st[1].st_size + 511) // 512)
    struct.pack_into('<i', b, 112, 4096)
    return bytes(b)

def dosysctl(name_ptr, namelen, old, oldlenp, new, newlen):
    mib = [u32(mu.mem_read(name_ptr + 4 * i, 4), 0) for i in range(namelen)]
    return mib

def svc():
    n = mu.reg_read(UC_ARM64_REG_X16)
    n &= 0xffffffff
    if n != 0x80000000 and n & 0x80000000:
        n -= 1 << 32
    sc_count[0] += 1
    sc_hist[n] += 1
    if time.time() - t0 > args.secs:
        stop_reason[0] = 'time limit %d s' % args.secs
        mu.emu_stop()
        return
    if args.trace_after >= 0 and sc_count[0] == args.trace_after:
        enable_trace()
    pc = mu.reg_read(UC_ARM64_REG_PC)
    if args.verbose:
        print('svc#%d n=%d x0=%x x1=%x x2=%x x3=%x pc=%s' % (sc_count[0], n, x(0), x(1), x(2), x(3), where(pc)))
    if n == 0x80000000:
        if x(3) == 2:
            mu.reg_write(UC_ARM64_REG_TPIDRRO_EL0, x(0))
            if args.verbose: print('tsd base', hex(x(0)))
        ret_ok(0)
        return
    if n < 0:
        return mach_trap(-n)
    return bsd(n)

def mach_trap(n):
    if n in (26, 27, 28, 29, 50):
        ports[0] += 4
        return setx(0, {27: 0x103, 28: 0x203, 29: 0x303}.get(n, ports[0]))
    if n == 47:
        return mach_msg2()
    if n in (31, 32):
        print('mach_msg trap', n, 'pc', where(mu.reg_read(UC_ARM64_REG_PC)), 'lr', where(mu.reg_read(UC_ARM64_REG_LR)))
        return setx(0, 0x10000003)
    if n == 10:  # mach_vm_allocate(task, addr*, size, flags)
        a = anon(x(2))
        mu.mem_write(x(1), struct.pack('<Q', a))
        return setx(0, 0)
    if n in (12, 14, 16, 18, 19, 21, 22, 25):
        if n == 16:
            ports[0] += 4
            mu.mem_write(x(2), struct.pack('<I', ports[0]))
        return setx(0, 0)
    if n == 15:  # mach_vm_map(task, addr*, size, mask, flags, cur)
        fl = x(4)
        if fl & 1:
            a = anon(x(2), x(3))
        else:
            a = u64(mu.mem_read(x(1), 8), 0)
            map_any(a, x(2))
        mu.mem_write(x(1), struct.pack('<Q', a))
        return setx(0, 0)
    if n == 24:  # port construct
        ports[0] += 4
        mu.mem_write(x(3), struct.pack('<I', ports[0]))
        return setx(0, 0)
    if n in (3, 4):
        return setx(0, int(time.monotonic() * 19200000))
    print('mach trap', n)
    return setx(0, 0)

mig_seen = collections.Counter()
PORT_REPLY = {206, 412, 3409, 3418, 3216, 3218, 3201}
def caller_chain(n):
    f = mu.reg_read(UC_ARM64_REG_FP)
    out = []
    for i in range(n):
        try:
            a, b = struct.unpack('<QQ', mu.mem_read(f, 16))
        except UcError:
            break
        out.append(where(b))
        f = a
    return out
def mach_msg2():
    buf, opts, bits_size, remote_local, voucher_id, id_rcv, rcv_to = x(0), x(1), x(2), x(3), x(4), x(5), x(6)
    msgh_id = voucher_id >> 32
    size = bits_size >> 32
    rcv = id_rcv >> 32
    remote = remote_local & 0xffffffff
    local = remote_local >> 32
    mig_seen[(remote, msgh_id)] += 1
    if args.verbose: print('mig port 0x%x id %d size %d rcv %d lr %s' % (remote, msgh_id, size, rcv, where(mu.reg_read(UC_ARM64_REG_LR))), 'caller', caller_chain(3))
    if not (opts & 2):  # no receive
        return setx(0, 0)
    if not (opts & 1):  # receive only: this fake kernel has nobody to send
        return setx(0, 0x10004003)
    body = bytes(mu.mem_read(buf, min(size, 256)))
    rep = bytearray(36)
    struct.pack_into('<IIIIII', rep, 0, 0x1200, 36, 0, local, 0, msgh_id + 100)
    struct.pack_into('<II', rep, 24, 0, 0x100 << 8)
    rc = 0
    if msgh_id == 200:  # host_info(flavor)
        flavor, cnt = struct.unpack_from('<II', body, 32)
        info = [0] * cnt
        if flavor == 5:   # HOST_PRIORITY_INFO
            info = [47, 47, 63, 63, 31, 0, 95, 79][:cnt]
        elif flavor == 1:  # HOST_BASIC_INFO
            info = [8, 8, 0x80000000, 0x100000c, 2, 0, 0, 0, 0, 0, 0, 0][:cnt]
        rep = bytearray(40 + 4 * cnt)
        struct.pack_into('<IIIIII', rep, 0, 0x1200, len(rep), 0, local, 0, msgh_id + 100)
        struct.pack_into('<II', rep, 24, 0, 0x100 << 8)
        struct.pack_into('<ii', rep, 32, 0, cnt)
        struct.pack_into('<%dI' % cnt, rep, 40, *info)
    elif msgh_id == 4811:
        body = bytes(mu.mem_read(buf, 100))
        addr, sz, mask, flags = struct.unpack_from('<QQQI', body, 48)
        if flags & 1:
            a = anon(sz, mask)
        else:
            a = addr
            map_any(a, sz)
        rep = bytearray(44)
        struct.pack_into('<IIIIII', rep, 0, 0x1200, 44, 0, local, 0, msgh_id + 100)
        struct.pack_into('<II', rep, 24, 0, 0x100 << 8)
        struct.pack_into('<iQ', rep, 32, 0, a) if False else (struct.pack_into('<i', rep, 32, 0), struct.pack_into('<Q', rep, 36, a))
    elif msgh_id in PORT_REPLY:
        ports[0] += 4
        rep = bytearray(40)
        struct.pack_into('<IIIIII', rep, 0, 0x80001200, 40, 0, local, 0, msgh_id + 100)
        struct.pack_into('<I', rep, 24, 1)
        struct.pack_into('<IIHBB', rep, 28, ports[0], 0, 0, 17, 0)
    else:
        struct.pack_into('<i', rep, 32, rc)
    mu.mem_write(buf, bytes(rep))
    return setx(0, 0)

def bsd(n):
    if n == 1:
        stop_reason[0] = 'exit(%d)' % x(0)
        mu.emu_stop(); return
    if n == 3 or n == 153:  # read, pread
        f = fds.get(x(0))
        if f is None:
            return ret_err(errno.EBADF)
        off = x(3) if n == 153 else f['pos']
        d = os.pread(f['fd'], x(2), off)
        guest_write(x(1), d)
        if n == 3:
            f['pos'] += len(d)
        return ret_ok(len(d))
    if n == 4 or n == 397:
        d = bytes(mu.mem_read(x(1), x(2)))
        print('WRITE fd', x(0), d[:400])
        return ret_ok(x(2))
    if n in (5, 463):  # open, openat
        pa = x(1) if n == 463 else x(0)
        path = rdstr(pa)
        if args.verbose: print('open raw', hex(pa), repr(path))
        h = resolve(path)
        if args.verbose: print('open', path, '->', 'ok' if h else 'ENOENT')
        if not h:
            return ret_err(errno.ENOENT)
        fd = next_fd[0]; next_fd[0] += 1
        fl = os.O_RDONLY
        if os.path.isdir(h):
            fl |= os.O_DIRECTORY
        fds[fd] = {'fd': os.open(h, fl), 'pos': 0, 'path': path, 'host': h}
        return ret_ok(fd)
    if n == 6:
        f = fds.pop(x(0), None)
        if f:
            os.close(f['fd'])
        return ret_ok(0)
    if n in (338, 339, 340, 470, 188, 189, 190, 169 + 10000):  # stat64 fstat64 lstat64 fstatat64 stat fstat lstat
        if n in (339, 189):
            f = fds.get(x(0))
            if f is None:
                return ret_err(errno.EBADF)
            h = f['host']; buf = x(1)
        elif n == 470:
            h = resolve(rdstr(x(1))); buf = x(2)
        else:
            h = resolve(rdstr(x(0))); buf = x(1)
        if not h:
            return ret_err(errno.ENOENT)
        mu.mem_write(buf, stat_buf((h, os.stat(h))))
        return ret_ok(0)
    if n == 197:  # mmap
        addr, ln, prot, fl, fd, off = x(0), x(1), x(2), x(3), x(4), x(5)
        fd = fd & 0xffffffff
        if fl & 0x10 and addr:  # MAP_FIXED
            map_any(addr, ln)
            a = addr
        else:
            a = anon(ln)
        if not (fl & 0x1000) and fd in fds:
            d = os.pread(fds[fd]['fd'], ln, off)
            guest_write(a, d)
        return ret_ok(a)
    if n in (73, 74, 75, 65):
        return ret_ok(0)
    if n == 92:  # fcntl
        cmd = x(1)
        if cmd == 97 or cmd == 59 or cmd == 61:  # F_ADDFILESIGS_RETURN etc
            return ret_ok(0)
        if cmd == 98:
            return ret_ok(0)
        return ret_ok(0)
    if n == 427:  # fsgetpath(buf, size, fsid, objid)
        obj = x(3)
        path = {0x20: EXE_PATH, 0x21: '/usr/lib/dyld', 12345: '/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e'}.get(obj)
        if path is None:
            return ret_err(errno.ENOENT)
        mu.mem_write(x(0), path.encode() + b'\0')
        return ret_ok(len(path) + 1)
    if n == 294:  # shared_region_check_np
        if x(0) == 0xffffffffffffffff:
            return ret_ok(0)
        mu.mem_write(x(0), struct.pack('<Q', SR_START + SLIDE))
        if args.verbose: print('shared_region_check_np ->', hex(SR_START + SLIDE))
        return ret_ok(0)
    if n in (20,):
        return ret_ok(27)
    if n in (24, 25, 43, 47, 327):
        return ret_ok(0)
    if n == 381:  # __mac_syscall
        pol = rdstr(x(0))
        if args.verbose: print('mac_syscall', pol, x(1))
        if pol == 'AMFI' and x(1) == 0x5a:
            mu.mem_write(x(2), struct.pack('<Q', 0xff))
            return ret_ok(0)
        if pol == 'Sandbox':
            # Kernel post/9010: sandbox_check(self, NULL, 0) of a process with com.apple.private.security.enable-state-flags. args: { u64 *result; i64 pid; const char *operation; ... }
            if args.sandbox_self and x(1) == 2:
                res, pid, op_ = struct.unpack('<QQQ', bytes(mu.mem_read(x(2), 24)))
                print('sandbox_check pid %d operation %#x' % (pid, op_))
                if op_ == 0:
                    mu.mem_write(res, struct.pack('<Q', 1))
            if args.sandbox_self and x(1) == 0x41:
                print('sandbox_enable_state_flag %r' % rdstr(struct.unpack('<Q', bytes(mu.mem_read(x(2) + 16, 8)))[0]))     # args { pid, idversion, name }: libsystem_sandbox 0x2a3534df8
            return ret_ok(0)
        return ret_err(errno.ENOSYS)
    if n == 500:  # getentropy
        mu.mem_write(x(0), (hashlib.sha256(b'x').digest() * (x(1) // 32 + 1))[:x(1)])
        return ret_ok(0)
    if n == 372:
        return ret_ok(0x1234)
    if n == 366:  # bsdthread_register
        if args.verbose: print('bsdthread_register start', where(x(0)), 'wq', where(x(1)), 'size', hex(x(2)))
        return ret_ok(0x4000003f | 0x80)
    if n in (177, 178, 179, 180, 181, 182, 183, 184, 185):
        return ret_ok(0)
    if n == 169 or n == 170:  # csops
        ops = x(1)
        if ops == 0:  # status
            mu.mem_write(x(2), struct.pack('<I', 0x24000001 | 0x4000))
            return ret_ok(0)
        return ret_err(errno.EINVAL)
    if n == 336 and x(0) == 2 and x(5):  # proc_info(PROC_INFO_CALL_PIDINFO, pid, flavor, arg, buffer, size): a zero answer of the size asked
        mu.mem_write(x(4), bytes(x(5)))
        return ret_ok(x(5))
    if n in (515, 516, 46, 48, 329, 54, 446, 194, 195, 116, 336, 337, 494, 220, 301, 302, 303, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313, 334):
        if n == 116:
            return ret_ok(0)
        return ret_ok(0)
    if n in (202, 274):
        return sysctl(n)
    if n in (520, 521, 435):  # terminate_with_payload, abort_with_payload
        print('abort_with_payload', n, hex(x(0)), hex(x(1)), rdstr(x(4)) if x(4) else '')
        stop_reason[0] = 'abort_with_payload'
        mu.emu_stop(); return
    if n == 37 or n == 328:
        print('kill/pthread_kill', n, x(0), x(1))
        for i in range(19, 29):
            v = x(i)
            try:
                if 0x180000000 < v < 0x2d0000000:
                    print(' x%d string %r' % (i, rdstr(v, 200)))
            except Exception:
                pass
        stop_reason[0] = 'kill'
        mu.emu_stop(); return
    if args.verbose: print('unknown syscall', n, hex(x(0)), hex(x(1)), hex(x(2)), 'pc', where(mu.reg_read(UC_ARM64_REG_PC)))
    if args.display_create and reached[0] and n != 1:  # workqueue, kevent: libdispatch asks for a thread or a timer. Blocks stay on their queues, timers do not fire
        fake_calls['syscall %d' % n] += 1
        return ret_ok(0)
    return ret_err(errno.ENOSYS)

SYSCTL_NAMES = {'hw.pagesize': 4096, 'hw.ncpu': 8, 'hw.activecpu': 8, 'hw.logicalcpu': 8, 'hw.physicalcpu': 8, 'hw.cputype': 0x100000c, 'hw.cpusubtype': 2, 'hw.memsize': 0x180000000, 'kern.argmax': 262144, 'hw.pagesize32': 4096, 'hw.cachelinesize': 64, 'hw.cpufamily': 0x07d34b9f}
def sysctl(n):
    if n == 274:
        name = rdstr(x(0))
        old, oldlenp, new, newlen = x(2), x(3), x(4), x(5)
    else:
        mib = [u32(mu.mem_read(x(0) + 4 * i, 4), 0) for i in range(x(1))]
        name = str(mib)
        old, oldlenp, new, newlen = x(2), x(3), x(4), x(5)
    if args.verbose: print('sysctl', name)
    if name in SYSCTL_NAMES and old and oldlenp:
        l = u64(mu.mem_read(oldlenp, 8), 0)
        v = SYSCTL_NAMES[name]
        if l >= 8:
            mu.mem_write(old, struct.pack('<Q', v)); mu.mem_write(oldlenp, struct.pack('<Q', 8))
        else:
            mu.mem_write(old, struct.pack('<I', v)); mu.mem_write(oldlenp, struct.pack('<Q', 4))
        return ret_ok(0)
    return ret_err(errno.ENOENT)

def hook_intr(uc, intno, ud):
    if intno == 2:
        try:
            svc()
        except Exception as e:
            import traceback
            traceback.print_exc()
            stop_reason[0] = 'emulator bug'
            uc.emu_stop()
        return
    pc = uc.reg_read(UC_ARM64_REG_PC)
    w = bytes(uc.mem_read(pc, 4)) if pc else b''
    i = struct.unpack('<I', w)[0] if w else 0
    if intno == 1 and (i & 0xFEFFF800) in (0xD61F0800, 0xD63F0800):
        rn = (i >> 5) & 31
        tgt = uc.reg_read(UC_ARM64_REG_X0 + rn) if rn <= 28 else (uc.reg_read(UC_ARM64_REG_FP) if rn == 29 else uc.reg_read(UC_ARM64_REG_LR))
        emu_undef['pacbr %s' % where(pc)] += 1
        if (i & 0xFEFFF800) == 0xD63F0800:
            uc.reg_write(UC_ARM64_REG_LR, pc + 4)
        pending[0] = tgt
        uc.emu_stop()
        return
    if intno == 1 and i in (0xD65F0BFF, 0xD65F0FFF):
        emu_undef['ret %s word %x' % (where(pc), i)] += 1
        pending[0] = uc.reg_read(UC_ARM64_REG_LR)
        uc.emu_stop()
        return
    print('INT', intno, 'pc', hex(pc), where(pc), w.hex())
    if intno == 7:
        for r in range(0, 29):
            v = x(r)
            if 0x100000000 < v < 0x2d0000000:
                try:
                    t = rdstr(v, 200)
                    if len(t) > 3 and t.isprintable():
                        print(' x%d string %r' % (r, t))
                except Exception:
                    pass
    stop_reason[0] = 'int %d pc %x word %s' % (intno, pc, w[::-1].hex())
    uc.emu_stop()

def hook_unmapped(uc, access, addr, size, value, ud):
    if map_cache_page(addr):
        return True
    if 0x300000000 <= addr < ARENA[0]:
        p = addr & ~0xffffff
        for i in range(0, 0x1000000, 0x1000):
            try:
                mu.mem_map(p + i, 0x1000, UC_PROT_ALL)
            except UcError:
                pass
        return True
    if access in (UC_MEM_READ_UNMAPPED, UC_MEM_WRITE_UNMAPPED) and 0xfc0000000 <= addr < 0x1000000000:
        map_any(addr, 8); return True
    print('FAULT access', access, 'addr', hex(addr), 'pc', hex(uc.reg_read(UC_ARM64_REG_PC)), 'lr', hex(uc.reg_read(UC_ARM64_REG_LR)))
    stop_reason[0] = 'fault %x' % addr
    return False

INIT_BL = 0x18017f958 + SLIDE   # dyld in the cache: block with the blr of an initializer
last_block = [0]
inits = []
def hook_block(uc, addr, size, ud):
    trace.append(addr)
    if last_block[0] == INIT_BL:
        inits.append(addr)
    last_block[0] = addr

hb = [None]
def enable_trace():
    if hb[0] is None:
        hb[0] = mu.hook_add(UC_HOOK_BLOCK, hook_block)
        print('trace on at syscall', sc_count[0])

reached = [False]
def hook_main(uc, addr, size, ud):
    if not reached[0]:
        reached[0] = True
        s = uc.reg_read(UC_ARM64_REG_SP)
        print('reached main(): pc %s, sp 0x%x (0x%x below the stack top), %d syscalls' % (where(addr), s, STACK_TOP - s, sc_count[0]))
        if args.start_cost:
            start_cost_report()
        if args.display_create:
            display_create_start(uc)
        if args.hid_event:
            hid_event_start(uc)
        if args.blastdoor_gate:
            blastdoor_gate_start(uc)
        if args.cpbitmap:
            cpbitmap_start(uc)
written, insns = set(), [0]
def start_cost_report():
    # the area of an address: where() names an image or says '?'; cache images have 'unslid' in their name
    areas = collections.defaultdict(set)
    for pg in written:
        w = where(pg << 12)
        a = 'program' if w.startswith('main') else 'dyld' if w.startswith('dyld') else 'cache data' if 'unslid' in w else 'stack' if STACK_TOP - (1 << 24) <= (pg << 12) < STACK_TOP else 'heap and the rest'
        areas[a].add(pg)
    print('start-cost: %d instructions to main(), %d KiB written in 4 KiB pages, %d KiB in 16 KiB pages' % (insns[0], 4 * len(written), 16 * len({p >> 2 for p in written})))
    for a, pages in sorted(areas.items(), key=lambda kv: -len(kv[1])):
        print('start-cost:   %-18s %6d KiB in 4 KiB pages %6d KiB in 16 KiB pages' % (a, 4 * len(pages), 16 * len({p >> 2 for p in pages})))
if args.start_cost:
    def hook_written(uc, access, addr, size, value, ud):
        written.add(addr >> 12)
        written.add((addr + size - 1) >> 12)
    def hook_counted(uc, addr, size, ud):
        if not reached[0]:
            insns[0] += size >> 2
    mu.hook_add(UC_HOOK_MEM_WRITE, hook_written)
    mu.hook_add(UC_HOOK_BLOCK, hook_counted)
mu.hook_add(UC_HOOK_CODE, hook_main, begin=EXE + main_entry, end=EXE + main_entry + 3)
mu.hook_add(UC_HOOK_INTR, hook_intr)
mu.hook_add(UC_HOOK_MEM_UNMAPPED, hook_unmapped)
if args.trace_after == 0 or args.inits:
    enable_trace()

# ---- --display-create: the real CoreBrightness function, with a fake IOKit at the function level ----
UNTIL = 0x2f0000000     # the fake return address of the function
SERVICE = 0x1234        # the io_object_t of AppleARMBacklight
fake_calls = collections.Counter()
display_result = [None]

def guest_read(a, n):
    p = a & ~0x3fff
    while p < a + n:
        map_cache_page(p)
        p += 0x4000
    return bytes(mu.mem_read(a, n))

def cf_const_string(a):
    """A constant CFString of the cache: isa, flags, pointer, length."""
    if not a:
        return ''
    w = guest_read(a, 32)
    ptr, n = u64(w, 16) & 0xfffffffff, u64(w, 24)
    return guest_read(ptr, n).decode(errors='replace') if ptr and n < 256 else '?'

def serialize(v):
    """A plist value as the XML of IOCFUnserialize."""
    import base64
    if isinstance(v, bool):
        return '<true/>' if v else '<false/>'
    if isinstance(v, int):
        return '<integer size="32">0x%x</integer>' % (v & 0xffffffff)
    if isinstance(v, bytes):
        return '<data>%s</data>' % base64.b64encode(v).decode()
    if isinstance(v, str):
        return '<string>%s</string>' % v
    if isinstance(v, dict):
        return '<dict>' + ''.join('<key>%s</key>%s' % (k, serialize(x)) for k, x in v.items()) + '</dict>'
    raise SystemExit('no XML for %r' % (v,))

def ret_now(uc, v):
    setx(0, v)
    pending[0] = uc.reg_read(UC_ARM64_REG_LR)
    uc.emu_stop()

def display_create_start(uc):
    """At main(): every hook, then the call. Addresses from the symbols of the original cache: the lowered one has the same layout."""
    import importlib.util, plistlib
    sp_ = importlib.util.spec_from_file_location('dsc_image', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dsc-image.py'))
    dsc = importlib.util.module_from_spec(sp_)
    sp_.loader.exec_module(dsc)
    c = dsc.Cache(BASE + '/tree/cache')
    def syms(part):
        return {n: a for a, k, n in dsc.symbols(c, c.find(part)[0])}
    iokit = syms('IOKit.framework/Versions/A/IOKit')
    cf = syms('CoreFoundation.framework/CoreFoundation')
    trace_ = syms('libsystem_trace.dylib')
    cb = syms('CoreBrightness.framework/CoreBrightness')
    props = plistlib.load(open(args.display_create, 'rb'))
    unser = iokit['_IOCFUnserialize'] + SLIDE

    def prop(uc, name, key, alloc):
        k = cf_const_string(key)
        if k in props:
            fake_calls['%s %s: found' % (name, k)] += 1
            xml = anon(0x10000)
            mu.mem_write(xml, serialize(props[k]).encode() + b'\0')
            setx(0, xml); setx(1, alloc); setx(2, 0); setx(3, 0)
            pending[0] = unser
            uc.emu_stop()
        else:
            fake_calls['%s %s: none' % (name, k)] += 1
            ret_now(uc, 0)
    def hook(name, fn):
        a = iokit.get(name, 0) or cf.get(name, 0) or trace_.get(name, 0)
        if not a:
            print('no symbol', name)
            return
        mu.hook_add(UC_HOOK_CODE, lambda uc, ad, sz, ud: fn(uc), begin=a + SLIDE, end=a + SLIDE + 3)
    hook('_IORegistryEntrySearchCFProperty', lambda uc: prop(uc, 'search', x(2), x(3)))
    hook('_IORegistryEntryCreateCFProperty', lambda uc: prop(uc, 'read', x(1), x(2)))
    def counted(name, v):
        def f(uc):
            fake_calls[name] += 1
            ret_now(uc, v)
        hook(name, f)
    # A set is a write to the driver, and the function must not fail on it. Each call is counted for the report.
    def set_prop(uc):
        fake_calls['set %s' % cf_const_string(x(1))] += 1
        ret_now(uc, 0)
    hook('_IORegistryEntrySetCFProperty', set_prop)
    for n in ('_IORegistryEntrySetCFProperties', '_IOObjectRetain', '_IOObjectRelease', '_IOConnectRelease', '_IOServiceClose', '_IONotificationPortCreate', '_IONotificationPortSetDispatchQueue', '_IOServiceAddMatchingNotification', '_IOServiceAddInterestNotification',
              '_IOServiceGetMatchingService', '_IOServiceGetMatchingServices', '_IORegistryEntryFromPath', '_IOIteratorNext', '_IOServiceOpen', '_IOConnectCallMethod', '_IOConnectCallScalarMethod', '_IORegistryEntryGetRegistryEntryID',
              '_CFPreferencesCopyAppValue', '_CFPreferencesCopyValue', '_CFPreferencesCopyMultiple', '_CFPreferencesGetAppBooleanValue', '_CFPreferencesGetAppIntegerValue',
              '_os_log_type_enabled'):
        counted(n, 0)
    def conforms(uc):
        k = rdstr(x(1))
        fake_calls['_IOObjectConformsTo %s' % k] += 1
        ret_now(uc, 1 if k in ('AppleARMBacklight', 'IOService', 'IORegistryEntry') else 0)
    hook('_IOObjectConformsTo', conforms)
    for n in ('_CFPreferencesAppSynchronize', '_CFPreferencesSynchronize', '_CFPreferencesSetAppValue', '_CFPreferencesSetValue', '_CFPreferencesSetMultiple'):
        counted(n, 1)
    # The iterator of IOServiceGetMatchingServices gives the one AppleARMBacklight, then the end
    def matching(uc):
        fake_calls['_IOServiceGetMatchingServices'] += 1
        mu.mem_write(x(2), struct.pack('<I', SERVICE + 4))
        ret_now(uc, 0)
    hook('_IOServiceGetMatchingServices', matching)
    left = [1]
    def next_(uc):
        fake_calls['_IOIteratorNext'] += 1
        ret_now(uc, SERVICE if x(0) == SERVICE + 4 and left.pop() else 0) if left else ret_now(uc, 0)
    hook('_IOIteratorNext', next_)
    def entry_id(uc):
        fake_calls['_IORegistryEntryGetRegistryEntryID'] += 1
        mu.mem_write(x(1), struct.pack('<Q', 0x100000123))
        ret_now(uc, 0)
    hook('_IORegistryEntryGetRegistryEntryID', entry_id)
    name_ = anon(0x1000)
    mu.mem_write(name_, b'AppleARMBacklight\0')
    def copy_class(uc):
        fake_calls['_IOObjectCopyClass'] += 1
        setx(0, 0); setx(1, name_); setx(2, 0x8000100)
        pending[0] = cf['_CFStringCreateWithCString'] + SLIDE
        uc.emu_stop()
    hook('_IOObjectCopyClass', copy_class)
    mu.mem_map(UNTIL, 0x1000, UC_PROT_ALL)
    if args.container:
        # NSUserDefaults goes to cfprefsd through XPC: no launchd here. Every read answers "not set"
        for n, a in syms('Foundation.framework/Foundation').items():
            if n.startswith('-[NSUserDefaults(NSUserDefaults) ') and 'init' not in n:
                mu.hook_add(UC_HOOK_CODE, lambda uc, ad, sz, ud: (fake_calls.update(['NSUserDefaults read']), ret_now(uc, 0)), begin=a + SLIDE, end=a + SLIDE + 3)
        # setupInternalModules: "if (caDisplay != nil || this function)". Here there is no CADisplay.
        a = cb['_CBU_IsAccessory']
        mu.hook_add(UC_HOOK_CODE, lambda uc, ad, sz, ud: ret_now(uc, 1), begin=a + SLIDE, end=a + SLIDE + 3)
        objc = syms('libobjc.A.dylib')
        s_ = anon(0x1000)
        mu.mem_write(s_, b'CBDisplayContaineriOS\0')
        steps.extend([
            (objc['_objc_getClass'] + SLIDE, lambda r: [s_, 0]),
            (objc['_objc_alloc'] + SLIDE, lambda r: [r, 0]),
            (cb['-[CBDisplayContaineriOS initWithBacklightService:]'] + SLIDE, lambda r: [r, 0, SERVICE]),
            (cb['-[CBDisplayContaineriOS handleDisplayArrival:]'] + SLIDE, lambda r: (the_self.append(r), [r, 0, SERVICE])[1]),
            (cb['-[CBDisplayContaineriOS setupInternalModules]'] + SLIDE, lambda r: [the_self[0], 0]),
        ])
        print('display-create: %s, %d properties; container path' % (args.display_create, len(props)))
    else:
        fn = cb['_DisplayCreateWithCapabilitiesAndID'] + SLIDE
        print('display-create: %s, %d properties; DisplayCreateWithCapabilitiesAndID at %s' % (args.display_create, len(props), where(fn)))
        steps.append((fn, lambda r: [SERVICE, 0, 0, 1]))
    next_step(uc)
    uc.emu_stop()

steps = []
the_self = []
last_result = [0]
# ---- --hid-event: the real parser of 23F84 on the bytes of the kernel ----
hid_results = []

def hid_event_start(uc):
    """IOHIDEventServicePlugin (not in the cache; it imports only IOHIDEventCreateWithBytesInternal) calls this with the queue entry. Each event: the parent, then its children."""
    import importlib.util, json
    sp_ = importlib.util.spec_from_file_location('dsc_image', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dsc-image.py'))
    dsc = importlib.util.module_from_spec(sp_)
    sp_.loader.exec_module(dsc)
    c = dsc.Cache(BASE + '/tree/cache')
    iokit = {n: a + SLIDE for a, k, n in dsc.symbols(c, c.find('IOKit.framework/Versions/A/IOKit')[0])}
    cf = {n: a + SLIDE for a, k, n in dsc.symbols(c, c.find('CoreFoundation.framework/CoreFoundation')[0])}
    j = json.load(open(args.hid_event))
    fl = j['fields']
    mu.mem_map(UNTIL, 0x1000, UC_PROT_ALL)
    def read_event(tag, e_):
        """Steps that read one event; each result goes to hid_results as (tag, name, x0, d0)."""
        for name in ('type',):
            steps.append((iokit['_IOHIDEventGetType'], lambda r, e=e_: [e()], (tag, 'event-type')))
        for name in ('x', 'y', 'pressure'):
            steps.append((iokit['_IOHIDEventGetFloatValue'], lambda r, e=e_, f=fl[name]: [e(), f], (tag, name)))
        for name in ('type', 'index', 'identity', 'mask', 'button', 'range', 'touch', 'collection'):
            steps.append((iokit['_IOHIDEventGetIntegerValue'], lambda r, e=e_, f=fl[name]: [e(), f], (tag, 'int-' + name)))
    ev = []
    for i, h in enumerate(j['events']):
        b = bytes.fromhex(h)
        a = anon(max(len(b), 0x1000))
        mu.mem_write(a, b)
        tag = 'event%d' % i
        hold = {}
        hid_holds.append(hold)
        def keep(r, hold=hold, key='parent'):
            hold[key] = r
            return [r]
        steps.append((iokit['_IOHIDEventCreateWithBytesInternal'], lambda r, a=a, n=len(b): [0, a, n], (tag, 'create')))
        steps.append((iokit['_IOHIDEventGetChildren'], keep, (tag, 'children')))
        def n_children(r, hold=hold):
            hold['children'] = r
            return [r]
        steps.append((cf['_CFArrayGetCount'], lambda r, hold=hold, n_children=n_children: n_children(r) if r else (hold.__setitem__('children', 0), None)[1], (tag, 'child-count')))
        def first(r, hold=hold):
            return [hold['children'], 0]
        read_event(tag, lambda hold=hold: hold['parent'])
        steps.append((cf['_CFArrayGetValueAtIndex'], lambda r, hold=hold: [hold['children'], 0] if hold['children'] else None, (tag, 'child0')))
        def keep_child(r, hold=hold):
            hold['child'] = r
        read_event(tag + '.child0', lambda hold=hold: hold.get('child', 0))
    next_hid_step(uc)
    uc.emu_stop()

hid_holds = []

def next_hid_step(uc):
    # A step with no object (no child) is left out: the report shows it as no answer
    while steps:
        fn, a, label = steps.pop(0)
        args_ = a(last_result[0])
        if args_ is None or (label[0].endswith('.child0') and not args_[0]):
            continue
        for i, v in enumerate(args_):
            setx(i, v)
        hid_label[0] = label
        uc.reg_write(UC_ARM64_REG_LR, UNTIL)
        pending[0] = fn
        return True
    return False

hid_label = [None]

def hid_step_done():
    t, n = hid_label[0]
    hid_results.append((t, n, x(0), mu.reg_read(UC_ARM64_REG_D0)))
    if n == 'child0':
        hid_holds[int(t[5:]) if t[5:].isdigit() else 0]['child'] = x(0)

cpb = {}
def cpbitmap_start(uc):
    import importlib.util
    sp_ = importlib.util.spec_from_file_location('dsc_image', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dsc-image.py'))
    dsc = importlib.util.module_from_spec(sp_)
    sp_.loader.exec_module(dsc)
    c = dsc.Cache(BASE + '/tree/cache')
    def sy(frag, name):
        return next(a for a, k, n in dsc.symbols(c, c.find(frag)[0]) if n == name) + SLIDE
    data = open(args.cpbitmap, 'rb').read()
    buf = 0x2e0000000
    mu.mem_map(UNTIL, 0x1000, UC_PROT_ALL)
    mu.mem_map(buf, (len(data) + 0x4fff) & ~0xfff, UC_PROT_ALL)
    mu.mem_write(buf, data)
    out = buf + ((len(data) + 0xfff) & ~0xfff)
    def rec(name):
        def f(r):
            cpb[name] = r
            return None
        return f
    cf, cg, app = 'CoreFoundation.framework/CoreFoundation', 'CoreGraphics.framework/CoreGraphics', 'AppSupport.framework/AppSupport'
    def keep(name, fn):
        def g(r):
            cpb[name] = r
            return fn(r)
        return g
    steps.extend([
        (sy(cf, '_CFDataCreate'), lambda r: [0, buf, len(data)]),
        (sy(app, '_CPBitmapCreateImagesFromData'), keep('data', lambda r: [r, out, 1, out + 8])),
        (sy(cf, '_CFArrayGetCount'), keep('array', lambda r: [r])),
        (sy(cf, '_CFArrayGetValueAtIndex'), keep('count', lambda r: [cpb['array'], 0])),
        (sy(cg, '_CGImageGetWidth'), keep('image', lambda r: [r])),
        (sy(cg, '_CGImageGetHeight'), keep('width', lambda r: [cpb['image']])),
    ])
    last_result[0] = 0
    next_step(uc)
    uc.emu_stop()

def cpbitmap_report():
    if mu.reg_read(UC_ARM64_REG_PC) != UNTIL or steps:
        print('RESULT cpbitmap: did not end: pc %s after %s; so far %s; stop %s' % (where(mu.reg_read(UC_ARM64_REG_PC)), cpb, len(steps), stop_reason[0]))
        return 3
    print('RESULT cpbitmap: %d image(s), %d x %d' % (cpb['count'], cpb['width'], x(0)))
    return 0 if cpb['count'] >= 1 and cpb['width'] else 3

def blastdoor_gate_start(uc):
    """The first caller in the phone's crash: BlastDoorServer.resume(sandboxID:) -> this function -> _assertionFailure (bt 0x2186ee51c 0x21825d6b8, boot 16). Both messages reach one call, at 0x21825d6b4."""
    mu.mem_map(UNTIL, 0x1000, UC_PROT_ALL)
    def fatal(u, addr, size, ud):
        ptr = u.reg_read(UC_ARM64_REG_X4) & 0x7fffffffffffffff
        gate_fatal[0] = rdstr(ptr + 0x20, 200)
        u.emu_stop()
    uc.hook_add(UC_HOOK_CODE, fatal, begin=0x21825d6b4 + SLIDE, end=0x21825d6b4 + SLIDE)
    def task_info(u, addr, size, ud):   # this fake has no MIG. task_info(self, TASK_AUDIT_TOKEN, out, &count): the pid is word 5, as the kernel gives
        u.mem_write(u.reg_read(UC_ARM64_REG_X2), struct.pack('<8I', 501, 501, 501, 501, 501, 27, 0, 1))
        u.reg_write(UC_ARM64_REG_X0, 0)
        pending[0] = addr + 4
        u.emu_stop()
    uc.hook_add(UC_HOOK_CODE, task_info, begin=0x21825d790 + SLIDE, end=0x21825d790 + SLIDE)
    uc.reg_write(UC_ARM64_REG_LR, UNTIL)
    pending[0] = 0x21825d59c + SLIDE
    uc.emu_stop()

gate_fatal = [None]
def blastdoor_gate_report():
    if gate_fatal[0]:
        print('RESULT blastdoor-gate: fatal: %s' % gate_fatal[0])
        return 3
    if mu.reg_read(UC_ARM64_REG_PC) != UNTIL:
        print('RESULT blastdoor-gate: did not return: pc %s stop %s' % (where(mu.reg_read(UC_ARM64_REG_PC)), stop_reason[0]))
        return 3
    print('RESULT blastdoor-gate: returned: the service is in its post launch state')
    return 0

def hid_event_report():
    pc = mu.reg_read(UC_ARM64_REG_PC)
    if pc != UNTIL:
        print('RESULT hid-event: did not return: pc %s lr %s stop %s after %s' % (where(pc), where(mu.reg_read(UC_ARM64_REG_LR)), stop_reason[0], hid_label[0]))
        return 3
    for t, n, v, d in hid_results:
        f = struct.unpack('<d', struct.pack('<Q', d))[0]
        print('HID %-14s %-14s x0 %#x d0 %.6f' % (t, n, v, f))
    print('RESULT hid-event: all calls returned')
    return 0

def next_step(uc):
    """The next call of the list, with the result of the one before."""
    fn, a = steps.pop(0)
    args_ = a(last_result[0])
    for i, v in enumerate(args_):
        setx(i, v)
    print('call', where(fn), [hex(v) for v in args_])
    uc.reg_write(UC_ARM64_REG_LR, UNTIL)
    pending[0] = fn

def display_create_report():
    pc = mu.reg_read(UC_ARM64_REG_PC)
    print('--- fake IOKit, CFPreferences calls')
    for k, n in sorted(fake_calls.items()):
        print(' %4d %s' % (n, k))
    if pc != UNTIL:
        print('RESULT display-create: did not return: pc %s lr %s stop %s' % (where(pc), where(mu.reg_read(UC_ARM64_REG_LR)), stop_reason[0]))
        return 3
    d = x(0)
    if args.container:
        print('RESULT display-create: the container path returned')
        return 0
    if not d:
        print('RESULT display-create: returned NULL')
        return 3
    f = lambda o: struct.unpack('<f', mu.mem_read(d + o, 4))[0]
    tp = u64(mu.mem_read(d + 0x48, 8), 0)
    tn = u32(mu.mem_read(d + 0x40, 4), 0)
    table = [round(v, 2) for v in struct.unpack('<%df' % tn, mu.mem_read(tp, 4 * tn))] if tp and tn < 1000 else []
    print('display 0x%x: table at +0x48 0x%x, %d entries: %s' % (d, tp, tn, table))
    print('lMaxProduct %.2f lMidProduct %.2f lMinProduct %.2f lMaxPanel %.2f lMidPanel %.2f lMinPanel %.2f milliAmps2Nits %.2f' % tuple(f(o) for o in (0x514, 0x518, 0x51c, 0x520, 0x524, 0x528, 0x52c)))
    print('digital dimming flag +0x5ec %d, extrabright +0x5ed %d' % (bytes(mu.mem_read(d + 0x5ec, 1))[0], bytes(mu.mem_read(d + 0x5ed, 1))[0]))
    print('RESULT display-create: returned a display')
    return 0

pc = DYLD + 0x30f0
t0 = time.time()
while True:
    try:
        mu.emu_start(pc, UNTIL if args.display_create or args.hid_event or args.blastdoor_gate or args.cpbitmap else 0xffffffffffffff00, timeout=args.secs * 1000000, count=args.max)
    except UcError as e:
        print('UcError', e)
        break
    if pending[0] is not None:
        pc = pending[0]
        pending[0] = None
        continue
    if args.hid_event and mu.reg_read(UC_ARM64_REG_PC) == UNTIL:
        last_result[0] = x(0)
        hid_step_done()
        if not next_hid_step(mu):
            break
        pc = pending[0]
        pending[0] = None
        continue
    if mu.reg_read(UC_ARM64_REG_PC) == UNTIL and steps:
        last_result[0] = x(0)
        next_step(mu)
        pc = pending[0]
        pending[0] = None
        continue
    break
print('undef', emu_undef.most_common(20))
print('time %.1f s' % (time.time() - t0), 'stop', stop_reason[0], 'syscalls', sc_count[0], 'pages', len(mapped))
pc = mu.reg_read(UC_ARM64_REG_PC)
print('pc', hex(pc), where(pc))
for i in range(0, 29, 4):
    print(' '.join('x%-2d=%016x' % (j, x(j)) for j in range(i, min(i + 4, 29))))
fp = mu.reg_read(UC_ARM64_REG_FP); lr = mu.reg_read(UC_ARM64_REG_LR); s = mu.reg_read(UC_ARM64_REG_SP)
print('fp', hex(fp), 'lr', hex(lr), where(lr), 'sp', hex(s), 'depth', hex(STACK_TOP - s))
try:
    d = bytes(mu.mem_read(s - 0x40, 0x100))
    for i in range(0, len(d), 16):
        print(hex(s - 0x40 + i), d[i:i + 8][::-1].hex(), d[i + 8:i + 16][::-1].hex())
except UcError:
    pass
f = fp
for i in range(30):
    try:
        a, b = struct.unpack('<QQ', mu.mem_read(f, 16))
    except UcError:
        break
    print(' frame', hex(f), where(b))
    if not a:
        break
    f = a
print('initializers run', len(inits))
c = collections.Counter(where(a).split('+')[0] for a in inits)
print('images with initializers', len(c))
print(' '.join(k for k in dict.fromkeys(where(a).split('+')[0] for a in inits)))
print('syscall counts', sc_hist.most_common(25))
if trace:
    print('--- last blocks')
    for a in list(trace)[-200:]:
        print(hex(a), where(a))
print('RESULT %s: %s' % (EXE_PATH, 'reached main()' if reached[0] else 'main() NOT reached: ' + str(stop_reason[0])))
if args.display_create:
    sys.exit(display_create_report())
if args.hid_event:
    sys.exit(hid_event_report())
if args.blastdoor_gate:
    sys.exit(blastdoor_gate_report())
if args.cpbitmap:
    sys.exit(cpbitmap_report())
sys.exit(0 if reached[0] else 3)
