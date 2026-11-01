# Mi A3: dual boot chosen on the phone

Owner requirement (2026-11-02): choose iOS or Android from the device, not only through fastboot. Lineage 24 on slot a. Mu + DarwinBoot + XNU on `boot_b`. iOS root on GPT partition `iosroot` (`dual-boot.md`, `scripts/lib/laurel-layout.sh`; merged here from `origin/laurel-sprout` 9cad90f).

**This work starts at step 12 of `dual-boot.md`, with the writable image.** The read-only first boot (steps 7-11) has no menu and no app. Section 6.1.

**Nothing here has run on the phone.** Marks: [V] read in source, in the phone's binaries or on the phone, or measured on a host. [I] inference. [U] unknown.

## 1. The result

| Way | What the owner does | What writes |
| --- | --- | --- |
| Power on, slot b active | Panel shows the UniXNU menu 5 s. No key: iOS. Volume keys select, Power boots | at most one flag byte, one boot in four (section 4) |
| iOS -> Android | Restart iOS (any plain reboot), or iOS panics (reset after 30 s), or iOS hangs: hold Power 9 s. Then in the menu: Vol Down, Power, Power | Mu: one flag byte in the GPT. ABL does the rest at the reset |
| Android -> iOS | One tap on the Quick Settings tile "Boot iOS" | the boot control HAL, then a normal Android reboot |

iOS itself never writes the GPT. There is no separate "Reboot to Android" in iOS: a plain restart reaches the menu.

```
ABL: retries of slot b - 1
 -> Mu -> UniXNU menu on the panel
      5 s, no key -> [retries <= 3: back to 7] -> DarwinBoot -> XNU
      Android + Power (confirm) -> boot_b: retries 0 -> reset
           -> ABL: slot b has no retries left -> its own fallback: slot a active, GUID swap, boot LUN -> reset -> Android
Android: tile -> app -> adbd on 127.0.0.1 as root -> checks -> bootctl set-active-boot-slot 1 -> svc power reboot
```

## 2. The first design does not work: flags alone cannot select slot a

The request was: "Android" writes the boot_a active bit, priority and retries, "the same bits the HAL writes". Reading the HAL and ABL shows that is not enough:

- [V `boot_control.cpp`, lineage-24.0-caf] `set_active_boot_slot` also swaps the partition **type GUID** of every A/B partition (`UPDATE_SLOT` does `memcpy(pentry, guid, ...)`), and moves the UFS boot LUN (`gpt_utils_set_xbl_boot_partition`).
- [V dump `gpt-sde-head.bin`] The inactive slot really has the "inactive" GUID: `abl_b` and `boot_b` both have `d46c0377...`, `abl_a` `a12869bd...`, `boot_a` `867f1120...`.
- [V QRD abl `PartitionTableUpdate.c`; V strings in the phone's own ABL, `abl_b.img.gz`, LZMA at 0x3078: `ValidateSlotGuids: BootableSlot %s does not have valid guids`, `Boot lun: %x and BootableSlot: %s do not match`] ABL refuses a slot whose boot and abl type GUIDs are equal, and a slot that does not match the boot LUN. A flag-only change to slot a boots nothing, and the phone stops in fastboot: a computer would be needed.
- A swap in Mu is not an option: it writes about 40 entries on 2 LUNs and needs the UFS attribute `bBootLunEn` through a Qualcomm protocol. That is a much larger write, in the code path with the least proof.

**What works, and only needs the flag byte of one entry.** [V same source; V the same strings on the phone: `Slot %s is unbootable, trying alternate slot`, `Alternate Slot %s is bootable`, `Switching the boot lun from 2 to 1`; V phone history, `dual-boot.md`: "it moved from b to a by itself"] When the active slot has successful = 0 and retries = 0, ABL runs `HandleActiveSlotUnbootable`: it marks that slot unbootable, takes the slot with successful = 1, and `SetActiveSlot` sets flags, swaps the GUIDs of all pairs, sets the boot LUN and resets. Mu therefore writes **boot_b retries = 0, successful = 0**. That is exactly the state after 7 failed boots, on a path this phone has already gone through. So the code rule of the task holds: only attribute bytes of boot_a and boot_b, both copies, both CRCs.

After it: [V test model] boot_a 0x7F, boot_b 0x82 (unbootable, priority 2). The HAL's byte 0x3F clears that at the next Android -> iOS.

If slot a is not a fallback target (successful clear or unbootable set, e.g. Android failed earlier), the owner's choice sets those two bits on boot_a in the same write. A priority of 0 on slot a is refused.

## 3. Slot flags, GPT write

Byte 6 of the attributes [V ABL `PART_ATT_*`, HAL `AB_*`]: bits 0-1 priority, 2 active, 3-5 retries, 6 successful, 7 unbootable. [V dump] LUN sde, 64 entries, boot_a entry 10 = 0x77, boot_b entry 31 = 0x7B, 4096-byte blocks, primary entries at LBA 2, backup header at LBA 1048575, a reserved run of 4 blocks before it.

Code: `tools/laurel-slot/laurel_slot.c` (no EDK2, no libc, also built by the host test), `uefi/LaurelSlot.c` (BlockIo glue). Copied into UniXNULib by `mu-build.sh`.

| Rule | How |
| --- | --- |
| Which LUN | From the actual tables: every whole-device BlockIo that is not read-only is read. The one LUN whose table passes every check and holds exactly one boot_a and boot_b is used. No fixed number. 0 or 2 such LUNs: refused |
| Check first | Both headers: signature, revision, size, own and other LBA, CRC. Header's other LBA = last LBA of the device. Entries: size 128, at most 16 KiB, primary at LBA 2. Both entry CRCs. The two entry arrays are equal except byte 6 of boot_a and boot_b. Anything else: refused, no write |
| What changes | Byte 6 of those two entries + the entry CRC and header CRC of each copy |
| Order | Backup (one command: entries, then header), flush, read back. Primary (one command: header, then entries, as ABL writes it at every retry), flush, read back. Then the whole table is loaded and checked again. Only then the reset |

### Power cut

| Cut during | State | Next boot |
| --- | --- | --- |
| Backup write | Primary valid and old; backup invalid | ABL reads the primary: slot b, menu. Mu's `PartitionDxe` restores the backup from the primary [V `Gpt.c`, V seen in QEMU]. Choose again |
| Between the copies | Both valid, flag bytes differ | Primary wins: slot b, menu. The code accepts this one difference and finishes the write |
| Primary write | Primary invalid; backup valid and new | The loader must use the backup: retries 0 -> fallback to Android. **[U] XBL's and ABL's GPT reader on this phone falling back to the backup** |
| After the primary | New in both | ABL's fallback |

The last-but-one row is not a new risk: [V ABL source] ABL rewrites the primary in the same way on **every boot** of a slot that is not successful, so the same window exists today at each retry, and the HAL has it at each slot change. It is the worst case and the reason this write is rare. [I] Host test: every block of every command as the cut point (12 points): each state boots, 0 lost.

A table that stays "copies differ" (e.g. a power cut inside an ABL write): the menu says so, no refill either, so ABL's retries end and the phone returns to Android with no computer.

### What Mu does on its own

- [V `Mu_Basecore/.../PartitionDxe/Gpt.c`] writes a GPT only when one copy is invalid. Both valid: reads only.
- [V] `PcdEmuVariableNvModeEnable` TRUE: UEFI variables stay in RAM. So the menu keeps no "last choice" on flash. None is needed: on slot b the last choice is iOS by construction, because the choice "Android" moves the phone off slot b. The timeout goes to iOS.
- [V strings `UFSDxe.efi`] the Qualcomm driver has `UFS WRITE`, LBA and power-on write protect functions, and "Set Active Boot LU". [U] whether `WriteBlocks` on this LUN is refused in UEFI. The code handles a refusal: nothing changes for the boot, the panel shows the reason. Other Qualcomm DXEs: not audited.

## 4. Retries (question C)

[V ABL] A slot with successful = 0 loses one retry at each normal boot, not in fastboot, recovery or charger mode. 0 = fallback. `set-active-boot-slot 1` gives 7 retries and clears successful.

**Mu does not mark slot b successful. It refills the retries, and only at the last moment.** With successful = 1 ABL stops counting: a broken Mu or a bad flash would then restart for ever, with no way back without a computer. So the bit stays clear, and the count is the fallback.

The order, in `RunXnu`, right before DarwinBoot:

1. ABL: retries - 1, writes, loads boot_b.
2. Mu starts, panel, UFS, input.
3. Menu shown, countdown runs, the entry is chosen.
4. `LaurelSlotRefill`: screen present, at least 2 input devices (the serial driver always counts as 1, so 2 = the side keys), table valid, b active, a a valid target, retries <= 3: retries = 7. Otherwise no write.
5. DarwinBoot, XNU.

| What breaks | Effect | Back to Android |
| --- | --- | --- |
| boot_b damaged, Mu dies before the menu | no refill | ABL after at most 7 boots, by itself |
| Panel or keys do not work in Mu | refill off (keys), or the owner cannot choose | same |
| GPT write refused or table odd | refill off, line on the log | same |
| Refill works, XNU panics | reset after 30 s, menu | Owner: Vol Down, Power, Power. No computer |
| Refill works, XNU hangs | hold Power 9 s (patch 2955), or Power + Vol Down and let go of Vol Down when the panel goes dark | same |

Numbers [V host test]: 100 iOS boots = 50 write commands (25 refills: 2 commands each, one flag byte). A broken Mu falls back within 7 boots from a full count, at least 4 from the lowest count after a refill point. [I] Boot time cost: two UFS commands, one boot in four.

**Unattended loop.** A kernel that panics at every boot now loops through the menu without end, where before it stopped after 7 boots on Android. The owner asked for no silent fallback, and without a "boot was good" signal from iOS the menu cannot tell the two apart. Decision O4 in section 8.

## 5. Input and display

- [V `Status.md`] Mu lists Display and Side Buttons as working on laurel_sprout. [V `Binaries/laurel_sprout/.../ButtonsDxe`] the binary polls VOL+ by PMIC GPIO, VOL- and Power by PON real-time status, and is patched so Power gives Enter (0xD). It holds the SimpleTextIn, SimpleTextInEx and DevicePath GUIDs, so ConSplitter takes it into `ConIn`.
- [V UniXNU `Menu.c`] the menu reads `ConIn`: Up/Down select, Enter boots, first key stops the countdown. `confirm` on an entry shows the question and needs another Power.
- [V earlier boots] the UniXNU menu is shown on this panel. **[U] No boot pressed a key in it.** This is the first thing to test.
- Touch: not built. It needs a touch driver in UEFI, and none exists for this panel in Mu.
- Patch `0201` in `Menu.c`: **an Enter within 1.5 s of the menu start or of the last Enter chooses nothing.** The owner may still hold Power from the reset, and that must not boot iOS at once. [V QEMU] three Enters in the first second chose nothing.

**If the keys do not work in UEFI:** the refill turns itself off (at most 1 input device), so the next best option works by itself: restart the phone until ABL returns to Android (at most 7 boots), no computer. Android -> iOS is not affected. Then the next step is to read PON and the GPIO directly in LaurelSlot, or a USB-OTG keyboard (Mu: USB Host Mode not working on this phone [V `Status.md`]).

## 6. Android -> iOS: one tap (question B)

Facts [V phone, read only]: Android 17, Lineage 24.0, `ro.build.type=userdebug`, `ro.debuggable=0`, `ro.adb.secure=1`, SELinux Enforcing. No `su` binary in `/system/bin` or `/system/xbin`. `adb root` works through `adbroot_service` (Rooted debugging). `hal_bootctl_client` = `su system_server update_engine update_verifier vold snapshotctl` (plat_sepolicy.cil line 1010): **no app domain, also no priv-app or platform app, can call the HAL.** Lineage recovery has no slot item in its menu (strings of its `recovery`).

| Option | Result | Verdict |
| --- | --- | --- |
| App + on-device adb client: the app is a normal adb host on 127.0.0.1. adbd checks its key, gives root by its own `root:` service, runs the checks and `bootctl` in the `su` domain | No partition write. One app, one `persist` property in /data. Survives a sideload | **Chosen** |
| Same with Wireless debugging (TLS, no property) | Needs Wi-Fi on a known network, port changes | No: must work offline |
| Magisk | Real `su`, trivial app. **boot_a write**, patch again after each update | Fallback, owner's choice |
| priv-app + init service in system | system_a write and AVB change; SELinux needs a new domain anyway; a sideload removes it | No |
| Lineage settings | [V phone] no slot setting; "ADB over network" not set (`adb_port` absent), [U] whether Lineage 24 still has it. The property does the same | No |
| `update_engine` `setShouldSwitchSlotOnReboot` | Needs a signed payload; only `gmscore_app` finds the service | No |
| Recovery zip | Many taps, needs an SD card (`/data` is encrypted there), signature prompt | No |

App: `tools/laurel-switcher` (Java, no libraries, 21 KB). Build `scripts/laurel/switcher-build.sh`, output `out/laurel/switcher/laurel-switcher.apk`. Setup once from the computer, with the owner's yes: `CONFIRM=switcher scripts/laurel/switcher-setup.sh` (`adb install`, `setprop persist.adb.tcp.port 5555`, restart adbd; undo in the script's head). First tap: Android's "Allow debugging" dialog, choose "Always allow". The key is RSA 2048 in Android Keystore.

