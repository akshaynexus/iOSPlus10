/*
 * laurel-autotest: lets an agent test the Mi A3's iOS 26 UI with no finger. Root tool, run over SSH by
 * scripts/laurel/ios26-autotest.sh, docs/laurel_sprout/ios26-autotest.md. Plain arm64, ad hoc, entitlements in autotest.ents.
 *
 *   laurel-autotest check                       one line: LAUREL AUTOTEST: on|off: ...
 *   laurel-autotest tap X Y [HOLD_MS]           panel pixels, 720x1560
 *   laurel-autotest swipe X0 Y0 X1 Y1 [MS]      one finger
 *   laurel-autotest edge bottom|top|left|right [LEN_PX] [MS] [AT_PX]   from the screen edge, with the kernel's edge flag
 *   laurel-autotest key power|volup|voldown|home [HOLD_MS]
 *   laurel-autotest open BUNDLE_ID              SpringBoard's own service, then LaunchServices
 *   laurel-autotest awake                       exit 0 if the panel is on, 1 if off (SpringBoard's state), and the lock state
 *   laurel-autotest surfaces                    all screen-size surfaces: id, format, use count
 *   laurel-autotest shot                        one whole frame to stdout (LATF record, see frame_head)
 *   laurel-autotest settle QUIET_MS MAX_MS [change]   waits until the picture holds still; change: it must first change
 *   laurel-autotest seq N [MAX_MS]              up to N flips to stdout: LATS head, then one record per frame, 1/4 size
 *
 * Input: the same events as SweetHIDTouch::touch and SweetHIDButtons::key of the kernel, with the sender id of
 * these two services, given to the event system in backboardd (IOHIDEventSystemClientDispatchEvent). So the event
 * takes all the path above the kernel, and the kernel's own `SWEET HID: touch` line does not print.
 *
 * Output: reads the surface in memory, never writes to it, takes no lock on it (a lock can change its seed), and
 * the display path does not see this tool. Which surface the panel shows: kern.laurel_scan_surface if the kernel has it
 * (patch 2983). Else from the in-use marks: the kernel sets one at each swap and drops it when the frame leaves the
 * panel, so the surface that came into use last is the newest frame ("inferred" in the output).
 */
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach-o/dyld_images.h>

#include <IOKit/IOKitLib.h>
#include <IOSurface/IOSurfaceRef.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <notify.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define PANEL_W 720
#define PANEL_H 1560
#define FINGER_INDEX 0
#define MASK_RANGE (1u << 0)
#define MASK_TOUCH (1u << 1)
#define MASK_POSITION (1u << 2)
#define MASK_IDENTITY (1u << 5)
#define MASK_FROM_EDGE_TIP (1u << 11)
#define EDGE_PX 32 /* SWEET_TOUCH_EDGE_PX * 720 / 1080, the kernel's test */
#define TYPE_HAND 3
#define PAGE_CONSUMER 0x0c
#define FIELD_IS_BUILTIN 4
#define FIELD_DIGITIZER(n) ((11u << 16) | (n))
#define FIELD_COLLECTION FIELD_DIGITIZER(22)
#define FIELD_DISPLAY_INTEGRATED FIELD_DIGITIZER(25)
#define MAX_SURFACE_ID 4096 /* SWEET_SURFACE_MAX_ID */
#define MAX_SCREENS 16
#define THUMB_DIV 4

typedef struct __IOHIDEvent *EventRef;
typedef struct __IOHIDEventSystemClient *ClientRef;

static ClientRef (*p_client_create)(CFAllocatorRef);
static void (*p_dispatch)(ClientRef, EventRef);
static EventRef (*p_digitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
static EventRef (*p_finger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
static EventRef (*p_keyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);
static void (*p_append)(EventRef, EventRef, uint32_t);
static void (*p_set_int)(EventRef, uint32_t, long);
static void (*p_set_sender)(EventRef, uint64_t);

static ClientRef g_client;
static uint64_t g_touch_id, g_buttons_id;

static uint64_t
service_id(const char *cls)
{
	uint64_t id = 0;
	io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls));
	if (s != IO_OBJECT_NULL) {
		IORegistryEntryGetRegistryEntryID(s, &id);
		IOObjectRelease(s);
	}
	return id;
}

