/*
 * usbnetcfg: make the USB Ethernet link (ue0) the network service iOS uses.
 *
 * The kernel (negroniusb=2) already gives ue0 192.168.7.2/24. That is enough for SSH, but
 * iOS has no default route and no DNS servers: configd's IPConfiguration agent never
 * configures ue0 (the reference ports saw the same, even with a preferences.plist service).
 * This tool writes the dynamic-store keys that IPConfiguration would write for a manual
 * service. IPMonitor then makes ue0 the primary service (default route via the Mac) and
 * gives mDNSResponder the DNS servers.
 *
 *   usbnetcfg [options] [up]   wait for configd + the interface, publish, check (default)
 *   usbnetcfg down             remove the keys
 *   usbnetcfg show             print the keys
 * Options: -i IF (ue0) -a ADDR (192.168.7.2) -m MASK (255.255.255.0) -r ROUTER (192.168.7.1)
 *          -d DNS[,DNS2] (1.1.1.1,8.8.8.8) -s SERVICE-UUID -t WAIT-SECONDS (120) -n (no route
 *          fallback)
 *
 * If IPMonitor does not install a default route within a few seconds, "up" adds one through
 * a routing socket (connectivity by IP; names still need IPMonitor's DNS state).
 * Exit 0 when the keys are published or when the interface never appears (no USB network
 * on this boot), so a launchd job with KeepAlive.SuccessfulExit=false does not loop.
 *
 * Approach from ios-flame phone/tools/netsvc.m (MIT, NWylynko/ios-flame); this file is our
 * own code. The SCDynamicStore API exists in iOS's SystemConfiguration.framework, but the
 * iOS SDK marks it unavailable, so it is resolved with dlsym. Needs the entitlement
 * com.apple.SystemConfiguration.SCDynamicStore-write-access (userland/ssh/entitlements.plist).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <net/if.h>
#include <netinet/in.h>
#if __has_include(<net/route.h>)
#include <net/route.h>
#else
/* The iPhoneOS SDK has no <net/route.h>. Routing-socket ABI, same as the macOS SDK header. */
struct rt_metrics {
	u_int32_t rmx_locks, rmx_mtu, rmx_hopcount;
	int32_t rmx_expire;
	u_int32_t rmx_recvpipe, rmx_sendpipe, rmx_ssthresh, rmx_rtt, rmx_rttvar, rmx_pksent;
	u_int32_t rmx_filler[4];
};
struct rt_msghdr {
	u_short rtm_msglen;
	u_char rtm_version, rtm_type;
	u_short rtm_index;
	int rtm_flags, rtm_addrs;
	pid_t rtm_pid;
	int rtm_seq, rtm_errno, rtm_use;
	u_int32_t rtm_inits;
	struct rt_metrics rtm_rmx;
};
#define RTM_VERSION 5
#define RTM_ADD 0x1
#define RTF_UP 0x1
#define RTF_GATEWAY 0x2
#define RTF_STATIC 0x800
#define RTA_DST 0x1
#define RTA_GATEWAY 0x2
#define RTA_NETMASK 0x4
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* Same UUID as the "USB Ethernet" service scripts/net/root-add-ssh.py writes into
 * preferences.plist, so Setup: and State: keys describe one service. */
#define DEFAULT_SERVICE "1F05B0E7-0000-4000-8000-0000000000E0"

typedef const struct __SCDynamicStore *SCDynamicStoreRef;
static SCDynamicStoreRef (*sc_create)(CFAllocatorRef, CFStringRef, void *, void *);
static CFPropertyListRef (*sc_copy)(SCDynamicStoreRef, CFStringRef);
static Boolean (*sc_set_multiple)(SCDynamicStoreRef, CFDictionaryRef, CFArrayRef, CFArrayRef);
static int (*sc_error)(void);
static const char *(*sc_error_string)(int);

static int
sc_load(void)
{
	void *h = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW);
	if (h == NULL) {
		fprintf(stderr, "usbnetcfg: dlopen SystemConfiguration: %s\n", dlerror());
		return -1;
	}
	sc_create = dlsym(h, "SCDynamicStoreCreate");
	sc_copy = dlsym(h, "SCDynamicStoreCopyValue");
	sc_set_multiple = dlsym(h, "SCDynamicStoreSetMultiple");
	sc_error = dlsym(h, "SCError");
	sc_error_string = dlsym(h, "SCErrorString");
	if (!sc_create || !sc_copy || !sc_set_multiple || !sc_error || !sc_error_string) {
		fprintf(stderr, "usbnetcfg: SCDynamicStore symbols missing\n");
		return -1;
	}
	return 0;
}

