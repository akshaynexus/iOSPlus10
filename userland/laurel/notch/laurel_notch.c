/*
 * liblaurel-notch.dylib: the Mi A3 (laurel_sprout) waterdrop as SpringBoard's display shape (the "exclusion area").
 * Inserted into SpringBoard by laurel-springboard (sb_wrap.c). Docs: docs/laurel_sprout/rtc-statusbar.md "C".
 *
 * Why [V 20H392 iPhone10,3 shared cache, scripts/debug/statusbar-re.sh]:
 *   SpringBoard's display shape = +[UISDisplaySingleRectShape(SpringBoard) sb_displayShapeForScreenType:
 *   SBHScreenTypeForCurrentDevice()]. The screen type matches the main screen reference bounds + scale against
 *   Apple's table; 360x780 @2 (kernel 2103 native canvas) matches no entry, and a gesture phone then falls back to
 *   type 4 "D22Zoomed" (iPhone X display zoom, 320x693 @3). Its shape is the iPhone X notch in a 320 pt frame:
 *   {70.8, 0, 178.4, 25.6} pt (627x90 px at x 249 px / native scale 3.515625). SpringBoard sends that rect to every
 *   app (UISDisplayContext exclusionArea -> UIScreen _exclusionArea), and _UIStatusBarVisualProvider_FixedSplit
 *   centres the time at notch.x / 2 + 0.15 * corner radius and ends its regions at (width - notch width) / 2: on
 *   our 360 pt screen the time and the battery sit 41 pt from the edges with a 178 pt notch between them.
 * What: the method above returns the real Mi A3 waterdrop for the current screen type:
 *   LineageOS laurel_sprout overlay config_mainBuiltInDisplayCutout (px, origin top centre):
 *     M -89.6 0  C -65.1 0 -51.2 0.2 -37 31.3  C -29.3 44.1 -15.5 53 0 53  C 15.5 53 ... 89.6 0  Z
 *   = 179.2 px wide at the top edge (with the curved shoulders), 74 px wide at y 31.3, 53 px deep.
 *   At @2x (2103: 720x1560 px = 360x780 pt): {135.2, 0, 89.6, 26.5} pt, centred.
 *   Other screen types (classic-mode apps) keep Apple's shapes. Safe areas (top 38, bottom 29, home affordance 21:
 *   the D22Zoomed edge info) are not changed: top 38 = drop 26.5 + 11.5 pt below it.
 * Self-check (at the first shape request; the result is one line "LAUREL NOTCH: on|off: ..."): the process is
 *   SpringBoard; UISDisplaySingleRectShape has the SpringBoard category method, -initWithRect: and -rect;
 *   SBHScreenTypeForCurrentDevice, __sb__mainScreenReferenceBounds and __sb__mainScreenScale resolve (dlsym, no
 *   UIScreen: the main-thread-free path of SpringBoard also asks for the shape); the main screen is 360x780 @2.
 *   Anything else: Apple's shape stays (off line with the reason). Kill switch: boot-arg notch=0 (in sb_wrap.c).
 * Log: syslog + /var/tmp/laurel-notch.log + /dev/console, so the lines reach the USB log (launchd sends SpringBoard's stderr to /dev/null).
 *
 * Top bar in SpringBoard [V 23F84, docs/laurel_sprout/ios26-touch.md section 5]: SpringBoard's bar is STUIStatusBar of SystemStatusUI, not _UIStatusBar of UIKitCore.
 *   STUIStatusBarGetVisualProviderClassForScreen does not read the default UIStatusBarVisualProviderClassName: only PTSettings (visualProviderSettings.visualProviderClassName). Its Split
 *   has no fallback: 720 px gives nil, and nil is the red rdar://45025538 bar. So Split with nil on the embedded 360x780 @2 screen gives FixedSplit, in both stacks. One line:
 *   "top bar: on|off: reason", also when no bar asks within 60 s. Self-check: both classes, and the method type. Else Apple's nil stays. The UIKit default stays for apps.
 */
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include <objc/message.h>
#include <objc/runtime.h>

#define LOG         "/var/tmp/laurel-notch.log"
/* panel and canvas (kernel 2103: native 720x1560, ADT display-scale 2) */
#define SCREEN_W    360.0
#define SCREEN_H    780.0
#define SCREEN_S    2.0
/* waterdrop bounding box from the Lineage cutout path, px */
#define DROP_W_PX   179.2
#define DROP_H_PX   53.0

typedef struct { double x, y, w, h; } rect_t;   /* = CGRect on arm64 (4 doubles, returned in d0-d3) */

static Class shape_class;
static SEL sel_shape, sel_init, sel_rect;
static id (*orig_shape)(id, SEL, unsigned long);
static unsigned long (*sbh_type)(void);
static rect_t (*sb_bounds)(void);
static double (*sb_scale)(void);
static pthread_once_t once = PTHREAD_ONCE_INIT;
static unsigned long drop_type = ~0UL;
static id drop_shape;                           /* retained for the life of SpringBoard */

