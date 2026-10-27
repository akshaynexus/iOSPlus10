/*
 * negroni-locd: feed positions into locationd through its simulation service (docs/location-plan.md, path L1).
 *
 *   negroni-locd set LAT LON [ACC]       one position (ACC = horizontal accuracy in m, default 10), then exit
 *   negroni-locd hold LAT LON [ACC]      the same, but stay and send the position again every -r seconds
 *   negroni-locd listen [PORT]           read fix lines (or "stop") from UDP PORT (default 5155)
 *   negroni-locd stop                    end a running listener (pid file) and stop the simulation
 *   negroni-locd enable | disable        Location Services switch (+[CLLocationManager setLocationServicesEnabled:])
 *   negroni-locd status                  +[CLLocationManager locationServicesEnabled], listener pid
 * Options (before the command):
 *   -r SEC    hold/listen: send the last position again every SEC s with a new timestamp (default 1; 0 = off)
 *   -a ADDR   listen: local address (default 192.168.7.2, the phone's USB network address; 0.0.0.0 = all)
 *   -s ADDR   listen: accept datagrams only from ADDR (default 192.168.7.1, the Mac; "any" = all)
 *             UNSAFE: "-a 0.0.0.0 -s any" lets any host on any network (Wi-Fi, cellular) set the phone's
 *             position. Never the default; the launchd job and the scripts in scripts/location do not use it.
 *   -b        listen/hold: run in the background (log /private/var/log/iosplus10-negroni-locd.log); the fork
 *             happens before CoreLocation/XPC/libdispatch are used (a forked child must not use them)
 *   -k        listen/hold: keep the simulation on when the program ends (default: stop it)
 *
 * How it works: CoreLocation is opened with dlopen; the private class CLSimulationManager connects to the
 * locationd mach service com.apple.locationd.simulation. locationd accepts the connection only if the client
 * has the entitlement com.apple.locationd.simulation = true ([V] 20H392 locationd: valueForEntitlement: +
 * NSNumber boolValue check before the "unentitled client attempting to simulate location" log line).
 * Call order stop/clear/append/flush/start: [V] on the phone 2026-10-27 (ClxSimulated fixes every 1 s after one set).
 * enable/disable: locationd's CLInternalService SPI accepts setLocationServicesEnabled only with the entitlement
 * com.apple.locationd.authorizeapplications ([V] 20H392, the same one Preferences.app has); else it logs
 * "#Spi, connecting process isn't entitled, they shall not pass".
 * Signed ad hoc with entitlements.plist (userland/location/build.sh). Our own code.
 *
 * Input interface (docs/location-plan.md section 6): every source makes a struct nl_fix and calls fix_deliver().
 * The text form of a fix, one per line (UDP today; a later kernel GNSS source can give the same lines):
 *   LAT LON [HACC [ALT VACC [SPEED COURSE]]]
 *   LAT -90..90, LON -180..180 (degrees, WGS-84); HACC m (0 < HACC <= 100000, default 10); ALT m above sea level
 *   with VACC m (VACC -1 = no altitude, the default); SPEED m/s (-1 = unknown) and COURSE degrees 0..360
 *   (-1 = unknown). Fields are separated by spaces or tabs; "stop" ends the simulation. The timestamp is the
 *   time of delivery (CoreLocation's simulation takes the CLLocation as it is; a source sends fresh fixes only).
 */
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>   /* types and method declarations only; no class is linked */
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/in.h>
#include <os/log.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#define CL_PATH "/System/Library/Frameworks/CoreLocation.framework/CoreLocation"
#define PIDFILE "/private/var/run/negroni-locd.pid"
#define LOGFILE "/private/var/log/iosplus10-negroni-locd.log"
#define DEF_PORT 5155

/* private API, iOS 16.7 CoreLocation (class-dump of the 20H392 shared cache) */
@protocol NLSimManager <NSObject>
- (void)appendSimulatedLocation:(id)location;
- (void)clearSimulatedLocations;
- (void)startLocationSimulation;
- (void)stopLocationSimulation;
- (void)flush;
@end
@protocol NLLocationManagerClass <NSObject>
+ (void)setLocationServicesEnabled:(BOOL)enabled;
+ (BOOL)locationServicesEnabled;
@end

static os_log_t lg;
static volatile sig_atomic_t quit;
static double opt_repeat = 1.0;
static const char *opt_addr = "192.168.7.2", *opt_src = "192.168.7.1";
static int opt_bg, opt_keep, any_src;
static struct in_addr src_addr;

static void
say(const char *fmt, ...)
{
	char buf[512], ts[32];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof buf, fmt, ap);
	va_end(ap);
	time_t t = time(NULL);
	strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
	fprintf(stderr, "%s negroni-locd: %s\n", ts, buf);
	os_log(lg, "negroni-locd: %{public}s", buf);
}

