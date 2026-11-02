/*
 * liblaurel-ringer.dylib (iOS 26 root only): no mute switch on the Mi A3, so SpringBoard must not take the ring state as muted. Inserted into SpringBoard by laurel-springboard (sb_wrap.c) when it is on the root.
 * Why: IOS-26-Hot (MIT, self-reported, phone/media/inject_sysfix.c, commit 504d74c "SpringBoard ringer fix") needs -[SBRingerControl isRingerMuted] = NO and com.apple.springboard.ringerstate = 1 on 23F84
 * for system sounds. N104AP has the switch in its identity, and this kernel publishes no switch event [I]. The class and the method are in the 23F84 cache [V: docs/laurel_sprout/ios26-parity.md "Audio"].
 * Not here: Hot's second hook, -[BKButtonHIDEventProcessor ringerState] in backboardd. iOS 26 runs Apple's backboardd with no wrapper (root-add-metal-ios26.sh). If the first boot shows muted sounds with this line "on": read the
 * state with `notifyutil -g com.apple.springboard.ringerstate` first.
 * Self-check at the start (one line "LAUREL RINGER: on|off: ..."): the process is SpringBoard; the class has the method; its return type is a BOOL. Anything else: Apple's answers stay.
 * Kill switch: boot-arg ringer=0 (sb_wrap.c does not insert this file). A failure turns off only this feature.
 */
#include <notify.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include <objc/message.h>
#include <objc/runtime.h>

#define LOG     "/var/tmp/laurel-notch.log"
#define STATE   "com.apple.springboard.ringerstate"

static void
say(const char *fmt, ...)
{
	char line[256];
	va_list ap;
	FILE *f;

	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	syslog(LOG_NOTICE, "LAUREL RINGER: %s", line);
	if ((f = fopen(LOG, "a")) != NULL) {
		fprintf(f, "%ld LAUREL RINGER: %s\n", (long)time(NULL), line);
		fclose(f);
	}
}

static BOOL
not_muted(id self, SEL cmd)
{
	(void)self;
	(void)cmd;
	return NO;
}

/* SpringBoard's own state can come up after the constructor: twice, as Hot found on a phone */
static void *
state_thread(void *arg)
{
	int token = -1;

	(void)arg;
	sleep(2);
	if (notify_register_check(STATE, &token) != NOTIFY_STATUS_OK) {
		say("off: %s: no token: the hook stays", STATE);
		return NULL;
	}
	notify_set_state(token, 1);
	notify_post(STATE);
	sleep(8);
	notify_set_state(token, 1);
	notify_post(STATE);
	return NULL;
}

__attribute__((constructor))
static void
laurel_ringer_init(void)
{
	Class c;
	Method m;
	const char *enc;
	pthread_t t;

	if (strcmp(getprogname(), "SpringBoard") != 0) {
		return;
	}
	c = objc_getClass("SBRingerControl");
	m = c != Nil ? class_getInstanceMethod(c, sel_registerName("isRingerMuted")) : NULL;
	if (m == NULL) {
		say("off: no -[SBRingerControl isRingerMuted]: Apple's answer stays");
		return;
	}
	enc = method_getTypeEncoding(m);
	if (enc == NULL || (enc[0] != 'B' && enc[0] != 'c')) {
		say("off: -[SBRingerControl isRingerMuted] has type %s, not a BOOL: Apple's answer stays", enc != NULL ? enc : "(none)");
		return;
	}
	(void)method_setImplementation(m, (IMP)not_muted);
	if (pthread_create(&t, NULL, state_thread, NULL) == 0) {
		pthread_detach(t);
	}
	say("on: -[SBRingerControl isRingerMuted] = NO, %s = 1", STATE);
}