static void
say(const char *fmt, ...)
{
	char line[400];
	va_list ap;
	FILE *f;

	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	syslog(LOG_NOTICE, "LAUREL NOTCH: %s", line);
	if ((f = fopen(LOG, "a")) != NULL) {
		fprintf(f, "%ld LAUREL NOTCH: %s\n", (long)time(NULL), line);
		fclose(f);
	}
	if ((f = fopen("/dev/console", "a")) != NULL) {         /* mode 0622: mobile can write it */
		fprintf(f, "LAUREL NOTCH: %s\n", line);
		fclose(f);
	}
}

static rect_t
drop_rect(void)
{
	rect_t r;

	r.w = DROP_W_PX / SCREEN_S;
	r.h = DROP_H_PX / SCREEN_S;
	r.x = (SCREEN_W - r.w) / 2;
	r.y = 0;
	return r;
}

/* once, at the first shape request: decide on/off and build the shape */
static void
decide(void)
{
	rect_t b = sb_bounds(), d = drop_rect(), old = { 0, 0, 0, 0 };
	double s = sb_scale();
	unsigned long type;
	id o, n;

	if (fabs(b.w - SCREEN_W) > 0.01 || fabs(b.h - SCREEN_H) > 0.01 || fabs(s - SCREEN_S) > 0.01) {
		say("off: main screen %.0fx%.0f pt @%.2f is not the native 360x780 @2 canvas (kernel 2103; sweetfb_native=0?): "
		    "SpringBoard keeps its own display shape", b.w, b.h, s);
		return;
	}
	type = sbh_type();
	o = orig_shape((id)shape_class, sel_shape, type);
	if (o != nil) {
		old = ((rect_t (*)(id, SEL))objc_msgSend)(o, sel_rect);
	}
	n = ((id (*)(id, SEL))objc_msgSend)((id)shape_class, sel_registerName("alloc"));
	n = ((id (*)(id, SEL, rect_t))objc_msgSend)(n, sel_init, d);
	if (n == nil) {
		say("off: -[UISDisplaySingleRectShape initWithRect:] gave nil: SpringBoard keeps its own display shape");
		return;
	}
	drop_shape = n;
	__atomic_store_n(&drop_type, type, __ATOMIC_RELEASE);
	say("on: screen type %lu shape {%.1f, %.1f, %.1f, %.1f} pt -> waterdrop {%.1f, %.1f, %.1f, %.1f} pt "
	    "(Lineage cutout %.1fx%.0f px @2x, screen %.0fx%.0f @%.0f)", type, old.x, old.y, old.w, old.h,
	    d.x, d.y, d.w, d.h, DROP_W_PX, DROP_H_PX, b.w, b.h, s);
}

static id
hook_shape(id self, SEL cmd, unsigned long type)
{
	pthread_once(&once, decide);
	if (drop_shape != nil && type == __atomic_load_n(&drop_type, __ATOMIC_ACQUIRE)) {
		return drop_shape;
	}
	return orig_shape(self, cmd, type);
}

/* ---- top bar: Split with no table entry -> FixedSplit ---- */
#define TOPBAR_CHECK_S 60
static Class (*orig_split_ui)(id, SEL, id, id), (*orig_split_stui)(id, SEL, id, id);
static Class fixed_ui, fixed_stui;
static int topbar_said;
static volatile int topbar_ui_asked;

/* this process's screen is the 360x780 @2 embedded one */
static int
topbar_screen_ok(id screen)
{
	rect_t b;

	if (sb_bounds == NULL || sb_scale == NULL) {
		return 0;
	}
	b = sb_bounds();
	return fabs(b.w - SCREEN_W) <= 0.01 && fabs(b.h - SCREEN_H) <= 0.01 && fabs(sb_scale() - SCREEN_S) <= 0.01 &&
	    ((BOOL (*)(id, SEL))objc_msgSend)(screen, sel_registerName("_isEmbeddedScreen"));
}

/* SystemStatusUI: the bar of SpringBoard. This is the path that gave the red bar on 23F84 */
static Class
hook_split_stui(id self, SEL cmd, id screen, id info)
{
	Class c = orig_split_stui(self, cmd, screen, info);
	int ok = c == Nil && topbar_screen_ok(screen);

	if (!__atomic_exchange_n(&topbar_said, 1, __ATOMIC_RELAXED)) {
		if (ok) {
			say("top bar: on: SystemStatusUI has no provider for 720 px: STUIStatusBarVisualProvider_FixedSplit");
		} else if (c != Nil) {
			say("top bar: on: Apple's table gives %s", class_getName(c));
		} else {
			say("top bar: off: SystemStatusUI gives no provider, and the screen is not the embedded 360x780 @2 one");
		}
	}
	return ok ? fixed_stui : c;
}

