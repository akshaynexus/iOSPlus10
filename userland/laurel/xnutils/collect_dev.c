/* Memory, battery, network: what the system keeps anyway (collect_ios.c has the frame). */
#include <CoreFoundation/CoreFoundation.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <time.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "collect.h"

/* IOKit: the SDK has the .tbd; these few declarations are all this file needs */
typedef mach_port_t io_object_t;
extern const mach_port_t kIOMainPortDefault;
CFMutableDictionaryRef IOServiceMatching(const char *name);
io_object_t IOServiceGetMatchingService(mach_port_t port, CFDictionaryRef matching);
kern_return_t IORegistryEntryCreateCFProperties(io_object_t e, CFMutableDictionaryRef *p, CFAllocatorRef a, uint32_t options);
kern_return_t IOObjectRelease(io_object_t o);

static struct { uint64_t net_rx, net_tx, net_at; } prev;

void
xt_collect_memory(void)
{
	vm_statistics64_data_t v;
	mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
	vm_size_t page = 0;
	uint64_t total = 0;
	size_t len = sizeof(total);
	int level = 0;

	host_page_size(mach_host_self(), &page);
	if (sysctlbyname("hw.memsize", &total, &len, NULL, 0) == 0) {
		kv("mem.total_mb", "%llu", (unsigned long long)(total >> 20));
	}
	if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&v, &c) == KERN_SUCCESS && page != 0) {
#define MB(x) ((unsigned long long)((uint64_t)(x) * page >> 20))
		kv("mem.free_mb", "%llu", MB(v.free_count));
		kv("mem.active_mb", "%llu", MB(v.active_count));
		kv("mem.inactive_mb", "%llu", MB(v.inactive_count));
		kv("mem.wired_mb", "%llu", MB(v.wire_count));
		kv("mem.compressor_mb", "%llu", MB(v.compressor_page_count));
		kv("mem.compressed_mb", "%llu", MB(v.total_uncompressed_pages_in_compressor));
#undef MB
	}
	struct xsw_usage sw;

	len = sizeof(sw);
	if (sysctlbyname("vm.swapusage", &sw, &len, NULL, 0) == 0) {
		kv("mem.swap_used_mb", "%llu", (unsigned long long)(sw.xsu_used >> 20));
		kv("mem.swap_total_mb", "%llu", (unsigned long long)(sw.xsu_total >> 20));
	}
	len = sizeof(level);
	if (sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, NULL, 0) == 0) {
		kv("mem.pressure", "%s", level <= 1 ? "normal" : level == 2 ? "warning" : "critical");
	}
	len = sizeof(level);
	if (sysctlbyname("kern.memorystatus_level", &level, &len, NULL, 0) == 0) {
		kv("mem.level", "%d", level);
	}
}

static int
cfnum(CFDictionaryRef d, const char *name, long *v)
{
	CFStringRef k = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
	CFTypeRef o = k ? CFDictionaryGetValue(d, k) : NULL;
	int ok = 0;

	if (o != NULL && CFGetTypeID(o) == CFNumberGetTypeID()) {
		ok = CFNumberGetValue((CFNumberRef)o, kCFNumberLongType, v);
	} else if (o != NULL && CFGetTypeID(o) == CFBooleanGetTypeID()) {
		*v = CFBooleanGetValue((CFBooleanRef)o) ? 1 : 0;
		ok = 1;
	}
	if (k != NULL) {
		CFRelease(k);
	}
	return ok;
}

/* The registry of SweetBattery (an IOPMPowerSource; its 10 s sample). No new read of the PMIC. */
void
xt_collect_battery(void)
{
	io_object_t e = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMPowerSource"));
	CFMutableDictionaryRef d = NULL;
	long v;

	if (e == 0) {
		return;
	}
	if (IORegistryEntryCreateCFProperties(e, &d, kCFAllocatorDefault, 0) == KERN_SUCCESS && d != NULL) {
		long cur, max;

		if (cfnum(d, "CurrentCapacity", &cur) && cfnum(d, "MaxCapacity", &max) && max > 0) {
			kv("bat.pct", "%ld", cur * 100 / max);
		}
		if (cfnum(d, "InstantAmperage", &v) || cfnum(d, "Amperage", &v)) {
			kv("bat.ma", "%d", (int)v);
		}
		if (cfnum(d, "Voltage", &v)) {
			kv("bat.mv", "%ld", v);
		}
		if (cfnum(d, "Temperature", &v)) {
			kv("bat.temp_cC", "%ld", v);
		}
		if (cfnum(d, "SweetBatteryTemperatureEstimated", &v)) {
			kv("bat.temp_est", "%ld", v);
		}
		if (cfnum(d, "IsCharging", &v)) {
			kv("bat.charging", "%ld", v);
		}
		if (cfnum(d, "ExternalConnected", &v)) {
			kv("bat.external", "%ld", v);
		}
		if (cfnum(d, "CycleCount", &v)) {
			kv("bat.cycles", "%ld", v);
		}
		CFRelease(d);
	}
	IOObjectRelease(e);
}

void
xt_collect_network(void)
{
	struct ifaddrs *list = NULL;

	if (getifaddrs(&list) != 0) {
		return;
	}
	for (struct ifaddrs *i = list; i != NULL; i = i->ifa_next) {
		if (strcmp(i->ifa_name, "en0") != 0 || i->ifa_addr == NULL || i->ifa_addr->sa_family != AF_LINK || i->ifa_data == NULL) {
			continue;
		}
		const struct if_data *d = i->ifa_data;
		uint64_t rx = d->ifi_ibytes, tx = d->ifi_obytes, t = (uint64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

		if (prev.net_at != 0 && t > prev.net_at) {
			uint64_t ms = (t - prev.net_at) / 1000000 + 1;

			/* if_data counts wrap at 4 GiB: a wrap shows one rate of 0 */
			kv("net.en0_rx_kbps", "%llu", (unsigned long long)(rx >= prev.net_rx ? (rx - prev.net_rx) * 8 / ms : 0));
			kv("net.en0_tx_kbps", "%llu", (unsigned long long)(tx >= prev.net_tx ? (tx - prev.net_tx) * 8 / ms : 0));
		}
		prev.net_rx = rx;
		prev.net_tx = tx;
		prev.net_at = t;
		break;
	}
	freeifaddrs(list);
}

