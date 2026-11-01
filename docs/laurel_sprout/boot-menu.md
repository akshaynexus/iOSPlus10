# Mi A3: dual boot chosen on the phone

Owner requirement (2026-11-02): choose iOS or Android from the device, not only through fastboot. Lineage 24 on slot a. Mu + DarwinBoot + XNU on `boot_b`. iOS root on GPT partition `iosroot` (`dual-boot.md`, `scripts/lib/laurel-layout.sh`; merged here from `origin/laurel-sprout`).

**This work starts at step 12 of `dual-boot.md`, with the writable image.** The read-only first boot (steps 7-11) has no menu and no app. Section 6.1.

**Nothing here has run on the phone.** Marks: [V] read in source, in the phone's binaries or on the phone, or measured on a host. [I] inference. [U] unknown.

## 1. The result

| Way | What the owner does | What writes |
| --- | --- | --- |
| Power on, slot b active | Panel shows the UniXNU menu 5 s. No key: iOS. Volume keys select, Power boots. **No key in 7 boots in a row: ABL returns to Android by itself.** The menu says so at 4 boots left | one flag byte, only after a key press with at most 4 boots left (section 4) |
| iOS -> Android | Restart iOS (any plain reboot), or iOS panics (reset after 30 s on the paths of section 4.1), or iOS hangs: hold Power until it resets. Then in the menu: Vol Down, Power, Power | Mu: one flag byte in the GPT. ABL does the rest at the reset |
| Android -> iOS | One tap on the Quick Settings tile "Boot iOS" | the boot control HAL, then a normal Android reboot |

iOS itself never writes the GPT. There is no separate "Reboot to Android" in iOS: a plain restart reaches the menu.

