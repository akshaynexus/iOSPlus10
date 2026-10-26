/* usb-host-kick: macOS host-side recovery for the phone's USB gadget (VID 0x1209), no network needed.
 *   usb-host-kick reenum    bus reset + re-enumeration (the gadget sees a USB reset)
 *   usb-host-kick suspend   suspend the port: no more SOF, so negroniusb_lost_reboot (0371) reboots the phone
 *   usb-host-kick resume    resume a suspended port
 *   usb-host-kick suspend S keeps the device open and suspended for S s (macOS resumes the port when we close it;
 *                           0371 needs >= negroniusb_lost_reboot s without SOF)
 * Use when the phone is enumerated but its data path is dead (ping/ctl fail) and the 0371 auto-reboot cannot fire
 * because the host still sends SOF. Build: scripts/debug/usb-host-kick.sh (clang, IOKit). Run with sudo. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#define VID 0x1209
int main(int argc, char **argv) {
	const char *cmd = argc > 1 ? argv[1] : "";
	if (strcmp(cmd, "reenum") && strcmp(cmd, "suspend") && strcmp(cmd, "resume")) {
		fprintf(stderr, "usage: %s reenum|suspend|resume\n", argv[0]); return 2;
	}
	CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
	io_iterator_t it; if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return 1;
	io_service_t s; int done = 0;
	while ((s = IOIteratorNext(it))) {
		int vid = 0; CFTypeRef p = IORegistryEntryCreateCFProperty(s, CFSTR("idVendor"), NULL, 0);
		if (p) { CFNumberGetValue((CFNumberRef)p, kCFNumberIntType, &vid); CFRelease(p); }
		if (vid != VID) { IOObjectRelease(s); continue; }
		IOCFPlugInInterface **pi = NULL; SInt32 score; IOUSBDeviceInterface **d = NULL;
		kern_return_t kr = IOCreatePlugInInterfaceForService(s, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &pi, &score);
		IOObjectRelease(s);
		if (kr != KERN_SUCCESS || !pi) { fprintf(stderr, "plugin: 0x%x\n", kr); continue; }
		(*pi)->QueryInterface(pi, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&d); (*pi)->Release(pi);
		if (!d) continue;
		IOReturn r = (*d)->USBDeviceOpenSeize(d);
		printf("open(seize): 0x%x\n", r);
		if (!strcmp(cmd, "reenum")) r = (*d)->USBDeviceReEnumerate(d, 0);
		else r = (*d)->USBDeviceSuspend(d, !strcmp(cmd, "suspend"));
		printf("%s: 0x%x\n", cmd, r); fflush(stdout);
		if (!strcmp(cmd, "suspend") && argc > 2) {
			int hold = atoi(argv[2]);
			for (int t = 0; t < hold; t++) { sleep(1); if (t % 5 == 4) (*d)->USBDeviceSuspend(d, true); }
			printf("held %d s\n", hold);
		}
		(*d)->USBDeviceClose(d); (*d)->Release(d); done++;
	}
	IOObjectRelease(it);
	if (!done) { fprintf(stderr, "no USB device with VID 0x%04x\n", VID); return 1; }
	return 0;
}
