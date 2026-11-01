/*
 * laurelnet: the network state of iOS as one line in the kernel log (USB log), so a boot log shows it without SSH.
 *
 *   LAUREL NET: on: default route en0 via 192.168.1.1, v6 en0 via fe80::1, dns 2 servers 192.168.1.1 8.8.8.8, reachability yes (flags 0x2)
 *   LAUREL NET: on: default route none, v6 none, dns 0 servers, reachability no (flags 0x0)
 *
 * The state is what apps get: configd's State:/Network/Global/{IPv4,IPv6,DNS} (IPMonitor writes them) and
 * SCNetworkReachability of the zero address (the "internet" check of apps). No traffic: this tool sends nothing.
 *
 * It sleeps in the run loop and wakes only when configd changes one of the keys. A line comes at the start and when
 * the text changes; changes are collected for 2 s, and one more look 30 s later catches a reachability that follows
 * late. At most one line in 5 s. Kill switch: boot-arg laurelnet=0. If configd's API is not there: one "off" line,
 * exit 0 (launchd job with KeepAlive.SuccessfulExit=false: no restart).
 *
 * Lines go to /dev/console: the USB log has the console, not syslog (as metal_gate.c). The SCDynamicStore API exists in
 * iOS's SystemConfiguration.framework, but the iOS SDK marks it unavailable, so all of it is resolved with dlsym.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

typedef const struct __SCDynamicStore *SCDynamicStoreRef;
typedef const struct __SCNetworkReachability *SCNetworkReachabilityRef;
typedef void (*sc_callout)(SCDynamicStoreRef, CFArrayRef, void *);

static SCDynamicStoreRef (*sc_create)(CFAllocatorRef, CFStringRef, sc_callout, void *);
static CFPropertyListRef (*sc_copy)(SCDynamicStoreRef, CFStringRef);
static Boolean (*sc_set_keys)(SCDynamicStoreRef, CFArrayRef, CFArrayRef);
static CFRunLoopSourceRef (*sc_source)(CFAllocatorRef, SCDynamicStoreRef, CFIndex);
static SCNetworkReachabilityRef (*re_create)(CFAllocatorRef, const struct sockaddr *);
static Boolean (*re_flags)(SCNetworkReachabilityRef, uint32_t *);

#define REACHABLE       (1u << 1)
#define NEEDS_CONNECT   (1u << 2)

static SCDynamicStoreRef store;
static SCNetworkReachabilityRef internet;
static CFRunLoopTimerRef timer;
static char last_line[512];
static time_t last_time;
static int looks_left;

static void
say(const char *text)
{
	char line[600];
	int n = snprintf(line, sizeof(line), "LAUREL NET: %s\n", text);
	int fd = open("/dev/console", O_WRONLY | O_NOCTTY);

	if (fd >= 0) {
		(void)!write(fd, line, (size_t)n);
		close(fd);
	}
	fputs(line, stdout);
	fflush(stdout);
}

static void
cstr(CFTypeRef v, char *out, size_t len)
{
	out[0] = 0;
	if (v != NULL && CFGetTypeID(v) == CFStringGetTypeID()) {
		CFStringGetCString(v, out, (CFIndex)len, kCFStringEncodingUTF8);
	}
}

/* "en0 via 192.168.1.1", "none" */
static void
route_text(CFStringRef key, char *out, size_t len)
{
	char ifname[32], router[64];
	CFPropertyListRef g = sc_copy(store, key);

	ifname[0] = router[0] = 0;
	if (g != NULL && CFGetTypeID(g) == CFDictionaryGetTypeID()) {
		cstr(CFDictionaryGetValue(g, CFSTR("PrimaryInterface")), ifname, sizeof(ifname));
		cstr(CFDictionaryGetValue(g, CFSTR("Router")), router, sizeof(router));
	}
	if (g != NULL) {
		CFRelease(g);
	}
	if (ifname[0] == 0) {
		snprintf(out, len, "none");
	} else {
		snprintf(out, len, "%s via %s", ifname, router[0] != 0 ? router : "no router");
	}
}

/* "2 servers 192.168.1.1 8.8.8.8": at most 3 addresses */
static void
dns_text(char *out, size_t len)
{
	CFPropertyListRef g = sc_copy(store, CFSTR("State:/Network/Global/DNS"));
	CFArrayRef servers = NULL;
	CFIndex count = 0;
	size_t at;

	if (g != NULL && CFGetTypeID(g) == CFDictionaryGetTypeID()) {
		servers = CFDictionaryGetValue(g, CFSTR("ServerAddresses"));
		if (servers != NULL && CFGetTypeID(servers) == CFArrayGetTypeID()) {
			count = CFArrayGetCount(servers);
		}
	}
	at = (size_t)snprintf(out, len, "%ld server%s", (long)count, count == 1 ? "" : "s");
	for (CFIndex i = 0; i < count && i < 3 && at < len; i++) {
		char one[64];

		cstr(CFArrayGetValueAtIndex(servers, i), one, sizeof(one));
		at += (size_t)snprintf(out + at, len - at, " %s", one);
	}
	if (g != NULL) {
		CFRelease(g);
	}
}

