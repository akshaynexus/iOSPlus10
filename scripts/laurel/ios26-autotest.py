#!/usr/bin/env python3
"""Mi A3 iOS 26: the runner of scripts/laurel/ios26-autotest.sh. Docs: docs/laurel_sprout/ios26-autotest.md.

Reads the scenario, drives the phone with laurel-autotest over SSH, reads the kernel's lines from the USB log,
prints one table and writes it to logs/autotest-DATE.txt. Files of the run: logs/autotest-DATE/.
A lost SSH is not a fault of the test: the step gets a line, the runner waits for SSH and goes on.
--self-test needs no phone.
"""
import argparse
import datetime
import glob
import os
import re
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOL = "/usr/local/bin/laurel-autotest"
SSH_WAIT_S = 120
KERNEL_LINES = {
    "panic": re.compile(r"\bpanic\b|Debugger synch pending|LAUREL PANIC", re.I),
    "gpu": re.compile(r"LAUREL GPU: off|TopazGPU: watchdog|GPU hang|LAUREL GPU SMMU: fault|LAUREL METAL NATIVE: off"),
    "flip": re.compile(r"LAUREL FLIP: surface \d+ of swap \d+ not drawn"),
    "crash": re.compile(r"CRASH (\S+?)\[\d+\] sig (\d+)"),
}
MOTION = re.compile(r"LAUREL FRAME: motion ended: (\d+) frames in (\d+) ms")
MOVING = re.compile(r"LAUREL FRAME: \d+ ticks .*moving: ([\d.]+) frames/s")
SUBMIT_GPU = re.compile(r"LAUREL FRAME: after SwapEnd, (\d+) flips: .*?(\d+) us GPU fence")
GPU_BUSY = re.compile(r"RedwoodGPU: \d+ submissions in \d+ ms: .*GPU busy ([\d.]+) %, clock (\d+) MHz")
STACK = re.compile(r"(LAUREL METAL: on: stack .*|LAUREL METAL26: on: stack .*|LAUREL METAL NATIVE: off: .*|LAUREL METAL26: off: .*|LAUREL METAL: off: .*)")
REFUSED = re.compile(r"native-metal: refused \(logged once per reason\): ([^:]+:[^:]+)|LAUREL METAL COUNT: .*refused .*")
SEQ = re.compile(r"seq: (\d+) frames in (\d+) ms, (\d+) surfaces, (\d+) older, (\d+) black, (.*)")
CRITICAL = {"backboardd", "SpringBoard"}
BLACK_PERCENT = 98.0
BOOT = "exec launchd"  # once in a boot; LAUREL BUILD prints more than once


class Step:
    def __init__(self, name):
        self.name = name
        self.ok = True
        self.notes = []
        self.motion = []
        self.moving = []
        self.fence_us = []
        self.busy = []
        self.gpu = []
        self.flip = 0
        self.crashes = []
        self.panic = []
        self.older = 0
        self.black = 0
        self.seq_frames = 0
        self.seq_ms = 0
        self.shots = []

    def fail(self, why):
        self.ok = False
        self.notes.append(why)


def parse_scenario(text):
    """A list of (name, [command words]). A scenario error stops before the phone is touched."""
    known = {"lock": (0, 0), "wake": (0, 0), "key": (1, 2), "tap": (2, 3), "swipe": (4, 5), "edge": (1, 4), "open": (1, 1), "home": (0, 0), "wait": (1, 1), "shot": (1, 1),
             "record": (2, 2), "stop": (0, 0), "changed": (0, 0), "settle": (2, 3)}
    steps = []
    for no, line in enumerate(text.splitlines(), 1):
        words = line.split("#", 1)[0].split()
        if not words:
            continue
        if words[0] == "step":
            if len(words) != 2:
                raise ValueError(f"line {no}: step NAME")
            steps.append((words[1], []))
            continue
        if not steps:
            raise ValueError(f"line {no}: a command before the first step")
        if words[0] not in known:
            raise ValueError(f"line {no}: unknown command {words[0]}")
        low, high = known[words[0]]
        if not low <= len(words) - 1 <= high:
            raise ValueError(f"line {no}: {words[0]} takes {low} to {high} arguments")
        steps[-1][1].append(words)
    return steps


