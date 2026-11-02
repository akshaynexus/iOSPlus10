/*
 * scripts/laurel/test-ios26-hid.sh: what the kernel sends to user space for one touch. Apple's IOHIDEvent.cpp of the tree in -I (1915 or 2238) + the real
 * SweetHIDTouch::touch of SweetHID.cpp (touch_body.inc: cut from the file by the script). Prints a JSON line: the bytes of IOHIDEventServiceQueue's entry, the field numbers.
 */
#define KERNEL 1
#define KERNEL_PRIVATE 1
#define TARGET_OS_DRIVERKIT 0
#include "hostkern.h"
#include <vector>
#include "IOHIDEvent.cpp"
#include "IOHIDUsageTables.h"
#include "IOHIDEvent.h"
typedef int IOLock;
static inline void IOLockLock(IOLock *) {}
static inline void IOLockUnlock(IOLock *) {}
static void laurel_input_touch(void) {}
enum { kPanelW = 720, kPanelH = 1560 };
#define SWEET_TOUCH_FINGERS 10
#define SWEET_TOUCH_EDGE_PX 48
static struct { int pw, ph, lw, lh, ox, oy, num, den; bool set; } sweet_hid_geo = { kPanelW, kPanelH, kPanelW, kPanelH, 0, 0, 1, 1, true };
static std::vector<std::vector<uint8_t>> sent;
struct SweetHIDTouch {
	IOLock *fLock = NULL;
	bool fDown[SWEET_TOUCH_FINGERS] = {};
	bool fEdge[SWEET_TOUCH_FINGERS] = {};
	IOFixed fX[SWEET_TOUCH_FINGERS] = {};
	IOFixed fY[SWEET_TOUCH_FINGERS] = {};
	const char *getName() const { return "SweetHIDTouch"; }
	void dispatchEvent(IOHIDEvent *e) {
		e->setSenderID(0x100000abc);
		std::vector<uint8_t> b(e->getLength());
		size_t n = e->readBytes(b.data(), b.size());
		b.resize(n);
		sent.push_back(b);
	}
	void touch(int finger, bool down, int x, int y);
};
#include "touch_body.inc"
int main()
{
	SweetHIDTouch t;
	t.touch(0, true, 360, 390);        /* finger down at 0.5, 0.25 of the panel */
	t.touch(0, true, 360, 780);        /* moved to 0.5, 0.5 */
	t.touch(0, false, 360, 780);       /* up */
	printf("{\"events\":[");
	for (size_t i = 0; i < sent.size(); i++) {
		printf("%s\"", i ? "," : "");
		for (uint8_t c : sent[i]) printf("%02x", c);
		printf("\"");
	}
	printf("],\"fields\":{\"x\":%u,\"y\":%u,\"type\":%u,\"index\":%u,\"identity\":%u,\"mask\":%u,\"button\":%u,\"range\":%u,\"touch\":%u,\"collection\":%u,\"pressure\":%u}}\n",
	    (unsigned)kIOHIDEventFieldDigitizerX, (unsigned)kIOHIDEventFieldDigitizerY, (unsigned)kIOHIDEventFieldDigitizerType, (unsigned)kIOHIDEventFieldDigitizerIndex,
	    (unsigned)kIOHIDEventFieldDigitizerIdentity, (unsigned)kIOHIDEventFieldDigitizerEventMask, (unsigned)kIOHIDEventFieldDigitizerButtonMask,
	    (unsigned)kIOHIDEventFieldDigitizerRange, (unsigned)kIOHIDEventFieldDigitizerTouch, (unsigned)kIOHIDEventFieldDigitizerCollection, (unsigned)kIOHIDEventFieldDigitizerPressure);
	return 0;
}
