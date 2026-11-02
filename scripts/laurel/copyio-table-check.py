#!/usr/bin/env python3
"""A built kernel: the copyio recovery table covers its whole section. A range after copyio_recover_table_end is not walked by find_copyio_recovery_entry(): a fault there is a panic.

  scripts/laurel/copyio-table-check.py KERNEL.unstripped     exit 1 on a difference
"""
import re
import subprocess
import sys


def main(k):
    h = subprocess.run(['llvm-objdump', '--section-headers', k], capture_output=True, text=True, check=True).stdout
    m = re.search(r'__copyio_vectors\s+([0-9a-f]+)\s+([0-9a-f]+)', h)
    if not m:
        sys.exit('copyio-table-check: no __copyio_vectors section in ' + k)
    size, addr = int(m.group(1), 16), int(m.group(2), 16)
    n = subprocess.run(['llvm-nm', k], capture_output=True, text=True, check=True).stdout
    sym = {x.split()[2]: int(x.split()[0], 16) for x in n.splitlines() if re.search(r' _copyio_recover_table(_end)?$', x)}
    start, end = sym.get('_copyio_recover_table'), sym.get('_copyio_recover_table_end')
    if start is None or end is None:
        sys.exit('copyio-table-check: no table symbols in ' + k)
    print(f'copyio-table-check: section 0x{size:x} bytes, table 0x{end - start:x} bytes, {(end - start) // 24} entries, outside the table 0x{addr + size - end:x}')
    if start != addr or end != addr + size:
        sys.exit('copyio-table-check: FAILED: a range outside the table is a panic on a fault')


main(sys.argv[1])
