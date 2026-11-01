/*
 * laurel-airplay: the self-check of AirPlay on the Mi A3. Job com.laurel.airplay (scripts/laurel/root-airplay-job.py); runs once at boot, then exits.
 * docs/laurel_sprout/airplay-airdrop.md. It changes nothing: Apple's sender in mediaserverd does the AirPlay work.
 *
 * Sender side of iOS 16.7 20H392 [V strings, AirPlaySender and APTransport in the dyld cache]: mediaserverd (Mach service com.apple.airplay.sender.xpc)
 * browses _airplay._tcp and _raop._tcp. Here that is en0 only: no awdl0. What each stage needs, in the order of the line:
 *   IPv4 on en0, mDNSResponder browse, a receiver heard, the sender's Mach service;
 *   fp-setup (APAuthenticationClientFairPlay): com.apple.fairplayd.versioned; receivers that ask for it fail without it;
 *   buffered audio (APSNetworkClockPTP): IOTimeSyncDomain in the kernel;
 *   mirroring: the encoder of AppleVideoEncoder.bundle, IOService AppleAVE2Driver.
 *
 * One line on the console (USB log) and in syslog, one more when it changes (at most 3 tries):
 *   LAUREL AIRPLAY: on: en0 192.168.1.5, default route en0, _airplay._tcp 2, _raop._tcp 3 heard; sender up; fp-setup off: ...; buffered audio off: ...; mirroring off: ...
 *   LAUREL AIRPLAY: off: <reason>
 * Kill switch: boot-arg airplay=0. A failure here cannot touch Wi-Fi: it only reads.
 */
#include <arpa/inet.h>
#include <dns_sd.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>

/* libSystem; bootstrap.h is not in the public iOS SDK */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);

#define BROWSE_S    15          /* a Bonjour answer comes in the first seconds */
#define NO_LINK_S   600         /* the first line without a link */
#define RETRY_S     300         /* no receiver heard: look again */
#define TRIES       3
#define NAMES       32

static char last[512];

static void
say(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	int fd;

	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	if (strcmp(line, last) == 0) {
		return;
	}
	strlcpy(last, line, sizeof(last));
	syslog(LOG_NOTICE, "LAUREL AIRPLAY: %s", line);
	if ((fd = open("/dev/console", O_WRONLY | O_NOCTTY)) >= 0) {
		dprintf(fd, "LAUREL AIRPLAY: %s\n", line);
		close(fd);
	}
}

static bool
switched_off(void)
{
	char args[1024] = "";
	size_t len = sizeof(args) - 1;
	const char *p = args;

	(void)sysctlbyname("kern.bootargs", args, &len, NULL, 0);
	while ((p = strstr(p, "airplay=0")) != NULL) {
		if ((p == args || p[-1] == ' ') && (p[9] == 0 || p[9] == ' ')) {
			return true;
		}
		p += 9;
	}
	return false;
}

/* the IPv4 address of en0, false if none */
static bool
en0_ipv4(char *out, size_t n)
{
	struct ifaddrs *all = NULL;
	bool found = false;

	if (getifaddrs(&all) != 0) {
		return false;
	}
	for (struct ifaddrs *a = all; a != NULL && !found; a = a->ifa_next) {
		if (a->ifa_addr != NULL && a->ifa_addr->sa_family == AF_INET && strcmp(a->ifa_name, "en0") == 0 && (a->ifa_flags & IFF_UP) != 0) {
			found = inet_ntop(AF_INET, &((struct sockaddr_in *)(void *)a->ifa_addr)->sin_addr, out, (socklen_t)n) != NULL;
		}
	}
	freeifaddrs(all);
	return found;
}

/*
 * Does the default route go through en0? A UDP connect() picks the route and sends nothing. docs/laurel_sprout/wifi.md "No page loads": with ue0 first, no name
 * resolves over Wi-Fi. A receiver on the LAN is on-link either way, so this is one word on the line, not a verdict.
 */
static bool
default_route_is(const char *ip)
{
	struct sockaddr_in to = { .sin_len = sizeof(to), .sin_family = AF_INET, .sin_port = htons(9) }, me;
	socklen_t len = sizeof(me);
	char got[64] = "";
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	bool same = false;

	if (fd < 0) {
		return false;
	}
	to.sin_addr.s_addr = htonl(0x01010101);
	if (connect(fd, (struct sockaddr *)&to, sizeof(to)) == 0 && getsockname(fd, (struct sockaddr *)&me, &len) == 0 &&
	    inet_ntop(AF_INET, &me.sin_addr, got, sizeof(got)) != NULL) {
		same = strcmp(got, ip) == 0;
	}
	close(fd);
	return same;
}

