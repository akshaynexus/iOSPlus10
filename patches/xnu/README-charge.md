# Charge-only mode after a cable power-on (0377)

`0377-negroni-charge-mode.patch`. Boot-arg `negronicharge` (default 0 = dry run: log only).

## Problem

The phone is off. The owner connects the USB cable. The PMIC powers the phone on (PON trigger
`USB_CHARGER`). Android: ABL sees this trigger and boots with `androidboot.mode=charger`, and the
off-mode charging screen runs. Our chain (ABL -> boot_a UEFI shim -> DarwinBoot -> XNU) boots iOS.

## Findings

- [V] The shim does not give ABL's command line to XNU.
  `NegroniBootMemoryDxe.c` reads ABL's device tree (x0) for `/memory`, `/reserved-memory` and the
  initrd in `/chosen` only. `NegroniXnuBoot.c` copies `CmdLine` from `payload.bin` (made on the Mac by
  `scripts/ios16/build.sh`) into `boot_args`. `/chosen/bootargs` (`out/live.dts`:
  `oplusboot.mode=reboot ...`) does not reach XNU. A change there is a Mu-Silicium change (external),
  not a kernel change.
- [V] The kernel reads the PMIC PON log (SDAM 0x7400, 0214). The log has the last PON trigger
  (`USB_CHARGER` = 0x31c2 or 0x8732 in downstream `pmic-pon-log.c`) and the reset entries before it.
- [V] Boot logs 10 and 13 show `NEGRONI PON LOG: FIFO read failed at +0x4b` / `+0x9c`. The offsets
  change from boot to boot. Boot log 3 decoded the whole log.
- [I] Cause of the failed reads: another reader uses the same EE 0 observer channel of APID 60 at the
  same time. The line before is the NegroniBattery census, which reads every APID. A collision can
  also give a wrong byte with no error.
- [V] The power key is PMK8350 PON 0x1300 RT_STS bit 7 (`negroni_keys.c`, a 20 ms poll thread).
- [V] VBUS: the PM8350B USBIN block has no APID for EE 0 (0272/0273). NegroniBattery measures VBUS
  through the PMK8350 VADC (`negronibatt=4/5`, plug tick every 1 s). Without the VADC, only a charge
  current >= 50 mA tells "cable present". Nothing tells "cable absent".
- [I] Charging with no HLOS: without the ADSP charger PD, the PM8350B charges on its XBL/hardware
  defaults (~1 A input limit, README-battery.md section 9). With `negroniadsp=1 negronichg_glink=1`,
  the PD and our GLINK client are kernel threads and keep running. 0377 writes no charger register.

## What 0377 changes

| File | Change |
| --- | --- |
| `bsd/dev/negroni_charge.c` (new) | the decision and the mode |
| `bsd/dev/negroni_charge_core.h` (new) | pure decision + state machine, host-tested |
| `bsd/kern/kern_exec.c` | `negroni_charge_check()` at the start of `load_init_program()` (before launchd) |
| `bsd/dev/negroni_reboot.c` | PON log read: up to 4 tries per byte, header + FIFO read until two passes agree (max 4); exports the last trigger, the reset type before it, and "reset after it"; `negroni_reboot_hard_type()`; summary gets `after=` |
| `bsd/dev/negroni_keys.c` | `negroni_keys_power()`: the key thread's last power key reading |
| `iokit/Kernel/arm/NegroniBattery.cpp` | gives percent, VBUS, charging to the mode (publish + plug tick) |
| `bsd/conf/files` | the new file |

### Decision (once per boot, before launchd)

Enter the mode only when all are true:

1. Last PON trigger is `USB_CHARGER` (0x31c2 / 0x8732), or the boot-args contain
   `androidboot.mode=charger` (only if a future shim passes ABL's mode).
2. No reset entry (RESET_TRIGGER / RESET_TYPE) after that trigger. A warm reset does not log a new
   trigger, so the old `USB_CHARGER` trigger stays the last one. This rule catches it.
3. The reset type before the trigger is not WARM_RESET / HARD_RESET / DVDD_HARD_RESET.
4. The power key is not pressed (unknown counts as not pressed).
5. VBUS is present (waits up to 15 s for the first battery reading). Unknown = boot iOS.

PON log not decoded = boot iOS. `negronicharge_force=1` skips 1-5 and enters.

### The mode

- launchd is not started. The init thread stays in the kernel. The other kernel threads run:
  USB gadget and command server (`op10tool ctl reboot|bootloader|poweroff` work), NegroniBattery,
  ADSP/GLINK when on.
- `negroni_console_muted = 1`: no console text on the screen. The log ring, USB log and boot log keep
  every line.
- Screen: the boot framebuffer (`PE_current_console`, mapped write-combined). Black, a battery
  outline, a fill (green while charging, red at <= 15 %, grey when the percent is not known), the
  percent in large digits, "Charging" / "Connected" / "Not connected", "Hold power 2 s to start iOS".
  Drawn again on each change and every 30 s.
- 10 s without a press: black pixels + `negroni_backlight_display_off(0)`.
- Short power key press: `negroni_backlight_display_on()` (only when off), draw, 10 s again.
- Key held >= 2 s: PS_HOLD type HARD_RESET, boot log end mark, reason 0, PSCI reset. The PMIC then
  logs PON trigger HARD_RESET, so the next boot boots iOS.
- No VBUS for 3 s (one stretch of VADC readings that say "no VBUS"; a "present" or "not known"
  reading starts the stretch again): boot log end mark, `negroni_power_off()` (0214). If it returns:
  reboot into iOS as above. If that also returns: try again after 5 s.
- VBUS source (review F1/F2): "absent" counts only when this reading came from the VADC USBIN value
  (a failed conversion is "not known"). The charger PD's `usb_online` and the battery current count
  only as "present". The driver's static placeholder (100 %, external) gives no percent and no plug
  state. A reading older than 30 s is "not known".
- Each tick is 50 ms. Every step is bounded. The loop ends only with a reset or a power off.

## Boot-args

| Arg | Default | Meaning |
| --- | --- | --- |
| `negronicharge=0` | yes | dry run: log the decision, boot iOS always |
| `negronicharge=1` | | act on the decision |
| `negronicharge_force=1` | | enter the mode on every boot (test only; acts also without `negronicharge=1`) |

Needs `negronibatt=4` or `5` for the unplug power off (the image default is 5).

## Log lines

```
NEGRONI PON LOG: read needed N retries and M passes                (only when not clean)
NEGRONI PON LOG: summary: pon=USB_CHARGER type=SHUTDOWN ...        (after=... when a reset follows the trigger)
NEGRONI CHARGE: negronicharge=1 force=0; PON log decoded: trigger 0x31c2, reset type before 4, reset after 0 (summary: ...); ABL mode not passed (...)
NEGRONI CHARGE: decision: boot iOS (the power-on trigger is not the charger)
NEGRONI CHARGE: key 0, vbus 1 (5012 mV), battery 57% charging 1
NEGRONI CHARGE: dry run (negronicharge=0): would ENTER the charge-only mode (...); iOS boots
NEGRONI CHARGE: decision: charge-only mode (cable power-on ...)
NEGRONI CHARGE: mode on: launchd not started; ...
NEGRONI CHARGE: framebuffer 1080x2412 (row 1080 px) at 0x...
NEGRONI CHARGE: 10 s without a press: screen off
NEGRONI CHARGE: short press: screen on
NEGRONI CHARGE: power key held 2000 ms
NEGRONI CHARGE: reboot into iOS (charge mode: power key held 2 s)
NEGRONI CHARGE: power off (no VBUS for 3000 ms)
NEGRONI CHARGE: status: 57% vbus 1 (5012 mV) charging 1 key 0 screen off      (every 60 s)
```

Failure lines: `no boot framebuffer ...: no screen`, `framebuffer map failed`, `no backlight service:
screen off = black pixels only`, `PS_HOLD type HARD_RESET not set: the next boot may enter the mode
again`, `reset failed (PSCI returned)`, `power off failed: rebooting into iOS instead`.

## Test (owner; RAM boot first)

A `fastboot boot` cannot be a cable power-on. So:

1. Dry run on the normal image (no behavior change): every boot logs `NEGRONI CHARGE: ...dry run...`.
   Expected on a RAM boot: `trigger 0x0085` (HARD_RESET) or a reset, `would boot iOS`.
2. Mode test with `BOOTARGS_ADD="negronicharge_force=1"` on a test image, `fastboot boot`:
   - expect `decision: charge-only mode (forced ...)`, the battery screen, no launchd lines;
   - after 10 s the screen goes off; a short press turns it on;
   - `op10tool ctl reboot` works (USB stays up);
   - hold power 2 s: the phone resets into boot_a (normal iOS, no force arg there);
   - or unplug for 3 s: the phone powers off. Power key starts it again (boot_a).
3. Real cable power-on (after 2 passes): flash `negronicharge=1` on boot_a (owner's go). Power off
   from iOS. Connect the cable. Expect the battery screen. Read the PON trigger code in the boot log
   (`trigger 0x....`). If it is not 0x31c2 / 0x8732, the dry run tells it: add the code to
   `negroni_charge_core.h`.

Host test of the decision and the state machine: `scripts/kernel/test-charge-core.sh` (takes the
header from the patch).

## Build

- [V] out/kernel/local-20261027-090703/kernel.development.negroni sha256 dceee47df05df4671ad5619d053e19f707bc6ba12d6a87d64b494dd8c2201a28 (277 applied, only the 4 usual dxb skips; 0377 applied; only the usual declaration-after-statement warnings). Not booted.

## Review (Opus, 2026-10-27): ACCEPT WITH FIXES

- F1 fixed: "measured" only when this full read's VADC USBIN reading worked (`fVbusMeasured`); the PD
  path sends a guess. Plug state is one word (`nc_plug`), so no torn pair.
- F2 fixed: the static placeholder sends no plug state and no percent.
- F3 not taken: the reviewer said the mode blocks the bootstrap thread. [V] It does not:
  `load_init_program()` is called from `bsdinit_task()` (bsd_init.c), which `bsd_ast()` runs on the
  init thread (kern_sig.c, `bsd_init_done`). `kernel_bootstrap_thread` goes on to `vm_pageout()`.
- F4 fixed: "not known" also restarts the unplug stretch (host test case added).
- F5 fixed: a non-32-bit framebuffer depth gives no screen.
- F6 (shared read buffer in the PON reread) left: the boot read and the reread do not overlap.

## Re-review (Opus, 2026-10-27): ACCEPT after 1 fix

- R1 fixed: the framebuffer map used `ml_io_map_wcomb`. Its VA comes from io_submap (8 MiB, KMA_NOFAIL);
  1080x2412x4 = 10.4 MB, so entering the mode would panic. Now `ml_io_map_unmappable(pa, size, 0x6)`
  (VM_WIMG_WCOMB, kernel_map VA), as `video_console.c` maps the same buffer. compile-one OK. The build above
  is older than this fix.
- F3: the author is right (init thread in `bsd_ast`; bootstrap thread goes on to `vm_pageout`; USB, bootlog,
  battery, keys, ADSP are kernel threads; IOWatchdog never fires). F6: no effect (the boot read finishes in
  `NegroniPlatformExpert::start`, before the root mount; the reread runs once, in the init thread).

## Not known / guesses

- [U] The PON trigger code of a cable power-on on this phone (0x31c2 and 0x8732 come from downstream).
- [U] Whether a warm reset logs no new trigger (rule 2 handles both cases).
- [I] The 0214 read failures came from a shared observer channel (retry + two-pass compare in any case).
- [I] The PMIC S2 reset on a long power key press (seconds, set by the bootloader) comes later than
  our 2 s. Not measured.
- [U] Charge speed with no HLOS: XBL defaults without the ADSP; untested in this mode.