static int
load_cl(void)
{
	if (dlopen(CL_PATH, RTLD_NOW) == NULL) {
		say("dlopen CoreLocation failed: %s", dlerror());
		return -1;
	}
	return 0;
}

static id<NLSimManager>
sim_new(void)
{
	Class c = NSClassFromString(@"CLSimulationManager");
	if (c == Nil) {
		say("class CLSimulationManager not found");
		return nil;
	}
	return [[c alloc] init];
}

/* one position fix, whatever its source (the input interface; see the header comment) */
struct nl_fix {
	double lat, lon, hacc;  /* degrees, degrees, m */
	double alt, vacc;       /* m; vacc -1 = no altitude */
	double speed, course;   /* m/s, degrees; -1 = unknown */
};

static int
num(const char *s, double *v)
{
	char *e;
	*v = strtod(s, &e);
	return (*e || e == s || !isfinite(*v)) ? -1 : 0;
}

/* n text fields (2, 3, 5 or 7) in the order LAT LON HACC ALT VACC SPEED COURSE -> *f; 0 or -1 */
static int
parse_fix(char *const *t, int n, struct nl_fix *f)
{
	*f = (struct nl_fix){ .hacc = 10, .vacc = -1, .speed = -1, .course = -1 };
	if (n != 2 && n != 3 && n != 5 && n != 7) return -1;
	if (num(t[0], &f->lat) || num(t[1], &f->lon)) return -1;
	if (n >= 3 && num(t[2], &f->hacc)) return -1;
	if (n >= 5 && (num(t[3], &f->alt) || num(t[4], &f->vacc))) return -1;
	if (n >= 7 && (num(t[5], &f->speed) || num(t[6], &f->course))) return -1;
	if (f->lat < -90 || f->lat > 90 || f->lon < -180 || f->lon > 180 || f->hacc <= 0 || f->hacc > 100000) return -1;
	if (f->vacc != -1 && (f->vacc <= 0 || f->vacc > 100000 || f->alt < -1000 || f->alt > 100000)) return -1;
	if (f->speed != -1 && (f->speed < 0 || f->speed > 1000)) return -1;
	if (f->course != -1 && (f->course < 0 || f->course > 360)) return -1;
	return 0;
}

static int
fix_same(const struct nl_fix *a, const struct nl_fix *b)
{
	return memcmp(a, b, sizeof *a) == 0;
}

static id
make_location(const struct nl_fix *f)
{
	Class c = NSClassFromString(@"CLLocation");
	CLLocationCoordinate2D co;
	co.latitude = f->lat;
	co.longitude = f->lon;
	return [[c alloc] initWithCoordinate:co altitude:(f->vacc > 0 ? f->alt : 0) horizontalAccuracy:f->hacc
	                    verticalAccuracy:f->vacc course:f->course speed:f->speed timestamp:[NSDate date]];
}

/* the one output: a fix into locationd's simulation service */
static void
fix_deliver(id<NLSimManager> m, const struct nl_fix *f, int quiet)
{
	id loc = make_location(f);
	[m stopLocationSimulation];
	[m clearSimulatedLocations];
	[m appendSimulatedLocation:loc];
	[m flush];
	[m startLocationSimulation];
	[m flush];
	if (!quiet)
		say("position %.7f %.7f acc %.1f m sent", f->lat, f->lon, f->hacc);
}

static void
sim_stop(id<NLSimManager> m)
{
	[m stopLocationSimulation];
	[m clearSimulatedLocations];
	[m flush];
	say("simulation stopped");
}

static void
on_signal(int s)
{
	quit = 1;
}

static void
background(void)
{
	pid_t p = fork();
	if (p < 0) { perror("fork"); exit(1); }
	if (p > 0) { printf("negroni-locd: pid %d, log %s\n", p, LOGFILE); exit(0); }
	setsid();
	int fd = open(LOGFILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
	int nul = open("/dev/null", O_RDONLY);
	if (nul >= 0) dup2(nul, 0);
	if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); }
}

static void
pidfile_write(void)
{
	FILE *f = fopen(PIDFILE, "w");
	if (f) { fprintf(f, "%d\n", getpid()); fclose(f); }
}

/* the pid file may be stale and the pid reused: act only on a process named negroni-locd */
static int
is_locd(pid_t p)
{
	struct kinfo_proc kp;
	size_t n = sizeof kp;
	int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, p};
	memset(&kp, 0, sizeof kp);
	if (sysctl(mib, 4, &kp, &n, NULL, 0) != 0 || n == 0) return 0;
	return strcmp(kp.kp_proc.p_comm, "negroni-locd") == 0;
}

