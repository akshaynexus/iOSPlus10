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
 * Top bar in SpringBoard [V 23F84 UIKitCore, docs/laurel_sprout/ios26-touch.md section 5]: _UIStatusBarVisualProvider_Split no longer falls back to
 *   _FixedSplit: no code of UIKitCore names that class; only the default UIStatusBarVisualProviderClassName reaches it. A width in no table (720 px) gets nil, and nil is
 *   the red rdar://45025538 bar. So when Split gives nil on this screen, it gives _FixedSplit, as UIKit of 20H392 does with Jindo off. One line says what the default holds, and
 *   whether UIKit calls this screen embedded: those are the two tests in front of the default. Self-check: both classes, and the method type. Else Apple's nil stays, one off line.
 */
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
static Class (*orig_split)(id, SEL, id, id);
static Class fixed_split;
static int topbar_said;

/* What the default holds in this process: the suite UIKit reads (_UIKitUserDefaults), as text. Only for the log line. */
static const char *
topbar_default(void)
{
	Class nsud = objc_getClass("NSUserDefaults"), nss = objc_getClass("NSString");
	id (*str)(id, SEL, const char *) = (id (*)(id, SEL, const char *))objc_msgSend;
	id d, v;

	if (nsud == Nil || nss == Nil) {
		return "?";
	}
	d = ((id (*)(id, SEL))objc_msgSend)((id)nsud, sel_registerName("alloc"));
	d = ((id (*)(id, SEL, id))objc_msgSend)(d, sel_registerName("initWithSuiteName:"), str((id)nss, sel_registerName("stringWithUTF8String:"), "com.apple.UIKit"));
	if (d == nil) {
		return "no suite";
	}
	v = ((id (*)(id, SEL, id))objc_msgSend)(d, sel_registerName("objectForKey:"), str((id)nss, sel_registerName("stringWithUTF8String:"), "UIStatusBarVisualProviderClassName"));
	return v == nil ? "not set" : ((const char *(*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(v, sel_registerName("description")), sel_registerName("UTF8String"));
}

static Class
hook_split(id self, SEL cmd, id screen, id info)
{
	Class c = orig_split(self, cmd, screen, info);
	rect_t b;

	if (c != Nil || sb_bounds == NULL || sb_scale == NULL) {
		return c;
	}
	b = sb_bounds();
	if (fabs(b.w - SCREEN_W) > 0.01 || fabs(b.h - SCREEN_H) > 0.01 || fabs(sb_scale() - SCREEN_S) > 0.01) {
		return c;
	}
	if (!__atomic_exchange_n(&topbar_said, 1, __ATOMIC_RELAXED)) {
		say("top bar: on: UIKit has no provider for 720 px and read the default as '%s', embedded screen %d: _UIStatusBarVisualProvider_FixedSplit",
		    topbar_default(), (int)((BOOL (*)(id, SEL))objc_msgSend)(screen, sel_registerName("_isEmbeddedScreen")));
	}
	return fixed_split;
}

static void
topbar_init(void)
{
	Class split = objc_getClass("_UIStatusBarVisualProvider_Split");
	SEL sel = sel_registerName("visualProviderSubclassForScreen:visualProviderInfo:");
	Method m = split == Nil ? NULL : class_getClassMethod(split, sel);

	fixed_split = objc_getClass("_UIStatusBarVisualProvider_FixedSplit");
	if (m == NULL || fixed_split == Nil) {
		say("top bar: off: no %s", m == NULL ? "+[_UIStatusBarVisualProvider_Split visualProviderSubclassForScreen:visualProviderInfo:]" : "class _UIStatusBarVisualProvider_FixedSplit");
		return;
	}
	if (strcmp(method_getTypeEncoding(m), "#32@0:8@16@24") != 0) {
		say("top bar: off: the Split method has type %s, not #32@0:8@16@24 [V 23F84]", method_getTypeEncoding(m));
		return;
	}
	orig_split = (Class (*)(id, SEL, id, id))method_setImplementation(m, (IMP)hook_split);
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