/* UIKit: the bar of a UIKit status bar in this process. No line of its own: the check below names it */
static Class
hook_split_ui(id self, SEL cmd, id screen, id info)
{
	Class c = orig_split_ui(self, cmd, screen, info);

	topbar_ui_asked = 1;
	return c == Nil && topbar_screen_ok(screen) ? fixed_ui : c;
}

/* the line also when no bar asked for a provider */
static void
topbar_check(void *ctx)
{
	if (!__atomic_exchange_n(&topbar_said, 1, __ATOMIC_RELAXED)) {
		say("top bar: off: %d s after the start SpringBoard did not ask SystemStatusUI for a Split provider (UIKit asked: %d); the hook did nothing",
		    TOPBAR_CHECK_S, topbar_ui_asked);
	}
}

/* one hook: nil -> fixed; returns the old IMP, or NULL when a test fails */
static IMP
topbar_hook(const char *split, const char *fixed, Class *out, IMP imp)
{
	Class c = objc_getClass(split);
	Method m = c == Nil ? NULL : class_getClassMethod(c, sel_registerName("visualProviderSubclassForScreen:visualProviderInfo:"));

	*out = objc_getClass(fixed);
	if (m == NULL || *out == Nil || strcmp(method_getTypeEncoding(m), "#32@0:8@16@24") != 0) {
		return NULL;
	}
	return method_setImplementation(m, imp);
}

static void
topbar_init(void)
{
	orig_split_ui = (Class (*)(id, SEL, id, id))topbar_hook("_UIStatusBarVisualProvider_Split", "_UIStatusBarVisualProvider_FixedSplit", &fixed_ui, (IMP)hook_split_ui);
	orig_split_stui = (Class (*)(id, SEL, id, id))topbar_hook("STUIStatusBarVisualProvider_Split", "STUIStatusBarVisualProvider_FixedSplit", &fixed_stui, (IMP)hook_split_stui);
	if (orig_split_stui == NULL) {
		__atomic_store_n(&topbar_said, 1, __ATOMIC_RELAXED);
		say("top bar: off: no STUIStatusBarVisualProvider_Split/_FixedSplit with the type #32@0:8@16@24 [V 23F84]: Apple's nil stays (the red bar)");
		return;
	}
	dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, TOPBAR_CHECK_S * NSEC_PER_SEC), dispatch_get_main_queue(), NULL, topbar_check);
}

__attribute__((constructor))
static void
laurel_notch_init(void)
{
	Method m;

	unsetenv("DYLD_INSERT_LIBRARIES");      /* not for SpringBoard's children */
	if (strcmp(getprogname(), "SpringBoard") != 0) {
		return;
	}
	topbar_init();
	shape_class = objc_getClass("UISDisplaySingleRectShape");
	sel_shape = sel_registerName("sb_displayShapeForScreenType:");
	sel_init = sel_registerName("initWithRect:");
	sel_rect = sel_registerName("rect");
	sbh_type = (unsigned long (*)(void))dlsym(RTLD_DEFAULT, "SBHScreenTypeForCurrentDevice");
	sb_bounds = (rect_t (*)(void))dlsym(RTLD_DEFAULT, "__sb__mainScreenReferenceBounds");
	sb_scale = (double (*)(void))dlsym(RTLD_DEFAULT, "__sb__mainScreenScale");
	if (shape_class == Nil) {
		say("off: no class UISDisplaySingleRectShape (UIKitServices)");
		return;
	}
	m = class_getClassMethod(shape_class, sel_shape);
	if (m == NULL || class_getInstanceMethod(shape_class, sel_init) == NULL ||
	    class_getInstanceMethod(shape_class, sel_rect) == NULL) {
		say("off: UISDisplaySingleRectShape has no %s", m == NULL ? "+sb_displayShapeForScreenType: (SpringBoard category)" :
		    "-initWithRect: or -rect");
		return;
	}
	if (sbh_type == NULL || sb_bounds == NULL || sb_scale == NULL) {
		say("off: missing %s", sbh_type == NULL ? "SBHScreenTypeForCurrentDevice (SpringBoardHome)" :
		    sb_bounds == NULL ? "__sb__mainScreenReferenceBounds" : "__sb__mainScreenScale");
		return;
	}
	if (strcmp(method_getTypeEncoding(m), "@24@0:8Q16") != 0) {
		say("off: +sb_displayShapeForScreenType: has type %s, not @24@0:8Q16 [V 20H392]", method_getTypeEncoding(m));
		return;
	}
	orig_shape = (id (*)(id, SEL, unsigned long))method_setImplementation(m, (IMP)hook_shape);
}