/*
 * backboardd asks for com.apple.private.hid.client.event-dispatch. A file in /var/tmp ran with csflags 0 and no blob on the phone, the same file in /usr/local/bin with 0x26000001:
 * so the self-check reads this process's own flags.
 */
extern int csops(pid_t, unsigned, void *, size_t);
static bool
signature_ok(void)
{
	uint32_t flags = 0;
	return csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & 1) != 0; /* CS_VALID */
}

/* NULL, or why input cannot work */
static const char *
input_open(void)
{
	if (!signature_ok())
		return "this file has no valid signature here, so no entitlement: run it from /usr/local/bin";
	void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
	if (io == NULL)
		return "no IOKit";
	p_client_create = dlsym(io, "IOHIDEventSystemClientCreate");
	p_dispatch = dlsym(io, "IOHIDEventSystemClientDispatchEvent");
	p_digitizer = dlsym(io, "IOHIDEventCreateDigitizerEvent");
	p_finger = dlsym(io, "IOHIDEventCreateDigitizerFingerEvent");
	p_keyboard = dlsym(io, "IOHIDEventCreateKeyboardEvent");
	p_append = dlsym(io, "IOHIDEventAppendEvent");
	p_set_int = dlsym(io, "IOHIDEventSetIntegerValue");
	p_set_sender = dlsym(io, "IOHIDEventSetSenderID");
	if (!p_client_create || !p_dispatch || !p_digitizer || !p_finger || !p_keyboard || !p_append || !p_set_int || !p_set_sender)
		return "IOKit has not all the HID event functions";
	g_touch_id = service_id("SweetHIDTouch");
	g_buttons_id = service_id("SweetHIDButtons");
	if (g_touch_id == 0 || g_buttons_id == 0)
		return "no SweetHIDTouch or SweetHIDButtons service";
	g_client = p_client_create(kCFAllocatorDefault);
	if (g_client == NULL)
		return "no event system client (backboardd is not up?)";
	return NULL;
}

/* The shape of SweetHIDTouch::touch: one hand collection, one finger child */
static void
touch_send(int x, int y, bool down, uint32_t mask)
{
	const uint64_t now = mach_absolute_time();
	const double nx = (double)(x < 0 ? 0 : x > PANEL_W - 1 ? PANEL_W - 1 : x) / PANEL_W;
	const double ny = (double)(y < 0 ? 0 : y > PANEL_H - 1 ? PANEL_H - 1 : y) / PANEL_H;
	EventRef hand = p_digitizer(kCFAllocatorDefault, now, TYPE_HAND, 0, 0, mask, down ? 1 : 0, nx, ny, 0, 0, 0, down, down, 0);
	EventRef finger = p_finger(kCFAllocatorDefault, now, FINGER_INDEX, FINGER_INDEX + 2, mask, nx, ny, 0, down ? 1 : 0, 0, down, down, 0);
	if (hand == NULL || finger == NULL) {
		fprintf(stderr, "laurel-autotest: no event\n");
		exit(1);
	}
	p_set_int(hand, FIELD_COLLECTION, 1);
	p_set_int(hand, FIELD_IS_BUILTIN, 1);
	p_set_int(hand, FIELD_DISPLAY_INTEGRATED, 1);
	p_set_int(finger, FIELD_IS_BUILTIN, 1);
	p_set_int(finger, FIELD_DISPLAY_INTEGRATED, 1);
	p_append(hand, finger, 0);
	p_set_sender(hand, g_touch_id);
	p_dispatch(g_client, hand);
	CFRelease(finger);
	CFRelease(hand);
}

static bool
is_edge(int x, int y)
{
	return x < EDGE_PX || x > PANEL_W - 1 - EDGE_PX || y < EDGE_PX || y > PANEL_H - 1 - EDGE_PX;
}

