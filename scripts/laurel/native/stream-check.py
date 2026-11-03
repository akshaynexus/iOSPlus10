#!/usr/bin/env python3
"""stream-check.py A6XX_XML FILE.rd [--strict]: the host decoder of a captured command stream (fake_kernel's .rd or Turnip's FD_RD_DUMP). It reads what the CP reads, and it has no code in common with nw_check.c: it is a second opinion, and it runs on Turnip's captures too.
For each CP packet: parity, length; events that write a time stamp have an address; a call goes no deeper than IB1 -> IB2 (an SDS group is another level and is walked as such); every address register and packet address lies in a buffer of this capture. An address outside any buffer is printed with what the GPU would do with it.
--strict (the native stack): an opcode with no rule is also an error.
Exit 0: no error. Run with python3 -I."""
import gzip
import struct
import sys

RD_CMD, RD_GPUADDR, RD_CMDSTREAM_ADDR, RD_BUFFER_CONTENTS = 2, 3, 6, 12  # freedreno/common/redump.h
TS_EVENTS = {4: "CACHE_FLUSH_TS", 8: "WT_DONE_TS", 22: "RB_DONE_TS", 26: "PC_CCU_RESOLVE_TS", 28: "PC_CCU_FLUSH_DEPTH_TS", 29: "PC_CCU_FLUSH_COLOR_TS"}
OPS = {16: "NOP", 18: "WAIT_MEM_WRITES", 19: "WAIT_FOR_ME", 29: "SKIP_IB2_ENABLE_GLOBAL", 38: "WAIT_FOR_IDLE", 44: "BLIT", 50: "LOAD_STATE6_GEOM", 51: "EXEC_CS", 52: "LOAD_STATE6_FRAG", 56: "DRAW_INDX_OFFSET", 63: "INDIRECT_BUFFER", 67: "SET_DRAW_STATE", 70: "EVENT_WRITE", 99: "SET_MODE", 100: "SET_VISIBILITY_OVERRIDE", 101: "SET_MARKER", 109: "REG_WRITE"}


def odd(v):
    v ^= v >> 16
    v ^= v >> 8
    v ^= v >> 4
    return (~0x6996 >> (v & 0xf)) & 1


def address_regs(xml):
    """the same reading of the register file as addr-regs.py, by its output format"""
    import runpy
    argv = sys.argv
    import io, contextlib
    out = io.StringIO()
    sys.argv = ["addr-regs.py", xml]
    with contextlib.redirect_stdout(out):
        runpy.run_path(__file__.replace("stream-check.py", "addr-regs.py"), run_name="__main__")
    sys.argv = argv
    return {int(l.split()[0], 16): l.split()[1] for l in out.getvalue().splitlines()}


def captures(path):
    """one (buffers, IB1s) per submission: each RD_CMD begins a new one; buffers are as they were at that submission"""
    data = open(path, "rb").read()
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    at = 0
    out = []
    bos, cmds = [], []
    addr = None
    while at + 8 <= len(data):
        t, n = struct.unpack_from("<II", data, at)
        at += 8
        body = data[at:at + n]
        at += n
        if t == RD_CMD:
            if cmds:
                out.append((bos, cmds))
                bos, cmds = [], []
        elif t == RD_GPUADDR:
            lo, size = struct.unpack_from("<II", body, 0)
            hi = struct.unpack_from("<I", body, 8)[0] if len(body) >= 12 else 0
            addr = (lo | (hi << 32), size)
        elif t == RD_BUFFER_CONTENTS and addr is not None:
            bos.append((addr[0], addr[0] + addr[1], body))
            addr = None
        elif t == RD_CMDSTREAM_ADDR:
            lo, dwords = struct.unpack_from("<II", body, 0)
            hi = struct.unpack_from("<I", body, 8)[0] if len(body) >= 12 else 0
            cmds.append((lo | (hi << 32), dwords))
    if cmds:
        out.append((bos, cmds))
    return out


