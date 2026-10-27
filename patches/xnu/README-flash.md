# Flashlight (torch): patch 0387 `0387-negroni-flash-torch.patch`

Status (2026-10-27): kernel code done, full kernel compile clean. Not tested on the phone. Not reviewed yet.
A copy stays in `out/hold/flash/` (git-ignored) with the build script and the test kernel.

## Files

| File | Change |
|------|--------|
| `bsd/dev/negroni_flash.c` | new: torch driver, `/dev/negroniflash`, fault watch, auto-off, quiesce |
| `bsd/dev/negroni_spmi.c`, `.h` | read allowlist SID 2 peripheral 0xee; write allowlist 10 flash registers; `negroni_spmi_flash_unlock()`, `negroni_spmi_flash_off_nolock()` |
| `bsd/dev/negroni_ufs.c` | `negroni_flash_init()` after `negroni_cam_init()` |
| `bsd/conf/files` | `bsd/dev/negroni_flash.c standard` |
| `iokit/Kernel/arm/NegroniPlatformExpert.cpp` | `negroni_flash_quiesce()` at kPEPanicBegin, kPEHaltCPU, kPERestartCPU |

## Hardware [V]

Source: `out/live.dts:12933-13052` (flash module), `:37143-37170` (camera flash nodes).

- PM8350C, SPMI bus 0, SID 2, peripheral 0xee (`qcom,flash_led@ee00`, `qcom,pm8350c-flash-led`).
  Interrupts: led-fault (0xee, 0), all-ramp-down (0xee, 3), all-ramp-up (0xee, 4).
- 4 channels. The rear camera (`qcom,camera-flash@0/1/2`) uses `torch-source = torch_0, torch_1`,
  `flash-source = flash_0, flash_1`, `switch-source = led_switch_2` (mask 0x0f, `qcom,symmetry-en`).
  So the LED is on channels 0 and 1. The driver drives both with the same current.
- torch_N: `qcom,max-current-ma = 500`, `qcom,ires-ua = 5000`. flash_N: 1500 mA, `ires-ua = 12500`,
  `duration-ms = 1280`. `qcom,thermal-derate-current = <200 500>`. HW strobe GPIO: PM8350C GPIO 1 (not used).

## Register sequence [V source, I on this phone]

Source: Linux `drivers/leds/flash/leds-qcom-flash.c` (mainline master, `mvflash_4ch_regs`,
`qcom_flash_led_brightness_set`, `set_flash_current`, `set_flash_timeout`, `set_flash_strobe`).
The HakiOS POCO X5 Pro driver (`hakios.torch.c`, same PM8350C module) uses the same registers.

| Reg | Name | Torch on | Off |
|-----|------|----------|-----|
| 0x4e | CHAN_EN (bit per channel) | first 0, last bits 0,1 = 1 | bits 0,1 = 0 |
| 0x46 | MODULE_EN bit 7 | 0, then 1 | 0 |
| 0x42/0x43 | ITARGET ch0/ch1 bits 6:0 | mA / 5 - 1 | 0 |
| 0x49 | IRESOLUTION (bit per channel) | bits 0,1 = 1 (5 mA steps = torch) | kept |
| 0x3e/0x3f | CHAN_TIMER ch0/ch1 | 0 (safety timer off, torch only) | kept |
| 0x4a/0x4b | CHAN_STROBE ch0/ch1 bits 6:0 | 0x01 (SW strobe, level, active high) | kept |
| 0xed | TORCH_CLAMP bits 6:0 | cap code, once (a mismatch is only logged) | kept |

Read only: 0x04 TYPE (0x18), 0x05 SUBTYPE (0x07 = 4 channels), 0x00 REVISION1, 0x06 STATUS1 (short: bit 2*chan),
0x07 STATUS2 (0x01 VPH low, 0x02 BCL, 0x0c BoB ILIM, 0x10 OTST2, 0x20 OTST1, 0x40 BoB thermal), 0x10 INT_RT_STS
(bit 0 fault).

Order of one level change (as mainline): CHAN_EN off, MODULE_EN off, ITARGET x2, IRESOLUTION, CHAN_TIMER x2,
MODULE_EN on, CHAN_STROBE x2, CHAN_EN on. Each write goes through `negroni_spmi_write` (3 tries) and is read back.
A refused write or a wrong read-back stops all writes for the boot.

## Safety limits

