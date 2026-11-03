/*
 * laurel-speed: what the CPU, the memory and the kernel of the Mi A3 give to one iOS process. Plain C, ARMv8.0, no LSE.
 * Run on the phone: laurel-speed [all|clock|chase|copy|sys|wake|timer|fault|time] [THREADS]. Each line is one number with its unit.
 * Reference numbers on paper for a Cortex-A73 at 2016 MHz: 2.0 G dependent adds/s, L1 about 2 ns, L2 about 10 ns, DRAM 100-140 ns,
 * memcpy 5-8 GB/s, a syscall under 1 us, a wake-up of a sleeping thread 30-80 us, a timer 50-500 us late at most.
 * Docs: docs/laurel_sprout/ios26-default-speed.md. Script: scripts/laurel/ios26-speed.sh.
 */
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>

static mach_timebase_info_data_t tb;

static uint64_t
ns_now(void)
{
	return mach_absolute_time() * tb.numer / tb.denom;
}

/* 1. dependent integer adds: one per cycle on A73 and A53. Gives the real clock of the core the thread lands on. */
static double
clock_ghz(uint64_t iters)
{
	uint64_t x = 1, t0 = ns_now();
	__asm__ volatile(
		"1:\n\t"
		"add %0, %0, #1\n\t"
		"add %0, %0, #1\n\t"
		"add %0, %0, #1\n\t"
		"add %0, %0, #1\n\t"
		"add %0, %0, #1\n\t"
		"add %0, %0, #1\n\t"
		"add %0, %0, #1\n\t"
		"add %0, %0, #1\n\t"
		"subs %1, %1, #1\n\t"
		"b.ne 1b\n\t"
		: "+r"(x), "+r"(iters) : : "cc");
	uint64_t t1 = ns_now();
	return (double)(x - 1) / (double)(t1 - t0);
}

struct clock_arg { double ghz; int ms; };

static void *
clock_thread(void *p)
{
	struct clock_arg *a = p;
	uint64_t t0 = ns_now();
	a->ghz = clock_ghz(50 * 1000 * 1000);
	a->ms = (int)((ns_now() - t0) / 1000000);
	return NULL;
}

static void
do_clock(int threads)
{
	struct clock_arg a[16];
	pthread_t th[16];
	if (threads > 16) threads = 16;
	for (int i = 0; i < threads; i++) pthread_create(&th[i], NULL, clock_thread, &a[i]);
	for (int i = 0; i < threads; i++) pthread_join(th[i], NULL);
	printf("clock: %d threads at once, dependent adds, GHz each:", threads);
	for (int i = 0; i < threads; i++) printf(" %.2f", a[i].ghz);
	printf("\n");
}

/* 2. pointer chase over a random cycle of cache lines: load-to-use latency of L1, L2 and DRAM */
static double
chase_ns(size_t bytes, uint64_t steps)
{
	size_t lines = bytes / 64;
	uint8_t *buf = malloc(bytes + 64);
	uint8_t *b = (uint8_t *)(((uintptr_t)buf + 63) & ~(uintptr_t)63);
	size_t *perm = malloc(lines * sizeof(size_t));
	for (size_t i = 0; i < lines; i++) perm[i] = i;
	uint64_t r = 0x9e3779b97f4a7c15ull ^ bytes;
	for (size_t i = lines - 1; i > 0; i--) {
		r ^= r << 13; r ^= r >> 7; r ^= r << 17;
		size_t j = r % (i + 1);
		size_t t = perm[i]; perm[i] = perm[j]; perm[j] = t;
	}
	for (size_t i = 0; i < lines; i++) {
		*(uint8_t **)(b + perm[i] * 64) = b + perm[(i + 1) % lines] * 64;
	}
	uint8_t *p = b;
	for (size_t i = 0; i < lines; i++) p = *(uint8_t **)p;   /* warm */
	uint64_t t0 = ns_now();
	for (uint64_t i = 0; i < steps; i++) p = *(uint8_t **)p;
	uint64_t t1 = ns_now();
	free(perm);
	if (p == NULL) printf("?");
	free(buf);
	return (double)(t1 - t0) / (double)steps;
}

