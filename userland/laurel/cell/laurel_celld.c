/*
 * laurel-celld: the Mi A3's cellular data session in configd (kernel patch 2932). Reads kern.laurel_cell_net every 2 s; on a change publishes one network
 * service to configd's dynamic store. IPMonitor then elects the primary service, writes the default route and the DNS configuration: Wi-Fi first while it is up,
 * cellular when it is gone [I: IPMonitor's rules from Apple's configd source, from memory; not in this repo. The phone test says]. Docs: docs/laurel_sprout/cellular.md section 11.
 *
 * On an iPhone CommCenter publishes the same keys: State:/Network/Service/<id>/{IPv4,IPv6,DNS,com.apple.CommCenter} [I]. No address work here: the kernel has
 * set the addresses on pdp_ip0 (bsd/dev/laurel_pdp2.h). A launchd job: starts at boot, exits only when the kernel has no such sysctl (kernel without 2932).
 * SC functions by dlsym: a missing one = one "off" line, nothing else changes. Every result line goes to the USB log through kern.laurel_cell_ui, as the status bar bridge.
 * Never a SIM or modem identity: the text has none. Kill switches: boot-args cell=0 or cell_data=0: the kernel text stays "off", nothing is published.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include "celld_net.h"

#define SERVICE     "6C1E5A30-2B7F-4D0E-9A44-1AE7C0DE0A70"
#define NET_PATH    "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration"

typedef const void *store_t;
static store_t (*p_create)(CFAllocatorRef, CFStringRef, void *, void *);
static Boolean (*p_set_multiple)(store_t, CFDictionaryRef, CFArrayRef, CFArrayRef);
static CFPropertyListRef (*p_copy)(store_t, CFStringRef);

static void
say(const char *fmt, ...)
{
	char b[150];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(b, sizeof(b), fmt, ap);
	va_end(ap);
	(void)sysctlbyname("kern.laurel_cell_ui", NULL, NULL, b, strlen(b));
	fprintf(stderr, "laurel-celld: %s\n", b);
}

static CFStringRef
str(const char *s)
{
	return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

static CFStringRef
key(const char *entity)
{
	char k[128];

	snprintf(k, sizeof(k), "State:/Network/Service/%s/%s", SERVICE, entity);
	return str(k);
}

static void
put_str(CFMutableDictionaryRef d, const char *k, const char *v)
{
	CFStringRef ks = str(k), vs = str(v);

	CFDictionarySetValue(d, ks, vs);
	CFRelease(ks);
	CFRelease(vs);
}

static void
put_list(CFMutableDictionaryRef d, const char *k, const char *const *v, int n)
{
	CFStringRef ks = str(k);
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);

	for (int i = 0; i < n; i++) {
		CFStringRef s = str(v[i]);
		CFArrayAppendValue(a, s);
		CFRelease(s);
	}
	CFDictionarySetValue(d, ks, a);
	CFRelease(ks);
	CFRelease(a);
}

static void
put_nums(CFMutableDictionaryRef d, const char *k, int v)
{
	CFStringRef ks = str(k);
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
	CFArrayRef a = CFArrayCreate(NULL, (const void **)&n, 1, &kCFTypeArrayCallBacks);

	CFDictionarySetValue(d, ks, a);
	CFRelease(ks);
	CFRelease(n);
	CFRelease(a);
}

static CFMutableDictionaryRef
dict(void)
{
	return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static void
set_entity(CFMutableDictionaryRef set, const char *entity, CFMutableDictionaryRef v)
{
	CFStringRef k = key(entity);

	CFDictionarySetValue(set, k, v);
	CFRelease(k);
	CFRelease(v);
}

/* the values IPMonitor reads, from the kernel's text; a family that is down has its key removed */
static bool
publish(store_t st, const struct celld_net *n)
{
	CFMutableDictionaryRef set = dict(), v;
	CFMutableArrayRef rem = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	static const char *const ents[] = { "IPv4", "IPv6", "DNS", "com.apple.CommCenter" };
	bool has4 = n->on && n->v4[0] != 0, has6 = n->on && n->v6[0] != 0;

	if (has4) {
		const char *a[1] = { n->v4 }, *m[1] = { n->v4_mask }, *g[1] = { n->v4_gw };
		v = dict();
		put_list(v, "Addresses", a, 1);
		put_list(v, "SubnetMasks", m, 1);
		put_list(v, "DestAddresses", g, 1);
		put_str(v, "InterfaceName", n->ifname);
		put_str(v, "Router", n->v4_gw);
		set_entity(set, "IPv4", v);
	}
	if (has6) {
		const char *a[1] = { n->v6 }, *d[1] = { "::" };
		v = dict();
		put_list(v, "Addresses", a, 1);
		put_list(v, "DestAddresses", d, 1);
		put_nums(v, "Flags", 0);
		put_nums(v, "PrefixLength", n->v6_plen > 0 ? n->v6_plen : 64);
		put_str(v, "InterfaceName", n->ifname);
		if (n->v6_gw[0] != 0) {
			put_str(v, "Router", n->v6_gw);
		}
		set_entity(set, "IPv6", v);
	}
	if (n->v4_dns_n + n->v6_dns_n > 0 && (has4 || has6)) {
		const char *a[4];
		int c = 0;
		for (int i = 0; i < n->v6_dns_n && has6; i++) {
			a[c++] = n->v6_dns[i];
		}
		for (int i = 0; i < n->v4_dns_n && has4; i++) {
			a[c++] = n->v4_dns[i];
		}
		v = dict();
		put_list(v, "ServerAddresses", a, c);
		put_str(v, "InterfaceName", n->ifname);
		set_entity(set, "DNS", v);
	}
	if (has4 || has6) {
		/* [I] CommCenter's entity: IPMonitor ranks the service by it */
		int one = 1;
		CFNumberRef o = CFNumberCreate(NULL, kCFNumberIntType, &one);
		CFStringRef ks = str("Active"), ka = str("Available");
		v = dict();
		CFDictionarySetValue(v, ks, o);
		CFDictionarySetValue(v, ka, o);
		CFRelease(o);
		CFRelease(ks);
		CFRelease(ka);
		set_entity(set, "com.apple.CommCenter", v);
	}
	for (unsigned i = 0; i < sizeof(ents) / sizeof(ents[0]); i++) {
		CFStringRef k = key(ents[i]);
		if (!CFDictionaryContainsKey(set, k)) {
			CFArrayAppendValue(rem, k);
		}
		CFRelease(k);
	}
	Boolean ok = p_set_multiple(st, set, rem, NULL);
	CFRelease(set);
	CFRelease(rem);
	return ok;
}

