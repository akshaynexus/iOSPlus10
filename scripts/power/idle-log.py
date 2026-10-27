#!/usr/bin/env python3
"""Idle power summary of a USB live log or a saved boot log (patch 0382, patches/xnu/README-power-idle.md).

  scripts/power/idle-log.py LOG [LOG...]     logs/usblog-*.txt (HH:MM:SS prefix) or logs/bootlog-*.txt

Per display state (NEGRONI FB: display off / on lines):
  - time in each state (usblog only: the bootlog has no clock), log lines per second, the top line kinds
  - CPUFREQ lines: mean busy % of each domain. These lines come mostly when a row changes (biased up);
    the 0382 NEGRONI TOP lines are the unbiased number.
  - NEGRONI TOP (0382): busy % and irq/s per CPU, the top processes and threads
  - respawns: "exec NAME" counts (launchd restart loops) and CRASH lines
"""
import collections
import re
import sys

CF = re.compile(r'd0 (\d+) MHz busy (\d+)% lmh \d+ \| d1 (\d+) MHz busy (\d+)% lmh \d+ \| d2 (\d+) MHz busy (\d+)%')
TOP = re.compile(r'NEGRONI TOP \d+ s dark (\d): busy% ([\d ]+) \| irq/s ([\d ]+) \| timer/s ([\d ]+) \| ipi/s ([\d ]+)')
TS = re.compile(r'^(\d\d):(\d\d):(\d\d) (.*)')


def main(paths):
    for path in paths:
        state = 'on'
        dur = collections.Counter()
        kinds = {'on': collections.Counter(), 'off': collections.Counter()}
        cf = {'on': [], 'off': []}
        top = {'on': [], 'off': []}
        procs = {'on': collections.Counter(), 'off': collections.Counter()}
        thr = {'on': collections.Counter(), 'off': collections.Counter()}
        execs = collections.Counter()
        crashes = collections.Counter()
        last = None
        topst = 'on'    # the dark flag of the last TOP header: its procs/thr lines belong to the same window
        for raw in open(path, 'rb'):
            line = raw.decode('latin1').rstrip('\n')
            m = TS.match(line)
            if m:
                t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
                body = m.group(4)
                if last is not None and 0 <= (t - last) % 86400 < 120:
                    dur[state] += (t - last) % 86400
                last = t
            else:
                body = line
            if 'usblog: en10 up' in body:
                state = 'on'
                continue
            if 'NEGRONI FB: display off (' in body:
                state = 'off'
            elif 'NEGRONI FB: display on' in body:
                state = 'on'
            k = re.search(r'(NEGRONI [A-Z0-9 ]+?):', body)
            kinds[state][k.group(1) if k else ('exec' if body.startswith('exec ') else 'other')] += 1
            for e in re.findall(r'exec ([A-Za-z0-9._-]+)', body):
                execs[e] += 1
            c = re.search(r'CRASH ([A-Za-z0-9._-]+)\[\d+\] sig (\d+)', body)
            if c:
                crashes[c.group(1) + ' sig ' + c.group(2)] += 1
            c = CF.search(body)
            if c:
                cf[state].append([int(x) for x in c.groups()])
            c = TOP.search(body)
            if c:
                st = topst = 'off' if c.group(1) == '1' else 'on'
                top[st].append([list(map(int, g.split())) for g in c.groups()[1:]])
            c = re.search(r'NEGRONI TOP procs \(\d+ threads\):(.*)', body)
            if c:
                for name, pct in re.findall(r' ([^ ,]+) ([\d.]+)%', c.group(1)):
                    procs[topst][name] += float(pct)
            c = re.search(r'NEGRONI TOP thr ([\d.]+)% (.*?) tid \d+ "([^"]*)"', body)
            if c:
                # the lr and the first 3 frames name the loop (a lazy match before an optional group anchored
                # at $ never captured them when a line had more than 3 frames)
                lr = re.search(r'lr 0x[0-9a-f]+(?: 0x[0-9a-f]+){0,3}', body)
                thr[topst][(c.group(2) + ' "' + c.group(3) + '" ' + (lr.group(0) if lr else '')).strip()] += float(c.group(1))
        print(f'== {path}: display on {dur["on"]} s, off {dur["off"]} s (usblog clock; 0 for a bootlog)')
        for st in ('on', 'off'):
            n = sum(kinds[st].values())
            if n == 0 and not top[st]:
                continue        # TOP windows go by their own dark flag: keep them when the log has no display line
            rate = f'{n / dur[st]:.1f} lines/s' if dur[st] else f'{n} lines'
            print(f' [{st}] {rate}; top: ' + ', '.join(f'{k} {v}' for k, v in kinds[st].most_common(8)))
            if cf[st]:
                a = cf[st]
                print(f'   CPUFREQ lines {len(a)} (biased): mean busy d0 {sum(x[1] for x in a) / len(a):.0f}% '
                      f'd1 {sum(x[3] for x in a) / len(a):.0f}% d2 {sum(x[5] for x in a) / len(a):.0f}%')
            if top[st]:
                a = top[st]
                ncpu = len(a[0][0])
                mean = lambda i: ' '.join(f'{sum(x[i][c] for x in a) / len(a):.0f}' for c in range(ncpu))
                print(f'   TOP windows {len(a)}: busy% {mean(0)} | irq/s {mean(1)} | timer/s {mean(2)} | ipi/s {mean(3)}')
                w = len(a)
                print('   TOP procs (mean %): ' + ', '.join(f'{k} {v / w:.1f}' for k, v in procs[st].most_common(6)))
                for k, v in thr[st].most_common(6):
                    print(f'   TOP thr {v / w:.1f}%  {k}')
        if execs:
            print(' exec: ' + ', '.join(f'{k} {v}' for k, v in execs.most_common(10)))
        if crashes:
            print(' CRASH: ' + ', '.join(f'{k} {v}' for k, v in crashes.most_common(8)))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1:])