def read_lines(text, step):
    """The kernel's lines of one step."""
    for line in text.splitlines():
        m = MOTION.search(line)
        if m:
            step.motion.append((int(m.group(1)), int(m.group(2))))
        m = MOVING.search(line)
        if m:
            step.moving.append(float(m.group(1)))
        m = SUBMIT_GPU.search(line)
        if m and int(m.group(1)) > 0:
            step.fence_us.append(int(m.group(2)))
        m = GPU_BUSY.search(line)
        if m:
            step.busy.append((float(m.group(1)), int(m.group(2))))
        for kind, rx in KERNEL_LINES.items():
            m = rx.search(line)
            if not m:
                continue
            if kind == "panic":
                step.panic.append(line.strip()[:160])
            elif kind == "gpu":
                step.gpu.append(line.strip()[:160])
            elif kind == "flip":
                step.flip += 1
            else:
                step.crashes.append(m.group(1))


def judge(step):
    """The kernel's lines can fail a step that all its pictures passed."""
    if step.panic:
        step.fail("panic lines")
    for name in sorted(set(step.crashes) & CRITICAL):
        step.fail(f"{name} crashed")
    if step.gpu:
        step.fail("GPU lines")


def fps(frames, ms):
    return frames * 1000.0 / ms if ms else 0.0


def step_row(s):
    if s.motion:
        rates = [fps(f, m) for f, m in s.motion]
        motion = f"{len(rates)}x {min(rates):.0f}-{max(rates):.0f} fps"
    else:
        motion = "-"
    moving = f"{max(s.moving):.1f}" if s.moving else "-"
    fence = f"{sum(s.fence_us) / len(s.fence_us) / 1000:.0f} ms" if s.fence_us else "-"
    seq = f"{s.seq_frames}/{s.seq_ms} ms" if s.seq_frames else "-"
    busy = f"{max(b for b, _ in s.busy):.0f} %/{max(c for _, c in s.busy)}" if s.busy else "-"
    crash = ",".join(sorted(set(s.crashes)))[:28] or "-"
    return [s.name, "ok" if s.ok else "FAIL", motion, moving, fence, busy, seq, str(s.older), str(s.black), str(s.flip), str(len(s.gpu)), str(len(s.panic)), crash]


HEADS = ["step", "result", "motion", "moving", "fence", "busy/MHz", "seq frames", "older", "black", "undrawn", "gpu", "panic", "crashes"]


def table(rows):
    w = [max(len(HEADS[i]), *(len(r[i]) for r in rows)) if rows else len(HEADS[i]) for i in range(len(HEADS))]
    def fmt(r):
        return "| " + " | ".join(c.ljust(w[i]) for i, c in enumerate(r)) + " |"
    return "\n".join([fmt(HEADS), "|" + "|".join("-" * (x + 2) for x in w) + "|"] + [fmt(r) for r in rows])


def stack_lines(text):
    """The stack selector, from the start of the newest boot in this log text."""
    at = text.rfind(BOOT)
    part = text[at:] if at >= 0 else text
    seen, out = set(), []
    for line in part.splitlines():
        m = STACK.search(line) or REFUSED.search(line)
        if not m:
            continue
        key = re.sub(r"\[\d+ ", "[", m.group(0))
        key = re.sub(r"\d+", "N", key)
        if key not in seen:
            seen.add(key)
            out.append(line.strip()[:200])
    return out


