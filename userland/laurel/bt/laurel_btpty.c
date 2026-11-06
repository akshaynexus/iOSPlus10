/*
 * liblaurel-btpty.dylib: inserted into bluetoothd by /usr/local/libexec/laurel-bluetoothd (btd_wrap.c). Port of Scion
 * 2e0c90a userland/src/inject_bluetoothd.c (Galaxy S9, bluetoothd 16.5; MIT).
 *
 * When an accessory offers iAP over Bluetooth (the Sony WH-1000XM3 does, on an RFCOMM channel), bluetoothd opens the
 * "Wireless IAP" profile as soon as the device is paired: it makes a PTY (openpty), hands the peripheral end to the
 * accessory server (com.apple.accessories.transport-server: not on this root) and from then on writes what the accessory
 * sends over iAP into the central end, from its stack thread, holding the stack's mutex. Nobody reads the other end, so
 * after a few hundred bytes the PTY is full and that write() sleeps in the kernel ("ptcout") for good; 20 s later
 * bluetoothd's watchdog finds the mutex still taken ("Stack Mutex try lock failed and watchdog has struck twice --
 * abort"), bluetoothd exits and the headphones are dropped [V Scion, S9, 2026-11-03]. On this phone: not yet seen [U];
 * the same bluetoothd code runs here (23F84 and 20H392 have openpty in bluetoothd).
 *
 * bluetoothd itself makes the central end non-blocking in one of its configurations (fcntl F_SETFL O_NONBLOCK after
 * openpty), only not in the one this phone gets. So here, in bluetoothd and nowhere else, openpty's central end is
 * always made non-blocking: a write the PTY has no room for fails (EAGAIN) and is dropped instead of stopping the
 * stack. iAP itself goes nowhere (there is no accessory server); A2DP, AVRCP and HFP do not use the PTY.
 *
 * Lines (bluetoothd's stderr, /var/tmp/laurel-bt.log through the wrapper): "LAUREL BT PTY: on: in bluetoothd (pid N)",
 * "LAUREL BT PTY: /dev/ttysNNN: central end FD non-blocking". Kill switch: boot-arg laurel_btpty=0 (the wrapper then
 * runs bluetoothd without this library).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static void
say(const char *format, ...)
{
	char line[300];
	va_list ap;
	int n;

	va_start(ap, format);
	n = vsnprintf(line, sizeof(line), format, ap);
	va_end(ap);
	if (n > 0) {
		write(2, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1);
	}
}

__attribute__((constructor)) static void
hello(void)
{
	say("LAUREL BT PTY: on: in bluetoothd (pid %d): openpty's central end non-blocking (nothing reads an iAP PTY here)\n",
	    getpid());
}

static int
laurel_openpty(int *central, int *peripheral, char *name, struct termios *termp, struct winsize *winp)
{
	int r = openpty(central, peripheral, name, termp, winp);
	int saved = errno;

	if (r == 0 && central != NULL) {
		int flags = fcntl(*central, F_GETFL);

		if (flags >= 0 && fcntl(*central, F_SETFL, flags | O_NONBLOCK) == 0) {
			say("LAUREL BT PTY: %s: central end %d non-blocking\n", name != NULL ? name : "?", *central);
		} else {
			say("LAUREL BT PTY: off: fcntl on the central end failed (errno %d): this PTY can block the stack\n", errno);
		}
	}
	errno = saved;
	return r;
}

__attribute__((used)) static const struct { const void *replacement, *replacee; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)laurel_openpty, (const void *)openpty },
};