static void
touch_path(int x0, int y0, int x1, int y1, int ms)
{
	const int step_ms = 8; /* 120 Hz, as a panel digitizer */
	const int steps = ms <= step_ms ? 1 : ms / step_ms;
	const uint32_t edge = is_edge(x0, y0) ? MASK_FROM_EDGE_TIP : 0;
	touch_send(x0, y0, true, edge | MASK_RANGE | MASK_TOUCH | MASK_IDENTITY);
	for (int i = 1; i <= steps; i++) {
		usleep(step_ms * 1000);
		touch_send(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps, true, edge | MASK_POSITION);
	}
	usleep(step_ms * 1000);
	touch_send(x1, y1, false, edge | MASK_RANGE | MASK_TOUCH);
}

static void
key_send(uint32_t usage, int hold_ms)
{
	for (int down = 1; down >= 0; down--) {
		EventRef e = p_keyboard(kCFAllocatorDefault, mach_absolute_time(), PAGE_CONSUMER, usage, down, 0);
		if (e == NULL) {
			fprintf(stderr, "laurel-autotest: no event\n");
			exit(1);
		}
		p_set_int(e, FIELD_IS_BUILTIN, 1);
		p_set_sender(e, g_buttons_id);
		p_dispatch(g_client, e);
		CFRelease(e);
		if (down)
			usleep((useconds_t)hold_ms * 1000);
	}
}

/* --- screen surfaces --- */

static IOSurfaceRef g_screen[MAX_SCREENS];
static int g_screens;
static int g_current;

static void
screens_release(void)
{
	for (int i = 0; i < g_screens; i++)
		CFRelease(g_screen[i]);
	g_screens = 0;
}

/* All surfaces of the panel's size and 4 bytes per pixel. A view of a surface is the only thing this adds. */
static void
screens_find(void)
{
	const uint32_t keep = g_current >= 0 && g_current < g_screens ? IOSurfaceGetID(g_screen[g_current]) : 0;
	screens_release();
	g_current = -1;
	for (uint32_t id = 1; id < MAX_SURFACE_ID && g_screens < MAX_SCREENS; id++) {
		IOSurfaceRef s = IOSurfaceLookup(id);
		if (s == NULL)
			continue;
		if (IOSurfaceGetWidth(s) == PANEL_W && IOSurfaceGetHeight(s) == PANEL_H && IOSurfaceGetBytesPerElement(s) == 4 && IOSurfaceGetPlaneCount(s) <= 1) {
			if (id == keep)
				g_current = g_screens;
			g_screen[g_screens++] = s;
		} else
			CFRelease(s);
	}
}

/* The surface id from the kernel, 0 if this kernel has no such sysctl */
static uint32_t
kernel_scan_id(void)
{
	uint32_t id = 0;
	size_t n = sizeof(id);
	return sysctlbyname("kern.laurel_scan_surface", &id, &n, NULL, 0) == 0 ? id : 0;
}

static IOSurfaceRef
screen_by_id(uint32_t id)
{
	for (int i = 0; i < g_screens; i++)
		if (IOSurfaceGetID(g_screen[i]) == id)
			return g_screen[i];
	return NULL;
}

/*
 * The kernel marks a surface in use at its swap, while the GPU can still be drawing it, and drops the mark of the frame before when the new one has latched (AppleCLCD::showDirect).
 * So a surface with a new mark holds an old picture for up to 900 ms: reading it would look like a flash of the previous state. The rule: the current surface stays until its own mark goes.
 */

static IOSurfaceRef
screen_from_marks(void)
{
	if (g_current >= 0 && g_current < g_screens && IOSurfaceIsInUse(g_screen[g_current]))
		return g_screen[g_current];
	g_current = -1;
	for (int i = 0; i < g_screens; i++)
		if (IOSurfaceIsInUse(g_screen[i])) {
			g_current = i;
			return g_screen[i];
		}
	return NULL;
}

