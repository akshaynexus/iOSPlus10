/*
 * liblaurel-cellbar.dylib: the Mi A3's SIM state, signal bars and network name in iOS, from kern.laurel_cell_state (kernel patch 2786). Inserted into
 * SpringBoard by laurel-springboard (userland/laurel/notch/sb_wrap.c). Docs: docs/laurel_sprout/cellular.md section 9.
 *
 * Why here [V 20H392 iPhone10,3 shared cache, scripts/debug/cell-statusbar-re.sh]: SpringBoard's status bar reads telephonyDomain.data.primarySIMInfo.
 * STTelephonyStatusDomainDataProvider fills that domain from STTelephonyStateProvider: subscriptionInfoForSlot:, isSIMPresentForSlot:,
 * isCellularRadioCapabilityActive, isDualSIMEnabled, isRadioModuleDead. These go through objc_msgSend. The provider's own builder (_updateDataForSlot:,
 * _SIMInfoForStateProvider:...) is objc_direct, so it cannot be replaced, and need not be. The state provider has no CommCenter here. So this file answers for it,
 * and Apple's code does the rest: NO_SIM, LOCKED_SIM, NO_SERVICE, SEARCHING, the network's name; the signal item is on only with cellularServiceState 2
 * (registered) [V -[SBStatusBarStateAggregator _updateSignalStrengthItem:...]]. Nothing is forced on the bar: no bars without a registration.
 * hackios-scion patched the bar's items at the aggregator instead; on 20H392 those setter blocks take (block, value), not scion's (block, data, value) [V].
 *
 * Self-check at the start (one line "LAUREL CELLBAR: on|off: ..."; also in the USB log through kern.laurel_cell_ui): the process is SpringBoard; the sysctl exists;
 * every class, method and CoreTelephony constant exists; 3 s after the first update the published domain must hold what was set. Failure = Apple's answers stay.
 * Kernel state "off" (cell=0, modem crash): Apple's answers come back. Kill switch: boot-arg cell=0 (sb_wrap.c does not insert this file).
 * Privacy: ICCID, IMSI and IMEI are not in the kernel's text, and this file reads nothing else.
 * Not here: data (the kernel has none yet), SMS, voice, Settings > Cellular content: those read CoreTelephony's XPC service, which is CommCenter.
 */
#include <dispatch/dispatch.h>
#include <dlfcn.h>
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
#include <sys/sysctl.h>
#include "cellbar_state.h"

#define LOG         "/var/tmp/laurel-cellbar.log"
#define TICK_S      3
#define NO_PROVIDER_S 120
#define MAX_BARS    4           /* an iPhone X shows at most 4 [I: the kernel's bars use the same scale] */

extern id objc_retain(id);
extern void objc_release(id);
extern id objc_autorelease(id);
extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *);

static Class c_info;
static id dp, sp;                       /* the domain provider and its state provider (SpringBoard's only ones, retained) */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct cellbar_state cur;        /* under lock */
static bool have, active;               /* under lock: a first state came; the kernel says it is not off */
static id info[2];                      /* under lock: our STMutableTelephonySubscriptionInfo per slot */
static bool said_on, said_off, gave_up;
static int check_in;                    /* ticks until the read-back of the published domain */

static id (*o_subinfo)(id, SEL, long);
static bool (*o_simpresent)(id, SEL, long);
static bool (*o_capactive)(id, SEL);
static bool (*o_dual)(id, SEL);
static bool (*o_dead)(id, SEL);
static id (*o_dpinit)(id, SEL, id, id);

static id st_notinserted, st_ready, st_pin, st_puk, st_perm, st_notready;

static void
say(const char *fmt, ...)
{
	char line[300];
	va_list ap;
	FILE *f;

	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	syslog(LOG_NOTICE, "LAUREL CELLBAR: %s", line);
	if ((f = fopen(LOG, "a")) != NULL) {
		fprintf(f, "%ld LAUREL CELLBAR: %s\n", (long)time(NULL), line);
		fclose(f);
	}
	(void)sysctlbyname("kern.laurel_cell_ui", NULL, NULL, line, strlen(line));
}

static id
msg_id(id o, const char *s)
{
	return ((id (*)(id, SEL))objc_msgSend)(o, sel_registerName(s));
}

