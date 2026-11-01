#!/usr/bin/env python3
"""The boot menu's real UEFI binary in a real UEFI (QEMU AArch64 + AAVMF), on disks made from the phone's GPT dump, 4 KiB blocks like the UFS LUNs.

Patched UniXNU (scripts/laurel/mu-build.sh + package/build.sh) runs as BOOTAA64.EFI; the keys come from the emulated USB keyboard; after each run the disk is read back byte by byte.
Not the phone: no Qualcomm UFSDxe, no ButtonsDxe, no ABL. docs/laurel_sprout/boot-menu.md says what this proves.

usage: boot-menu-qemu.py UNIXNU.EFI GPT_DUMP_DIR WORKDIR
"""
import concurrent.futures, json, os, re, shutil, socket, struct, subprocess, sys, time, zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BS = 4096
AREA = 1 << 20
ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Za-z0-9]")


def load_toml_templates():
    src = (REPO / "scripts/laurel/mkdarwinboot.py").read_text()
    ns = {}
    exec(src[src.index("TOML = '''"):src.index("def main")], ns)
    return ns["TOML"], ns["ANDROID_ENTRY"]


def rd(f, lba, n=1):
    f.seek(lba * BS)
    return f.read(n * BS)


class Disk:
    def __init__(self, path, dump, lun):
        self.path = Path(path)
        head = (Path(dump) / f"gpt-{lun}-head.bin").read_bytes()
        tail = (Path(dump) / f"gpt-{lun}-tail.bin").read_bytes()
        alt = struct.unpack_from("<Q", head, BS + 32)[0]
        self.blocks = alt + 1
        with open(path, "wb") as f:
            f.truncate(self.blocks * BS)
            f.seek(0)
            f.write(head)
            f.seek(self.blocks * BS - len(tail))
            f.write(tail)

    def _copies(self, f):
        hp = rd(f, 1)
        alt = struct.unpack_from("<Q", hp, 32)[0]
        hb = rd(f, alt)
        count = struct.unpack_from("<I", hp, 80)[0]
        ebytes = count * 128
        pl = struct.unpack_from("<Q", hp, 72)[0]
        bl = struct.unpack_from("<Q", hb, 72)[0]
        return [(1, pl), (alt, bl)], ebytes

    def find(self, name):
        with open(self.path, "rb") as f:
            copies, ebytes = self._copies(f)
            e = rd(f, copies[0][1], (ebytes + BS - 1) // BS)[:ebytes]
        for i in range(ebytes // 128):
            if e[i * 128 + 56:i * 128 + 128].decode("utf-16le").rstrip("\0") == name:
                return i
        raise KeyError(name)

    def flags(self, copy=0):
        with open(self.path, "rb") as f:
            copies, ebytes = self._copies(f)
            e = rd(f, copies[copy][1], (ebytes + BS - 1) // BS)
        return e[self.find("boot_a") * 128 + 54], e[self.find("boot_b") * 128 + 54]

    def set_flags(self, a, b, copies=(0, 1)):
        ia, ib = self.find("boot_a"), self.find("boot_b")
        with open(self.path, "r+b") as f:
            cs, ebytes = self._copies(f)
            for c in copies:
                h_lba, e_lba = cs[c]
                e = bytearray(rd(f, e_lba, (ebytes + BS - 1) // BS))
                e[ia * 128 + 54] = a
                e[ib * 128 + 54] = b
                self._store(f, h_lba, e_lba, e, ebytes)

    def _store(self, f, h_lba, e_lba, e, ebytes):
        h = bytearray(rd(f, h_lba))
        struct.pack_into("<I", h, 88, zlib.crc32(bytes(e[:ebytes])))
        struct.pack_into("<I", h, 16, 0)
        struct.pack_into("<I", h, 16, zlib.crc32(bytes(h[:92])))
        f.seek(h_lba * BS); f.write(h)
        f.seek(e_lba * BS); f.write(e)

    def poke_backup_entry(self, off):
        """a valid backup that differs from the primary at one entry byte"""
        with open(self.path, "r+b") as f:
            cs, ebytes = self._copies(f)
            h_lba, e_lba = cs[1]
            e = bytearray(rd(f, e_lba, (ebytes + BS - 1) // BS))
            e[off] ^= 0x10
            self._store(f, h_lba, e_lba, e, ebytes)

    def break_primary_crc(self):
        with open(self.path, "r+b") as f:
            f.seek(BS + 16)
            b = f.read(1)
            f.seek(BS + 16)
            f.write(bytes([b[0] ^ 1]))

    def snapshot(self):
        with open(self.path, "rb") as f:
            f.seek(0)
            head = f.read(AREA)
            f.seek(self.blocks * BS - AREA)
            tail = f.read(AREA)
        return head, tail

    def valid(self):
        """both copies pass header and entry CRC"""
        with open(self.path, "rb") as f:
            cs, ebytes = self._copies(f)
            for h_lba, e_lba in cs:
                h = bytearray(rd(f, h_lba))
                crc = struct.unpack_from("<I", h, 16)[0]
                struct.pack_into("<I", h, 16, 0)
                if zlib.crc32(bytes(h[:92])) != crc:
                    return False
                if zlib.crc32(rd(f, e_lba, (ebytes + BS - 1) // BS)[:ebytes]) != struct.unpack_from("<I", h, 88)[0]:
                    return False
        return True

    def changed_since(self, snap):
        now = self.snapshot()
        out = []
        for name, x, y, base in (("head", snap[0], now[0], 0), ("tail", snap[1], now[1], self.blocks * BS - AREA)):
            for i in range(len(x)):
                if x[i] != y[i]:
                    out.append(base + i)
        return out

    def allowed_offsets(self, flags_changed=("boot_b",)):
        ok = set()
        with open(self.path, "rb") as f:
            cs, _ = self._copies(f)
        for h_lba, e_lba in cs:
            for k in range(4):
                ok.add(h_lba * BS + 16 + k)
                ok.add(h_lba * BS + 88 + k)
            for n in flags_changed:
                ok.add(e_lba * BS + self.find(n) * 128 + 54)
        return ok


class Qmp:
    def __init__(self, path):
        end = time.time() + 15
        while True:
            try:
                self.s = socket.socket(socket.AF_UNIX)
                self.s.connect(str(path))
                break
            except OSError:
                if time.time() > end:
                    raise
                time.sleep(0.1)
        self.f = self.s.makefile("rw")
        self.f.readline()
        self.cmd("qmp_capabilities")

    def cmd(self, name, **a):
        self.f.write(json.dumps({"execute": name, **({"arguments": a} if a else {})}) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "return" in r or "error" in r:
                return r


FW = next(p for p in ("/usr/share/edk2/aarch64/QEMU_EFI.fd", "/usr/share/AAVMF/AAVMF_CODE.fd") if Path(p).exists())


def run(name, work, esp, disks, script, keyboard=True, stop_on=None, timeout=120, screenshot=None):
    """script: list of (regex, delay seconds, key); each key is sent after its regex is in the log + delay"""
    d = Path(work) / name
    log = d / "serial.log"
    d.mkdir(parents=True, exist_ok=True)
    qmp_path = d / "qmp.sock"
    vars_tpl = Path(FW).with_name("QEMU_VARS.fd")
    cmd = ["qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a72", "-m", "1024", "-smp", "2",
           "-drive", f"if=pflash,format=raw,readonly=on,file={FW}"]
    if vars_tpl.exists():
        shutil.copy(vars_tpl, d / "vars.fd")
        cmd += ["-drive", f"if=pflash,format=raw,file={d / 'vars.fd'}"]
    cmd += ["-drive", f"if=none,id=esp,format=raw,readonly=on,file=fat:{esp}", "-device", "virtio-blk-pci,drive=esp"]
    for i, disk in enumerate(disks):
        cmd += ["-drive", f"if=none,id=d{i},format=raw,file={disk.path},cache=writethrough",
                "-device", f"virtio-blk-pci,drive=d{i},logical_block_size={BS},physical_block_size={BS}"]
    cmd += ["-device", "virtio-gpu-pci,xres=720,yres=1560", "-device", "qemu-xhci"]
    if keyboard:
        cmd += ["-device", "usb-kbd"]
    cmd += ["-nic", "none", "-display", "none", "-no-reboot", "-serial", f"file:{log}", "-qmp", f"unix:{qmp_path},server=on,wait=off"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    q = Qmp(qmp_path)
    steps = list(script)
    pending_at = None
    shot_done = False
    end = time.time() + timeout
    exited = False
    text = ""
    try:
        while time.time() < end:
            if p.poll() is not None:
                exited = True
                break
            text = ANSI.sub(b"", log.read_bytes()).decode(errors="replace") if log.exists() else ""
            if screenshot and not shot_done and "menu: shown" in text:
                time.sleep(0.5)
                q.cmd("screendump", filename=str(d / "menu.ppm"))
                shot_done = True
            if steps:
                rx, delay, key = steps[0]
                if re.search(rx, text):
                    if pending_at is None:
                        pending_at = time.time() + delay
                    elif time.time() >= pending_at:
                        q.cmd("send-key", keys=[{"type": "qcode", "data": key}])
                        steps.pop(0)
                        pending_at = None
            if stop_on and not steps and re.search(stop_on, text):
                time.sleep(0.5)
                break
            time.sleep(0.1)
    finally:
        if p.poll() is None:
            try:
                q.cmd("quit")
            except OSError:
                pass
        try:
            p.wait(10)
        except subprocess.TimeoutExpired:
            p.kill()
    text = ANSI.sub(b"", log.read_bytes()).decode(errors="replace") if log.exists() else ""
    (d / "clean.log").write_text(text)
    return text, exited


FAILS = []
CHECKS = [0]


def check(scn, cond, what):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(f"{scn}: {what}")
        print(f"FAIL {scn}: {what}", flush=True)


def lines(text):
    return [l.split("UNIXNU: ", 1)[1] for l in text.splitlines() if "UNIXNU: " in l and ("LAUREL" in l or "menu:" in l or "action:" in l)]


KEYS_THEN_IOS = [("menu: shown", 2.0, "down"), ("menu: shown", 0.3, "up"), ("menu: shown", 0.5, "ret")]


def s_no_key_no_refill(w, esp, dump):
    n = "1-no-key-no-refill"
    d = Disk(f"{w}/{n}.img", dump, "sde")
    other = Disk(f"{w}/{n}-sdb.img", dump, "sdb")
    d.set_flags(0x73, 0x1F)  # b active, retries 3
    snap = d.snapshot()
    t, _ = run(n, w, esp, [other, d], [], stop_on=r"no loader protocol", screenshot=True)
    check(n, "LAUREL SLOT: on:" in t, "self-check line")
    check(n, "menu: timeout, booting default 0" in t, "timeout boots iOS")
    check(n, "refill off: no key event in this menu" in t, "no refill with no key")
    check(n, not d.changed_since(snap), "disk changed with no key")
    print(n, lines(t), flush=True)


def s_refill_after_key(w, esp, dump):
    n = "1b-refill-after-key"
    d = Disk(f"{w}/{n}.img", dump, "sde")
    d.set_flags(0x73, 0x1F)
    snap = d.snapshot()
    t, _ = run(n, w, esp, [d], KEYS_THEN_IOS, stop_on=r"LAUREL SLOT: refill: .*\n[\s\S]*no loader protocol")
    check(n, "menu: enter, booting 0" in t, "iOS by key")
    check(n, "refill: b 1F->3F: ok" in t, "refill line")
    check(n, d.flags(0) == (0x73, 0x3F) and d.flags(1) == (0x73, 0x3F), f"flags {d.flags(0)} {d.flags(1)}")
    check(n, d.valid(), "CRCs after")
    bad = [o for o in d.changed_since(snap) if o not in d.allowed_offsets()]
    check(n, not bad, f"bytes outside flag + CRCs: {bad[:8]}")
    print(n, lines(t), flush=True)


def s_no_write_at_4(w, esp, dump):
    n = "2-no-write-at-4"
    d = Disk(f"{w}/{n}.img", dump, "sde")
    d.set_flags(0x73, 0x27)  # retries 4
    snap = d.snapshot()
    t, _ = run(n, w, esp, [d], KEYS_THEN_IOS, stop_on=r"no loader protocol")
    check(n, "refill:" not in t, "no refill write")
    check(n, not d.changed_since(snap), "disk changed")
    print(n, lines(t), flush=True)


def s_a_not_successful(w, esp, dump):
    n = "2b-slot-a-not-successful"
    d = Disk(f"{w}/{n}.img", dump, "sde")
    d.set_flags(0x33, 0x3F)  # slot a: successful clear
    snap = d.snapshot()
    t, _ = run(n, w, esp, [d], [("menu: shown", 2.0, "down"), ("menu: shown", 0.5, "ret"), ("menu: shown", 1.5, "ret")], stop_on=r"Android refused")
    check(n, "Android refused: slot a is not marked successful" in t, "refusal")
    check(n, not d.changed_since(snap), "disk changed: slot a's state must stay")
    print(n, lines(t), flush=True)


def s_android(w, esp, dump):
    n = "3-android"
    d = Disk(f"{w}/{n}.img", dump, "sde")
    d.set_flags(0x73, 0x3F)
    snap = d.snapshot()
    t, ex = run(n, w, esp, [d], [("menu: shown", 2.0, "down"), ("menu: shown", 0.5, "ret"), ("menu: shown", 1.5, "ret")], stop_on=r"action: reset for Android")
    check(n, "LAUREL SLOT: Android: a 73->73 b 3F->07: ok" in t, "Android line")
    check(n, "action: reset for Android" in t, "reset")
    check(n, d.flags(0) == (0x73, 0x07) and d.flags(1) == (0x73, 0x07), f"flags {d.flags(0)} {d.flags(1)}")
    check(n, d.valid(), "CRCs")
    ch = d.changed_since(snap)
    bad = [o for o in ch if o not in d.allowed_offsets()]
    check(n, not bad, f"bytes outside flag + CRCs: {bad[:8]}")
    print(n, f"{len(ch)} bytes changed, all in the allowed list", lines(t), flush=True)


def s_held_power(w, esp, dump):
    n = "4-held-power"
    d = Disk(f"{w}/{n}.img", dump, "sde")
    d.set_flags(0x73, 0x3F)
    # Enter 0.1, 0.5, 1.0 s after the menu: a held key. It must choose nothing; the countdown goes on
    t, _ = run(n, w, esp, [d], [("menu: shown", 0.0, "ret"), ("menu: shown", 0.3, "ret"), ("menu: shown", 0.3, "ret")], stop_on=r"no loader protocol")
    check(n, "menu: enter" not in t, "a held Enter chose an entry")
    check(n, "menu: timeout, booting default 0" in t, "timeout after the held key")
    print(n, lines(t), flush=True)


def s_cancel(w, esp, dump):
    n = "5-cancel"
    d = Disk(f"{w}/{n}.img", dump, "sde")
    d.set_flags(0x73, 0x3F)
    snap = d.snapshot()
    t, _ = run(n, w, esp, [d], [("menu: shown", 2.0, "down"), ("menu: shown", 0.5, "ret"), ("menu: shown", 1.5, "esc")], stop_on=r"not confirmed")
    check(n, "not confirmed" in t, "confirm cancelled")
    check(n, not d.changed_since(snap), "disk changed")
    print(n, lines(t), flush=True)


def s_refused_copies(w, esp, dump):
    n = "6-copies-differ"
    d = Disk(f"{w}/{n}.img", dump, "sde")
    d.set_flags(0x73, 0x3F)
    d.poke_backup_entry(d.find("boot_a") * 128 + 1)  # type GUID of boot_a in the backup
    snap = d.snapshot()
    t, _ = run(n, w, esp, [d], [("menu: shown", 2.0, "down"), ("menu: shown", 0.5, "ret"), ("menu: shown", 1.5, "ret")], stop_on=r"Android refused")
    check(n, "LAUREL SLOT: off: GPT copies differ" in t, "off line")
    check(n, "LAUREL SLOT: Android refused: GPT copies differ" in t, "refusal line")
    check(n, not d.changed_since(snap), "disk changed")
    print(n, lines(t), flush=True)


def s_refused_two_luns(w, esp, dump):
    n = "7-two-luns"
    d1 = Disk(f"{w}/{n}-1.img", dump, "sde")
    d2 = Disk(f"{w}/{n}-2.img", dump, "sde")
    d1.set_flags(0x73, 0x3F)
    d2.set_flags(0x73, 0x3F)
    s1, s2 = d1.snapshot(), d2.snapshot()
    t, _ = run(n, w, esp, [d1, d2], [("menu: shown", 2.0, "down"), ("menu: shown", 0.5, "ret"), ("menu: shown", 1.5, "ret")], stop_on=r"Android refused")
    check(n, "boot_b on more than one LUN" in t, "refusal")
    check(n, not d1.changed_since(s1) and not d2.changed_since(s2), "disk changed")
    print(n, lines(t), flush=True)


def s_plan_refused(w, esp, dump):
    n = "8-slot-a-active"
    d = Disk(f"{w}/{n}.img", dump, "sde")
    snap = d.snapshot()  # the dump as it is: slot a active, b not
    t, _ = run(n, w, esp, [d], [("menu: shown", 2.0, "down"), ("menu: shown", 0.5, "ret"), ("menu: shown", 1.5, "ret")], stop_on=r"Android refused")
    check(n, "Android refused: slot b is not active" in t, "refusal")
    check(n, not d.changed_since(snap), "disk changed")
    print(n, lines(t), flush=True)


def s_repair_primary(w, esp, dump):
    n = "9-primary-torn"
    d = Disk(f"{w}/{n}.img", dump, "sde")
    d.set_flags(0x73, 0x3F)
    d.break_primary_crc()
    t, _ = run(n, w, esp, [d], [], stop_on=r"LAUREL SLOT: (on|off)")
    # PartitionDxe (EDK2 Gpt.c) restores a copy that fails: firmware behaviour, seen here on AAVMF
    check(n, "LAUREL SLOT: on:" in t, "firmware restored the primary before the menu")
    check(n, d.valid(), "valid after")
    print(n, lines(t), flush=True)


def s_no_keys(w, esp, dump):
    n = "10-no-keyboard"
    d = Disk(f"{w}/{n}.img", dump, "sde")
    d.set_flags(0x73, 0x17)  # retries 2
    snap = d.snapshot()
    t, _ = run(n, w, esp, [d], [], keyboard=False, stop_on=r"no loader protocol")
    check(n, "refill off: no key event" in t, "no refill without keys")
    check(n, not d.changed_since(snap), "disk changed")
    print(n, lines(t), flush=True)


def main():
    efi, dump, work = sys.argv[1:4]
    work = Path(work).resolve()
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    TOML, AE = load_toml_templates()
    esp = work / "esp"
    (esp / "EFI/BOOT").mkdir(parents=True)
    (esp / "EFI/UniXNU").mkdir(parents=True)
    (esp / "Payloads").mkdir()
    shutil.copy(efi, esp / "EFI/BOOT/BOOTAA64.EFI")
    (esp / "Payloads/kernel.macho").write_bytes(b"\0" * 4096)
    (esp / "EFI/UniXNU/unixnu.toml").write_text(TOML.format(timeout=5, title="iOS 26 (laurel XNU)", cmdline="-v") + AE)
    scenarios = [s_no_key_no_refill, s_refill_after_key, s_no_write_at_4, s_a_not_successful, s_android, s_held_power, s_cancel, s_refused_copies, s_refused_two_luns, s_plan_refused, s_repair_primary, s_no_keys]
    with concurrent.futures.ThreadPoolExecutor(5) as ex:
        for f in concurrent.futures.as_completed([ex.submit(s, str(work), str(esp), dump) for s in scenarios]):
            f.result()
    ppm = work / "1-no-key-no-refill/menu.ppm"
    if ppm.exists():
        sys.path.insert(0, str(REPO))
        data = ppm.read_bytes()
        m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+255\s", data)
        w_, h_ = int(m[1]), int(m[2])
        px = data[m.end():]
        raw = b"".join(b"\0" + px[y * w_ * 3:(y + 1) * w_ * 3] for y in range(h_))

        def chunk(tag, body):
            return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
        (work / "menu.png").write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w_, h_, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
        print("menu screenshot:", work / "menu.png")
    for img in work.glob("*.img"):
        img.unlink()
    print(f"qemu: {len(scenarios)} scenarios, {CHECKS[0]} checks, {len(FAILS)} failures")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