static const char *
sc_err(void)
{
	return sc_error_string(sc_error());
}

static CFStringRef
str(const char *s)
{
	return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

static CFStringRef
fmt(const char *f, const char *a)
{
	char buf[256];
	snprintf(buf, sizeof(buf), f, a);
	return str(buf);
}

/* array of strings from "a,b,c" */
static CFArrayRef
list(const char *csv)
{
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	char *copy = strdup(csv), *save = NULL;
	for (char *t = strtok_r(copy, ",", &save); t != NULL; t = strtok_r(NULL, ",", &save)) {
		CFStringRef s = str(t);
		CFArrayAppendValue(a, s);
		CFRelease(s);
	}
	free(copy);
	return a;
}

static CFMutableDictionaryRef
dict(void)
{
	return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static void
put(CFMutableDictionaryRef d, const char *k, CFTypeRef v)
{
	CFStringRef key = str(k);
	CFDictionarySetValue(d, key, v);
	CFRelease(key);
	CFRelease(v);
}

static void
print_value(SCDynamicStoreRef st, CFStringRef key)
{
	char k[256];
	CFStringGetCString(key, k, sizeof(k), kCFStringEncodingUTF8);
	CFPropertyListRef v = sc_copy(st, key);
	if (v == NULL) {
		printf("%s = (none)\n", k);
		return;
	}
	CFStringRef desc = CFCopyDescription(v);
	CFIndex n = CFStringGetMaximumSizeForEncoding(CFStringGetLength(desc), kCFStringEncodingUTF8) + 1;
	char *buf = malloc(n);
	CFStringGetCString(desc, buf, n, kCFStringEncodingUTF8);
	printf("%s = %s\n", k, buf);
	free(buf);
	CFRelease(desc);
	CFRelease(v);
}

/* PrimaryInterface from State:/Network/Global/IPv4 (empty string if none) */
static void
primary_interface(SCDynamicStoreRef st, char *out, size_t len)
{
	out[0] = 0;
	CFDictionaryRef g = sc_copy(st, CFSTR("State:/Network/Global/IPv4"));
	if (g == NULL) {
		return;
	}
	if (CFGetTypeID(g) == CFDictionaryGetTypeID()) {
		CFStringRef p = CFDictionaryGetValue(g, CFSTR("PrimaryInterface"));
		if (p != NULL && CFGetTypeID(p) == CFStringGetTypeID()) {
			CFStringGetCString(p, out, len, kCFStringEncodingUTF8);
		}
	}
	CFRelease(g);
}

/* Add "default via ROUTER" through a routing socket. 0 = added, 1 = one exists, -1 = error. */
static int
add_default_route(const char *router)
{
	struct {
		struct rt_msghdr h;
		struct sockaddr_in dst, gw, mask;
	} m;
	memset(&m, 0, sizeof(m));
	m.h.rtm_msglen = sizeof(m);
	m.h.rtm_version = RTM_VERSION;
	m.h.rtm_type = RTM_ADD;
	m.h.rtm_flags = RTF_UP | RTF_GATEWAY | RTF_STATIC;
	m.h.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
	m.h.rtm_pid = getpid();
	m.h.rtm_seq = 1;
	struct sockaddr_in *sa[] = { &m.dst, &m.gw, &m.mask };
	for (int i = 0; i < 3; i++) {
		sa[i]->sin_len = sizeof(struct sockaddr_in);
		sa[i]->sin_family = AF_INET;
	}
	if (inet_pton(AF_INET, router, &m.gw.sin_addr) != 1) {
		fprintf(stderr, "usbnetcfg: bad router %s\n", router);
		return -1;
	}
	int s = socket(PF_ROUTE, SOCK_RAW, AF_INET);
	if (s < 0) {
		perror("usbnetcfg: routing socket");
		return -1;
	}
	ssize_t r = write(s, &m, sizeof(m));
	int e = errno;
	close(s);
	if (r < 0 && e == EEXIST) {
		return 1;
	}
	if (r < 0) {
		fprintf(stderr, "usbnetcfg: RTM_ADD default via %s: %s\n", router, strerror(e));
		return -1;
	}
	return 0;
}

static void
usage(void)
{
	fprintf(stderr, "usage: usbnetcfg [-i IF] [-a ADDR] [-m MASK] [-r ROUTER] [-d DNS[,DNS2]] "
	    "[-s SERVICE] [-t SECONDS] [-n] [up|down|show]\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	const char *ifname = "ue0", *addr = "192.168.7.2", *mask = "255.255.255.0";
	const char *router = "192.168.7.1", *dns = "1.1.1.1,8.8.8.8", *service = DEFAULT_SERVICE;
	int wait_s = 120, route_fallback = 1, c;
	setvbuf(stdout, NULL, _IOLBF, 0);
	while ((c = getopt(argc, argv, "i:a:m:r:d:s:t:nh")) != -1) {
		switch (c) {
		case 'i': ifname = optarg; break;
		case 'a': addr = optarg; break;
		case 'm': mask = optarg; break;
		case 'r': router = optarg; break;
		case 'd': dns = optarg; break;
		case 's': service = optarg; break;
		case 't': wait_s = atoi(optarg); break;
		case 'n': route_fallback = 0; break;
		default: usage();
		}
	}
	const char *cmd = optind < argc ? argv[optind] : "up";
	if (strcmp(cmd, "up") && strcmp(cmd, "down") && strcmp(cmd, "show")) {
		usage();
	}
	if (sc_load() != 0) {
		return 1;
	}

	CFStringRef k_v4 = fmt("State:/Network/Service/%s/IPv4", service);
	CFStringRef k_dns = fmt("State:/Network/Service/%s/DNS", service);
	CFStringRef k_if = fmt("State:/Network/Interface/%s/IPv4", ifname);

	/* configd may start after us and ue0 may come up late: wait for both. */
	SCDynamicStoreRef st = NULL;
	int waited = 0;
	for (;;) {
		if (st == NULL) {
			st = sc_create(NULL, CFSTR("usbnetcfg"), NULL, NULL);
		}
		if (st != NULL && (strcmp(cmd, "up") || if_nametoindex(ifname) != 0)) {
			break;
		}
		if (waited >= wait_s) {
			if (st == NULL) {
				printf("usbnetcfg: no configd after %d s: %s\n", waited, sc_err());
				return 1;
			}
			printf("usbnetcfg: no interface %s after %d s (USB network off?), nothing done\n", ifname, waited);
			return 0;
		}
		sleep(2);
		waited += 2;
	}

	if (!strcmp(cmd, "show")) {
		print_value(st, CFSTR("State:/Network/Global/IPv4"));
		print_value(st, CFSTR("State:/Network/Global/DNS"));
		print_value(st, k_v4);
		print_value(st, k_dns);
		print_value(st, k_if);
		return 0;
	}
	if (!strcmp(cmd, "down")) {
		const void *keys[] = { k_v4, k_dns, k_if };
		CFArrayRef rm = CFArrayCreate(NULL, keys, 3, &kCFTypeArrayCallBacks);
		Boolean ok = sc_set_multiple(st, NULL, rm, NULL);
		printf("usbnetcfg: remove %s keys: %s\n", ifname, ok ? "ok" : sc_err());
		return ok ? 0 : 1;
	}

	CFMutableDictionaryRef v4 = dict(), d = dict(), ifv4 = dict(), all = dict();
	put(v4, "Addresses", list(addr));
	put(v4, "SubnetMasks", list(mask));
	put(v4, "Router", str(router));
	put(v4, "InterfaceName", str(ifname));
	put(v4, "ConfigMethod", str("Manual"));
	put(d, "ServerAddresses", list(dns));
	put(ifv4, "Addresses", list(addr));
	put(ifv4, "SubnetMasks", list(mask));
	CFDictionarySetValue(all, k_v4, v4);
	CFDictionarySetValue(all, k_dns, d);
	CFDictionarySetValue(all, k_if, ifv4);
	Boolean ok = sc_set_multiple(st, all, NULL, NULL);
	printf("usbnetcfg: publish %s %s/%s router %s dns %s (service %s): %s\n", ifname, addr, mask,
	    router, dns, service, ok ? "ok" : sc_err());
	if (!ok) {
		return 1;
	}

	/* IPMonitor reacts within about a second. */
	char primary[64] = "";
	for (int i = 0; i < 5 && strcmp(primary, ifname); i++) {
		sleep(1);
		primary_interface(st, primary, sizeof(primary));
	}
	if (!strcmp(primary, ifname)) {
		printf("usbnetcfg: %s is the primary interface\n", ifname);
	} else {
		printf("usbnetcfg: primary interface is '%s', not %s\n", primary, ifname);
		if (route_fallback) {
			int r = add_default_route(router);
			printf("usbnetcfg: default route via %s: %s\n", router,
			    r == 0 ? "added by hand" : r == 1 ? "already present" : "FAILED");
		}
	}
	return 0;
}
