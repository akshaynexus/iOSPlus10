#!/usr/bin/env python3
"""What set the pace of the compositor in a usb log (docs/laurel_sprout/gpu.md "Frame budget"). Host only. Run with python3 -I.

  frame-pace.py LOG      each LAUREL FRAME window: frames/s, gaps, and "24 Hz image timer" or "other"
  frame-pace.py --test   the model below against numbers from real windows

The model: panel ticks each 1/60 s. A frame goes at the first tick after it is due.
  timer  a keyframe animation changes its image each 1/N s (backboardd's boot-UI spinner: 24 images in 1.0 s, discrete).
  cost   the next frame is due when the last one is drawn, COST seconds later.
A 1/24 s timer gives 2 ticks + 3 ticks in turn, 120 gaps of each in 10 s. A fixed cost gives one gap size, so a slow GPU or CPU has no 2 + 3 mix.

The vsync message (post/9008). IOMFBServer::vsync_callback of 23F84 renders at a tick only if tick + a3 reaches the next update; the frame shows one tick later.
a3 is the period. Before 9008 it was the tick counter at 19.2 MHz: a due time in the rest of the tick waited one tick more. The gap pattern stays, the delay does not.
"""
import re
import sys

TICK = 1 / 60
WINDOW = re.compile(r'^(\S+) LAUREL FRAME: \d+ ticks of (\d+) us.*?moving: (\d+\.\d) frames/s.*?gaps <20 ms (\d+), <36 (\d+), <52 (\d+), longer (\d+)')


def histogram(gaps):
    """The classes of the LAUREL FRAME line (patch 2915): under 20, 36, 52 ms, longer."""
    h = [0, 0, 0, 0]
    for g in gaps:
        ms = g * 1000
        h[0 if ms < 20 else 1 if ms < 36 else 2 if ms < 52 else 3] += 1
    return h


def next_tick(t):
    n = int(t / TICK)
    return (n + 1) * TICK if n * TICK < t - 1e-9 else n * TICK


def timer_gaps(rate, seconds):
    shown = [next_tick(k / rate) for k in range(int(rate * seconds) + 1)]
    return [b - a for a, b in zip(shown, shown[1:])]


def cost_gaps(cost, seconds):
    shown, t = [], 0.0
    while t < seconds:
        t = next_tick(t + cost)
        shown.append(t)
    return [b - a for a, b in zip(shown, shown[1:])]


def timer_shown(rate, seconds, a3):
    """Ticks at which a timer's frames reach the panel, with the render rule of vsync_callback."""
    shown = []
    for k in range(1, int(rate * seconds) + 2):
        due = k / rate
        n = int((due - a3) / TICK)
        while n * TICK + a3 < due - 1e-9:
            n += 1
        shown.append(n * TICK + TICK)
    return shown


def is_24hz(fps, g0, g1, g2, g3):
    """About 24 frames/s, almost no one-tick gap, and the 2-tick and 3-tick gaps in equal numbers."""
    n = g0 + g1 + g2 + g3
    return n >= 20 and 23 <= fps <= 25 and g0 * 20 <= n and abs(g1 - g2) * 4 <= g1 + g2 and g3 * 5 <= n


def test():
    bad = 0

    def check(what, got, want):
        nonlocal bad
        ok = got == want
        bad += not ok
        print(f'{"ok  " if ok else "FAIL"} {what}: {got}' + ('' if ok else f' (want {want})'))

    # the model: boot 00:08:03 logged "gaps <20 ms 0, <36 120, <52 120, longer 0"
    check('24 Hz timer on 60 Hz ticks, 10 s', histogram(timer_gaps(24, 10)), [0, 120, 120, 0])
    # a real 60 Hz animation and two fixed costs: one gap size each
    check('60 Hz timer, 10 s', histogram(timer_gaps(60, 10)), [600, 0, 0, 0])
    check('fixed 41 ms a frame, 10 s', histogram(cost_gaps(0.041, 10))[1], 0)
    check('fixed 30 ms a frame, 10 s', histogram(cost_gaps(0.030, 10))[2], 0)
    # vsync_callback, a3: the counter after 20 min (3.75 ms) against the period
    old, new = timer_shown(24, 10, 72000 / 19.2e6), timer_shown(24, 10, TICK)
    gaps = lambda shown: [b - a for a, b in zip(shown, shown[1:])]
    check('a3 = counter: the 24 Hz pattern', histogram(gaps(old)), [0, 120, 120, 0])
    check('a3 = period: the 24 Hz pattern', histogram(gaps(new)), [0, 120, 120, 0])
    check('a3 = counter: frames that show one tick later', round(sum((a - b) / TICK for a, b in zip(old, new))), 241)
    # the rule, on lines from logs/usblog-20261103-000638.txt
    check('window 00:08:03', is_24hz(23.9, 0, 120, 120, 0), True)
    check('window 00:50:22', is_24hz(24.1, 0, 121, 111, 8), True)
    check('window 00:49:08 (shell starts, one-tick gaps)', is_24hz(38.4, 15, 14, 10, 0), False)
    check('window 22:59:15 (use: 76 frames, long gaps)', is_24hz(22.6, 0, 22, 2, 52), False)
    print('frame-pace: ' + ('all pass' if not bad else f'{bad} FAILED'))
    return 1 if bad else 0


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    if sys.argv[1] == '--test':
        return test()
    for line in open(sys.argv[1], errors='replace'):
        m = WINDOW.match(line)
        if m:
            fps = float(m[3])
            g = [int(m[i]) for i in range(4, 8)]
            print(m[1], f'{fps:5.1f} frames/s, gaps {g}:', '24 Hz image timer' if is_24hz(fps, *g) else 'other')
    return 0


if __name__ == '__main__':
    sys.exit(main())