The checks, `assets/to-ios.sh`, run on the phone; any failure = one line with the reason, no write. `scripts/laurel/switcher-asset.sh` fills in the layout numbers and the fence text at build time, so a new fence or layout needs a new APK, and an old APK refuses:

| Check | Refuses when |
| --- | --- |
| uid 0, `ro.product.device` | Rooted debugging off, another phone |
| `ro.boot.slot_suffix`, `get-current-slot`, `get-active-boot-slot` | Android not on slot a, an update waits |
| `is-slot-marked-successful 0` | no fallback target |
| by-name `iosroot` = sda16, `userdata` = sda15, sizes = `IOSROOT_BYTES`, `USERDATA_BYTES` | not the layout of `laurel-layout.sh` |
| `boot_b`: magic, `laurel_ios_mode=rw`, `laurel_ios_image=PAGES:SHA256` from its command line against the bytes on flash | **read-only image**, Android image, a sideload, a damaged or partial flash |
| `dtbo_b` against `laurel_ios_dtbo=BYTES:SHA256` | not the stock dtbo that iOS needs |
| fence text `LDB_KERNEL_MARKER` in `boot_b` | a kernel with another fence |
| OS field (byte 44) of `boot_a` = that of `boot_b` (S1, as `dual-boot.sh switch`) | a sideload changed Android |
| `iosroot` first MiB against `laurel_ios_root=1048576:SHA256` | **an image not built by `dual-boot.sh image rw`**, another root |

