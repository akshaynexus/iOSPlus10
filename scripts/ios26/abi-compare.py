#!/usr/bin/env python3
"""Compare two a64-abi outputs (iOS 16 and iOS 26): selector sets per image, function -> selector changes, SPI symbol diffs.
Usage: python3 -I abi-compare.py OLD_DIR NEW_DIR [OUT.md]"""
import csv
import os
import sys
from collections import defaultdict


def calls(d):
    rows = list(csv.DictReader(open(os.path.join(d, 'abi-calls.tsv')), delimiter='\t'))
    out = defaultdict(lambda: defaultdict(set))
    fn = defaultdict(lambda: defaultdict(set))
    for r in rows:
        if r['api'] == '_IOServiceOpen' or r['api'] == '_IOConnectMapMemory64':
            continue
        key = r['image']
        out[key][r['selector']].add((r['function'], r['input_scalars'], r['input_struct_or_output']))
        fn[key][r['function']].add(r['selector'])
    return out, fn


def sels(s):
    nums = sorted(int(x) for x in s if x != '?')
    ranges, i = [], 0
    while i < len(nums):
        j = i
        while j + 1 < len(nums) and nums[j + 1] == nums[j] + 1:
            j += 1
        ranges.append(str(nums[i]) if i == j else f'{nums[i]}-{nums[j]}')
        i = j + 1
    return ', '.join(ranges) + (' + unknown' if '?' in s else '')


def main():
    old_dir, new_dir = sys.argv[1:3]
    (old, old_fn), (new, new_fn) = calls(old_dir), calls(new_dir)
    out = []
    out.append('| Image | selectors iOS 16 (20H392) | selectors iOS 26 (23F84) | only iOS 26 | only iOS 16 | same function, other selector |')
    out.append('|---|---|---|---|---|---|')
    for image in sorted(set(old) | set(new)):
        a, b = set(old[image]), set(new[image])
        moved = []
        for f in set(old_fn[image]) & set(new_fn[image]):
            x, y = old_fn[image][f] - {'?'}, new_fn[image][f] - {'?'}
            if x and y and x != y:
                moved.append(f'{f}: {sorted(x)} -> {sorted(y)}')
        moved.sort()
        out.append(f'| {image} | {sels(a)} | {sels(b)} | {sels(b - a)} | {sels(a - b)} | {len(moved)}: {"; ".join(moved[:6])} |')
    text = '\n'.join(out) + '\n'
    if len(sys.argv) > 3:
        open(sys.argv[3], 'w').write(text)
    print(text)


if __name__ == '__main__':
    main()