/* Picks the surface on the panel. *how: "kernel" or "inferred". */
static IOSurfaceRef
screen_current(const char **how)
{
	const uint32_t id = kernel_scan_id();
	if (id != 0) {
		IOSurfaceRef s = screen_by_id(id);
		if (s == NULL) {
			screens_find();
			s = screen_by_id(id);
		}
		if (s != NULL) {
			*how = "kernel";
			return s;
		}
	}
	*how = "inferred";
	return screen_from_marks();
}

/* Everything is little endian. Whole frames: LATF. Sequence: LATS, then the same record for each frame, 1/4 size. */
struct frame_head {
	char magic[4];
	uint32_t surface, w, h, row, format;
	uint64_t t_us;
	uint32_t inferred, reserved;
};

static void
write_all(const void *p, size_t n)
{
	const uint8_t *c = p;
	while (n > 0) {
		ssize_t w = write(1, c, n);
		if (w <= 0)
			exit(3); /* the host went away */
		c += w;
		n -= (size_t)w;
	}
}

static uint64_t
now_us(void)
{
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0)
		mach_timebase_info(&tb);
	return mach_absolute_time() * tb.numer / tb.denom / 1000;
}

/* The rows go to the pipe as they are: BGRA, top row first */
static int
cmd_shot(uint32_t want_id)
{
	screens_find();
	const char *how = "";
	IOSurfaceRef s = want_id != 0 ? screen_by_id(want_id) : screen_current(&how);
	if (s == NULL) {
		fprintf(stderr, "laurel-autotest: no surface on the panel: %d screen surfaces, none in use (is the panel off?)\n", g_screens);
		return 1;
	}
	const uint8_t *base = IOSurfaceGetBaseAddress(s);
	const uint32_t w = (uint32_t)IOSurfaceGetWidth(s), h = (uint32_t)IOSurfaceGetHeight(s), row = (uint32_t)IOSurfaceGetBytesPerRow(s);
	if (base == NULL) {
		fprintf(stderr, "laurel-autotest: surface %u has no mapping\n", IOSurfaceGetID(s));
		return 1;
	}
	uint8_t *copy = malloc((size_t)w * 4 * h);
	if (copy == NULL)
		return 1;
	const uint64_t t = now_us();
	for (uint32_t y = 0; y < h; y++)
		memcpy(copy + (size_t)y * w * 4, base + (size_t)y * row, (size_t)w * 4);
	struct frame_head head = { { 'L', 'A', 'T', 'F' }, IOSurfaceGetID(s), w, h, w * 4, IOSurfaceGetPixelFormat(s), t, strcmp(how, "kernel") != 0, 0 };
	write_all(&head, sizeof(head));
	write_all(copy, (size_t)w * 4 * h);
	free(copy);
	return 0;
}

#define SEQ_RESCAN_US 300000 /* the compositor adds screen surfaces at times (an app in front): look for new ones when no frame came for this long */

static void
thumb_read(IOSurfaceRef s, uint8_t *thumb, uint32_t tw, uint32_t th)
{
	const uint8_t *base = IOSurfaceGetBaseAddress(s);
	const size_t row = IOSurfaceGetBytesPerRow(s);
	for (uint32_t y = 0; y < th; y++) {
		const uint32_t *src = (const uint32_t *)(base + (size_t)y * THUMB_DIV * row);
		uint32_t *dst = (uint32_t *)(thumb + (size_t)y * tw * 4);
		for (uint32_t x = 0; x < tw; x++)
			dst[x] = src[x * THUMB_DIV];
	}
}

/*
 * One record per change of the surface, or of its picture. The host (op10tool autotest-seq) finds a frame that equals an older one.
 * Rows are read 1 in 4, to keep to the flip rate.
 */