/* what IPMonitor made of it: for the result line */
static void
primary(store_t st, char *out, size_t max)
{
	CFStringRef k = str("State:/Network/Global/IPv4");
	CFPropertyListRef g = p_copy(st, k);

	snprintf(out, max, "none");
	CFRelease(k);
	if (g != NULL) {
		if (CFGetTypeID(g) == CFDictionaryGetTypeID()) {
			CFTypeRef i = CFDictionaryGetValue(g, CFSTR("PrimaryInterface"));
			if (i != NULL && CFGetTypeID(i) == CFStringGetTypeID()) {
				(void)CFStringGetCString(i, out, (CFIndex)max, kCFStringEncodingUTF8);
			}
		}
		CFRelease(g);
	}
}

int
main(void)
{
	char text[640], last[640] = "", pri[16], pri_said[16] = "";
	size_t n = sizeof(text);

	if (sysctlbyname("kern.laurel_cell_net", text, &n, NULL, 0) != 0) {
		fprintf(stderr, "laurel-celld: off: no kern.laurel_cell_net in this kernel\n");
		return 0;
	}
	void *h = dlopen(NET_PATH, RTLD_NOW);
	p_create = h != NULL ? dlsym(h, "SCDynamicStoreCreate") : NULL;
	p_set_multiple = h != NULL ? dlsym(h, "SCDynamicStoreSetMultiple") : NULL;
	p_copy = h != NULL ? dlsym(h, "SCDynamicStoreCopyValue") : NULL;
	if (p_create == NULL || p_set_multiple == NULL || p_copy == NULL) {
		say("celld: off: no SCDynamicStore functions in SystemConfiguration");
		return 0;
	}
	store_t st = p_create(NULL, CFSTR("laurel-celld"), NULL, NULL);
	if (st == NULL) {
		say("celld: off: configd refused the session");
		return 0;
	}
	say("celld: on: waiting for a data session");
	for (;;) {
		n = sizeof(text);
		if (sysctlbyname("kern.laurel_cell_net", text, &n, NULL, 0) == 0 && strcmp(text, last) != 0) {
			struct celld_net net;
			celld_parse(text, &net);
			if (publish(st, &net)) {
				say("celld: configd has: %s%s%s", net.on ? net.ifname : "no service", net.v4[0] != 0 ? " IPv4" : "", net.v6[0] != 0 ? " IPv6" : "");
				strlcpy(last, text, sizeof(last));
			} else {
				say("celld: configd refused the keys; trying again in 2 s");
			}
		}
		primary(st, pri, sizeof(pri));
		if (strcmp(pri, pri_said) != 0) {
			say("celld: primary interface %s", pri);
			strlcpy(pri_said, pri, sizeof(pri_said));
		}
		sleep(2);
	}
}