- Torch only. IRESOLUTION 5 mA and timer 0 are always written together. ITARGET is at most `FL_CAP_MA / 5 - 1`.
  No flash-mode (12.5 mA) current is ever written.
- `FL_CAP_MA` = 100 mA per channel at level 10 (200 mA total). DT maximum 500 mA per channel; a
  `_Static_assert` keeps the cap at or below it. [I] Android's flashlight current on this phone is not known.
- Auto-off after 600 s of light (`FL_SECS`). A new level write lights it again.
- Fault watch every 100 ms while lit: fault interrupt, channel short, any STATUS2 flag -> off. Before a light:
  fault, short, thermal flags (STATUS2 0x70) refuse it. 3 faults in a boot -> EBUSY for the rest of the boot.
- Halt, restart, panic: CHAN_EN = 0, MODULE_EN = 0, no lock, bounded polls (only if the LED was lit this boot).
  Quiesce also clears the ready flag first, so no write can light the LED after it (review 2026-10-27).
- A failed write (or an earlier one: broken) does not leave the LED lit: the off path then writes CHAN_EN = 0 and
  MODULE_EN = 0 straight on the flash channel (`negroni_spmi_flash_off_nolock`, under `fl_lock`) and reads both back
  (log `NEGRONI FLASH: emergency off ...`). Writing `0` also runs it when the driver is broken.
- SPMI: writes only when EE 0 owns the module APID (no force option). Only 10 registers are writable.

## Interface

- `/dev/negroniflash`, root:mobile (gid 501), 0660.
- write ASCII `0`..`10` (newline allowed). 0 = off. N = N/10 of the cap, rounded to 5 mA, at least 5 mA.
  Above 10 = 10. Other text: EINVAL. Write failure: EIO. Fault limit: EBUSY.
- read: `level=L max=10 ma=M cap_ma=100 lit=0|1 cut=N faults=N broken=0|1`.
- Boot-arg `negroniflash=0`: kill switch (no PMIC access, no node).

## Self-check at start (on by default)

Own thread: SPMI arbiter, TYPE/SUBTYPE, EE 0 owner + channel window, status reads, LED off if found on, watch
thread, node. On a failure: one line `NEGRONI FLASH: off: <reason>`, no node, no write. On success: one line
`NEGRONI FLASH: on: PM8350C 0xee00 rev .. APID .. (EE 0), channels 0+1, levels 0..10 = 0..100 mA per channel ...`.

## Build

- Tree: `scripts/kernel/patched-tree.sh out/kernel/tree-flash` + the changes; `compile-one.sh` clean (0 warnings
  with the compile-one flags).
- Full build with the held patch: `out/hold/flash/build-flash.sh` (a copy of `build-local.sh` that adds
  `out/hold/flash/0387-negroni-flash-torch.patch`, writes to `out/hold/flash/kernel-*`, and does not change
  `out/kernel/kernel.macho`). 2026-10-27 13:01 UTC: `XNU Build Done`, 0386 and 0387 applied, no 0xxx patch skipped.
  `kernel.development.negroni` sha256 `2e3fd83b33433e91b32cd2d8f2d50c67957760f3cce6a2f9277b71ac8e9eb081`.

## Test (kernel only, after the image with 0387)

1. Boot log: `NEGRONI FLASH: on: ...` (or `off: <reason>`).
2. `scripts/net/ssh-phone.sh 'ls -l /dev/negroniflash; cat /dev/negroniflash'`
3. `scripts/net/ssh-phone.sh 'echo 3 > /dev/negroniflash; cat /dev/negroniflash'` -> LED on at 30 mA x 2,
   log `NEGRONI FLASH: on: level 3/10, 30 mA per channel x 2 (ITARGET 0x05 ...)`.
4. `echo 10 > /dev/negroniflash` (100 mA x 2), then `echo 0 > /dev/negroniflash` -> off.
5. Leave it on; after 600 s: `NEGRONI FLASH: auto-off after 600 s`.

## Risks [I]

- Not run on the phone. The register map is the mainline 4ch map; HakiOS uses it on the same PMIC module.
- The flash APID owner must be EE 0 (on Android the HLOS driver writes it, so it should be). Else: `off: ... owner EE N`.
- STATUS2 load flags (BCL, ILIM, VPH low) can cut the light; the log line names the bits.
- TORCH_CLAMP semantics on this revision are not checked; a mismatch is only logged.
- The arbiter can drop a command that collides with another channel's command; the driver retries 3 times,
  then stops writes for the boot (the off path still runs).
