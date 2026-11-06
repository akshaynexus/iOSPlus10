#!/usr/bin/env python3
"""Symbolize the kernel frames printed by post/9021 on pmap_assert_free.

Usage: scripts/laurel/pmap-backtrace.py [USB_LOG [UNSTRIPPED_KERNEL]]
Use '-' as USB_LOG to read stdin. This tool reads logs and symbols only.
"""

from __future__ import annotations

import bisect
import glob
import os
import shutil
import re
import subprocess
import sys


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
DEFAULT_KERNEL = os.path.join(
    ROOT, "out/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k.unstripped"
)
FRAME_RE = re.compile(r"kernel backtrace n=\d+(?: truncated)?((?:\s+0x[0-9a-fA-F]+)+)")


def read_log(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    with open(path, encoding="utf-8", errors="replace") as stream:
        return stream.read()


def symbols(kernel: str) -> tuple[list[int], list[tuple[str, int]]]:
    nm = os.environ.get("LLVM_NM") or shutil.which("llvm-nm") or shutil.which("nm")
    if not nm:
        raise RuntimeError("llvm-nm or nm is required")
    numeric_arg = "--numeric-sort" if os.path.basename(nm).startswith("llvm-") else "-n"
    output = subprocess.run(
        [nm, numeric_arg, kernel], check=True, text=True, capture_output=True
    ).stdout
    values: list[int] = []
    entries: list[tuple[str, int]] = []
    for line in output.splitlines():
        fields = line.split(None, 2)
        if len(fields) != 3 or fields[1] not in "TtSs":
            continue
        try:
            address = int(fields[0], 16)
        except ValueError:
            continue
        values.append(address)
        entries.append((fields[2], address))
    order = sorted(zip(values, entries))
    return [item[0] for item in order], [item[1] for item in order]


def main() -> int:
    args = sys.argv[1:]
    if len(args) > 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    if args:
        log_path = args[0]
    else:
        logs = sorted(glob.glob(os.path.join(ROOT, "logs/usblog-*.txt")), key=os.path.getmtime)
        if not logs:
            print("no logs/usblog-*.txt found", file=sys.stderr)
            return 1
        log_path = logs[-1]
    kernel = args[1] if len(args) == 2 else DEFAULT_KERNEL
    if not os.path.isfile(kernel):
        print(f"no unstripped kernel: {kernel}", file=sys.stderr)
        return 1

    text = read_log(log_path)
    matches = list(FRAME_RE.finditer(text))
    if not matches:
        print("no 'kernel backtrace n=... 0x...' line found", file=sys.stderr)
        return 1
    addresses, entries = symbols(kernel)
    for match in matches:
        frames = [int(value, 16) for value in re.findall(r"0x[0-9a-fA-F]+", match.group(1))]
        print(f"pmap_assert_free: {len(frames)} frame(s) from {log_path}")
        for index, address in enumerate(frames):
            pos = bisect.bisect_right(addresses, address) - 1
            if pos < 0:
                print(f"  #{index:02d} {address:#018x} ?")
                continue
            name, start = entries[pos]
            print(f"  #{index:02d} {address:#018x} {name}+{address - start:#x}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
