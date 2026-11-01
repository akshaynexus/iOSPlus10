# Mi A3: dual boot LineageOS and iOS, no wipe, no GPT change

Owner goal (2026-11-02): LineageOS 24 and iOS on one phone, Android keeps working. iOS 16 root first, because it exists, then iOS 26. **Nothing here has run on the phone.** Not one write step was run. Marks: [V] measured or read in source, [I] inference, [U] unknown.

## 1. Recommendation

| Part | Choice |
| --- | --- |
| Boot selection | A/B slots. Lineage on slot a (as now). Mu + DarwinBoot + XNU on `boot_b`, stock `dtbo_b`. |
| Android -> iOS | `dual-boot.sh switch`: root adb, seal, `bootctl set-active-boot-slot 1`, reboot. |
| iOS -> Android | `fastboot set_active a`, or ABL's fallback when the retries of slot b end. No iOS GPT write (owner decision D3). |
| iOS root | A pinned, preallocated f2fs file in `/data`, written raw on `sda15`. XNU reads a table of extents from the boot image and never parses f2fs. |
| Safety | One write fence in `ufs_write_blocks`. A self-check before any write. Failure = no write anywhere, restart, ABL falls back to Android. |

## 2. Design answers

### Q1. Boot selection

- [V phone] Android runs on slot a: `ro.boot.slot_suffix=_a`, `/` = sda12 (system_a), `/vendor` = sde16 (vendor_a), `/vendor/firmware_mnt` = sde4 (modem_a).
- [V phone] `adb root` answers "ADB Root access is disabled by system setting". `/dev/block/*`, slot attributes and `/sys/fs/f2fs` need root. **So what system_b, vendor_b, modem_b hold now is [U] on the phone.** [I] They are stock: `docs/flash-lineageos.md` wrote only boot_b and dtbo_b on slot b, and the sideload wrote slot a. Check at step 1 of section 4.
- [V phone] `getprop ro.debuggable` = 0 (read twice), `ro.build.type` = userdebug, `/proc/cmdline` has `buildvariant=user`. No such property in the device trees (`laurel-device-los`, `sm6125-common-los`). [U] whether Rooted debugging then gives root: see decision D1.
- [V source, QRD-Development/abl uefi.lnx.3.0.r12-rel; I that this phone's ABL acts the same] `FindBootableSlot`: a slot not successful with retries > 0: retries - 1 and boot. Retries 0: mark unbootable, `HandleActiveSlotUnbootable` takes the slot with successful = 1, not unbootable, highest priority > 0, sets it active and resets. No such slot: boot fails to fastboot. The count does not fall in fastboot, recovery or charger mode (`IsABRetryCountUpdateRequired`).
- [V phone history] The fallback works from `fastboot set_active b` (device-state notes: "it moved from b to a by itself").
- [V source, LineageOS bootctrl lineage-24.0-caf, `boot_control.cpp`, `gpt-utils.h`] `set_active_boot_slot` writes byte 0x3F to slot b (priority 3, active, 7 retries) and only clears the active bit of slot a, so slot a keeps its priority and fallback stays possible. It also moves the UFS boot LUN to xbl_b. [I] This binary is on the phone (`android.hardware.boot-service.qti` [V present]).
- [V source] HAL `mark_boot_successful` is what sets slot a successful; iOS never does. So one `switch` gives iOS **at most 7 boots**, then the phone returns to Android [I].

**Android -> iOS.** Needs root adb, because `bootctl` from shell says "Failed to get bootctl module" [V].

**iOS -> Android**, three ways:
1. `op10tool ctl bootloader` (or Power + Vol Down), then `fastboot set_active a`. Needs a computer. No write from iOS. Recommended now.
2. Reboot iOS until the retries end. No computer. Up to 7 boots. ABL writes the attributes, not iOS.
3. iOS writes the slot attributes in the GPT of the boot LUN. Not built. Decision D3. A bug there can destroy a GPT, and today the kernel cannot write a GPT at all (`ufs_write_blocks` fence, LUN 0 only).

**OTA pitfall [V partition list, I behaviour].** An Updater install writes all 22 partitions of slot b (list below) and makes b active: `boot_b` and `dtbo_b` are gone, Android is on b, iOS has no boot image. The file in `/data` stays. `dual-boot.sh switch` refuses when Android is not on slot a. Decision D2: disable the Updater, or accept to redo section 4 steps 7-8 on slot a afterwards.

**Alternative: boot menu in Mu on one slot, chain-loading Android from boot_a. Rejected.**
- It puts Mu in the slot Android boots from, so a Mu bug stops Android.
- [V source, `VerifiedBoot.c`] ABL gives TrustZone the OS version and patch level **from the boot image header it loaded** (`KeyMasterSetRotAndBootState`). Android's FBE and metadata keys are keymaster keys. [I] A Mu image with another header can make them unusable: the data stays, Android cannot open it. Faking the header makes every Lineage update a Mu rebuild.
- ABL's work for Linux would have to be redone in Mu: dtbo overlay with board id, command line (`androidboot.*`, serial, verified boot state, slot), RAM banks, display. No such code exists in Mu.
- A/B slots need no new boot code: [V] ABL -> Mu -> XNU on slot b has booted many times.

[I] Keymaster when iOS boots between two Android boots: ABL sends the Mu image's header (11.0.0, 2022-08) only for that boot, and XNU uses no key. [U] whether TrustZone keeps anything across that boot. Android after an iOS boot is the **first thing to test**, and the case where a failure costs most: section 6.

### Q2. Firmware per slot

[V code, `TopazModem.cpp`, `laurel_ipa_fw.c`, `laurel_bt_fat.c`] What the iOS kernel reads, read-only:

| Partition | How it picks | Why |
| --- | --- | --- |
| `modem_<active>`, then the other, then `modem` | GPT active bit of boot_a / boot_b | modem, ADSP, WLAN, camera firmware |
| `vendor_<active>`, then the other | same | IPA firmware |
| `bluetooth_b`, then `bluetooth_a` | fixed order | BT firmware |
| `modemst1`, `modemst2`, `fsc`, `fsg` | fixed | rmtfs answers, writes are dropped [V] |
| `boot_a`, `boot_b` | GPT attributes only | the active bit |

`dsp_*` is not read at all [V grep]. So it follows the slot, and the iOS slot is what matters.

[V `scripts/laurel/ota-partitions.py`, OTA hash against the stock ROM file + zero padding] Lineage's OTA holds these 22 partitions. **All firmware in it is byte-identical to the stock ROM** that iOS has booted on: abl, bluetooth, cmnlib, cmnlib64, devcfg, dsp, hyp, imagefv, keymaster, modem, qupfw, rpm, storsec, tz, uefisecapp, xbl, xbl_config. Different: boot, dtbo, vbmeta, system, vendor. [I] So modem_a = modem_b and bluetooth_a = bluetooth_b, and iOS gets the same firmware on either slot. Only `vendor_*` differs; iOS on slot b reads stock vendor_b, as tested.

No kernel change is needed. After an OTA flip iOS would read vendor_a of Lineage; its IPA firmware path is [U], and a miss turns off only IPA.

**dtbo [V code, ABL stops on a failed overlay: "Error: Dtb overlay failed"].** dtbo_b holds Lineage's dtbo now; Lineage's boot failed with stock dtbo [V], so the pairs matter. iOS has booted only with the stock DTB + stock dtbo [V]. So `dtbo_b` goes back to stock with `boot_b`. Slot a has its own dtbo_a [I].

### Q3. Root storage

**Mechanism [V, `external/laurel-kernel-los` fs/f2fs at 8aaa002b].**
- `F2FS_IOC_SET_PIN_FILE` exists (`file.c`). It refuses in LFS mode; `/data` has `mode=adaptive` [V phone].
- `fallocate` on a pinned file (`expand_inode_data`): whole segments, `F2FS_GET_BLOCK_PRE_DIO`, `CURSEG_COLD_DATA_PINNED`: real block addresses at once. Without the pin: `PRE_AIO`, no address. So pin first.
- FIEMAP: `phys = blk_to_logical(b_blocknr)`, the f2fs block address, which starts at block 0 of the filesystem device. `UNWRITTEN` only for `NEW_ADDR`; op10tool refuses it.
- Pinned file data is written in place (`f2fs_should_update_inplace`).
- GC: `move_data_page` and `move_data_block` return `-EAGAIN` for a pinned file. A checkpoint does not move data.
- Offset: [V phone] `/data` = dm-40, f2fs. [V] `CONFIG_DM_DEFAULT_KEY=y`, fstab `keydirectory=`, `ro.crypto.metadata.enabled=true`. [I, AOSP MetadataCrypt] the target is `default-key ... <sda15> 0` over the whole partition. dm-40 cannot be read without root. Two checks on the phone cover it: `check_dm` reads `dmctl table userdata`, and `check-map` is a proof: it writes through the file and sees exactly the named raw block change.
- dm-default-key encrypts what goes through dm-40. Our image goes to raw `sda15` by `ldbhelper`, and XNU reads raw. Reading the file through f2fs gives noise; nothing does that.

**What can damage or move the blocks, and what happens:**

| Android event | Effect | What stops harm |
| --- | --- | --- |
| Foreground GC with the disk nearly full: each failed try counts; **over 2048 tries f2fs clears the pin** (`f2fs_pin_file_control`, `gc_pin_file_thresh`) [V] | later GC moves the blocks and reuses them for Android data. iOS writing there would corrupt Android | keep >= 8 GiB free (`allocate` checks). `seal` re-pins, refuses >= 1024 failures, and compares FIEMAP with the table. The fingerprint below |
| GC of an encrypted file counts also in background GC (`move_data_block`) [V] | as above, sooner | The file is in the new top-level `/data/laurel-ios`, no FBE policy [I]. op10tool accepts the flag, `status` shows it |
| `rm`, app, script | blocks freed, then discarded (mount has `discard`) | immutable flag (`lock`) |
| Factory reset, Format data, `fastboot -w` | new filesystem, new metadata key | superblock + checkpoint fingerprint changes: iOS off, no write |
| Android runs without `switch` (retries ended, then `fastboot set_active b`) | anything above may have happened | the checkpoint fingerprint changes: iOS off until `switch` |
| OTA | slot b overwritten; `/data` untouched | section Q1 |
| fsck.f2fs at boot (fstab `check`) | [I] fixes metadata, does not relocate data | FIEMAP check at seal |
| FITRIM / idle maintenance | free segments only; urgent GC is background GC | pin |
| `gsid` | works only in `/data/gsi` [I] | another folder |
| userdata checkpoint | no `checkpoint=` in the fstab [V] | not used |
| F2FS resize, defragment, move-range ioctls | nobody calls them [I]. Defragment refuses a pinned file [V `f2fs_should_update_inplace`] | seal |

**The fingerprint.** `seal` writes area block 0 in state FRESH, with the places of the f2fs superblock and both checkpoint heads, on the way to a reboot. XNU's first boot hashes those raw blocks (ciphertext) and stores them: state BOUND. Each later boot compares. Any Android write sync changes a checkpoint [I, cp_interval 60 s], and any format changes all. A false alarm costs one `switch`; it cannot cost data.

**Size [V measured].** The existing iOS 16 root: HFS+ 16 GiB, 12010 MiB used. iOS 16 donor images 7484 MB -> root 12010 MiB: 1.68 x. iOS 26 donor iPhone12,1 23F84, decrypted on disk 2026-11-02 (the userland agent's files, nothing downloaded here): OS 8409579520, SystemOS 5221908480, AppOS 14680064 bytes (encrypted in the IPSW: 7180648448, 2013265920). `dual-boot.sh size ios26`: root about 21.4 GiB [I: 1.68 x from iOS 16; not measured for iOS 26], + 8 GiB /private/var (`VAR_GIB=`, `EXPAND=`, `DONOR_BYTES=`) = **SIZE=30G, area 30.01 GiB**. `/data` has 104 GiB free [V], so 74 GiB stay for Android. iOS 16 alone: 16.01 GiB. The size is a parameter of `allocate`. The HFS+ size is `SIZE=` of root.sh; the area must be >= volume + 1 MiB header + 4 MiB + 4 KiB log (both tools refuse less).

The one area holds one root. iOS 26 later = `remove`, `allocate` again, new table, new boot image.

**Fallback if pinned files fail on the phone:** decision D4: shrink userdata. It needs a GPT write and an Android wipe. No script exists for it.

## 3. What the iOS kernel can write: audit [V code, kernel tree of this branch]

The SCSI layer knows four commands: TEST UNIT READY, READ(10), WRITE(10), SYNCHRONIZE CACHE (`bsd/dev/sweet_ufs.c`). No UNMAP, no WRITE SAME. `ufs_write_blocks` is the one place WRITE(10) is built.

| Writer | Before 2950 | With 2950 |
| --- | --- | --- |
| HFS+ on `ufsroot0`, `/dev/rufsroot0` (fsck, raw users) | partition | only through the extent map; the fence checks again |
| **Console log thread**: last 4 MiB + 4 KiB of the partition, every 10 s, **once UFS is up, with nothing checking what the partition holds** | **a boot of any existing kernel writes into the end of Android's `/data`** | end of the mapped area. No table: only when the partition starts with HFS+ |
| rmtfs (`TopazModem.cpp`) | writes answered ok, dropped [V]; reads `sweet_ufs_read_part` | unchanged, read-only |
| `sweet_ufs_read_part`, `_part_info` users (modem, IPA, BT) | read-only | unchanged |
| boot log area N-28673 (negroni 0367, laurel 2900) | parked, not in the series [V `patches/laurel/parked`] | not built |
| panic: `d_dump = eno_dump` | nothing | nothing |
| LUNs other than 0, GPT | fence by LUN state and GPT lines; a change panics (`sweet_gpt_watch`) | fence also needs LUN 0 and the table |

Below the kernel, not changed by this work:
- Mu: `PcdEmuVariableNvModeEnable` TRUE [V], so `BootOrder` stays in RAM.
- Mu `PartitionDxe` writes a GPT **only when one copy of it is invalid** [V `Gpt.c`]. [U] whether Qualcomm's UFS driver lets it. This is the state of today's iOS boots too.
- Qualcomm DXE binaries: not audited.
- ABL writes slot attributes (its normal work).

Userland: `root-update`, `phone-metal.sh` go through HFS+. `scripts/fw/write-areas.sh` is for the NE2211 only (fixed partition size check).

## 4. Steps

All script steps: `scripts/laurel/dual-boot.sh`. Each writing step needs `CONFIRM=<step>`. **Agents run no writing step until the owner asks for that step.**

| # | Who | Step | Writes |
| --- | --- | --- | --- |
| 1 | Owner | Settings -> System -> Developer options -> Rooted debugging on | a setting |
| 2 | Agent | `adb root`, `dual-boot.sh status`, and `sha256sum` of `/dev/block/by-name/{modem,bluetooth,boot,dtbo}_b` against the stock ROM | nothing |
| 3 | Agent | `dual-boot.sh size ios16` (later `ios26`) | nothing |
| 4 | Owner yes, agent | `CONFIRM=allocate dual-boot.sh allocate 16.1`; it prints the extent count and writes `out/laurel/dualboot/table.ldbt` | a file in `/data` |
| 5 | Owner yes, agent | `CONFIRM=check-map dual-boot.sh check-map`: mapping proof, then immutable | that file |
| 6 | Owner yes, agent | `CONFIRM=install dual-boot.sh install` (tmux: `scripts/bg.sh db-install ...`, 10 min for 12 GB): reads back by hash | raw sda15, only in the table |
| 7 | Agent | `scripts/bg.sh db-image scripts/laurel/dual-boot.sh image`: boot image with the table. Root must also pass the usual `flash-check` | host only |
| 8 | Owner yes, owner cable | `adb reboot bootloader`, `CONFIRM=flash-slot-b dual-boot.sh flash-slot-b`; slot a stays active; `fastboot reboot`; **Android must start and open its data** | `boot_b`, `dtbo_b` |
| 9 | Owner yes, agent | `CONFIRM=switch dual-boot.sh switch` | area header, slot attributes |
| 10 | Owner | Watch iOS. Expected line: `LAUREL DUALBOOT: on: root = ... MiB in N extents of userdata, table ..., seal 1 (first boot after the seal), writes fenced to the table` | iOS root only |
| 11 | Owner or agent | Back: `out/bin/op10tool ctl bootloader`, `CONFIRM=to-android dual-boot.sh to-android`. **Android must open its data** | slot attributes |

Daily use: step 9, step 11. To read the iOS log from Android: `dual-boot.sh logs`. `root-update.sh` works over SSH when iOS reports `kern.laurel_dualboot=1`.

## 5. Recovery

| What you see | What it means | What to do | Who |
| --- | --- | --- | --- |
| iOS screen log `LAUREL DUALBOOT: off: ...`, restart after 30 s | self-check said no; **no block was written** | wait: ABL returns to Android after the retries; or Power + Vol Down, `fastboot set_active a`, `fastboot reboot` | Owner |
| `off: Android ran or /data was formatted` | normal after a fallback | on Android: `dual-boot.sh switch` | Agent |
| `off: no header ...` or `another table` | not installed, file allocated again, or old boot image | steps 7, 8 (table), or `remove` and step 4 on | Agent |
| `seal` says "the file moved", "shorter" or "cannot pin" | f2fs moved or lost it; the root content is gone | `remove`, free space, steps 4-9. Android is fine | Agent |
| iOS hangs, no USB, not the off line | kernel problem | hold Power: each boot costs a retry; ABL falls back | Owner |
| Slot stuck, ABL in fastboot ("no alternate slot") | slot a not marked successful | `fastboot set_active a`, `fastboot reboot` | Owner |
| Android does not start after iOS: logo loop or asks for reset | [U] Keymaster or slot state | **Do not wipe.** Power + Vol Down, `fastboot set_active a`; report the log. Lineage recovery from boot_a | Owner |
| Android on slot b after an update | OTA pitfall | `dual-boot.sh status`; do steps 7, 8 for slot a only after a new decision | Owner + agent |
| boot_b must go back | | `BOOTIMG=~/laurel-backup/lineage-24.0-20261027/boot.img ANDROID_IMAGE=1 scripts/laurel/flash-boot.sh`, and Lineage's dtbo.img to dtbo_b | Agent, owner yes |
| Remove all iOS | | `CONFIRM=remove dual-boot.sh remove`, then the line above | Agent, owner yes |
| Clean iOS install again, Android given up | | owner says so; `git rm config/laurel-android-data`; `root-flash-test.sh` | Owner |

## 6. Unproven: all of this needs the phone

- [U] Rooted debugging gives root with `ro.debuggable=0` (D1).
- [U] `bootctl` as root, HAL on this ABL, slot b state, retry count after `set-active`.
- [U] Android opens its data after an iOS boot. **Biggest risk.** No backup of `/data` exists here; decision D5.
- [U] pin, FIEMAP, `check-map`, `dmctl table` format on the phone; extent count (limit 4096); helper's aarch64 build has compiled, not run; SELinux of the su domain.
- [U] XNU boots from the table: the mapping code ran on a host against a RAM disk through the real `sweet_ufs.c`, with the SCSI command replaced.
- [U] Write speed over `adb exec-in`, HFS+ on the area at full load.
- [I] A checkpoint happens whenever Android has written. A crash right after boot could leave the checkpoint unchanged with new data in roll-forward nodes: the blocks of the pinned file are still not touched by that.
- Not defended: someone with root deleting the flag and file on purpose.

## 7. Owner decisions

| # | Decision | Recommendation |
| --- | --- | --- |
| D1 | Rooted debugging on. If it gives no root (`ro.debuggable=0`): another way to root (Magisk or KernelSU in boot_a, a boot_a write) | Try Rooted debugging first |
| D2 | Disable Lineage's Updater (`pm disable-user org.lineageos.updater`, a setting), or update and redo the boot steps | Disable until dual boot has run once |
| D3 | iOS writes slot attributes (GPT of the boot LUN) for a button "Android" | Not now. If wanted: a Mu or XNU piece with its own fence, later |
| D4 | Fallback: shrink userdata (GPT write + Android wipe) | Only if pinned files fail on the phone |
| D5 | Back up Android's data before step 8 | Yes: apps' data cannot be restored when the keys fail |
| D6 | Area size: 16.1 GiB for iOS 16 now, or 30.1 GiB now to keep it for iOS 26 | 30.1: `SIZE=16G` root fits, later only a new volume |

## 8. Build and test

- Kernel: `patches/laurel/xnu/2950-laurel-dual-boot.patch`. `scripts/laurel/kernel-linux.sh`.
- Host test: `scripts/laurel/test-dualboot.sh` (needs the kernel tree: `AUDIT=1 scripts/laurel/kernel-linux.sh`).
- Tools: `op10tool dualboot {table,check,show,stream,size}`, `tools/laurel-dualboot/ldbhelper.c`, `laurel_dualboot.h` (kernel + helper share it), `scripts/laurel/ota-partitions.py`.
- Guard: `scripts/laurel/android-guard.sh`, flag `config/laurel-android-data`. Refuses in: flash-root, root-flash-test, update-phone, root-update (real + rollback), flash-boot, boot-test, fastboot-drain.py (userdata, metadata, boot), scripts/flash/{ios16,all,restore,reflash-root via ios16}. No environment switch; `ANDROID_IMAGE=1` passes only an image with no iOS payload.
- Results [V, host only] 2026-11-02, commit 03c7ed146a: kernel 310/310 patches, 0 LSE/RCpc, printf check OK, sha256 afab8ee2a6cd3c08...; `test-dualboot.sh` PASS: 11 op10tool tests, 40496 checks in the real `sweet_ufs.c` (37349 random I/Os across extents, 0 blocks outside the table changed; 12 bad addresses + wrong LUN fenced; 20 refused states with the disk byte-identical), helper on a fake partition, 29 guard checks. `build-honest-test.sh` 60/60, `root-update-test.sh` 94/94.