static void
do_chase(void)
{
	printf("chase: load-to-use ns: 16 KiB %.1f, 128 KiB %.1f, 1 MiB %.1f, 8 MiB %.1f, 64 MiB %.1f\n",
	    chase_ns(16 << 10, 4000000), chase_ns(128 << 10, 4000000), chase_ns(1 << 20, 2000000), chase_ns(8 << 20, 1000000), chase_ns(64 << 20, 500000));
}

/* 3. memcpy and memset of 32 MiB, cached heap memory */
static void
do_copy(void)
{
	size_t n = 32 << 20;
	uint8_t *a = malloc(n), *b = malloc(n);
	memset(a, 1, n); memset(b, 2, n);
	uint64_t t0 = ns_now();
	for (int i = 0; i < 4; i++) memcpy(b, a, n);
	uint64_t t1 = ns_now();
	for (int i = 0; i < 4; i++) memset(a, i, n);
	uint64_t t2 = ns_now();
	uint64_t s = 0;
	for (size_t i = 0; i < n; i += 8) s += *(uint64_t *)(a + i);
	uint64_t t3 = ns_now();
	printf("copy: memcpy %.2f GB/s, memset %.2f GB/s, read %.2f GB/s (sum %llu)\n",
	    4.0 * n / (t1 - t0), 4.0 * n / (t2 - t1), 1.0 * n / (t3 - t2), (unsigned long long)s);
	free(a); free(b);
}

/* 4. the cost of a trap into the kernel, and of the time reads that CoreAnimation makes */
static void
do_sys(void)
{
	uint64_t t0 = ns_now();
	for (int i = 0; i < 100000; i++) getppid();
	uint64_t t1 = ns_now();
	for (int i = 0; i < 1000000; i++) mach_absolute_time();
	uint64_t t2 = ns_now();
	mach_port_t self = mach_task_self();
	for (int i = 0; i < 100000; i++) {
		mach_port_t p = MACH_PORT_NULL;
		mach_port_allocate(self, MACH_PORT_RIGHT_RECEIVE, &p);
		mach_port_mod_refs(self, p, MACH_PORT_RIGHT_RECEIVE, -1);
	}
	uint64_t t3 = ns_now();
	printf("sys: getppid %.2f us, mach_absolute_time %.1f ns, mach port make+drop %.2f us\n",
	    (t1 - t0) / 100000.0 / 1000, (t2 - t1) / 1000000.0, (t3 - t2) / 100000.0 / 1000);
}

/* 5. wake-up: two threads pass a mach semaphore back and forth; each half trip is one wake of a sleeping thread */
static semaphore_t s_ping, s_pong;
static int wake_trips;

static void *
pong_thread(void *p)
{
	for (int i = 0; i < wake_trips; i++) {
		semaphore_wait(s_ping);
		semaphore_signal(s_pong);
	}
	return NULL;
}