```
ABL: retries of slot b - 1
 -> Mu -> UniXNU menu on the panel
      5 s, no key -> no write -> DarwinBoot -> XNU
      a key, then iOS -> [retries <= 3, no panic word, battery ok: back to 7] -> DarwinBoot -> XNU
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

**What ABL needs of slot a** [V `HandleActiveSlotUnbootable`]: successful = 1, unbootable = 0, priority > 0. If it has no such slot, it stops in fastboot. `dual-boot.sh switch` and the app both require this before they leave Android, and the HAL's slot change keeps slot a's bits, so the normal case has it. Mu leaves slot a's byte alone. If slot a is not such a target (Android failed earlier), the entry refuses with the reason on the panel: to force the bits would hide a broken Android. Then the owner needs fastboot (`set_active a`). That is the price, and the state is honest.

## 3. Slot flags, GPT write

Byte 6 of the attributes [V ABL `PART_ATT_*`, HAL `AB_*`]: bits 0-1 priority, 2 active, 3-5 retries, 6 successful, 7 unbootable. [V dump] LUN sde, 64 entries, boot_a entry 10 = 0x77, boot_b entry 31 = 0x7B, 4096-byte blocks, primary entries at LBA 2, backup header at LBA 1048575, a reserved run of 4 blocks before it.

Code: `tools/laurel-slot/laurel_slot.c` (no EDK2, no libc, also built by the host test), `uefi/LaurelSlot.c` (BlockIo glue). Copied into UniXNULib by `mu-build.sh`.

| Rule | How |
| --- | --- |
| Which LUN | From the actual tables: every whole-device BlockIo that is not read-only is read. The one LUN whose table passes every check and holds exactly one boot_a and boot_b is used. No fixed number. 0 or 2 such LUNs: refused |
| Check first | Both headers: signature, revision, size, own and other LBA, CRC. Header's other LBA = last LBA of the device. Entries: size 128, at most 16 KiB, primary at LBA 2. Both entry CRCs. The two entry arrays are equal except byte 6 of boot_a and boot_b. Anything else: refused, no write |
| What changes | Byte 6 of those two entries + the entry CRC and header CRC of each copy |
| Order | Backup (one command: entries, then header), flush, read back. Primary (one command: header, then entries up to the block with the flags: **2 blocks on this LUN**, ABL writes 5), flush, read back. Then the whole table is loaded and checked again. Only then the reset |
| When | Android: one write per choice. Refill: only after a key press, at retries <= 3, with no panic word. Same flags: no write |
| Low battery | [V] `EFI_CHARGER_EX_PROTOCOL.GetBatteryVoltage`, the call ABL itself makes on this phone (GUID + "Error getting battery voltage" in its binary; layout from QcomPkg `EFIChargerEx.h`, same in QRD abl r12). Below 3600 mV with no charger: no write, reason on the panel. Protocol absent or read failed: goes on with a log line. [U] the call on this binary in Mu |

### Power cut

| Cut during | State | Next boot |
| --- | --- | --- |
| Backup write | Primary valid and old; backup invalid | ABL reads the primary: slot b, menu. Mu's `PartitionDxe` restores the backup from the primary [V `Gpt.c`, V seen in QEMU]. Choose again |
| Between the copies | Both valid, flag bytes differ | Primary wins: slot b, menu. The code accepts this one difference and finishes the write |
| Primary write | Primary invalid; backup valid and new | The loader must use the backup: retries 0 -> fallback to Android. **[U] XBL's and ABL's GPT reader on this phone falling back to the backup** |
| After the primary | New in both | ABL's fallback |

**The primary row, and what the XBL does.** [V disassembly of this phone's `xbl_b`, ELF segment 0xc221000: the code that references "EFI PART" at 0xc228c3c] 0xc258bac reads a header at a given LBA and checks signature, header CRC over 92 bytes, own LBA, entry count, entry size, entries inside the device, entry array CRC. Its caller at 0xc2589c4: `if (read(1) != 0) { read(block_count - 1) ... }`. **So this XBL loader falls back to the backup at the last LBA when the primary fails either CRC.** Mu writes the backup first, so in that window the backup is whole and new, and ABL's fallback then runs. That closes "EDL may be the only exit" for the XBL loader's own lookups (tz, hyp, abl, ...). Still open: [U] XBL Core's `PartitionDxe` and ABL behind it: its FV is compressed and not read here; [I] standard EDK2, which uses the backup too [V `Gpt.c` in Mu]. PBL reads only the boot LUN (xbl_a, xbl_b), not this table.

The window itself is not new: [V ABL source] ABL rewrites this primary (5 blocks) at **every boot** of a slot that is not successful, and the HAL at each slot change. Host test: every block of every command as the cut point (12 points): each state boots, 0 lost.

A table that stays "copies differ" (e.g. a power cut inside an ABL write): the menu says so, no refill either, so ABL's retries end and the phone returns to Android with no computer.

### What Mu does on its own

- [V `Mu_Basecore/.../PartitionDxe/Gpt.c`] writes a GPT only when one copy is invalid. Both valid: reads only.
- [V] `PcdEmuVariableNvModeEnable` TRUE: UEFI variables stay in RAM. So the menu keeps no "last choice" on flash. None is needed: on slot b the last choice is iOS by construction, because the choice "Android" moves the phone off slot b. The timeout goes to iOS.
- [V strings `UFSDxe.efi`] the Qualcomm driver has `UFS WRITE`, LBA and power-on write protect functions, and "Set Active Boot LU". [U] whether `WriteBlocks` on this LUN is refused in UEFI. The code handles a refusal: nothing changes for the boot, the panel shows the reason. Other Qualcomm DXEs: not audited.

## 4. Retries (question C)

[V ABL] A slot with successful = 0 loses one retry at each normal boot, not in fastboot, recovery or charger mode. 0 = fallback. `set-active-boot-slot 1` gives 7 retries and clears successful.

**Mu does not mark slot b successful. It refills the retries, and only when a person is proven at the phone.** With successful = 1 ABL stops counting: a broken Mu or a bad flash would then restart for ever, with no way back without a computer. So the bit stays clear, and the count is the fallback.

The order, in `RunXnu`, right before DarwinBoot:

1. ABL: retries - 1, writes, loads boot_b.
2. Mu starts, panel, UFS, input.
3. Menu shown, countdown runs, the entry is chosen.
4. `LaurelSlotRefill`: **a real key event in this menu** (`gLaurelKeyHeard`, set where `ReadKeyStroke` returns a key), no panic word in IMEM, table valid, b active, slot a a valid target, retries <= 3, battery ok: retries = 7. Anything else: no write.
5. DarwinBoot, XNU.

An earlier version counted input handles and checked for a GOP. That proved nothing: ButtonsDxe can install and give no event, and a GOP exists on a dark panel. Then refill stayed on, and the way back to Android needed a computer. A key event is the only proof that the owner has a way out here. "The last boot" is not stored: no store is proven safe, and it is not needed.

| What breaks | Effect | Back to Android |
| --- | --- | --- |
| boot_b damaged, Mu dies before the menu | no refill | ABL after at most 7 boots, by itself |
| Dark panel, dead keys, nobody at the phone | no key event, no refill, 0 writes by Mu | same [V host test: 7 boots, 0 writes, then slot a; QEMU: no key = disk unchanged] |
| Kernel panics at each boot, nobody at the phone | same: reset (4.1), no key, no refill | same. This ends the loop that a handle count left open |
| GPT write refused, table odd, low battery | refill off, line on the log | same |
| Keys work, XNU panics or hangs | section 4.1, menu | Owner: Vol Down, Power, Power. No computer |

**The cost, plainly:** the owner must press a key about once per 4 iOS boots, or the phone is on Android after 7 boots with no key. The menu says it from 4 boots left: "Android after N more boots: press a key to stay". Any key counts, then Power to boot iOS.

Numbers [V host test]: with a key in each menu, 100 iOS boots = 50 write commands (25 refills: 2 commands each, one flag byte). A broken Mu falls back within 7 boots from a full count, at least 4 from the lowest count after a refill point.

### 4.1 Panic and hang, what really happens

An earlier text said "a panic resets after 30 s". [V code] It was not always true: `laurel_usb_panic_hold` returns at once when USB is not running; with `debug=0xc` (DB_NMI, `panicDebugging`) XNU sends only `kPEPanicDiagnosticsDone`, never `kPEPanicRestartCPU`, then spins in `panic_spin_forever`; and before `SweetPlatformExpert::start` no `PE_halt_restart` exists.

Kernel patch **2956** (both kernels; iOS 26: "applied+rules 3way osfmk/kern/debug.c"): `laurel_panic_final()` is called after the USB hold returns and from `panic_spin_forever` itself. It reads `laurelpanic=N`, counts N s on the system counter directly (no timebase needed), then resets by PSCI. A nested panic on that CPU resets at once.

| Case | Result |
| --- | --- |
| Panic, USB running | USB hold with its timed reset, 30 s, as before |
| Panic, USB not running, `debug=0xc` | hold returns, `kPEPanicDiagnosticsDone` -> final -> 30 s -> reset. **New** |
| Panic before `SweetPlatformExpert::start` | `panic_spin_forever` -> final -> 30 s -> reset, if boot-args are readable. **New**. No panic word: no IMEM mapping yet |
| Panic that hangs in its own printing, or before PE has the boot-args | no reset. Hold Power |
| Hang, no panic (interrupts off, a stuck driver) | **no reset, at any stage.** No watchdog driver exists (`build-honest.md`). Hold Power until it resets |
| Hang before `laurel_reboot_prepare` ran (2955 not applied yet) | the PMIC holds what the firmware or the last Android set. A warm reboot from Android: 4480 + 2000 ms [V dtsi]. A cold start: [U] the firmware's value. If Power alone does nothing: Power + Vol Down, and let go of Vol Down when the panel goes dark, or ABL enters fastboot |

**The panic word.** 2956 writes 0x4C504E43 to the IMEM restart word (0x0C12565C: `restart_reason@65c` [V DT on the phone]; the kernel writes this word at each start anyway, Linux writes it at each reboot, and neither ABL's source nor the phone's ABL binary holds the 0x776655xx values). Mu reads it (page is `IMEM Cookie Base` in its map, QEMU has no such page, so `gDS` decides) and skips the refill; the menu says "The last iOS boot panicked". It needs no write by Mu: the next start of the kernel writes the word back. [U] whether the word survives the reset. **The design does not depend on it:** with no word the gate still needs a key, so it only stops a refill when the owner presses a key right after a panic. Why not a counter of boots with no "good" signal: it needs a store too, and the key gate already ends the loop with 0 extra writes.

## 5. Input and display

- [V `Status.md`] Mu lists Display and Side Buttons as working on laurel_sprout, "state: inactive". [V `Binaries/laurel_sprout/.../ButtonsDxe`] the binary polls VOL+ by PMIC GPIO, VOL- and Power by PON real-time status, and is patched so Power gives Enter (0xD). It holds the SimpleTextIn, SimpleTextInEx and DevicePath GUIDs. That shows what it can do, not that it delivers on this phone.
- [V UniXNU `Menu.c`] the menu reads `ConIn`: Up/Down select, Enter boots, first key stops the countdown. `confirm` on an entry shows the question and needs another Power.
- [V earlier boots] the UniXNU menu is shown on this panel. **[U] No boot pressed a key in it.** This is the first thing to test.
- Touch: not built. It needs a touch driver in UEFI, and none exists for this panel in Mu.
- Patch `0201` in `Menu.c`: **an Enter within 1.5 s of the menu start or of the last Enter chooses nothing.** The owner may still hold Power from the reset, and that must not boot iOS at once. It does count as a key event. [V QEMU] three Enters in the first second chose nothing.
- **What decides is a key event, not a count** (section 4). This also covers the case where the serial driver has no device path, so a count would be 1 with working keys.

**If the keys do not work in UEFI:** no key event, so no refill and no Android entry in reach. Restart the phone until ABL returns to Android, at most 7 boots, no computer. Android -> iOS is not affected. Then the next step is to read PON and the GPIO directly in LaurelSlot, or a USB-OTG keyboard (Mu: USB Host Mode not working on this phone [V `Status.md`]).

## 6. Android -> iOS: one tap (question B)

Facts [V phone, read only]: Android 17, Lineage 24.0, `ro.build.type=userdebug`, `ro.debuggable=0`, `ro.adb.secure=1`, SELinux Enforcing. No `su` binary in `/system/bin` or `/system/xbin`. `adb root` works through `adbroot_service` (Rooted debugging). `hal_bootctl_client` = `su system_server update_engine update_verifier vold snapshotctl` (plat_sepolicy.cil line 1010): **no app domain, also no priv-app or platform app, can call the HAL.** Lineage recovery has no slot item in its menu (strings of its `recovery`).

| Option | Result | Verdict |
| --- | --- | --- |
| App + on-device adb client: the app is a normal adb host on 127.0.0.1. adbd checks its key, gives root by its own `root:` service, runs the checks and `bootctl` in the `su` domain | No partition write. One app, one `persist` property in /data. Survives a sideload | **Chosen, owner decision O2** |
| Same with Wireless debugging (TLS, no property) | Needs Wi-Fi on a known network, port changes | No: must work offline |
| Magisk | Real `su`, trivial app. **boot_a write**, patch again after each update | Fallback, owner's choice |
| priv-app + init service in system | system_a write and AVB change; SELinux needs a new domain anyway; a sideload removes it | No |
| Lineage settings | [V phone] no slot setting. [V source, lineage-24.0: no `adb_port` in `LineageSettings.java` or `AdbService.java`; phone: `settings get secure adb_port` null, no entry in lineagesettings] "ADB over network" no longer exists in this Lineage. The property does the same | No |
| `update_engine` `setShouldSwitchSlotOnReboot` | Needs a signed payload; only `gmscore_app` finds the service | No |
| Recovery zip | Many taps, needs an SD card (`/data` is encrypted there), signature prompt | No |

App: `tools/laurel-switcher` (Java, no libraries, 25 KB). Build `scripts/laurel/switcher-build.sh`, output `out/laurel/switcher/laurel-switcher.apk`. Setup once from the computer, with the owner's yes: `CONFIRM=switcher scripts/laurel/switcher-setup.sh` (`adb install`, the port of section 6.2; undo in the script's head). First Check: Android's "Allow debugging" dialog. The key is RSA 2048 in Android Keystore.

Who can start what (a local app must not be able to make adbd root): the launcher activity is exported only because a launcher entry must be. It does nothing with no tap: Check and Restart are buttons with `filterTouchesWhenObscured`, Restart asks again. The activity that switches at once is not exported; only the app's tile starts it, and the tile needs `BIND_QUICK_SETTINGS_TILE`. The boot receiver is not exported. **What the app makes root, it makes shell again**: `unroot:` after each step, also after a refusal, except a switch that reboots.

The checks, `assets/to-ios.sh`, run on the phone; any failure = one line with the reason, no write. `scripts/laurel/switcher-asset.sh` fills in the layout numbers and the fence text at build time, so a new fence or layout needs a new APK, and an old APK refuses:

| Check | Refuses when |
| --- | --- |
| uid 0, `ro.product.device` | Rooted debugging off, another phone |
| `ro.boot.slot_suffix`, `get-current-slot`, `get-active-boot-slot` | Android not on slot a, an update waits |
| `is-slot-bootable 0`, `is-slot-marked-successful 0`, as yes / no / **unknown** like `slot_answer` in `dual-boot.sh` [V real bootctl: no = stdout 0, exit 70; a HAL error also exits 70, with other text] | no fallback target. A HAL error is not a "no": refused too |
| Update state. [V phone] **`update_engine_client` does not exist on Lineage 24**, only the daemon. If the client exists: must be `UPDATE_STATUS_IDLE`. Else [V update_engine `constants.h`] prefs: `update-state-next-operation` not set or -1, `update-completed-on-boot-id` not this boot. Always `get-snapshot-merge-status` = none | an update in progress or waiting |
| by-name `iosroot` = sda16, `userdata` = sda15; start and size in sysfs = `laurel-layout.sh` | not the layout |
| `android-opened`, live, the same facts as `dual-boot.sh android-check`: `sys.boot_completed`, `sys.user.0.ce_available`, `ro.crypto.state`, `/data` = f2fs on sda15, superblock magic, block count fits the new userdata. **Equal evidence for the host's record, and newer** | Android has not opened its data on this layout |
| `boot_b`: magic, `laurel_ios_mode=rw`, `laurel_ios_image=PAGES:SHA256` from its command line against the bytes on flash | **read-only image**, Android image, a sideload, a damaged or partial flash |
| `dtbo_b` against `laurel_ios_dtbo=BYTES:SHA256` | not the stock dtbo that iOS needs |
| `laurel_ios_fence=SHA256` = hash of this app's fence text, and the text is in `boot_b` | a kernel with another fence than the app |
| Bytes 44..47 of `boot_a` = those of `boot_b` (S1, as `dual-boot.sh switch`) | a sideload changed Android |
| `iosroot` first MiB against `laurel_ios_root=1048576:SHA256` | **an image not built by `dual-boot.sh image rw`**, another root |
| `laurel_ios_fwb=SHA256`: one hash over the `FW_B` list of `laurel-layout.sh` (same list as `check_fw_b`: abl, tz, xbl, ... of slot b), from the backup's SHA256SUMS at build time | slot b firmware is not the backup's: the slot change would run another boot chain. Last, because it reads the most [I some seconds] |

### 6.1 The read-only flow: the app and the menu do not bypass it

The gate of `dual-boot.md` (a writable image needs `ro-on` + `android-opened-after-ro` in `out/laurel/dualboot/first-boot.result`) lives on the host: `dual-boot.sh image rw` and `android-guard.sh boot-image`. The phone cannot read that file. What holds it from the phone's side:

| Rule | How |
| --- | --- |
| The read-only boot goes only through `dual-boot.sh switch` | `LAUREL_READONLY=1` forces `BOOT_MENU=0` in `uefi-image.sh`: no marks in the header, so the app refuses that image ("does not hold our image") |
| The read-only boot writes nothing we control | Same switch: no Android entry and no retries refill, so Mu's code never writes a GPT there. 3 s menu with iOS only, panic hold as before (USB log can be read). Back to Android as `dual-boot.md` says: `to-android`, or the retries |
| A writable image that passed no gate cannot be switched to by the app | The app needs mode `rw` **and** the root mark. `dual-boot.sh image` sets the root mark from the `installed` record, and for `rw` it first checks the two records. A hand-built `uefi-image.sh` image has no root mark: the app refuses it. The flash of any writable image goes through the guard |
| `android-check` after each iOS boot while the flow runs | Not reachable by the app: before step 12 it refuses. After step 12 the flow is over: Android's data is checked by Android itself |

Not defended: someone who writes a marked image with plain `fastboot`, as for `dual-boot.sh`.

**S1 and the helper's hash.** [V host test, section 5 of `boot-menu-test.sh`] `os_version`, `os_patch_level` and the command line all lie in the header page. Two builds with other values give the same bytes after it, so `laurel_ios_image` holds with Lineage's values. `uefi-image.sh`: `mk()` is the one `mkbootimg` call; it takes Lineage's 17.0.0, 2026-10 whenever `config/laurel-android-data` exists, in both modes, also for `MU_ONLY=1` and `BOOT_MENU=0`. `scripts/laurel/shim.sh` keeps the fixed values: it makes the old shim image, which has no sidecar, so the guard refuses to flash it while the flag exists.

Then: `set-active-boot-slot 1`; active must read 1 and slot b must read not successful, else back to slot a (`set-active 0` + `mark-boot-successful`) and refused. Then `svc power reboot`, a clean Android shutdown. The marks are written by `uefi-image.sh` into the boot image's command line. Neither ABL nor Mu reads them.

### 6.2 The port (O2, owner decision: stay with adbd, reduce exposure)

| Rule | How |
| --- | --- |
| Not 5555 | A random high port, made once at the first build: `out/laurel/switcher/port` (20000-59999). The APK carries it, `switcher-setup.sh` sets the same one in `persist.adb.tcp.port` |
| Loopback after boot | `BootLockReceiver` (`LOCKED_BOOT_COMPLETED`, `BOOT_COMPLETED`, direct boot aware) connects with the app's key, `root:`, then `setprop service.adb.listen_addrs tcp:localhost:PORT; setprop service.adb.root 0; setprop ctl.restart adbd`. adbd comes back as shell on loopback only. The receiver reads `/proc/net/tcp*` and logs `LAUREL PORT: on|off: reason` |
| Why this and not iptables | [V `daemon/main.cpp`, lineage-24.0] `service.adb.listen_addrs` goes before both port properties; [V `socket_spec.cpp`] in adbd `tcp:N` = any address, `tcp:localhost:N` = `network_loopback_server`. No socket on Wi-Fi at all, v4 and v6 in one step, no rule to lose. [V plat_property_contexts] the property has no own context, so `default_prop`: `(allow coredomain default_prop (file read))` and `(typepermissive su)`, so root sets it and adbd reads it. [U] on the phone |

**The window at boot, plainly.** `service.*` properties end at the reboot, `persist.adb.tcp.port` does not. So from adbd's start until the receiver has run, **adbd listens on the port on all interfaces**, some tens of seconds [U how many], before the first unlock too if Wi-Fi is already up [I]. If the receiver fails (key expired, Rooted debugging off, app stopped) it stays so until the next try: the log line says so. Also [V `setup_adb`] adbd announces the port by mDNS when it listens, also later on loopback: the number is not secret on the LAN.

**The doc used to say "a stranger gets only a dialog". That is too mild.** In the window, anyone on the network can raise Android's "Allow debugging" dialog. **One wrong tap on "Always allow" gives that person persistent adb, and with Rooted debugging on, persistent root.** So: tap Allow only right after your own tap on Check, the first time; never when a dialog comes by itself. After the lock nothing from the network reaches adbd. A key not used for 7 days can expire (`adb_allowed_connection_time`, [V `AdbDebuggingManager`]): then the receiver cannot lock and the dialog comes again.

Any authorized key can get root, as the owner's computer can today. USB debugging and Rooted debugging must stay on.

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

| # | Decision | State |
| --- | --- | --- |
| O1 | **Mu writes the GPT of the boot LUN (LUN 4)**: one byte + CRCs in both copies, at each Android choice and after a key press at <= 4 boots left. Only in the writable image. D8 of `dual-boot.md` covers LUN 0 only. The window: section 3, the same as at every ABL retry. | Open. Recommendation: yes, no other design gives a device-side choice. `BOOT_MENU=0` is the way out |
| O2 | Android -> iOS | **Decided: adbd, with less exposure.** Section 6.2 |
| O3 | Patch 2955 sets a hold-Power reset for a hung kernel when nothing else has set it. No lasting effect in Android: [V `laurel_sprout-trinket-power.dtsi`] Android writes `pon_1` 4480 + 2000 ms hard reset at probe. So "hold until it resets": after a warm reboot from Android about 6.5 s, after a cold start with 2955 8.7 s | Open. Recommendation: yes |
| O4 | The cost of the key gate: a key press once per about 4 iOS boots, or Android after 7 | Open. Later a stored "keys work" flag can lower this, when a store is proven |
| O5 | `laurelpanic=30` in the boot-args: 30 s to read a panic and to fetch the USB log, then the menu. Was: hold for ever | Open. Recommendation: yes |

## 9. Unproven on the phone

Order of the first test. Each step is one flash or one tap, and the owner decides each.

1. Steps 0-11 of `dual-boot.md` come first, with no menu. Then step 12: `dual-boot.sh image rw`, `flash-slot-b rw`. O1 must be decided before this flash; without O1 build with `BOOT_MENU=0`.
2. **Menu on the panel, keys work?** `CONFIRM=switch dual-boot.sh switch rw`. Read: `LAUREL SLOT: on:`, a key moves the highlight. [U] the biggest open point for this feature.
3. iOS by timeout, no key, reboot: the count falls, nothing written by Mu (`refill off: no key event`). Then at 4 boots left the notice, a key, Power: **retries back to 7?** `[U] WriteBlocks on the LUN in UEFI`, `[U] flags as seen by the next ABL`, `[U] GetBatteryVoltage from Mu`.
4. **Android from the menu.** [U] ABL's fallback when entered from Mu's byte; [V earlier on phone] from real retries. Android must open its data: `dual-boot.md` section 4.
5. Hold Power until it resets, in a running iOS. `[U] the PMIC takes the S2 write from the kernel`. Linux writes the same registers [V], so [I] yes. Else Power + Vol Down. A panic with the cable out: the reset after 30 s (2956), and `The last iOS boot panicked` in the menu `[U] the word survives`.
6. App: `LAUREL PORT: on` in logcat after a boot, `/proc/net/tcp*` shows 127.0.0.1 only; Check, dialog, root, `LAUREL SWITCH: ok`, adbd is shell after it. [U] everything real: properties set from the `su` domain, adbd's key dialog over TCP, `root:` and `unroot:` over TCP, Keystore RSA with `NONEwithRSA` on this TEE before the first unlock, the boot receiver on Android 17, the tile (`startActivityAndCollapse`), a 12 KB `shell:` line.
7. Also [U]: PSCI reset from Mu reaches ABL in normal mode; UFS DMA to a buffer above 4 GiB in `WriteBlocks` (reads in the same place work [V boots]); the 5 s on a real panel is long enough; XBL Core's and ABL's use of the backup GPT.

Time [I]: if each step passes, about 1 hour with the owner at the phone. A failure in steps 2-4 costs about 1-2 hours each (one build + one flash per try, this ABL refuses `fastboot boot`). All of it after step 11 of `dual-boot.md`.

## 10. Fit with `dual-boot.sh`

- `switch` keeps working after a menu choice: slot b then reads not bootable (0x82) until the HAL's 0x3F, and `switch` does not ask `is-slot-bootable 1`.
- `to-android` over fastboot stays the computer way, and the only way out of a read-only boot besides the retries.
- `android-check` works after a menu choice: it reads only the layout and `/data`.
- `dual-boot.md` D3 ("selecting the OS from the device") is answered here: iOS writes nothing, Mu does; O1.
- Kernel: 2950 is not touched. 2955 changes only `laurel_reboot.c`. 2956 adds a panic path in `laurel_reboot.c`, `SweetPlatformExpert.cpp`, `osfmk/kern/debug.c`.
- `FW_B` moved from `dual-boot.sh` to `laurel-layout.sh`: one list for `check_fw_b` and the app's mark.
- iOS and Android keep apart: the menu reads and writes only the sde table, mounts nothing, and opens neither `userdata` nor `iosroot`. The fence is in 2950. O1 is about LUN 4; the approved GPT write of `dual-boot.md` D8 is about LUN 0 only, so it does not cover this.