static id
nsstr(const char *s)
{
	return ((id (*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), s);
}

static void
set_id(id o, const char *s, id v)
{
	((void (*)(id, SEL, id))objc_msgSend)(o, sel_registerName(s), v);
}

static void
set_long(id o, const char *s, long v)
{
	((void (*)(id, SEL, long))objc_msgSend)(o, sel_registerName(s), v);
}

static void
set_bool(id o, const char *s, bool v)
{
	((void (*)(id, SEL, bool))objc_msgSend)(o, sel_registerName(s), v);
}

static id
sim_status(const char *k)
{
	if (strcmp(k, "ready") == 0) {
		return st_ready;
	}
	if (strcmp(k, "pin") == 0) {
		return st_pin;
	}
	if (strcmp(k, "puk") == 0) {
		return st_puk;
	}
	if (strcmp(k, "blocked") == 0 || strcmp(k, "illegal") == 0 || strcmp(k, "error") == 0 || strcmp(k, "noapp") == 0) {
		return st_perm;         /* the bar says the SIM is bad: true for each of these */
	}
	if (strcmp(k, "starting") == 0 || strcmp(k, "unknown") == 0) {
		return st_notready;
	}
	return st_notinserted;
}

static id
build_info(const struct cellbar_state *s, int i)
{
	const struct cellbar_sub *b = &s->sub[i];
	id o = ((id (*)(id, SEL))objc_msgSend)((id)c_info, sel_registerName("alloc"));
	char label[16];

	o = msg_id(o, "init");
	if (o == nil) {
		return nil;
	}
	snprintf(label, sizeof(label), "SIM %d", b->slot != 0 ? b->slot : i + 1);
	set_id(o, "setSIMLabel:", nsstr(label));
	snprintf(label, sizeof(label), "%d", b->slot != 0 ? b->slot : i + 1);
	set_id(o, "setShortSIMLabel:", nsstr(label));
	set_id(o, "setSIMStatus:", sim_status(b->sim));
	set_long(o, "setRegistrationStatus:", b->reg);
	set_long(o, "setCellularRegistrationStatus:", b->reg);
	set_long(o, "setSignalStrengthBars:", b->bars);
	set_long(o, "setMaxSignalStrengthBars:", MAX_BARS);
	set_long(o, "setDataConnectionType:", 0);           /* no data path yet: no LTE tag next to the bars */
	set_bool(o, "setProvidingDataConnection:", false);
	/* SIM 2 becomes the status bar's "primary" only when it alone is registered [V -[STTelephonyStatusDomainData primarySIMInfo]] */
	set_bool(o, "setPreferredForDataConnections:", i == 0 ? s->sub[1].reg != 2 || s->sub[0].reg == 2 : s->sub[0].reg != 2 && s->sub[1].reg == 2);
	set_id(o, "setOperatorName:", b->op[0] != 0 ? nsstr(b->op) : nil);
	return o;
}

/* ---------------------------------------------------------------- answers for STTelephonyStateProvider */

static id
h_subinfo(id self, SEL cmd, long slot)
{
	id r = nil;
	bool mine;

	pthread_mutex_lock(&lock);
	mine = active && (slot == 1 || slot == 2);
	if (mine) {
		r = objc_retain(info[slot - 1]);
	}
	pthread_mutex_unlock(&lock);
	return mine ? objc_autorelease(r) : o_subinfo(self, cmd, slot);
}

static bool
h_simpresent(id self, SEL cmd, long slot)
{
	bool mine, r = false;

	pthread_mutex_lock(&lock);
	mine = active && (slot == 1 || slot == 2);
	if (mine) {
		r = strcmp(cur.sub[slot - 1].sim, "absent") != 0;
	}
	pthread_mutex_unlock(&lock);
	return mine ? r : o_simpresent(self, cmd, slot);
}

static bool
h_capactive(id self, SEL cmd)
{
	bool mine;

	pthread_mutex_lock(&lock);
	mine = active;
	pthread_mutex_unlock(&lock);
	return mine ? true : o_capactive(self, cmd);
}

static bool
h_dual(id self, SEL cmd)
{
	bool mine, r = false;

	pthread_mutex_lock(&lock);
	mine = active;
	r = cur.sub[0].reg == 2 && cur.sub[1].reg == 2;     /* two rows of bars only for two real registrations */
	pthread_mutex_unlock(&lock);
	return mine ? r : o_dual(self, cmd);
}

static bool
h_dead(id self, SEL cmd)
{
	bool mine;

	pthread_mutex_lock(&lock);
	mine = active;
	pthread_mutex_unlock(&lock);
	return mine ? false : o_dead(self, cmd);
}

/* ---------------------------------------------------------------- the update */

static void
notify(void)
{
	SEL n = sel_registerName("subscriptionInfoDidChangeForStateProvider:slot:");

	((void (*)(id, SEL, id, long))objc_msgSend)(dp, n, sp, 1);
	((void (*)(id, SEL, id, long))objc_msgSend)(dp, n, sp, 2);
}

/* the domain holds what we set? The publisher runs on its own queue: read one tick later */
static void
readback(const struct cellbar_state *s)
{
	Ivar iv = class_getInstanceVariable(object_getClass(dp), "_telephonyDomainPublisher");
	id pub = iv != NULL ? object_getIvar(dp, iv) : nil;
	id data = pub != nil ? msg_id(pub, "data") : nil;
	id one = data != nil ? msg_id(data, "SIMOneInfo") : nil;
	long bars = one != nil ? ((long (*)(id, SEL))objc_msgSend)(one, sel_registerName("signalStrengthBars")) : -1;

	if (s->state == CB_OFF) {
		return;
	}
	if (one == nil || bars != s->sub[0].bars) {
		say("off: the telephony domain does not hold our state (SIM one bars %ld, wanted %d): Apple's answers stay", bars, s->sub[0].bars);
		pthread_mutex_lock(&lock);
		active = false;
		pthread_mutex_unlock(&lock);
		gave_up = true;
		notify();
		return;
	}
	if (!said_on) {
		bool (*mg)(id) = (bool (*)(id))dlsym(RTLD_DEFAULT, "MGGetBoolAnswer");

		said_on = true;
		say("on: domain follows the kernel: SIM one %s, reg %d, bars %d; MobileGestalt cellular-data %d, CellularTelephonyCapability %d (the Settings row needs the first)",
		    s->sub[0].sim, s->sub[0].reg, s->sub[0].bars, mg != NULL ? mg(nsstr("cellular-data")) : -1, mg != NULL ? mg(nsstr("CellularTelephonyCapability")) : -1);
	}
}

static void
tick(void *unused)
{
	char text[512] = "";
	size_t len = sizeof(text) - 1;
	struct cellbar_state s;
	void *pool;

	(void)unused;
	if (gave_up) {
		return;
	}
	if (sysctlbyname("kern.laurel_cell_state", text, &len, NULL, 0) != 0) {
		return;
	}
	cellbar_parse(text, &s);
	pool = objc_autoreleasePoolPush();
	pthread_mutex_lock(&lock);
	bool same = have && memcmp(&s, &cur, sizeof(s)) == 0;
	pthread_mutex_unlock(&lock);
	if (check_in > 0 && --check_in == 0 && same) {
		readback(&s);
	}
	if (!same && !gave_up) {
		id n0 = build_info(&s, 0), n1 = build_info(&s, 1), old0, old1;
		bool was;

		pthread_mutex_lock(&lock);
		was = active;
		memcpy(&cur, &s, sizeof(cur));
		have = true;
		active = s.state != CB_OFF && n0 != nil && n1 != nil;
		old0 = info[0];
		old1 = info[1];
		info[0] = n0;
		info[1] = n1;
		pthread_mutex_unlock(&lock);
		objc_release(old0);
		objc_release(old1);
		if (s.state == CB_OFF && (was || !said_off)) {
			said_off = true;
			say("off: the kernel's cellular client is off: Apple's answers stay");
		}
		notify();
		check_in = 1;
	}
	objc_autoreleasePoolPop(pool);
}

static id
h_dpinit(id self, SEL cmd, id handle, id provider)
{
	id r = o_dpinit(self, cmd, handle, provider);
	static dispatch_source_t timer;

	if (r != nil && dp == nil) {
		dp = objc_retain(r);
		sp = objc_retain(provider);
		timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
		dispatch_source_set_event_handler_f(timer, tick);
		dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), TICK_S * NSEC_PER_SEC, NSEC_PER_SEC / 2);
		dispatch_resume(timer);
	}
	return r;
}