static pid_t
pidfile_read(void)
{
	FILE *f = fopen(PIDFILE, "r");
	int p = 0;
	if (f == NULL) return 0;
	if (fscanf(f, "%d", &p) != 1) p = 0;
	fclose(f);
	if (p > 1 && kill(p, 0) == 0 && is_locd(p)) return p;
	return 0;
}

static void
sigsetup(void)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_signal;          /* no SA_RESTART: select() returns EINTR */
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);
}

static int
cmd_hold(id<NLSimManager> m, const struct nl_fix *f)
{
	pidfile_write();
	sigsetup();
	fix_deliver(m, f, 0);
	while (!quit) {
		if (opt_repeat <= 0) { pause(); continue; }
		usleep((useconds_t)(opt_repeat * 1e6));
		if (!quit) @autoreleasepool { fix_deliver(m, f, 1); }
	}
	if (!opt_keep) sim_stop(m);
	unlink(PIDFILE);
	return 0;
}

static int
open_udp(int port)
{
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_len = sizeof a;
	a.sin_family = AF_INET;
	a.sin_port = htons(port);
	if (inet_pton(AF_INET, opt_addr, &a.sin_addr) != 1) {
		say("bad address %s", opt_addr);
		return -2;
	}
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) return -1;
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) {
		int e = errno;
		close(fd);
		errno = e;
		return -1;
	}
	return fd;
}

