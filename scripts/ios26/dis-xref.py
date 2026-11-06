#!/usr/bin/env python3
"""Find the code that references given addresses (strings) in an llvm-objdump -d listing of an arm64 Mach-O.

Usage: python3 -I scripts/ios26/dis-xref.py LISTING ADDR[=label]... [--context N]
Functions: the nearest symbol label, else f_<address of the last pacibsp>. Matches adrp+add (and adrp+ldr) pairs within 8 instructions whose sum is the address; prints the function
(nearest preceding label) and the instruction address. --context N prints N lines before each hit.
"""
import re, sys

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    ctx = 0
    for a in sys.argv[1:]:
        if a.startswith('--context'):
            ctx = int(a.split('=', 1)[1]) if '=' in a else 8
    listing = args[0]
    want = {}
    for a in args[1:]:
        s, _, label = a.partition('=')
        want[int(s, 16)] = label or s
    lines = open(listing, errors='replace').read().split('\n')
    ins = re.compile(r'^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$')
    adrp = re.compile(r'^(\w+), .*?(0x[0-9a-f]+)')
    add = re.compile(r'^(\w+), (\w+), #(0x[0-9a-f]+|\d+)')
    ldr = re.compile(r'^\w+, \[(\w+), #(0x[0-9a-f]+|\d+)\]')
    func = None
    pages = {}          # reg -> (page, line index)
    for i, ln in enumerate(lines):
        m = ins.match(ln)
        if not m:
            if ln.endswith(':') and not ln.startswith(' '):
                func = ln[:-1]
            continue
        addr, op, rest = int(m.group(1), 16), m.group(2), m.group(3)
        if op == 'pacibsp' or (op == 'stp' and rest.endswith(']!') and 'x29' in rest):
            if op == 'pacibsp' or func is None or not func.startswith('f_') or True:
                func = 'f_%x' % addr if op == 'pacibsp' else func
        if op == 'adrp':
            a = adrp.match(rest)
            if a:
                pages[a.group(1)] = (int(a.group(2), 16), i)
            continue
        tgt = None
        if op == 'add':
            a = add.match(rest)
            if a and a.group(2) in pages and i - pages[a.group(2)][1] <= 8:
                tgt = pages[a.group(2)][0] + int(a.group(3), 0)
        elif op.startswith('ldr') or op.startswith('str'):
            a = ldr.match(rest)
            if a and a.group(1) in pages and i - pages[a.group(1)][1] <= 8:
                tgt = pages[a.group(1)][0] + int(a.group(2), 0)
        if tgt in want:
            print('%s: %08x in %s' % (want[tgt], addr, func))
            for j in range(max(0, i - ctx), i + 1):
                print('    ' + lines[j])
main()