### 6.1 The read-only flow: the app and the menu do not bypass it

The gate of `dual-boot.md` (a writable image needs `ro-on` + `android-opened-after-ro` in `out/laurel/dualboot/first-boot.result`) lives on the host: `dual-boot.sh image rw` and `android-guard.sh boot-image`. The phone cannot read that file. What holds it from the phone's side:

| Rule | How |
| --- | --- |
| The read-only boot goes only through `dual-boot.sh switch` | `LAUREL_READONLY=1` forces `BOOT_MENU=0` in `uefi-image.sh`: no marks in the header, so the app refuses that image ("does not hold our image") |
| The read-only boot writes nothing we control | Same switch: no Android entry and no retries refill, so Mu's code never writes a GPT there. 3 s menu with iOS only, panic hold as before (USB log can be read). Back to Android as `dual-boot.md` says: `to-android`, or the retries |
| A writable image that passed no gate cannot be switched to by the app | The app needs mode `rw` **and** the root mark. `dual-boot.sh image` sets the root mark from the `installed` record, and for `rw` it first checks the two records. A hand-built `uefi-image.sh` image has no root mark: the app refuses it. The flash of any writable image goes through the guard |
| `android-check` after each iOS boot while the flow runs | Not reachable by the app: before step 12 it refuses. After step 12 the flow is over: Android's data is checked by Android itself |

Not defended: someone who writes a marked image with plain `fastboot`, as for `dual-boot.sh`. The app also does not repeat `check-slot-b` (firmware of slot b against the backup): `dual-boot.sh switch` did it at step 12, and a sideload that changes that firmware also overwrites boot_b, which the app refuses.

**S1 and the helper's hash.** [V host test, section 5 of `boot-menu-test.sh`] `os_version`, `os_patch_level` and the command line all lie in the header page. Two builds with other values give the same bytes after it, so `laurel_ios_image` holds with Lineage's values. `uefi-image.sh`: `mk()` is the one `mkbootimg` call; it takes Lineage's 17.0.0, 2026-10 whenever `config/laurel-android-data` exists, in both modes, also for `MU_ONLY=1` and `BOOT_MENU=0`. `scripts/laurel/shim.sh` keeps the fixed values: it makes the old shim image, which has no sidecar, so the guard refuses to flash it while the flag exists.

Then: `set-active-boot-slot 1`; active must read 1 and slot b must read not successful, else back to slot a (`set-active 0` + `mark-boot-successful`) and refused. Then `svc power reboot`, a clean Android shutdown. The marks are written by `uefi-image.sh` into the boot image's command line. Neither ABL nor Mu reads them.