/* ---------------------------------------------------------------- start */

/* SpringBoard's status bar aggregator makes the provider [V -[SBStatusBarStateAggregator telephonyDataProvider]]: if it did not, say so */
static void
no_provider(void *unused)
{
	(void)unused;
	if (dp == nil) {
		say("off: no STTelephonyStatusDomainDataProvider %d s after SpringBoard's start: the status bar stays Apple's", NO_PROVIDER_S);
	}
}

static const char *const need_info[] = { "setSIMLabel:", "setShortSIMLabel:", "setSIMStatus:", "setRegistrationStatus:", "setCellularRegistrationStatus:",
	"setSignalStrengthBars:", "setMaxSignalStrengthBars:", "setDataConnectionType:", "setProvidingDataConnection:", "setPreferredForDataConnections:",
	"setOperatorName:" };

static Method
need(Class c, const char *cn, const char *s)
{
	Method m = c != Nil ? class_getInstanceMethod(c, sel_registerName(s)) : NULL;

	if (m == NULL) {
		say("off: no -[%s %s]: Apple's answers stay", cn, s);
	}
	return m;
}

static id
ct_const(const char *name)
{
	id *p = (id *)dlsym(RTLD_DEFAULT, name);

	if (p == NULL || *p == nil) {
		say("off: no CoreTelephony %s: Apple's answers stay", name);
		return nil;
	}
	return *p;
}