static int
cmd_seq(int want, int max_ms)
{
	screens_find();
	const char *how = "";
	const uint32_t tw = PANEL_W / THUMB_DIV, th = PANEL_H / THUMB_DIV;
	const size_t bytes = (size_t)tw * 4 * th;
	uint8_t *thumb = malloc(bytes), *last = calloc(1, bytes);
	if (thumb == NULL || last == NULL)
		return 1;
	const char magic[4] = { 'L', 'A', 'T', 'S' };
	write_all(magic, 4);
	const uint64_t t0 = now_us();
	uint64_t t_find = t0;
	uint32_t last_id = 0;
	for (int got = 0; got < want && now_us() - t0 < (uint64_t)max_ms * 1000;) {
		usleep(2000);
		if (now_us() - t_find > SEQ_RESCAN_US) {
			screens_find();
			t_find = now_us();
		}
		IOSurfaceRef s = screen_current(&how);
		if (s == NULL || IOSurfaceGetBaseAddress(s) == NULL)
			continue;
		thumb_read(s, thumb, tw, th);
		const uint32_t id = IOSurfaceGetID(s);
		if (id == last_id && memcmp(thumb, last, bytes) == 0)
			continue;
		struct frame_head head = { { 'L', 'A', 'T', 'F' }, id, tw, th, tw * 4, IOSurfaceGetPixelFormat(s), now_us() - t0, strcmp(how, "kernel") != 0, 0 };
		write_all(&head, sizeof(head));
		write_all(thumb, bytes);
		memcpy(last, thumb, bytes);
		last_id = id;
		t_find = now_us();
		got++;
	}
	free(thumb);
	free(last);
	return 0;
}

/*
 * Waits until the picture holds still for QUIET_MS, at most MAX_MS. With change=1 the picture must first change (an app that takes seconds to come). Exit 0 if it settled.
 * Two panel frames may differ by a little (a clock, noise): under 0.2 % of the samples moved counts as still, as the host's rule for one picture.
 */
static int
cmd_settle(int quiet_ms, int max_ms, int must_change)
{
	screens_find();
	const char *how = "";
	const uint32_t tw = PANEL_W / THUMB_DIV, th = PANEL_H / THUMB_DIV;
	const size_t bytes = (size_t)tw * 4 * th, pixels = (size_t)tw * th;
	uint8_t *thumb = malloc(bytes), *last = malloc(bytes);
	if (thumb == NULL || last == NULL)
		return 1;
	const uint64_t t0 = now_us();
	uint64_t t_find = t0, still_since = t0;
	bool have = false, changed = false;
	while (now_us() - t0 < (uint64_t)max_ms * 1000) {
		usleep(30000);
		if (now_us() - t_find > SEQ_RESCAN_US) {
			screens_find();
			t_find = now_us();
		}
		IOSurfaceRef s = screen_current(&how);
		if (s == NULL || IOSurfaceGetBaseAddress(s) == NULL)
			continue;
		thumb_read(s, thumb, tw, th);
		if (have) {
			size_t moved = 0;
			for (size_t i = 0; i < pixels; i++) {
				const uint8_t *a = thumb + i * 4, *b = last + i * 4;
				if (abs((int)a[0] - b[0]) > 8 || abs((int)a[1] - b[1]) > 8 || abs((int)a[2] - b[2]) > 8)
					moved++;
			}
			if (moved * 500 >= pixels) {
				changed = true;
				still_since = now_us();
				memcpy(last, thumb, bytes);
			}
		} else {
			memcpy(last, thumb, bytes);
			have = true;
			still_since = now_us();
		}
		size_t dark = 0;
		if (must_change) {
			for (size_t i = 0; i < pixels; i++) {
				const uint8_t *a = thumb + i * 4;
				dark += a[0] <= 8 && a[1] <= 8 && a[2] <= 8;
			}
		}
		/* an app's black launch screen is not the end of a change: a black screen that stays ends at MAX_MS, and the step says so */
		const bool black = must_change && dark * 100 >= pixels * 98;
		if (black && have)
			still_since = now_us();
		if ((changed || !must_change) && !black && now_us() - still_since >= (uint64_t)quiet_ms * 1000) {
			printf("settled in %llu ms, %s\n", (now_us() - t0) / 1000, changed ? "changed" : "no change");
			return 0;
		}
	}
	printf("not settled in %d ms, %s\n", max_ms, changed ? "changed" : "no change");
	return 1;
}