**Cost, plainly:** adbd listens on TCP 5555 of all interfaces, also on Wi-Fi, because adbd has no way to persist a loopback-only address (`service.adb.listen_addrs` is not a persist property [V strings]). Its normal key check stays on: a stranger gets only a dialog on the phone. Any authorized key can get root, as the owner's computer can today. USB debugging and Rooted debugging must stay on. Decision O2.

## 7. Build and test

| Step | Command | Result [V, host, 2026-11-02] |
| --- | --- | --- |
| Mu | `scripts/laurel/mu-build.sh` (private tree: `scripts/laurel/mu-private-tree.sh`, then `MU_TREE= UNIXNU_TREE= SETUP=0`) | FD 3,145,728 bytes (the fixed FV), FVMAIN_COMPACT 1,404,888 used, 1,740,840 free. f1563f3b |
| Kernel iOS 16 | `scripts/laurel/kernel-linux.sh` | 312/312 patches, 0 failed, 0 LSE/RCpc, printf check OK, fence V3 text. 7210b49c |
| Kernel iOS 26 | `scripts/laurel/kernel-ios26-linux.sh` | series 212 applied, 84 applied+rules, 7 skipped, 11 base, 0 errors, 0 LSE/RCpc, fence V3 text. 336df6fe |
| Images, both modes, iOS 16 and iOS 26 | `dual-boot.sh image`; `LAUREL_READONLY=0 ...-image.sh` | **52,867,072 bytes each** of 67,108,864 (boot_b 64 MiB). Header v2, os 17.0.0, 2026-10 = Lineage's. `dual-boot.sh image rw` refuses with no record: "no recorded result of a read-only boot of this kernel fence" |
| APK | `scripts/laurel/switcher-build.sh` | 21,034 bytes, `apksigner verify` OK, target SDK 36, fence and sizes filled in. 96e71314 |
| Host test | `scripts/bg.sh menu-test scripts/laurel/boot-menu-test.sh` | slot core 645 checks (ASan, UBSan) on the phone's dump; helper 27 cases; client 15 checks; TOML; mkbootimg header page; real images of 7 builds: **PASS** |
| UEFI test | `scripts/bg.sh menu-qemu scripts/laurel/boot-menu-qemu.sh` | real `UniXNU.efi` on AAVMF, 720x1560, disks from the dump at 4096-byte blocks: 10 scenarios, 28 checks, **0 failures** |
| Dual boot | `scripts/laurel/test-dualboot.sh` | PASS: `test_kernel` 42720 checks, helper 12, guard 70, `dual-boot-test` 73 (1 new: `image rw` passes the root's hash on) |
| Older tests | `build-honest-test.sh` 60/60 | PASS |

What the host test holds for the flow: a read-only image, `BOOT_MENU=0` and `MU_ONLY=1` are refused by the helper as "not our image"; a writable image with no root mark is refused; a writable image with the root mark says "ready"; each has Lineage's OS field; a read-only image holds no `ufsrw=` or `rootrw=`, one entry, 3 s, no `laurelpanic`. Also a fake phone with: other OS field in boot_a, older fence, other root in `iosroot`, wrong partition number or size, a script with no build numbers.

What the host test holds:
- All six LUN dumps read correctly: only sde has the pair, 0 writes.
- A write changes 0 bytes outside byte 6 of boot_a and boot_b and the 4 CRC fields (exact byte list, 2 MiB compared).
- 18 damaged or odd tables refused, 0 writes each: signature, revision, header CRC, other LBA, entry byte, entry count, entry size, entry LBA, in either copy; valid copies that differ in a GUID, a name, attribute byte 7, flags of another partition, a first LBA; two boot_a; no boot_b; block size; LUN size.
- A model of ABL and the HAL [written from the source, so it proves the code against my reading, not against the phone]: 100 boots with refill; Android choice leads to slot a; broken Mu falls back; **a flag-only slot change is refused by the model's `ValidateSlotGuids`**; a cut at every block; a write error at each command.

What the UEFI test holds [V real firmware, real `BlockIo`, `-no-reboot` sees the reset]: refill at 3, no write at 4; Vol-Down-Power-Power = `LAUREL SLOT: Android: a 73->73 b 3F->07: ok`, then the reset, 18 bytes changed, all allowed; held Enter chooses nothing; cancel writes nothing; refused on copies that differ, on two LUNs, on slot a active; a primary with a bad CRC is restored by the firmware before the menu; no keyboard = no refill. Screenshot `out/laurel/menu-qemu/menu.png`.

It does not hold: Qualcomm `UFSDxe`, `ButtonsDxe`, ABL, the panel.

Kill switches: `BOOT_MENU=0 scripts/laurel/uefi-image.sh`: the old menu, no Android entry, Mu writes nothing. `laurelpowerhold=0`. Lines to read: `LAUREL SLOT: on|off: reason`, `LAUREL POWERKEY: on|off: reason`, `LAUREL SWITCH: ok|refused: reason`.

## 8. Owner decisions

| # | Decision | Recommendation |
| --- | --- | --- |
| O1 | **Mu writes the GPT of the boot LUN (LUN 4)**: one byte + CRCs in both copies, at each Android choice and one boot in four. Only in the writable image. Not approved so far; D8 of `dual-boot.md` covers LUN 0 only. The window of section 3 (primary being rewritten, power cut, XBL's backup fallback [U]) is the same as at every ABL retry, and adds to their count | Yes. No alternative gives a device-side choice. `BOOT_MENU=0` is the way out |
| O2 | Android -> iOS: app + adbd on TCP 5555, or Magisk on boot_a | App: no partition write. Owner should know the port is open on Wi-Fi (section 6) |
| O3 | Patch 2955: hold Power 9 s = hard reset, stays set in the PMIC until the next power-up, so also in Android after an iOS boot | Yes: without it a hung kernel needs Power + Vol Down |
| O4 | A kernel that panics at each boot loops through the menu without end | Accept for now. An automatic return needs a "boot was good" signal from iOS (IMEM word read by Mu): small, not built |
| O5 | `laurelpanic=30` in the boot-args: 30 s to read a panic and to fetch the USB log, then the menu. Was: hold for ever | Yes |

## 9. Unproven on the phone

Order of the first test. Each step is one flash or one tap, and the owner decides each.

1. Steps 0-11 of `dual-boot.md` come first, with no menu. Then step 12: `dual-boot.sh image rw`, `flash-slot-b rw`. O1 must be decided before this flash; without O1 build with `BOOT_MENU=0`.
2. **Menu on the panel, keys work?** `CONFIRM=switch dual-boot.sh switch rw`. Read: `LAUREL SLOT: on:`, `input yes`. [U] the biggest open point for this feature.
3. iOS by timeout. Reboot 5 times. **Do retries stay above 0?** `[U] WriteBlocks on the LUN in UEFI`, `[U] slot flags as seen by the next ABL`.
4. **Android from the menu.** [U] ABL's fallback when entered from Mu's byte; [V earlier on phone] from real retries. Android must open its data: `dual-boot.md` section 4.
5. Hold Power 9 s in a hung or running iOS. `[U] the PMIC takes the S2 write from the kernel`. Linux writes the same registers [V], so [I] yes. Else Power + Vol Down.
6. App: first tap, dialog, root, `LAUREL SWITCH: ok`. [U] everything real: `persist.adb.tcp.port` set from the `su` domain, adbd's key dialog over TCP, `root:` over TCP, Keystore RSA with `NONEwithRSA` on this TEE, the tile on Android 17 (`startActivityAndCollapse`).
7. Also [U]: PSCI reset from Mu reaches ABL in normal mode; UFS DMA to a buffer above 4 GiB in `WriteBlocks` (reads in the same place work [V boots]); the 5 s on a real panel is long enough.

Time [I]: if each step passes, about 1 hour with the owner at the phone. A failure in steps 2-4 costs about 1-2 hours each (one build + one flash per try, this ABL refuses `fastboot boot`). All of it after step 11 of `dual-boot.md`.

## 10. Fit with `dual-boot.sh`

- `switch` keeps working after a menu choice: slot b then reads not bootable (0x82) until the HAL's 0x3F, and `switch` does not ask `is-slot-bootable 1`.
- `to-android` over fastboot stays the computer way, and the only way out of a read-only boot besides the retries.
- `android-check` works after a menu choice: it reads only the layout and `/data`.
- `dual-boot.md` D3 ("selecting the OS from the device") is answered here: iOS writes nothing, Mu does; O1.
- Kernel: 2950 is not touched. 2955 changes only `laurel_reboot.c`.
- iOS and Android keep apart: the menu reads and writes only the sde table, mounts nothing, and opens neither `userdata` nor `iosroot`. The fence is in 2950. O1 is about LUN 4; the approved GPT write of `dual-boot.md` D8 is about LUN 0 only, so it does not cover this.
