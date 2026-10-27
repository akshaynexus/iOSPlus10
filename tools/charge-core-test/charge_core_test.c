/* Host test of bsd/dev/negroni_charge_core.h (patch 0377). Run: scripts/kernel/test-charge-core.sh */
#include <stdio.h>
#include <stdlib.h>
#include "negroni_charge_core.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static struct nc_inputs
cable(void)
{
	struct nc_inputs in = { .pon_decoded = 1, .pon = NC_PON_USB_CHARGER_A, .type_before = 0x04 /* SHUTDOWN */,
		.reset_after = 0, .abl_charger = 0, .key = 0, .vbus = 1, .force = 0 };
	return in;
}

int
main(void)
{
	struct nc_inputs in;

	/* decisions */
	in = cable(); CHECK(nc_decide(&in) == NC_YES_CABLE);
	in = cable(); in.pon = NC_PON_USB_CHARGER_B; CHECK(nc_decide(&in) == NC_YES_CABLE);
	in = cable(); in.type_before = -1; CHECK(nc_decide(&in) == NC_YES_CABLE);         /* first power-on ever */
	in = cable(); in.pon = 0x0087; CHECK(nc_decide(&in) == NC_NO_TRIGGER);            /* KPDPWR_N */
	in = cable(); in.pon = 0x0085; CHECK(nc_decide(&in) == NC_NO_TRIGGER);            /* HARD_RESET */
	in = cable(); in.pon = -1; CHECK(nc_decide(&in) == NC_NO_TRIGGER);
	in = cable(); in.pon_decoded = 0; CHECK(nc_decide(&in) == NC_NO_PON_UNKNOWN);
	in = cable(); in.reset_after = 1; CHECK(nc_decide(&in) == NC_NO_RESET_AFTER);     /* warm reset, old trigger */
	in = cable(); in.type_before = 0x07; CHECK(nc_decide(&in) == NC_NO_RESET_BEFORE);
	in = cable(); in.type_before = 0x01; CHECK(nc_decide(&in) == NC_NO_RESET_BEFORE);
	in = cable(); in.key = 1; CHECK(nc_decide(&in) == NC_NO_KEY);
	in = cable(); in.key = -1; CHECK(nc_decide(&in) == NC_YES_CABLE);                 /* key unknown: not held */
	in = cable(); in.vbus = 0; CHECK(nc_decide(&in) == NC_NO_VBUS);
	in = cable(); in.vbus = -1; CHECK(nc_decide(&in) == NC_NO_VBUS_UNKNOWN);
	in = cable(); in.pon_decoded = 0; in.abl_charger = 1; CHECK(nc_decide(&in) == NC_YES_CABLE);
	in = cable(); in.pon = 0x0087; in.abl_charger = 1; CHECK(nc_decide(&in) == NC_YES_CABLE);
	in = cable(); in.pon = 0x0085; in.reset_after = 1; in.vbus = 0; in.key = 1; in.force = 1;
	CHECK(nc_decide(&in) == NC_YES_FORCED);
	CHECK(nc_enters(NC_YES_CABLE) && nc_enters(NC_YES_FORCED) && !nc_enters(NC_NO_VBUS));
	for (int r = NC_YES_CABLE; r <= NC_NO_VBUS_UNKNOWN; r++) {
		CHECK(nc_reason_text((enum nc_reason)r)[0] != '?');
	}

	/* the mode: screen timer */
	struct nc_state s;
	uint64_t t = 1000;
	nc_init(&s, t);
	CHECK(nc_step(&s, t + 9950, 0, 1) == NC_NONE);
	CHECK(nc_step(&s, t + 10000, 0, 1) == NC_SCREEN_OFF);
	CHECK(!s.screen_on);
	CHECK(nc_step(&s, t + 20000, 0, 1) == NC_NONE);
	/* short press: screen on at release, timer again from there */
	CHECK(nc_step(&s, t + 30000, 1, 1) == NC_NONE);
	CHECK(nc_step(&s, t + 30300, 0, 1) == NC_SCREEN_ON);
	CHECK(s.screen_on);
	CHECK(nc_step(&s, t + 40250, 0, 1) == NC_NONE);
	CHECK(nc_step(&s, t + 40300, 0, 1) == NC_SCREEN_OFF);
	/* long press: one reboot request at 2 s, none at release, none again while held */
	CHECK(nc_step(&s, t + 50000, 1, 1) == NC_NONE);
	CHECK(nc_step(&s, t + 51950, 1, 1) == NC_NONE);
	CHECK(nc_step(&s, t + 52000, 1, 1) == NC_REBOOT);
	CHECK(nc_step(&s, t + 53000, 1, 1) == NC_NONE);
	CHECK(nc_step(&s, t + 53050, 0, 1) == NC_NONE);
	CHECK(!s.screen_on);
	/* key unknown does not end a press */
	CHECK(nc_step(&s, t + 60000, 1, 1) == NC_NONE);
	CHECK(nc_step(&s, t + 61000, -1, 1) == NC_NONE);
	CHECK(nc_step(&s, t + 62000, 1, 1) == NC_REBOOT);
	CHECK(nc_step(&s, t + 62100, 0, 1) == NC_NONE);
	/* the screen does not go off while the key is held */
	nc_init(&s, t);
	CHECK(nc_step(&s, t + 9000, 1, 1) == NC_NONE);
	CHECK(nc_step(&s, t + 10500, 1, 1) == NC_NONE);
	CHECK(nc_step(&s, t + 10600, 0, 1) == NC_SCREEN_ON);
	/* unplug: 3 s of VBUS 0 in one stretch; a VBUS 1 or unknown sample restarts it */
	nc_init(&s, t);
	CHECK(nc_step(&s, t + 100, 0, 0) == NC_NONE);
	CHECK(nc_step(&s, t + 2000, 0, 0) == NC_NONE);
	CHECK(nc_step(&s, t + 2100, 0, 1) == NC_NONE);
	CHECK(nc_step(&s, t + 2200, 0, 0) == NC_NONE);
	CHECK(nc_step(&s, t + 4000, 0, -1) == NC_NONE);
	CHECK(nc_step(&s, t + 34000, 0, 0) == NC_SCREEN_OFF);   /* review F4: no instant power off after a gap */
	CHECK(nc_step(&s, t + 36950, 0, 0) == NC_NONE);
	CHECK(nc_step(&s, t + 37000, 0, 0) == NC_POWEROFF);
	/* power off wins over a long press at the same tick */
	nc_init(&s, t);
	CHECK(nc_step(&s, t, 1, 0) == NC_NONE);
	CHECK(nc_step(&s, t + 3000, 1, 0) == NC_POWEROFF);
	/* a time of 0 still starts the unplug stretch */
	nc_init(&s, 0);
	CHECK(nc_step(&s, 0, 0, 0) == NC_NONE);
	CHECK(s.unplug_since != 0);

	printf("%s (%d failures)\n", fails ? "FAILED" : "charge core: all checks passed", fails);
	return fails ? 1 : 0;
}
