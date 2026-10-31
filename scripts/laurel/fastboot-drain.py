#!/usr/bin/env python3
"""Talk to the Mi A3 ABL fastboot directly (Linux usbfs, no pyusb): drain stale replies, getvar, flash, reboot.

The Mi A3 ABL sometimes keeps one extra reply queued (after a fastboot entry by buttons following a
panic, or after a refused command): then every command gets the answer of the previous one
("unknown command", "Variable Not found", "download size is more than max allowed").
This tool claims the fastboot interface (class ff/42/03), reads the bulk IN endpoint until it has
been quiet for --quiet ms, prints what it dropped, and releases the interface.
  scripts/laurel/fastboot-drain.py [--serial SERIAL] [--quiet 300]            drain only
  scripts/laurel/fastboot-drain.py getvar NAME                                one getvar
  scripts/laurel/fastboot-drain.py flash PARTITION FILE                       download + flash
  scripts/laurel/fastboot-drain.py reboot | reboot-bootloader
Why: on this ABL the stock fastboot client gets out of step (each command receives the previous
answer), so it refuses uploads ("download size is more than max allowed") and boots. Every command
here drains first, then reads its own replies (INFO lines printed) until OKAY/FAIL/DATA.
Optional --probe sends one 'getvar:product' after the drain and prints the answer.
"""
import argparse, ctypes, fcntl, glob, os, struct, sys, time

USBDEVFS_BULK = 0xC0185502            # _IOWR('U', 2, struct usbdevfs_bulktransfer), 64-bit
USBDEVFS_CLAIMINTERFACE = 0x8004550F  # _IOR('U', 15, unsigned int)
USBDEVFS_RELEASEINTERFACE = 0x80045510


def find(serial):
    for d in glob.glob('/sys/bus/usb/devices/*'):
        try:
            if serial and open(d + '/serial').read().strip() != serial:
                continue
        except OSError:
            continue
        for itf in glob.glob(d + '/*:1.*'):
            try:
                cls = [open(f'{itf}/{k}').read().strip() for k in ('bInterfaceClass', 'bInterfaceSubClass', 'bInterfaceProtocol')]
            except OSError:
                continue
            if cls == ['ff', '42', '03']:
                eps = [os.path.basename(e)[3:] for e in glob.glob(itf + '/ep_*')]
                ep_in = next(int(e, 16) for e in eps if int(e, 16) & 0x80)
                ep_out = next(int(e, 16) for e in eps if not int(e, 16) & 0x80 and e != '00')
                bus, dev = (int(open(f'{d}/{k}').read()) for k in ('busnum', 'devnum'))
                return f'/dev/bus/usb/{bus:03d}/{dev:03d}', int(open(itf + '/bInterfaceNumber').read(), 16), ep_in, ep_out
    sys.exit('fastboot-drain: no fastboot interface found')


def bulk(fd, ep, buf, timeout_ms):
    if isinstance(buf, (bytes, bytearray)):   # write: exactly these bytes (no trailing NUL)
        n = len(buf)
        cbuf = ctypes.create_string_buffer(bytes(buf), n)
    else:                                      # read: buf is the length
        n = buf
        cbuf = ctypes.create_string_buffer(n)
    arg = bytearray(struct.pack('IIIxxxxQ', ep, n, timeout_ms, ctypes.addressof(cbuf)))
    try:
        n = fcntl.ioctl(fd, USBDEVFS_BULK, arg, True)   # mutable arg: returns the transferred length
    except OSError:
        return None   # timeout (ETIMEDOUT) or error
    return cbuf.raw[:n]


def command(fd, ep_in, ep_out, cmd, timeout_ms=30000, tries=3):
    """Send one command, print INFO lines, return (status, text) of OKAY/FAIL/DATA.
    This ABL drops about 1 in 5 commands sent right after the previous answer ("unknown command";
    measured 2026-10-31: 0 ms gap ~20 %, 50 ms 1/20, 200 ms 0/20). So wait 200 ms first, and send
    again on "unknown command" (ABL did not run it)."""
    for attempt in range(tries):
        time.sleep(0.2)
        st, txt = _command(fd, ep_in, ep_out, cmd, timeout_ms)
        if not (st == 'FAIL' and txt == 'unknown command'):
            return st, txt
        print(f'fastboot-drain: {cmd!r}: unknown command, sending again ({attempt + 1}/{tries})')
    return st, txt