class Walk:
    def __init__(self, bos, regs, strict):
        self.bos = sorted(bos, key=lambda b: b[0])
        self.regs = regs
        self.strict = strict
        self.errors = []
        self.packets = 0
        self.depth = {1: 0, 2: 0, 3: 0}

    def find(self, a, n=1):
        for lo, hi, body in self.bos:
            if lo <= a and a + n <= hi:
                return lo, body
        return None

    def err(self, at, text):
        if len(self.errors) < 40:
            self.errors.append(f"  {at:#x}: {text}")

    def words(self, a, n):
        f = self.find(a, n * 4)
        if f is None:
            return None
        lo, body = f
        o = a - lo
        if o + n * 4 > len(body):
            return None
        return struct.unpack_from(f"<{n}I", body, o)

    def stream(self, a, n, level):
        w = self.words(a, n)
        if w is None:
            self.err(a, f"level {level}: {n} dwords not in a buffer of the capture")
            return
        i = 0
        self.depth[min(level, 3)] += 1
        while i < n:
            h = w[i]
            at = a + i * 4
            self.packets += 1
            if h >> 28 == 4:
                c = h & 0x7f
                reg = (h >> 8) & 0x3ffff
                if ((h >> 7) & 1) != odd(c) or ((h >> 27) & 1) != odd(reg):
                    self.err(at, f"pkt4 {h:08x}: parity")
                if i + 1 + c > n:
                    self.err(at, f"pkt4 {h:08x}: past the IB")
                    return
                j = 0
                while j < c:
                    r = reg + j
                    if r in self.regs:
                        if j + 1 >= c:
                            self.err(at, f"{self.regs[r]}: the packet ends after the low word")
                            break
                        v = w[i + 1 + j] | (w[i + 2 + j] << 32)
                        v &= ~0x3f
                        if v and self.find(v) is None:
                            self.err(at, f"{self.regs[r]} = {v:#x}: no buffer holds it")
                        j += 1
                    j += 1
            elif h >> 28 == 7:
                c = h & 0x3fff
                op = (h >> 16) & 0x7f
                if ((h >> 15) & 1) != odd(c) or ((h >> 23) & 1) != odd(op):
                    self.err(at, f"pkt7 {h:08x}: parity")
                if i + 1 + c > n:
                    self.err(at, f"pkt7 {h:08x}: past the IB")
                    return
                p = w[i + 1:i + 1 + c]
                if op == 0x46:
                    e = p[0] & 0xff if c else -1
                    if e in TS_EVENTS and c == 1:
                        wild = (w[i + 2] | (w[i + 3] << 32)) if i + 3 < n else 0
                        self.err(at, f"{TS_EVENTS[e]} has no address: the CP takes the next words as one and writes to {wild:#x}")
                    elif c == 4:
                        v = p[1] | (p[2] << 32)
                        if v and self.find(v, 4) is None:
                            self.err(at, f"event {e} writes to {v:#x}: no buffer holds it")
                elif op == 0x3f:
                    if c == 3:
                        v = p[0] | (p[1] << 32)
                        if level >= 2:
                            self.err(at, f"a call to {v:#x} from level {level}: an a6xx has IB1 and IB2 only")
                        self.stream(v, p[2], level + 1)
                elif op == 0x43:
                    # draw state groups: SDS, a level of its own, once per group
                    for g in range(0, c - c % 3, 3):
                        size = p[g] & 0xffff
                        v = p[g + 1] | (p[g + 2] << 32)
                        if size and v and not (p[g] & (1 << 18)):
                            if self.find(v, size * 4) is None:
                                self.err(at, f"a draw state at {v:#x} of {size} dwords: no buffer holds it")
                elif op in (0x32, 0x34) and c >= 3:
                    src = (p[0] >> 16) & 3
                    if src == 2:
                        v = p[1] | (p[2] << 32)
                        if self.find(v) is None:
                            self.err(at, f"a load state from {v:#x}: no buffer holds it")
                elif op == 0x38 and c == 7:
                    v = p[4] | (p[5] << 32)
                    if self.find(v) is None:
                        self.err(at, f"an index buffer at {v:#x}: no buffer holds it")
                elif self.strict and op not in OPS:
                    self.err(at, f"opcode {op:#x}: no rule")
            else:
                self.err(at, f"word {h:08x}: no packet header")
                return
            i += 1 + c


xml, path = sys.argv[1:3]
strict = "--strict" in sys.argv
regs = address_regs(xml)
errors = packets = streams = 0
depth = [0, 0, 0]
for sub, (bos, cmds) in enumerate(captures(path)):
    w = Walk(bos, regs, strict)
    for a, n in cmds:
        w.stream(a, n, 1)
    packets += w.packets
    streams += len(cmds)
    depth = [depth[i] + w.depth[i + 1] for i in range(3)]
    if w.errors:
        print(f"submission {sub}:")
        print("\n".join(w.errors))
    errors += len(w.errors)
print(f"{path.rsplit('/', 1)[-1]}: {streams} IB1s, {packets} packets; streams at level 1 {depth[0]}, level 2 {depth[1]}, deeper {depth[2]}; errors {errors}")
sys.exit(1 if errors else 0)
