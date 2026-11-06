/*
 * laurel 3030: host test of the PMIC watchdog rules (laurel_pmic_wdog_core.h, taken from the patch by scripts/laurel/pmic-wdog-test.sh). PASS = exit 0.
 */
#include <stdio.h>
#include <stdlib.h>
#include "laurel_pmic_wdog_core.h"

static int failures, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(void)
{
	/* registers: the PON of the PM6125 at 0x800, the watchdog block 0x54-0x58 [V pm8916_wdt.c] */
	CHECK(LPW_S1_TIMER == 0x854 && LPW_S2_TIMER == 0x855 && LPW_S2_CTL == 0x856 && LPW_S2_CTL2 == 0x857 && LPW_PET == 0x858, "register map");
	CHECK(LPW_TYPE_HARD == 7 && LPW_EN == 0x80 && LPW_PET_BIT == 1, "bits");
	/* times: the boot loader's count must reach the kernel's pet thread; the kernel's must outlast the timed panic reset (laurelpanic=30, uefi-image.sh) and the
	 * APSS bark + its 20 s hold reset (2990); both fit the 7-bit timers */
	CHECK(LPW_S1_BOOT_S <= LPW_TIMER_MAX && LPW_S1_KERNEL_S <= LPW_TIMER_MAX && LPW_S2_S <= LPW_TIMER_MAX, "timers fit 7 bits");
	CHECK(LPW_S1_BOOT_S > LPW_S1_KERNEL_S, "the boot count is the longer one");
	CHECK(LPW_S1_KERNEL_S > 30 + 20, "the kernel count outlasts laurelpanic=30 and the 20 s hold reset of a bark");
	CHECK(lpw_timer(300) == LPW_TIMER_MAX && lpw_timer(60) == 60 && lpw_timer(0) == 0, "timer clamp");
	/* pets: the first at once, then one per second, whatever the caller's rate */
	CHECK(lpw_pet_due(5, 0), "first pet at once");
	CHECK(!lpw_pet_due(1500, 1000), "500 ms after a pet: none");
	CHECK(lpw_pet_due(2000, 1000), "1000 ms after a pet: one");
	{
		unsigned long long now, last = 0; unsigned pets = 0;
		for (now = 1; now <= 60000; now += 7) {            /* a 7 ms loop for 60 s */
			if (lpw_pet_due(now, last)) { pets++; last = now; }
		}
		CHECK(pets >= 59 && pets <= 61, "60 s of a fast loop: %u pets", pets);
	}
	/* what a boot finds */
	CHECK(lpw_found_state(0x00, 0x07) == 0, "enable off: off");
	CHECK(lpw_found_state(0x80, 0x07) == 1, "armed, hard: ours");
	CHECK(lpw_found_state(0x80, 0x01) == 2, "armed, warm: another");
	CHECK(lpw_armed_as(60, 2, 0x07, 0x80, 60, 2), "armed as asked");
	CHECK(lpw_armed_as(0xbc, 0x82, 0x17, 0x80, 60, 2), "upper bits of the registers do not count");
	CHECK(!lpw_armed_as(100, 2, 0x07, 0x80, 60, 2), "S1 differs");
	CHECK(!lpw_armed_as(60, 2, 0x01, 0x80, 60, 2), "type differs");
	CHECK(!lpw_armed_as(60, 2, 0x07, 0x00, 60, 2), "not enabled");
	printf("pmic-wdog rules: %d checks, %d failures\n", checks, failures);
	return failures ? 1 : 0;
}