static void
reach_text(char *out, size_t len)
{
	uint32_t flags = 0;

	if (internet == NULL || !re_flags(internet, &flags)) {
		snprintf(out, len, "unknown");
		return;
	}
	snprintf(out, len, "%s (flags 0x%x)", (flags & REACHABLE) == 0 ? "no" : (flags & NEEDS_CONNECT) != 0 ? "needs a connection" : "yes", flags);
}

static void
arm(CFAbsoluteTime seconds)
{
	CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + seconds);
}

static void
look(CFRunLoopTimerRef t, void *info)
{
	char v4[128], v6[128], dns[220], reach[64], line[512];
	time_t now = time(NULL);

	(void)t;
	(void)info;
	route_text(CFSTR("State:/Network/Global/IPv4"), v4, sizeof(v4));
	route_text(CFSTR("State:/Network/Global/IPv6"), v6, sizeof(v6));
	dns_text(dns, sizeof(dns));
	reach_text(reach, sizeof(reach));
	snprintf(line, sizeof(line), "on: default route %s, v6 %s, dns %s, reachability %s", v4, v6, dns, reach);
	if (strcmp(line, last_line) != 0) {
		if (last_time != 0 && now - last_time < 5) {
			arm(5);
			return;
		}
		say(line);
		strlcpy(last_line, line, sizeof(last_line));
		last_time = now;
	}
	if (looks_left > 0) {
		looks_left--;
		arm(30);
	}
}

static void
changed(SCDynamicStoreRef st, CFArrayRef keys, void *info)
{
	(void)st;
	(void)keys;
	(void)info;
	looks_left = 1;
	arm(2);
}

static int
kill_switch(void)
{
	char args[1024];
	size_t len = sizeof(args) - 1;

	if (sysctlbyname("kern.bootargs", args, &len, NULL, 0) != 0) {
		return 0;
	}
	args[len] = 0;
	return strstr(args, "laurelnet=0") != NULL;
}

int
main(void)
{
	void *h;
	const void *keys[] = { CFSTR("State:/Network/Global/IPv4"), CFSTR("State:/Network/Global/IPv6"), CFSTR("State:/Network/Global/DNS") };
	struct sockaddr_in zero;
	CFArrayRef list;
	CFRunLoopSourceRef source;

	if (kill_switch()) {
		say("off: boot-arg laurelnet=0");
		return 0;
	}
	h = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW);
	if (h == NULL) {
		say("off: no SystemConfiguration");
		return 0;
	}
	sc_create = dlsym(h, "SCDynamicStoreCreate");
	sc_copy = dlsym(h, "SCDynamicStoreCopyValue");
	sc_set_keys = dlsym(h, "SCDynamicStoreSetNotificationKeys");
	sc_source = dlsym(h, "SCDynamicStoreCreateRunLoopSource");
	re_create = dlsym(h, "SCNetworkReachabilityCreateWithAddress");
	re_flags = dlsym(h, "SCNetworkReachabilityGetFlags");
	if (!sc_create || !sc_copy || !sc_set_keys || !sc_source || !re_create || !re_flags) {
		say("off: SystemConfiguration symbols missing");
		return 0;
	}
	/* configd may start after us */
	for (int i = 0; i < 60 && store == NULL; i++) {
		store = sc_create(NULL, CFSTR("laurelnet"), changed, NULL);
		if (store == NULL) {
			sleep(2);
		}
	}
	if (store == NULL) {
		say("off: no configd after 120 s");
		return 0;
	}
	memset(&zero, 0, sizeof(zero));
	zero.sin_len = sizeof(zero);
	zero.sin_family = AF_INET;
	internet = re_create(NULL, (const struct sockaddr *)&zero);
	list = CFArrayCreate(NULL, keys, 3, &kCFTypeArrayCallBacks);
	source = sc_source(NULL, store, 0);
	if (list == NULL || source == NULL || !sc_set_keys(store, list, NULL)) {
		say("off: configd does not take the notification keys");
		return 0;
	}
	CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
	/* next fire date far away: it is set by arm(); an interval keeps the timer valid after a fire */
	timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1, 1e9, 0, 0, look, NULL);
	looks_left = 1;
	CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
	CFRunLoopRun();
	return 0;
}
