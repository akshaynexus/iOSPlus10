/*
 * Which Metal stack a process of the iOS 26 root takes: the rule of NegroniMetal.bundle's selector (option_select.m), plain C, tested on the host (scripts/laurel/option-rule-test.sh).
 * The compositor is the risk. A bad or missing setting is the default. In backboardd, a start that does not report a lit screen before the next start counts as failed; NMTL_OPTION_FAILS of them, or a failure the
 * running stack reported, return it to the default until the setting is written again (XNUtils clears the state with the setting).
 */
#ifndef NMTL_OPTION_RULE_H
#define NMTL_OPTION_RULE_H
#include <stdio.h>
#include <string.h>

#define NMTL_OPTION_DEFAULT "default"
#define NMTL_OPTION_FAILS   2

struct nmtl_option_state {
	char option[16];        /* the option these counts belong to */
	int fails, pending;     /* pending: a start of it has not reported a lit screen yet */
};

static inline void nmtl_option_state_read(const char *text, struct nmtl_option_state *s)
{
	memset(s, 0, sizeof(*s));
	if (text == NULL || sscanf(text, "%15s %d %d", s->option, &s->fails, &s->pending) != 3)
		memset(s, 0, sizeof(*s));
}

/*
 * wanted: first word of the setting, or NULL. known(name): the option's file is in the bundle. ok: the last start reported a lit screen. failed: the last start reported a failure.
 * compositor: this process is backboardd; only it counts. Returns the option to take; why gets a reason when the result is not what was wanted. s is updated: write it back.
 */
static inline const char *nmtl_option_choose(const char *wanted, int (*known)(const char *), struct nmtl_option_state *s, int ok, int failed, int compositor, char *why, size_t size)
{
	why[0] = 0;
	if (wanted == NULL || wanted[0] == 0)
		return NMTL_OPTION_DEFAULT;
	if (strcmp(wanted, NMTL_OPTION_DEFAULT) == 0) {
		memset(s, 0, sizeof(*s));
		return NMTL_OPTION_DEFAULT;
	}
	if (!known(wanted)) {
		snprintf(why, size, "option %.32s is not in this bundle", wanted);
		return NMTL_OPTION_DEFAULT;
	}
	if (strcmp(s->option, wanted) != 0) {
		memset(s, 0, sizeof(*s));
		snprintf(s->option, sizeof(s->option), "%s", wanted);
	}
	if (compositor) {
		if (ok) {
			s->fails = 0;
			s->pending = 0;
		} else if (failed) {
			s->fails = NMTL_OPTION_FAILS;
		} else if (s->pending && s->fails < NMTL_OPTION_FAILS) {
			s->fails++;
		}
	}
	if (s->fails >= NMTL_OPTION_FAILS) {
		snprintf(why, size, "option %s failed in %d starts of the compositor", wanted, s->fails);
		return NMTL_OPTION_DEFAULT;
	}
	if (compositor)
		s->pending = 1;
	return wanted;
}
#endif
