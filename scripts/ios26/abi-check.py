#!/usr/bin/env python3
"""abi-check.py STAGE: the ABI of the Mach-O files we inject into a lowered 23F84 userland (docs/laurel_sprout/ios26-metal.md section 2). Each file must be:
  thin arm64, CPU_SUBTYPE_ARM64_ALL (no arm64e slice: no signed pointer, no PAC ABI);
  chained fixups in a plain format (DYLD_CHAINED_PTR_64, no ARM64E format: dyld has no auth bind to do);
  no instruction newer than ARMv8.0 + CRC + AES/SHA (scripts/laurel/armv80-check.py: LSE, RCpc, PAC, FP16, ...);
  minos and platform iOS;
  no import of a symbol that is gone in 23F84 is checked separately by scripts/metal/check-imports.py at build time.
One line per file, exit 1 if one fails. Run with python3 -I. Needs llvm-otool, llvm-objdump."""
import os
import re
import subprocess
import sys


def run(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    fail = 0
    n = 0
    for dp, _, fs in os.walk(sys.argv[1]):
        for f in sorted(fs):
            p = os.path.join(dp, f)
            with open(p, "rb") as h:
                if h.read(4) != b"\xcf\xfa\xed\xfe":
                    continue
            n += 1
            head = run("llvm-objdump", "--macho", "--private-header", p)
            m = re.search(r"MH_MAGIC_64\s+(\S+)\s+(\S+)", head)
            cpu = f"{m.group(1)} {m.group(2)}" if m else "?"
            fx = run("llvm-objdump", "--macho", "--chained-fixups", p)
            fmts = sorted(set(re.findall(r"pointer_format\s*=\s*\d+\s*\((\S+)\)", fx)))
            minos = re.search(r"minos (\S+)", run("llvm-otool", "-l", p))
            v8 = subprocess.run([sys.executable, "-I", os.path.join(here, "../laurel/armv80-check.py"), p], capture_output=True, text=True)
            ok = cpu == "ARM64 ALL" and not any("ARM64E" in x for x in fmts) and v8.returncode == 0
            fail += not ok
            print(f"{'ok  ' if ok else 'FAIL'} {os.path.relpath(p, sys.argv[1])}: {cpu}, fixups {','.join(fmts) or 'none listed'}, minos {minos.group(1) if minos else '?'}, {v8.stdout.strip().split(': ', 1)[-1]}")
    print(f"abi-check: {n} Mach-O files, {fail} failed")
    return 1 if fail or n == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