static int
cmd_listen(id<NLSimManager> m, int port)
{
	pidfile_write();
	sigsetup();

	int fd = -1, warned = 0;
	while (!quit && fd < 0) {   /* at boot the USB address may come later: retry every 5 s */
		fd = open_udp(port);
		if (fd == -2) { unlink(PIDFILE); return 2; }
		if (fd < 0) {
			if (!warned++) say("bind %s:%d failed (%s); retrying every 5 s", opt_addr, port, strerror(errno));
			sleep(5);
		}
	}
	if (fd < 0) { unlink(PIDFILE); return 1; }
	say("listening on udp %s:%d (from %s), repeat %.1f s", opt_addr, port, opt_src, opt_repeat);

	int have = 0;
	struct nl_fix cur;
	struct timespec last = {0, 0};
	while (!quit) @autoreleasepool {
		fd_set rs;
		FD_ZERO(&rs);
		FD_SET(fd, &rs);
		struct timeval tv = {1, 0};
		if (opt_repeat > 0 && opt_repeat < 1) { tv.tv_sec = 0; tv.tv_usec = (int)(opt_repeat * 1e6); }
		int n = select(fd + 1, &rs, NULL, NULL, &tv);
		if (n < 0 && errno != EINTR) { say("select: %s", strerror(errno)); break; }
		if (n > 0 && FD_ISSET(fd, &rs)) {
			char buf[1024];
			struct sockaddr_in from;
			socklen_t fl = sizeof from;
			ssize_t r = recvfrom(fd, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
			if (r > 0) {
				buf[r] = 0;
				if (!any_src && from.sin_addr.s_addr != src_addr.s_addr) {
					say("datagram from %s ignored", inet_ntoa(from.sin_addr));
					continue;
				}
				/* the last valid line of the datagram wins */
				char *save = NULL, *line;
				int got = 0, stop = 0;
				struct nl_fix nf, in;
				for (line = strtok_r(buf, "\r\n", &save); line; line = strtok_r(NULL, "\r\n", &save)) {
					char copy[256], *t[8], *s2 = NULL, *w;
					int k = 0;
					strlcpy(copy, line, sizeof copy);
					for (w = strtok_r(copy, " \t", &s2); w && k < 8; w = strtok_r(NULL, " \t", &s2)) t[k++] = w;
					if (k == 1 && strcmp(t[0], "stop") == 0) { stop = 1; got = 0; continue; }
					if (k > 0 && k < 8 && parse_fix(t, k, &in) == 0) { nf = in; got = 1; stop = 0; }
					else if (k > 0) say("bad line ignored: %.80s", line);
				}
				if (stop && have) { sim_stop(m); have = 0; }
				if (got) {
					int moved = !have || !fix_same(&nf, &cur);
					cur = nf; have = 1;
					fix_deliver(m, &cur, !moved);
					clock_gettime(CLOCK_MONOTONIC, &last);
				}
			}
		}
		if (have && opt_repeat > 0) {
			struct timespec now;
			clock_gettime(CLOCK_MONOTONIC, &now);
			double dt = (now.tv_sec - last.tv_sec) + (now.tv_nsec - last.tv_nsec) / 1e9;
			if (dt >= opt_repeat) { fix_deliver(m, &cur, 1); last = now; }
		}
	}
	close(fd);
	if (have && !opt_keep) sim_stop(m);
	unlink(PIDFILE);
	say("listener ended");
	return 0;
}

static void
usage(void)
{
	fprintf(stderr,
	    "usage: negroni-locd [-r SEC] [-a ADDR] [-s ADDR|any] [-b] [-k] COMMAND\n"
	    "  set LAT LON [ACC] | hold LAT LON [ACC] | listen [PORT] | stop | enable | disable | status\n");
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		int o;
		char *e;
		while ((o = getopt(argc, argv, "r:a:s:bkh")) != -1) {
			switch (o) {
			case 'r':
			opt_repeat = strtod(optarg, &e);
			if (*e || e == optarg || !isfinite(opt_repeat) || opt_repeat < 0 || opt_repeat > 3600) {
				fprintf(stderr, "negroni-locd: -r SEC: 0..3600\n");
				return 2;
			}
			break;
			case 'a': opt_addr = optarg; break;
			case 's': opt_src = optarg; break;
			case 'b': opt_bg = 1; break;
			case 'k': opt_keep = 1; break;
			default: usage(); return 2;
			}
		}
		argc -= optind;
		argv += optind;
		if (argc < 1) { usage(); return 2; }
		const char *cmd = argv[0];
		int is_set = strcmp(cmd, "set") == 0, is_hold = strcmp(cmd, "hold") == 0;
		int is_listen = strcmp(cmd, "listen") == 0;
		struct nl_fix fix;
		int port = DEF_PORT;
		/* check every argument before CoreLocation, XPC or libdispatch are used: -b forks below */
		if (is_set || is_hold) {
			if (argc < 3 || argc > 4 || parse_fix(argv + 1, argc - 1, &fix)) {
				fprintf(stderr, "negroni-locd: %s LAT LON [ACC]: LAT -90..90, LON -180..180, ACC 0..100000 m\n", cmd);
				return 2;
			}
		}
		if (is_listen) {
			if (argc >= 2) {
				long v = strtol(argv[1], &e, 10);
				port = (*e || e == argv[1] || v <= 0 || v > 65535) ? -1 : (int)v;
			}
			if (port < 0 || argc > 2) { usage(); return 2; }
			struct in_addr tmp;
			if (inet_pton(AF_INET, opt_addr, &tmp) != 1) {
				fprintf(stderr, "negroni-locd: bad address %s\n", opt_addr);
				return 2;
			}
			any_src = strcmp(opt_src, "any") == 0;
			if (!any_src && inet_pton(AF_INET, opt_src, &src_addr) != 1) {
				fprintf(stderr, "negroni-locd: bad source address %s\n", opt_src);
				return 2;
			}
		}
		if (opt_bg && (is_hold || is_listen)) background();
		lg = os_log_create("dev.iosplus10.negroni-locd", "sim");
		/* listen runs under launchd (KeepAlive SuccessfulExit=false): a permanent error exits 0, so launchd
		 * does not restart it every ThrottleInterval */
		int perm = is_listen ? 0 : 1;
		if (load_cl() < 0) return perm;

		if (strcmp(cmd, "enable") == 0 || strcmp(cmd, "disable") == 0 || strcmp(cmd, "status") == 0) {
			Class<NLLocationManagerClass> lm = (Class<NLLocationManagerClass>)NSClassFromString(@"CLLocationManager");
			if (lm == Nil) { say("class CLLocationManager not found"); return 1; }
			if (cmd[0] != 's') {
				BOOL on = cmd[0] == 'e';
				[lm setLocationServicesEnabled:on];
				usleep(500000);
				say("setLocationServicesEnabled:%d sent", on);
			}
			pid_t p = pidfile_read();
			printf("locationServicesEnabled %d\nlistener %s", [lm locationServicesEnabled], p ? "" : "none\n");
			if (p) printf("pid %d\n", p);
			return 0;
		}

		id<NLSimManager> m = sim_new();
		if (m == nil) {
			if (is_listen) say("permanent error: listener not started (exit 0, no launchd restart)");
			return perm;
		}
		if (is_set || is_hold) {
			if (is_hold) return cmd_hold(m, &fix);
			fix_deliver(m, &fix, 0);
			usleep(300000);   /* let the XPC messages leave before exit */
			return 0;
		}
		if (is_listen)
			return cmd_listen(m, port);
		if (strcmp(cmd, "stop") == 0) {
			pid_t p = pidfile_read();
			if (p) {
				kill(p, SIGTERM);
				for (int i = 0; i < 30 && kill(p, 0) == 0; i++) usleep(100000);
				say("listener pid %d ended", p);
			}
			sim_stop(m);
			usleep(300000);
			return 0;
		}
		usage();
		return 2;
	}
}