class Phone:
    def __init__(self, repo):
        self.ssh = os.path.join(repo, "scripts/net/ssh-phone.sh")
        self.op10 = os.environ.get("OP10TOOL") or self.find_tool(repo)

    @staticmethod
    def find_tool(repo):
        return os.path.join(repo, "out/bin/op10tool")

    def run(self, cmd, timeout=60, stdout=None):
        """rc, text. rc 255: no SSH."""
        try:
            p = subprocess.run([self.ssh, cmd], stdout=stdout or subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, timeout=timeout)
        except subprocess.TimeoutExpired:
            return 255, "time limit"
        text = p.stdout.decode(errors="replace") if p.stdout else ""
        if p.returncode != 0:
            text += p.stderr.decode(errors="replace")
        return p.returncode, text

    def wait(self, seconds=SSH_WAIT_S):
        end = time.time() + seconds
        while time.time() < end:
            if self.run("true", timeout=20)[0] == 0:
                return True
            time.sleep(3)
        return False

    def ctl(self, word):
        try:
            p = subprocess.run([self.op10, "ctl", word], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
            return p.stdout.decode(errors="replace")
        except (subprocess.TimeoutExpired, OSError) as e:
            return f"no answer: {e}"


class LiveLog:
    """The USB log that make usblog writes. Without it the table has no kernel lines, and says so."""

    def __init__(self, repo):
        main = subprocess.run(["git", "-C", repo, "worktree", "list", "--porcelain"], stdout=subprocess.PIPE, text=True).stdout.split("\n")[0].replace("worktree ", "")
        files = glob.glob(os.path.join(repo, "logs/usblog-*.txt")) + glob.glob(os.path.join(main, "logs/usblog-*.txt"))
        self.path = max(files, key=os.path.getmtime) if files else None
        if self.path and time.time() - os.path.getmtime(self.path) > 90:
            self.path = None
        self.at = os.path.getsize(self.path) if self.path else 0

    def take(self):
        if not self.path:
            return ""
        with open(self.path, "rb") as f:
            f.seek(self.at)
            data = f.read()
        self.at += len(data)
        return data.decode(errors="replace")

    def whole(self, limit=64 << 20):
        if not self.path:
            return ""
        with open(self.path, "rb") as f:
            f.seek(max(0, os.path.getsize(self.path) - limit))
            return f.read().decode(errors="replace")


class Run:
    def __init__(self, phone, out, log, kernel_input=False):
        self.phone, self.out, self.log = phone, out, log
        self.kernel_input = kernel_input
        self.last_shots = []
        self.recording = None
        self.step = None
        self.nseq = 0

    def tool(self, *words, timeout=60):
        if self.kernel_input and words[0] in ("tap", "swipe", "edge", "key"):
            p = subprocess.run([self.phone.op10, "input"] + list(words), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
            if p.returncode != 0:
                self.step.fail(f"{' '.join(words)}: {p.stdout.strip()[:120]}")
            return p.returncode, p.stdout
        rc, text = self.phone.run(" ".join([TOOL] + list(words)), timeout=timeout)
        if rc == 255:
            self.step.notes.append(f"SSH lost at: {' '.join(words)}")
            if self.phone.wait():
                rc, text = self.phone.run(" ".join([TOOL] + list(words)), timeout=timeout)
            else:
                self.step.fail(f"no SSH in {SSH_WAIT_S} s; kernel: {self.phone.ctl('ping').strip()}")
        elif rc != 0:
            self.step.fail(f"{' '.join(words)}: rc {rc}: {text.strip()[:120]}")
        return rc, text

    def shot(self, tag):
        name = f"{self.step.name}-{tag}"
        raw = os.path.join(self.out, name + ".bin")
        png = os.path.join(self.out, name + ".png")
        with open(raw, "wb") as f:
            rc, text = self.phone.run(f"{TOOL} shot", stdout=f)
        if rc != 0:
            self.step.notes.append(f"no shot {tag}: rc {rc} {text.strip()[:100]}")
            self.step.shots.append(None)
            return
        cmd = [self.phone.op10, "autotest-png", raw, png]
        if self.last_shots:
            cmd += ["--prev", self.last_shots[-1]]
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.step.notes.append(p.stdout.strip().replace(self.out + "/", ""))
        if p.returncode == 0:
            self.last_shots.append(raw)
            self.step.shots.append(png)

    def changed(self):
        if len(self.last_shots) < 2:
            self.step.fail("changed: fewer than 2 shots")
            return
        p = subprocess.run([self.phone.op10, "autotest-png", self.last_shots[-1], os.devnull, "--prev", self.last_shots[-2]], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        m = re.search(r"([\d.]+) % changed", p.stdout)
        if not m or float(m.group(1)) < 0.2:
            self.step.fail(f"changed: the picture did not change ({m.group(1) if m else '?'} %)")
        dark = re.search(r"([\d.]+) % dark", p.stdout)
        if dark and float(dark.group(1)) >= BLACK_PERCENT:
            self.step.fail(f"changed: the picture is black ({dark.group(1)} % dark)")

    def record(self, n, ms):
        self.nseq += 1
        name = f"{self.step.name}-seq{self.nseq}"
        raw = os.path.join(self.out, name + ".bin")
        f = open(raw, "wb")
        cmd = [self.phone.ssh, f"{TOOL} seq {n} {ms}"]
        self.recording = (subprocess.Popen(cmd, stdout=f, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL), f, raw, name, int(ms))
        time.sleep(0.4)  # the view of the surfaces: before the gesture

    def stop(self):
        if not self.recording:
            self.step.fail("stop: no record")
            return
        proc, f, raw, name, ms = self.recording
        self.recording = None
        try:
            proc.wait(timeout=ms / 1000 + 30)
        except subprocess.TimeoutExpired:
            proc.kill()
            self.step.notes.append("sequence: no end in time")
        f.close()
        p = subprocess.run([self.phone.op10, "autotest-seq", raw, os.path.join(self.out, name)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in p.stdout.splitlines():
            m = SEQ.match(line)
            if m:
                self.step.seq_frames += int(m.group(1))
                self.step.seq_ms += int(m.group(2))
                self.step.older += int(m.group(4))
                self.step.black += int(m.group(5))
            self.step.notes.append(f"{name}: {line}")
        if p.returncode != 0:
            self.step.notes.append(f"{name}: autotest-seq rc {p.returncode}")

    def settle(self, quiet, most, change):
        cmd = f"{TOOL} settle {quiet} {most}" + (" change" if change else "")
        rc, text = self.phone.run(cmd, timeout=int(most) / 1000 + 30)
        self.step.notes.append(f"settle{' change' if change else ''}: {text.strip()[:100]}")
        if rc != 0 and change:
            self.step.fail(f"no new picture in {most} ms")

    def open_app(self, bundle):
        # SBSLaunchApplicationWithIdentifier gave 11 during the animation to Home [V phone]: try again, with a note
        for _ in range(4):
            rc, text = self.phone.run(f"{TOOL} open {bundle}")
            if rc == 0:
                self.step.notes.append(text.strip().splitlines()[-1][:120])
                return
            self.step.notes.append(f"open {bundle}: rc {rc}: {text.strip().splitlines()[0][:100] if text.strip() else ''}")
            time.sleep(3)
        self.step.fail(f"open {bundle}: refused 4 times")

    def panel_on(self):
        """SpringBoard's own state; None: no answer."""
        rc, _ = self.phone.run(f"{TOOL} awake")
        return True if rc == 0 else False if rc == 1 else None

    def panel_until(self, want, seconds=15):
        # the state follows the key by more than 3 s on this phone; a second key in that time would undo the first
        end = time.time() + seconds
        while time.time() < end:
            if self.panel_on() is want:
                return True
            time.sleep(0.5)
        return False

    def do(self, words):
        c = words[0]
        if c == "open":
            self.open_app(words[1])
        elif c in ("key", "tap", "swipe", "edge"):
            self.tool(*words)
        elif c == "lock":
            if self.panel_on() is True:
                self.tool("key", "power")
                if not self.panel_until(False):
                    self.step.fail("lock: the panel stayed on for 15 s")
        elif c == "wake":
            if self.panel_on() is False:
                self.step.notes.append("wake: panel off, power key")
                self.tool("key", "power")
                if not self.panel_until(True):
                    self.step.fail("wake: the panel stayed off for 15 s")
        elif c == "wait":
            time.sleep(float(words[1]))
        elif c == "shot":
            self.shot(words[1])
        elif c == "changed":
            self.changed()
        elif c == "record":
            self.record(words[1], words[2])
        elif c == "stop":
            self.stop()
        elif c == "home":
            self.tool("edge", "bottom", "700", "250")
        elif c == "settle":
            self.settle(words[1], words[2], len(words) > 3)

    def run_step(self, name, commands):
        self.step = Step(name)
        self.log.take()
        print(f"== {name}", flush=True)
        for words in commands:
            print("   " + " ".join(words), flush=True)
            self.do(words)
        if self.recording:
            self.stop()
        read_lines(self.log.take(), self.step)
        judge(self.step)
        return self.step


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--scenario", default=os.path.join(REPO, "scripts/laurel/ios26-autotest.scenario"))
    ap.add_argument("--only", help="the names of the steps to run, with commas")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    with open(a.scenario) as f:
        steps = parse_scenario(f.read())
    if a.only:
        want = a.only.split(",")
        steps = [s for s in steps if s[0] in want]
    date = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = os.path.join(REPO, "logs", f"autotest-{date}")
    os.makedirs(out, exist_ok=True)
    phone = Phone(REPO)
    if not os.access(phone.op10, os.X_OK):
        print(f"ios26-autotest: no {phone.op10}: scripts/setup/build-op10tool.sh")
        return 2
    if not phone.wait(60):
        print(f"ios26-autotest: no SSH; kernel: {phone.ctl('ping').strip()}")
        return 2
    rc, text = phone.run(f"{TOOL} check")
    print(text.strip())
    if rc != 0:
        print("ios26-autotest: the tool is off or absent: scripts/laurel/ios26-autotest.sh install")
        return 2
    log = LiveLog(REPO)
    # patch 2983: the real HID path, so the CPU and GPU clock answer to touch as for a finger. AUTOTEST_INPUT=ssh: the tool, no kernel path.
    kernel_input = os.environ.get("AUTOTEST_INPUT") != "ssh" and subprocess.run([phone.op10, "input", "check"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    input_line = "Input: kernel HID path (patch 2983)" if kernel_input else "Input: laurel-autotest, event system in backboardd; no kernel clock answer to touch (CPU, GPU), so frame rates can be under those of a finger"
    print(input_line, flush=True)
    run = Run(phone, out, log, kernel_input)
    done = [run.run_step(n, c) for n, c in steps]

    lines = [f"Mi A3 iOS 26 UI test {date}", text.strip(), input_line, f"USB log: {log.path or 'none: no kernel lines in this table. make usblog'}", f"Files: {out}", ""]
    lines.append(table([step_row(s) for s in done]))
    lines.append("")
    lines.append("motion: LAUREL FRAME: motion ended, one line per finished motion. moving: best frames/s while moving. fence: mean GPU fence wait of a flip. busy/MHz: the highest GPU busy share and clock of a RedwoodGPU window. "
                 "seq frames: frames seen in the sequence shots. older: frames equal to an older frame after a different one. black: mostly black frames. undrawn: flips that the kernel refused as not drawn.")
    lines.append("")
    lines.append("Stack selector (this boot):")
    whole = log.whole()
    lines += ["  " + x for x in stack_lines(whole)] or ["  no line in the USB log"]
    rc2, stk = phone.run("for f in /var/db/negronimetal/stack/* /var/db/negronimetal/option; do [ -f \"$f\" ] && echo \"$f: $(head -c 100 \"$f\" | tr '\\n' ' ')\"; done", timeout=20)
    lines.append("Selector files (read only):")
    lines += ["  " + x for x in stk.strip().splitlines()] or ["  none"]
    lines.append("")
    for s in done:
        lines.append(f"-- {s.name}")
        lines += ["  " + n for n in s.notes]
        lines += ["  gpu: " + g for g in s.gpu]
        lines += ["  panic: " + g for g in s.panic]
        if s.motion:
            lines.append("  motion: " + ", ".join(f"{f} frames in {m} ms = {fps(f, m):.1f} fps" for f, m in s.motion))
    report = "\n".join(lines) + "\n"
    path = os.path.join(REPO, "logs", f"autotest-{date}.txt")
    with open(path, "w") as f:
        f.write(report)
    print()
    print(report)
    print(f"Written: {path}")
    return 0 if all(s.ok for s in done) else 1


def self_test():
    steps = parse_scenario(open(os.path.join(REPO, "scripts/laurel/ios26-autotest.scenario")).read())
    assert [s[0] for s in steps] == ["unlock", "home-page-swipe", "control-center", "settings", "safari"], steps
    for bad in ["tap 1 2", "step a\nnope 1", "step a\ntap 1", "step a b"]:
        try:
            parse_scenario(bad)
        except ValueError:
            continue
        raise AssertionError(bad)
    s = Step("x")
    read_lines("""06:14:48 LAUREL FRAME: motion ended: 37 frames in 967 ms
06:14:49 LAUREL FRAME: 63 ticks of 16940 us, worst 32470; moving: 13.1 frames/s for 532 ms of 1077; gaps <20 ms 0, <36 0, <52 0, longer 10
06:14:49 LAUREL FRAME: after SwapEnd, 9 flips: 144 us to the presenter, 28131 us GPU fence, 9152 us flush to latch, 0 past one panel frame; touch to next flip 0
06:47:05 LAUREL FLIP: surface 3 of swap 91 not drawn after 900 ms (fence 2652): the panel keeps its frame
06:47:15 TopazGPU: watchdog: GPU hang: fence 2708 done 2705
06:51:42 RedwoodGPU: 51 submissions in 5107 ms: 712 command buffers and 15205 buffers named, 356 KB out of the cache in 215 us a submission; GPU busy 13.8 %, clock 697 MHz over the window
06:44:32 CRASH aonsensed[593] sig 9 code 0x0 sub 0x0 slide 0x6cdc000 mh 0x1007a8000
06:44:32 CRASH aonsensed pc 0x2aa205ccc lr 0x1885ee654
""", s)
    assert s.motion == [(37, 967)] and s.moving == [13.1] and s.fence_us == [28131] and s.flip == 1 and len(s.gpu) == 1 and s.crashes == ["aonsensed"], vars(s)
    assert not s.panic
    row = step_row(s)
    assert row[2] == "1x 38-38 fps" and row[4] == "28 ms" and row[12] == "aonsensed" and row[5] == "14 %/697", row
    t = table([row])
    assert t.splitlines()[0].startswith("| step") and len({len(x) for x in t.splitlines()}) == 1, t
    p = Step("p")
    read_lines("06:15:41 panic(cpu 5 caller 0x1): boom\n", p)
    assert len(p.panic) == 1
    judge(p)
    assert not p.ok
    c = Step("c")
    read_lines("07:07:45 CRASH backboardd[66] sig 11 code 0x100000001 sub 0x175cc0000\n07:07:45 CRASH backboardd pc 0x11fc1e294\n", c)
    judge(c)
    assert not c.ok and c.crashes == ["backboardd"], vars(c)
    d = Step("d")
    read_lines("07:07:45 CRASH aonsensed[66] sig 9 code 0x0\n", d)
    judge(d)
    assert d.ok
    log = """old line
06:20:00 exec launchd
06:20:01 NMTL[66 backboardd]: LAUREL METAL: on: stack default (setting absent)
06:30:00 exec launchd
06:30:01 NMTL[840 backboardd]: LAUREL METAL: on: stack native (setting native)
06:30:02 NMTL[862 backboardd]: LAUREL METAL: on: stack native (setting native)
06:30:03 NMTL[862 backboardd]: LAUREL METAL NATIVE: off: stack native gave no device: restart on stack default
06:30:04 NMTL[9 SpringBoard]: native-metal: refused (logged once per reason): heap texture: heap texture: OutOfMemory(Heap)
"""
    st = stack_lines(log)
    assert len(st) == 3 and "stack native" in st[0] and "gave no device" in st[1] and "refused" in st[2], st
    assert "default" not in st[0]
    print("ios26-autotest self-test: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