static void
do_wake(void)
{
	semaphore_create(mach_task_self(), &s_ping, SYNC_POLICY_FIFO, 0);
	semaphore_create(mach_task_self(), &s_pong, SYNC_POLICY_FIFO, 0);
	wake_trips = 2000;
	pthread_t th;
	pthread_create(&th, NULL, pong_thread, NULL);
	uint64_t worst = 0, sum = 0;
	for (int i = 0; i < wake_trips; i++) {
		uint64_t t0 = ns_now();
		semaphore_signal(s_ping);
		semaphore_wait(s_pong);
		uint64_t d = ns_now() - t0;
		sum += d;
		if (d > worst) worst = d;
		if ((i & 15) == 0) usleep(300);         /* let both sleep: the wake is from idle, as a vsync wake is */
	}
	pthread_join(th, NULL);
	printf("wake: semaphore round trip (2 wakes): mean %.1f us, worst %.1f us, %d trips\n", sum / 1000.0 / wake_trips, worst / 1000.0, wake_trips);
	/* a mach_msg round trip: the path a vsync takes */
	mach_port_t port;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
	mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
	struct { mach_msg_header_t h; uint64_t v[6]; } msg;
	struct { mach_msg_header_t h; uint64_t v[6]; mach_msg_trailer_t t; } in;
	sum = worst = 0;
	for (int i = 0; i < 2000; i++) {
		uint64_t t0 = ns_now();
		memset(&msg, 0, sizeof(msg));
		msg.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
		msg.h.msgh_size = sizeof(msg);
		msg.h.msgh_remote_port = port;
		mach_msg(&msg.h, MACH_SEND_MSG, sizeof(msg), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
		mach_msg(&in.h, MACH_RCV_MSG, 0, sizeof(in), port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
		uint64_t d = ns_now() - t0;
		sum += d;
		if (d > worst) worst = d;
	}
	printf("wake: mach_msg send+receive on one thread: mean %.1f us, worst %.1f us\n", sum / 1000.0 / 2000, worst / 1000.0);
}

/* 6. timer: how late a sleep of 1 ms and of 16 ms ends */
static void
timer_one(uint64_t want_ns, int n, const char *what)
{
	uint64_t worst = 0, sum = 0;
	for (int i = 0; i < n; i++) {
		uint64_t t0 = ns_now();
		mach_wait_until(mach_absolute_time() + want_ns * tb.denom / tb.numer);
		uint64_t d = ns_now() - t0 - want_ns;
		sum += d;
		if (d > worst) worst = d;
	}
	printf("timer: mach_wait_until %s: late by mean %.1f us, worst %.1f us (%d)\n", what, sum / 1000.0 / n, worst / 1000.0, n);
}

static void
do_timer(void)
{
	timer_one(1000000, 300, "1 ms");
	timer_one(16666000, 60, "16.7 ms");
	uint64_t worst = 0, sum = 0;
	for (int i = 0; i < 300; i++) {
		uint64_t t0 = ns_now();
		usleep(1000);
		uint64_t d = ns_now() - t0 - 1000000;
		sum += d;
		if (d > worst) worst = d;
	}
	printf("timer: usleep 1 ms: late by mean %.1f us, worst %.1f us (300)\n", sum / 1000.0 / 300, worst / 1000.0);
}

/* 7. page faults: first touch of fresh anonymous pages, and a second pass over the same pages */
static void
do_fault(void)
{
	size_t n = 64 << 20;
	uint8_t *m = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
	if (m == MAP_FAILED) { printf("fault: mmap: %s\n", strerror(errno)); return; }
	uint64_t t0 = ns_now();
	for (size_t i = 0; i < n; i += 4096) m[i] = 1;
	uint64_t t1 = ns_now();
	for (size_t i = 0; i < n; i += 4096) m[i] = 2;
	uint64_t t2 = ns_now();
	printf("fault: first touch %.2f us a 4 KiB page, second pass %.3f us a page, page size %d\n",
	    (t1 - t0) / 1000.0 / (n / 4096), (t2 - t1) / 1000.0 / (n / 4096), getpagesize());
	munmap(m, n);
}

static void
do_time(void)
{
	printf("time: timebase %u/%u, mach_absolute_time %llu\n", tb.numer, tb.denom, (unsigned long long)mach_absolute_time());
}

int
main(int argc, char **argv)
{
	const char *what = argc > 1 ? argv[1] : "all";
	int threads = argc > 2 ? atoi(argv[2]) : 8;
	mach_timebase_info(&tb);
	setvbuf(stdout, NULL, _IOLBF, 0);
	int all = strcmp(what, "all") == 0;
	if (all || !strcmp(what, "time")) do_time();
	if (all || !strcmp(what, "clock")) { do_clock(1); do_clock(threads); }
	if (all || !strcmp(what, "chase")) do_chase();
	if (all || !strcmp(what, "copy")) do_copy();
	if (all || !strcmp(what, "sys")) do_sys();
	if (all || !strcmp(what, "wake")) do_wake();
	if (all || !strcmp(what, "timer")) do_timer();
	if (all || !strcmp(what, "fault")) do_fault();
	return 0;
}