/*
 * SpringBoard's own state. The surfaces cannot tell: with the panel off the last one keeps its mark, drawn black [V phone].
 * Exit 0: on. 1: off. 3: no answer (no state in notifyd, SpringBoard not up).
 */
static uint64_t
springboard_state(const char *name, int *ok)
{
	int token = 0;
	uint64_t v = 0;
	*ok = notify_register_check(name, &token) == NOTIFY_STATUS_OK && notify_get_state(token, &v) == NOTIFY_STATUS_OK;
	if (token != 0)
		notify_cancel(token);
	return v;
}

static int
cmd_awake(void)
{
	int ok_blank, ok_lock;
	const uint64_t blank = springboard_state("com.apple.springboard.hasBlankedScreen", &ok_blank);
	const uint64_t lock = springboard_state("com.apple.springboard.lockstate", &ok_lock);
	printf("blanked %llu (%s), locked %llu (%s)\n", blank, ok_blank ? "read" : "no answer", lock, ok_lock ? "read" : "no answer");
	return !ok_blank ? 3 : blank != 0 ? 1 : 0;
}

static int
cmd_surfaces(void)
{
	screens_find();
	printf("kernel scan surface: %u\n", kernel_scan_id());
	for (uint32_t id = 1; id < MAX_SURFACE_ID; id++) { /* everything of 400 x 400 or more */
		IOSurfaceRef s = IOSurfaceLookup(id);
		if (s == NULL)
			continue;
		if (IOSurfaceGetWidth(s) >= 400 && IOSurfaceGetHeight(s) >= 400) {
			const uint32_t f = IOSurfaceGetPixelFormat(s);
			printf("big id %u %zux%zu bpe %zu row %zu format %c%c%c%c (%#x) inuse %d alloc %zu\n", id, IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), IOSurfaceGetBytesPerElement(s), IOSurfaceGetBytesPerRow(s),
			    (char)(f >> 24), (char)(f >> 16), (char)(f >> 8), (char)f, f, IOSurfaceIsInUse(s), IOSurfaceGetAllocSize(s));
		}
		CFRelease(s);
	}
	for (int i = 0; i < g_screens; i++) {
		IOSurfaceRef s = g_screen[i];
		const uint32_t f = IOSurfaceGetPixelFormat(s);
		printf("id %u %zux%zu row %zu format %c%c%c%c inuse %d base %p\n", IOSurfaceGetID(s), IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), IOSurfaceGetBytesPerRow(s),
		    (char)(f >> 24), (char)(f >> 16), (char)(f >> 8), (char)f, IOSurfaceIsInUse(s), IOSurfaceGetBaseAddress(s));
	}
	return 0;
}

/* --- apps --- */

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundle;
@end

static int
cmd_open(const char *bundle)
{
	@autoreleasepool {
		NSString *b = [NSString stringWithUTF8String:bundle];
		void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
		int (*launch)(CFStringRef, Boolean) = sbs ? dlsym(sbs, "SBSLaunchApplicationWithIdentifier") : NULL;
		if (launch != NULL) {
			const int r = launch((__bridge CFStringRef)b, false);
			if (r == 0) {
				printf("open %s: SBSLaunchApplicationWithIdentifier ok\n", bundle);
				return 0;
			}
			printf("open %s: SBSLaunchApplicationWithIdentifier -> %d\n", bundle, r);
		}
		dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
		Class ws = NSClassFromString(@"LSApplicationWorkspace");
		if (ws != nil && [[ws defaultWorkspace] openApplicationWithBundleID:b]) {
			printf("open %s: LSApplicationWorkspace ok\n", bundle);
			return 0;
		}
		fprintf(stderr, "open %s: FAILED\n", bundle);
		return 1;
	}
}

static int
num(const char *s, const char *what)
{
	char *end;
	const long v = strtol(s, &end, 10);
	if (*s == 0 || *end != 0 || v < -100000 || v > 100000) {
		fprintf(stderr, "laurel-autotest: %s: not a number: %s\n", what, s);
		exit(2);
	}
	return (int)v;
}