static bool
mach_service(const char *name)
{
	mach_port_t port = MACH_PORT_NULL;

	if (bootstrap_look_up(bootstrap_port, name, &port) != KERN_SUCCESS) {
		return false;
	}
	mach_port_deallocate(mach_task_self(), port);
	return true;
}

static bool
io_service(const char *class)
{
	io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(class));

	if (s == IO_OBJECT_NULL) {
		return false;
	}
	IOObjectRelease(s);
	return true;
}

struct seen {
	unsigned count;
	char names[NAMES][64];
};

static void DNSSD_API
on_browse(DNSServiceRef ref, DNSServiceFlags flags, uint32_t ifindex, DNSServiceErrorType err, const char *name, const char *type,
    const char *domain, void *context)
{
	struct seen *s = context;

	(void)ref;
	(void)ifindex;
	(void)type;
	(void)domain;
	if (err != kDNSServiceErr_NoError || !(flags & kDNSServiceFlagsAdd)) {
		return;
	}
	for (unsigned i = 0; i < s->count; i++) {
		if (strncmp(s->names[i], name, sizeof(s->names[i]) - 1) == 0) {
			return;
		}
	}
	if (s->count < NAMES) {
		strlcpy(s->names[s->count++], name, sizeof(s->names[0]));
	}
}

/* both browses at once on en0; the error of DNSServiceBrowse, or 0 */
static int
browse(struct seen *airplay, struct seen *raop)
{
	DNSServiceRef ref[2] = { NULL, NULL };
	uint32_t en0 = if_nametoindex("en0");
	int err = DNSServiceBrowse(&ref[0], 0, en0, "_airplay._tcp", "local.", on_browse, airplay);
	time_t end = time(NULL) + BROWSE_S;

	if (err == 0) {
		err = DNSServiceBrowse(&ref[1], 0, en0, "_raop._tcp", "local.", on_browse, raop);
	}
	while (err == 0 && time(NULL) < end) {
		struct timeval tv = { 1, 0 };
		fd_set fds;
		int a = DNSServiceRefSockFD(ref[0]), b = DNSServiceRefSockFD(ref[1]);

		FD_ZERO(&fds);
		FD_SET(a, &fds);
		FD_SET(b, &fds);
		if (select((a > b ? a : b) + 1, &fds, NULL, NULL, &tv) > 0) {
			if (FD_ISSET(a, &fds) && DNSServiceProcessResult(ref[0]) != 0) {
				break;
			}
			if (FD_ISSET(b, &fds) && DNSServiceProcessResult(ref[1]) != 0) {
				break;
			}
		}
	}
	for (int i = 0; i < 2; i++) {
		if (ref[i] != NULL) {
			DNSServiceRefDeallocate(ref[i]);
		}
	}
	return err;
}

int
main(void)
{
	char ip[64] = "";
	time_t start = time(NULL);
	bool sender, fp, ptp, ave, route;

	if (switched_off()) {
		say("off: boot-arg airplay=0");
		return 0;
	}
	while (!en0_ipv4(ip, sizeof(ip))) {
		if (time(NULL) - start >= NO_LINK_S) {
			say("off: no IPv4 on en0 yet: AirPlay here needs infrastructure Wi-Fi (no awdl0)");
		}
		sleep(5);
	}
	sender = mach_service("com.apple.airplay.sender.xpc");
	fp = mach_service("com.apple.fairplayd.versioned");
	ptp = io_service("IOTimeSyncDomain");
	ave = io_service("AppleAVE2Driver") || io_service("AppleAVEDriver");
	route = default_route_is(ip);
	for (int t = 0; t < TRIES; t++) {
		struct seen airplay = { 0 }, raop = { 0 };
		int err;

		if (t != 0) {
			sleep(RETRY_S);
		}
		err = browse(&airplay, &raop);
		if (err != 0) {
			say("off: mDNSResponder refused the browse: error %d", err);
		} else if (!sender) {
			say("off: no com.apple.airplay.sender.xpc: mediaserverd has no AirPlay sender");
		} else if (airplay.count + raop.count == 0) {
			say("off: no receiver heard on en0 (%s, default route %s) in %d s: _airplay._tcp 0, _raop._tcp 0", ip, route ? "en0" : "not en0", BROWSE_S);
		} else {
			say("on: en0 %s, default route %s, _airplay._tcp %u, _raop._tcp %u heard; sender up; fp-setup %s; buffered audio %s; mirroring %s", ip, route ? "en0" : "not en0", airplay.count, raop.count,
			    fp ? "on" : "off: no fairplayd", ptp ? "on" : "off: no IOTimeSyncDomain", ave ? "on" : "off: no AppleAVE2Driver (H.264 encoder)");
			return 0;
		}
	}
	return 0;
}