def _command(fd, ep_in, ep_out, cmd, timeout_ms):
    # NUL-padded to the 64-byte fastboot command maximum: this ABL keeps the bytes of a longer previous
    # command in its buffer, so a shorter command was read with that tail ("Variable Not found",
    # "unknown command", a garbled download size). The padding clears the tail.
    raw = cmd.encode()
    if len(raw) > 64:
        sys.exit(f'fastboot-drain: command longer than 64 bytes: {cmd!r}')
    if bulk(fd, ep_out, raw + b'\0' * (64 - len(raw)), 5000) is None:
        sys.exit(f'fastboot-drain: cannot send {cmd!r}')
    while True:
        r = bulk(fd, ep_in, 256, timeout_ms)
        if r is None:
            sys.exit(f'fastboot-drain: no answer to {cmd!r}')
        st, txt = r[:4].decode(errors='replace'), r[4:].rstrip(b'\0').decode(errors='replace')
        if st == 'INFO':
            print(f'(bootloader) {txt}')
            continue
        return st, txt


def drain(fd, ep_in, quiet):
    dropped = 0
    while True:
        r = bulk(fd, ep_in, 256, quiet)
        if not r:
            return dropped
        dropped += 1
        print(f'fastboot-drain: dropped {r!r}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--serial')
    ap.add_argument('--quiet', type=int, default=300)
    ap.add_argument('--probe', action='store_true')
    ap.add_argument('cmd', nargs='*')
    a = ap.parse_args()
    path, itf, ep_in, ep_out = find(a.serial)
    fd = os.open(path, os.O_RDWR)
    fcntl.ioctl(fd, USBDEVFS_CLAIMINTERFACE, struct.pack('I', itf))
    rc = 0
    try:
        n = drain(fd, ep_in, a.quiet)
        print(f'fastboot-drain: {n} stale replies dropped ({path}, ep 0x{ep_in:02x})')
        if a.probe:
            print('fastboot-drain: probe getvar:product -> %s %s' % command(fd, ep_in, ep_out, 'getvar:product'))
        c = a.cmd
        if not c:
            pass
        elif c[0] == 'getvar' and len(c) == 2:
            st, txt = command(fd, ep_in, ep_out, 'getvar:' + c[1])
            print(f'{c[1]}: {txt}' if st == 'OKAY' else f'getvar {c[1]}: {st} {txt}')
            rc = st != 'OKAY'
        elif c[0] == 'flash' and len(c) == 3:
            data = open(c[2], 'rb').read()
            st, txt = command(fd, ep_in, ep_out, 'getvar:max-download-size')
            if st == 'OKAY' and len(data) > int(txt, 0):
                sys.exit(f'fastboot-drain: {c[2]} is {len(data)} bytes, more than max-download-size {txt}')
            st, txt = command(fd, ep_in, ep_out, f'download:{len(data):08x}')
            if st != 'DATA' or int(txt, 16) != len(data):
                sys.exit(f'fastboot-drain: download refused: {st} {txt}')
            for off in range(0, len(data), 1 << 20):
                if bulk(fd, ep_out, data[off:off + (1 << 20)], 30000) is None:
                    sys.exit(f'fastboot-drain: upload stopped at {off}')
            r = bulk(fd, ep_in, 256, 30000)
            if r is None or r[:4] != b'OKAY':
                sys.exit(f'fastboot-drain: download not confirmed: {r!r}')
            print(f'fastboot-drain: sent {len(data)} bytes')
            st, txt = command(fd, ep_in, ep_out, f'flash:{c[1]}', 120000)
            print(f'fastboot-drain: flash {c[1]}: {st} {txt}')
            rc = st != 'OKAY'
        elif c[0] in ('reboot', 'reboot-bootloader') and len(c) == 1:
            st, txt = command(fd, ep_in, ep_out, c[0])
            print(f'fastboot-drain: {c[0]}: {st} {txt}')
            rc = st != 'OKAY'
        else:
            sys.exit(f'fastboot-drain: unknown command {c}')
    finally:
        try:
            fcntl.ioctl(fd, USBDEVFS_RELEASEINTERFACE, struct.pack('I', itf))
        except OSError:
            pass   # the device is gone after a reboot
        os.close(fd)
    sys.exit(rc)


if __name__ == '__main__':
    main()
