# Parked kernel patches (not applied)

`scripts/laurel/kernel-linux.sh` applies `patches/laurel/xnu/*.patch` only. These came with branch `t3/laurel-kernel-infra-ports`
(built on an older base, never booted) and do not apply on `laurel-sprout` of 2026-11-01. Review: `docs/laurel_sprout/system-features.md` section 4.

| Patch | What | Why parked |
| --- | --- | --- |
| 2900 console head, live log from byte 0, boot log area | debug channel | 2 hunks in `sweet_usb.c`, 1 in `SweetPlatformExpert.cpp` conflict; it changes console, panic and UFS write paths. Refresh it and boot it alone, not with a feature boot |
| 2901 RTC calendar + settime | same job as 2720 | superseded: 2720 has `laurel_rtc.c`, `settime` and `time`. Only its offset file `/private/var/db/laurel_rtc` idea may be worth a look |
| 2907 SPMI init mutex + PON spinlock | review fix for 2900's users | written against the SPMI code before 2710 (one lock); all hunks conflict. Check it again with 2900 |