/* laurel: where a process's running threads spend their time: for docs/laurel_sprout/ios26-default-speed.md. `sample PID SECONDS HZ` prints "I base path" per image, then "S thread pc lr frames...".
 * Each sample stops one running thread for the time of its stack walk through frame pointers. */
extern kern_return_t mach_vm_read_overwrite(vm_map_t, uint64_t, uint64_t, uint64_t, uint64_t *);
extern kern_return_t task_for_pid(mach_port_t, int, mach_port_t *);

static int
read_task(task_t task, uint64_t at, void *to, uint64_t size)
{
	uint64_t got = 0;
	return mach_vm_read_overwrite(task, at, size, (uint64_t)to, &got) == KERN_SUCCESS && got == size;
}

static void
sample_images(task_t task)
{
	struct task_dyld_info info;
	mach_msg_type_number_t n = TASK_DYLD_INFO_COUNT;
	if (task_info(task, TASK_DYLD_INFO, (task_info_t)&info, &n) != KERN_SUCCESS)
		return;
	struct { uint32_t version, count; uint64_t array; } head;
	if (!read_task(task, info.all_image_info_addr, &head, sizeof(head)))
		return;
	for (uint32_t i = 0; i < head.count; i++) {
		struct { uint64_t base, path, date; } image;
		char path[300] = "";
		if (!read_task(task, head.array + i * sizeof(image), &image, sizeof(image)))
			break;
		for (uint32_t k = 0; k + 1 < sizeof(path); k++) {
			if (!read_task(task, image.path + k, path + k, 1) || !path[k])
				break;
		}
		printf("I %llx %s\n", image.base, path);
	}
}

static int
cmd_sample(int pid, int seconds, int hz)
{
	task_t task;
	kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
	if (kr != KERN_SUCCESS) {
		fprintf(stderr, "sample: task_for_pid: %s\n", mach_error_string(kr));
		return 1;
	}
	sample_images(task);
	uint64_t ends = mach_absolute_time() + (uint64_t)seconds * 24000000;
	while (mach_absolute_time() < ends) {
		thread_act_array_t threads;
		mach_msg_type_number_t count;
		if (task_threads(task, &threads, &count) != KERN_SUCCESS)
			break;
		for (mach_msg_type_number_t t = 0; t < count; t++) {
			struct thread_basic_info basic;
			mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
			if (thread_info(threads[t], THREAD_BASIC_INFO, (thread_info_t)&basic, &n) == KERN_SUCCESS && basic.run_state == TH_STATE_RUNNING &&
			    thread_suspend(threads[t]) == KERN_SUCCESS) {
				arm_thread_state64_t state;
				n = ARM_THREAD_STATE64_COUNT;
				if (thread_get_state(threads[t], ARM_THREAD_STATE64, (thread_state_t)&state, &n) == KERN_SUCCESS) {
					printf("S %u %llx %llx", t, arm_thread_state64_get_pc(state), arm_thread_state64_get_lr(state));
					uint64_t fp = arm_thread_state64_get_fp(state);
					for (int d = 0; d < 48 && fp; d++) {
						uint64_t frame[2];
						if (!read_task(task, fp, frame, sizeof(frame)))
							break;
						printf(" %llx", frame[1] & 0xfffffffffULL);
						if (frame[0] <= fp)
							break;
						fp = frame[0];
					}
					printf("\n");
				}
				thread_resume(threads[t]);
			}
			mach_port_deallocate(mach_task_self(), threads[t]);
		}
		vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(threads[0]));
		usleep(1000000 / hz);
	}
	fflush(stdout);
	return 0;
}

static int
usage(void)
{
	fprintf(stderr, "usage: laurel-autotest check | awake | tap X Y [MS] | swipe X0 Y0 X1 Y1 [MS] | edge bottom|top|left|right [LEN] [MS] [AT] | key power|volup|voldown|home [MS] | open BUNDLE | surfaces | shot | settle QUIET_MS MAX_MS [change] | seq N [MAX_MS]\n");
	return 2;
}