__attribute__((constructor))
static void
laurel_cellbar_init(void)
{
	char text[512] = "";
	size_t len = sizeof(text) - 1;
	Class csp, cdp;
	Method m[6];

	unsetenv("DYLD_INSERT_LIBRARIES");      /* not for SpringBoard's children */
	if (strcmp(getprogname(), "SpringBoard") != 0) {
		return;
	}
	if (sysctlbyname("kern.laurel_cell_state", text, &len, NULL, 0) != 0) {
		say("off: this kernel has no kern.laurel_cell_state (patch 2786): Apple's answers stay");
		return;
	}
	c_info = objc_getClass("STMutableTelephonySubscriptionInfo");
	csp = objc_getClass("STTelephonyStateProvider");
	cdp = objc_getClass("STTelephonyStatusDomainDataProvider");
	for (size_t i = 0; i < sizeof(need_info) / sizeof(need_info[0]); i++) {
		if (need(c_info, "STMutableTelephonySubscriptionInfo", need_info[i]) == NULL) {
			return;
		}
	}
	m[0] = need(csp, "STTelephonyStateProvider", "subscriptionInfoForSlot:");
	m[1] = need(csp, "STTelephonyStateProvider", "isSIMPresentForSlot:");
	m[2] = need(csp, "STTelephonyStateProvider", "isCellularRadioCapabilityActive");
	m[3] = need(csp, "STTelephonyStateProvider", "isDualSIMEnabled");
	m[4] = need(csp, "STTelephonyStateProvider", "isRadioModuleDead");
	m[5] = need(cdp, "STTelephonyStatusDomainDataProvider", "initWithServerHandle:stateProvider:");
	if (need(cdp, "STTelephonyStatusDomainDataProvider", "subscriptionInfoDidChangeForStateProvider:slot:") == NULL ||
	    m[0] == NULL || m[1] == NULL || m[2] == NULL || m[3] == NULL || m[4] == NULL || m[5] == NULL) {
		return;
	}
	if ((st_notinserted = ct_const("kCTSIMSupportSIMStatusNotInserted")) == nil || (st_ready = ct_const("kCTSIMSupportSIMStatusReady")) == nil ||
	    (st_pin = ct_const("kCTSIMSupportSIMStatusPINLocked")) == nil || (st_puk = ct_const("kCTSIMSupportSIMStatusPUKLocked")) == nil ||
	    (st_perm = ct_const("kCTSIMSupportSIMStatusPermanentlyLocked")) == nil || (st_notready = ct_const("kCTSIMSupportSIMStatusNotReady")) == nil) {
		return;
	}
	o_subinfo = (id (*)(id, SEL, long))method_setImplementation(m[0], (IMP)h_subinfo);
	o_simpresent = (bool (*)(id, SEL, long))method_setImplementation(m[1], (IMP)h_simpresent);
	o_capactive = (bool (*)(id, SEL))method_setImplementation(m[2], (IMP)h_capactive);
	o_dual = (bool (*)(id, SEL))method_setImplementation(m[3], (IMP)h_dual);
	o_dead = (bool (*)(id, SEL))method_setImplementation(m[4], (IMP)h_dead);
	o_dpinit = (id (*)(id, SEL, id, id))method_setImplementation(m[5], (IMP)h_dpinit);
	say("hooks in: waiting for SpringBoard's telephony domain");
	dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, NO_PROVIDER_S * NSEC_PER_SEC), dispatch_get_main_queue(), NULL, no_provider);
}