static int
need_input(void)
{
	const char *why = input_open();
	if (why != NULL) {
		fprintf(stderr, "LAUREL AUTOTEST: off: %s\n", why);
		return 1;
	}
	return 0;
}

int
main(int argc, char **argv)
{
	if (argc < 2)
		return usage();
	const char *c = argv[1];
	if (strcmp(c, "check") == 0) {
		const char *why = input_open();
		if (why != NULL) {
			printf("LAUREL AUTOTEST: off: %s\n", why);
			return 1;
		}
		screens_find();
		printf("LAUREL AUTOTEST: on: touch service %#llx, buttons %#llx, %d screen surfaces, panel surface from %s\n", g_touch_id, g_buttons_id, g_screens, kernel_scan_id() ? "the kernel" : "in-use marks (inferred)");
		return 0;
	}
	if (strcmp(c, "awake") == 0)
		return cmd_awake();
	if (strcmp(c, "surfaces") == 0)
		return cmd_surfaces();
	if (strcmp(c, "shot") == 0)
		return cmd_shot(argc > 2 ? (uint32_t)num(argv[2], "ID") : 0);
	if (strcmp(c, "seq") == 0 && argc >= 3)
		return cmd_seq(num(argv[2], "N"), argc > 3 ? num(argv[3], "MAX_MS") : 10000);
	if (strcmp(argv[1], "sample") == 0 && argc >= 5)
		return cmd_sample(num(argv[2], "PID"), num(argv[3], "SECONDS"), num(argv[4], "HZ"));
	if (strcmp(c, "settle") == 0 && argc >= 4)
		return cmd_settle(num(argv[2], "QUIET_MS"), num(argv[3], "MAX_MS"), argc > 4 && strcmp(argv[4], "change") == 0);
	if (strcmp(c, "open") == 0 && argc == 3)
		return cmd_open(argv[2]);
	if (need_input())
		return 1;
	if (strcmp(c, "tap") == 0 && argc >= 4) {
		const int x = num(argv[2], "X"), y = num(argv[3], "Y");
		touch_path(x, y, x, y, argc > 4 ? num(argv[4], "MS") : 50);
	} else if (strcmp(c, "swipe") == 0 && argc >= 6) {
		touch_path(num(argv[2], "X0"), num(argv[3], "Y0"), num(argv[4], "X1"), num(argv[5], "Y1"), argc > 6 ? num(argv[6], "MS") : 300);
	} else if (strcmp(c, "edge") == 0 && argc >= 3) {
		const char *e = argv[2];
		const int vertical = strcmp(e, "bottom") == 0 || strcmp(e, "top") == 0;
		const int len = argc > 3 ? num(argv[3], "LEN") : (vertical ? 800 : 400);
		const int ms = argc > 4 ? num(argv[4], "MS") : 300;
		const int at = argc > 5 ? num(argv[5], "AT") : (vertical ? PANEL_W / 2 : PANEL_H / 2);
		if (strcmp(e, "bottom") == 0)
			touch_path(at, PANEL_H - 2, at, PANEL_H - 2 - len, ms);
		else if (strcmp(e, "top") == 0)
			touch_path(at, 2, at, 2 + len, ms);
		else if (strcmp(e, "left") == 0)
			touch_path(2, at, 2 + len, at, ms);
		else if (strcmp(e, "right") == 0)
			touch_path(PANEL_W - 3, at, PANEL_W - 3 - len, at, ms);
		else
			return usage();
	} else if (strcmp(c, "key") == 0 && argc >= 3) {
		static const struct {
			const char *name;
			uint32_t usage;
		} keys[] = { { "power", 0x30 }, { "volup", 0xe9 }, { "voldown", 0xea }, { "home", 0x40 } }; /* as sweet_hid_key */
		uint32_t usage_id = 0;
		for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
			if (strcmp(argv[2], keys[i].name) == 0)
				usage_id = keys[i].usage;
		if (usage_id == 0)
			return usage();
		key_send(usage_id, argc > 3 ? num(argv[3], "MS") : 80);
	} else {
		return usage();
	}
	return 0;
}
