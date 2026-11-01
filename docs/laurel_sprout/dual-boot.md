# Mi A3: dual boot LineageOS and iOS 26, with a real partition

Owner decisions 2026-11-02: iOS gets the partition `iosroot` on LUN 0. One GPT write on LUN 0 of the Mi A3 only, and one Android data wipe, are approved. This changes nothing for other partitions, other LUNs or the OnePlus. **The first boot on the new partition is iOS 26.** If it fails, the phone goes back to Android, and work goes on the next day.

**Nothing here has run on the phone. Not one write step was run.** Marks: [V] measured or read in a source, [I] inference, [U] unknown. The old design, and why it was dropped: section 9.

**Choosing on the phone (menu in Mu, one-tap app in Android): `boot-menu.md`.** It comes after step 12: the read-only image has no menu, and the app refuses to start it.

## 1. The steps

All script steps: `scripts/laurel/dual-boot.sh`. Each writing step needs `CONFIRM=<step>`. **Agents run no writing step until the owner asks for that step.**

| # | Who | Step | Writes |
| --- | --- | --- | --- |
| 0 | Owner yes, agent | Rooted debugging on (Settings -> System -> Developer options). A backup right before the first write: `scripts/backup/laurel-backup.sh` (rerun `data`; the wipe takes all app data). The newest backup with `gpt-sda-head.bin` is what the plan reads | a setting, files on the host |
| 1 | Agent | `adb root`, `dual-boot.sh check-slot-b`, `dual-boot.sh gpt-write --dry-run`: device check, fresh on-disk table = backup, the exact commands, the table before and after | nothing |
| 2 | Owner yes, agent | `CONFIRM=gpt-write dual-boot.sh gpt-write`: the write, then read back past the page cache and compared with the plan, before any reboot | 4 table blocks + 2 superblock blocks of userdata |
| 3 | Agent, right after | `adb reboot bootloader`, `CONFIRM=after-gpt dual-boot.sh after-gpt`: ABL must show the new sizes; reboots to recovery | nothing |
| 4 | Owner | Lineage recovery: Factory reset -> Format data / factory reset -> yes; Reboot system now. Android sets itself up. Unlock once; Rooted debugging on again (the wipe turned it off) | all of userdata, metadata |
| 5 | Agent | `adb root`, `dual-boot.sh android-check`: new sizes, `/data` on the new size, f2fs block count fits, data open. A record on the host | nothing |
| 6 | Owner yes, agent | `adb reboot bootloader`; `scripts/bg.sh db-install env CONFIRM=install scripts/laurel/dual-boot.sh install` (default the iOS 26 root). Android starts after it | `iosroot` only |
| 7 | Agent | `scripts/bg.sh db-image scripts/laurel/dual-boot.sh image`: read-only image (kernel of `kernel-ios26-linux.sh` through `ios26-image.sh`, no `ufsrw`, no `rootrw`) | host only |
| 8 | Owner yes, owner cable | `adb reboot bootloader`, `CONFIRM=flash-slot-b dual-boot.sh flash-slot-b`, `fastboot reboot`. **Android must start** | `boot_b`, `dtbo_b` |
| 9 | Owner yes, agent | `CONFIRM=switch dual-boot.sh switch`: all checks, then `bootctl set-active-boot-slot 1`, then a normal `adb reboot` | slot attributes |
| 10 | Owner | Read the `LAUREL DUALBOOT` line on the screen or with `scripts/debug/usblog.sh`. Then `dual-boot.sh ro-result LOG` (a USB log, or a file with the line typed in). Section 5 | host only |
| 11 | Owner + agent | **Back to Android, one step:** Power + Vol Down, then `CONFIRM=to-android dual-boot.sh to-android`. Then `adb root`, `dual-boot.sh android-check`. **Android must open its data** | slot attributes |
| 12 | Owner yes | Only after 10 and 11: `dual-boot.sh image rw`, `CONFIRM=flash-slot-b dual-boot.sh flash-slot-b rw`, `CONFIRM=switch dual-boot.sh switch rw`. The guard refuses a writable image with no result on record, from any script | `boot_b`, `dtbo_b`, slot attributes, then iOS writes `iosroot` |

If step 10 or any iOS boot fails: step 11, and work goes on the next day. No computer: the retries of slot b end after 7 boots and ABL returns to Android [V source, I this ABL]. A hanging kernel does not restart itself: hold Power for each boot, or use step 11.

iOS 16 stays supported: `TARGET=ios16` in front of `image`, `flash-slot-b`, `install`, `switch`. It is not the first path. Its kernel also needs the new patch 2950.

## 2. The layout

[V, `~/laurel-backup/android-20261102-0137/gpt-sda-head.bin`, `-tail.bin`, read and checked by `op10tool gpt`] LUN 0 (sda): 30119936 blocks of 4096 bytes. Primary header LBA 1, entries LBA 2, 32 slots of 128 bytes, 15 used. Backup entries LBA 30119931, backup header LBA 30119935. Usable 6..30119930.

| Partition (number) | First | Last | Bytes |
| --- | --- | --- | --- |
| 1-14 `ssd` .. `metadata` | unchanged | unchanged, byte-identical | |
| 15 `userdata` before | 1831432 | 30119930 | 115869691904 (107.9 GiB) |
| 15 `userdata` after | 1831432 | 21633535 | 81109417984 (75.5 GiB), 70.00 % of the old size; start, type GUID, unique GUID, attributes kept |
| 16 `iosroot` new | 21633536 (on a 2 MiB boundary) | 30119930 | **34760273920** (32.37 GiB) |

The one place for these numbers: `scripts/lib/laurel-layout.sh`. `test-dualboot.sh` compares it with `op10tool gpt plan`.

**The roots.** The iOS 26 root that exists, `ios26-root.img`, is 34354491392 bytes (`scripts/laurel/ios26-root.sh` takes it from `IOS26_VOLUME_BYTES` in the layout file). `iosroot` must hold the volume + the console log (1025 blocks = 4198400 bytes) = 34358689792 bytes. **Margin: 401584128 bytes (383 MiB).** The largest volume: `IOSROOT_VOLUME_MAX` = 34756075520 bytes. The old iOS 16 root (16 GiB) fits.

**Rebuild? No.** [V code] The image is a plain HFS+ volume; its block 0 is block 0 of the BSD disk. The old reserved header was not in the image: it lay in the area in front of the BSD disk (256 blocks the kernel skipped). In the new layout the BSD disk starts at the start of `iosroot`, so the same bytes are right at offset 0. [I, as the old 16 GiB root in the 108 GiB userdata] HFS+ mounts a volume smaller than its disk. The 383 MiB stay unused. A later `ios26-root.sh` with a larger `IOS26_VOLUME_BYTES` is free to take them.

Boot selection is unchanged: A/B slots. Lineage on slot a, Mu + DarwinBoot + XNU on `boot_b` + stock `dtbo_b` [V: stock dtbo is what iOS has booted with; Lineage's boot fails with it, so the pairs matter]. `ufs_find_partition` is LUN 0 only, and the kernel takes no boot-arg for the partition.

## 3. How the GPT is written

| Way | What happens | Verdict |
| --- | --- | --- |
| (b) ABL `fastboot flash partition:0 <gpt_both0-style image>` | [V QRD-Development/abl uefi.lnx.3.0.r12-rel `PartitionTableUpdate.c` `WriteGpt`: `/* Erase the entire card */ ErasePartition (BlockIo, ...)`, before the write. I this phone's ABL acts the same] **It erases all of LUN 0: ssd, persist, misc, keystore, frp, product_a/b, odm_a/b, oem, minidump, system_a/b, metadata, userdata.** `persist` is unique to the phone. [V] `partition` is a critical partition: needs the unlock_critical state [U on this phone]. [V] `PatchGpt` also rewrites the last entry and the usable range. No read-back. | **Rejected.** Last resort only: section 8 |
| (a) `sgdisk` on the phone | [V AOSP `external/gptfdisk` `gpt.cc` `SaveGPTData`] Writes backup table, backup header, main table, main header, MBR, then asks the kernel to re-read (busy with `/data` mounted [I]). Warns at 32 slots (under 16 KiB, line 356). Needs several flags to keep the GUIDs and attributes of `userdata`. Rewrites the MBR. Its order is fine, but what it writes is known only afterwards | Not chosen. Useful as a read-only second look: `sgdisk -p /dev/block/sda` |
| (c) `ldbhelper gpt-write` with a plan from `op10tool gpt plan` | Exact bytes, computed and checked on the host from the backup, with no phone. Each old block must equal the plan's before it is written. `O_DIRECT` + `O_SYNC`: each write and read goes past the page cache. No `BLKRRPART`. | **Chosen.** Of the three, it alone compares the planned bytes **before any reboot** with no extra tool |

Order of the writes (`tools/op10tool/src/gpt.rs` `plan_bytes`, `ldbhelper.c` `cmd_write`):

1. backup entries, LBA 30119931. 2. backup header, LBA 30119935. These two prove that this device takes writes. A refusal here (SELinux, a read-only LUN) destroys nothing.
3. zero the two f2fs superblock blocks of `userdata`, LBA 1831432 + 2 blocks, read back.
4. primary header + entries, LBA 1 + 2, **in one write command**. Up to here the old table rules; after it the new one.

Then the helper reads all of it back, and the host reads it again with `gpt-dump` and runs `op10tool gpt verify-new`: every rule, plus equal to the planned bytes.

**Which table rules when, and a power cut at each moment.** [V kernel `block/partitions/efi.c`: without the `gpt` boot-arg the backup is read only when the primary is valid: a bad primary means no partitions on sda.]

| Power lost after | Primary | Backup | Next Android boot | What to do |
| --- | --- | --- | --- | --- |
| before step 1 | old, valid | old | normal | start again |
| step 1 | old, valid | invalid | normal; Linux reads the primary [V] | `gpt-write --resume` |
| step 2 | old, valid | new, valid | normal, old table | `gpt-write --resume` |
| step 3 | old, valid | new, valid | old table; [I] `partition_wiped` true for raw block 0, so init formats `userdata` at the old size: Android restarts empty | `gpt-write --resume`. The wipe was approved |
| inside step 4 | [U] one UFS command: the device may finish it or not | new, valid | if the primary is bad: no sda partitions, no `system_a`, Android does not start. [I] Mu or ABL `PartitionDxe` may restore the primary from the backup | section 8: helper from a root shell in recovery |
| after step 4 | new | new | new table, no old superblock | steps 3, 4 of section 1 |

`--resume` accepts only "the first steps new, the rest old, block for block". Anything else stops. Host tests cover a stop after steps 1, 2, 3. They do not show what UFS does at a power loss [U].

**The running `/data` between the write and the wipe.** The running kernel keeps the old table until its reboot: no re-read is asked. `/data` stays mounted on the old range through dm-default-key. Its writes can land in what will be `iosroot`: nothing is there yet, and `install` comes later. The superblock is in memory; the zeroed copy on flash has no effect until the next mount. [V 4.14 tree] `f2fs_commit_super` has callers for resize, sysfs, an ioctl in `file.c`, and a few paths in `super.c`; a run of one before the reboot could write a valid superblock again: step 4 of section 1 still removes it. So: reboot right after the write. Android data written after the write is lost anyway.

**Slot attributes write the table too.** [V LineageOS `boot_control.cpp`: `AB_PTN_LIST`, `gpt_disk_commit`] `set-active-boot-slot` rewrites GPT copies of the LUNs that hold slot partitions. [V backup] `system_a` on LUN 0 has attribute 0x7f000000000000. [I] So LUN 0 is among them. The first read must equal the backup, but later the attributes change. The kernel's rules do not compare attributes with numbers, only the two copies with each other. [I] The HAL handles 16 entries as 15: it uses the header's values.

## 4. Android after the write

**Format data in recovery is the way; no reinstall of Lineage.** [V sources LineageOS lineage-23.0, I the same on the phone's 24.0]
- `install/wipe_data.cpp` `WipeData`: erases `/data`, `/cache` if there, `/metadata`.
- `recovery_utils/roots.cpp` `format_volume`, for a volume with a metadata key dir, `length == 0`: wipes the whole block device (`wipe_block_device`, size from the device) and leaves the format to the next boot. [V fstab] `userdata`: `keydirectory=/metadata/vold/metadata_encryption`, no `length=`. The device is `by-name/userdata` under the new table: `iosroot` is not touched.
- `fs_mgr.cpp` `fs_mgr_mount_all`: mount fails, `partition_wiped` + `formattable` -> `vdc cryptfs encryptFstab ... shouldFormat`.
- `vold MetadataCrypt.cpp`: new key if none, `DmTargetDefaultKey` over `get_number_of_sectors(blk_device)`: the new size. `fs/F2fs.cpp` `Format`: `make_f2fs -g android` on that device.
- Nothing in that path needs `system_a`, `product_a`, `odm_a`, `vendor_a` to change, and the table leaves them byte-identical. So Lineage stays installed.

**`fastboot -w` is wrong here** [I]: it formats a plain f2fs image from the host. Metadata encryption expects ciphertext on the raw device, and the block is not wiped, so no format follows, and the mount fails to the recovery prompt.

**fstab.** `reserve_root=32768,resgid=1065` and `reservedsize=128M` are mount options, not geometry. No `resize` flag, no `length=`, no `encryptable=footer`, no crypto footer [V `rootdir/etc/fstab.qcom`].

**A stale superblock on the smaller partition must be impossible.** [V 4.14 `fs/f2fs/super.c`] `sanity_check_raw_super` compares fields inside the superblock; I found no compare with the device size in it. So the kernel check is **not** the protection. These are:
1. The superblock blocks are zeroed **before** the new table is valid (step 3 of the write). A new table never meets an old superblock, unless a `f2fs_commit_super` rewrites it before the reboot (section 3).
2. The format in recovery: all blocks wiped, `/metadata` wiped, so a new metadata key: an old superblock would decrypt to noise.
3. If the owner skips the format: raw block 0 is zero, `partition_wiped` [I from memory of its code, not read here] is true, and init formats at the new size.
4. `android-check` reads the superblock through the decrypting device and refuses a block count over the new size. `install` and `switch` need its record.

The device-mapper target ends at the new size [V vold], so even a stale mount could not write into `iosroot`.

## 5. The read-only first boot, iOS 26

**Can it reach the `LAUREL DUALBOOT: on` line?** [V code] Yes, if the iOS 26 kernel reaches its root device search. `sweet_ufs_rootdev` runs at the root search, and `sweet_ufs_init` prints the line before the root mounts, with or without `ufsrw`. [V host] Tested in the real driver of the iOS 16 tree; the iOS 26 tree carries the same patch and compiles. [U] **The iOS 26 kernel has never booted**: it can stop anywhere before that.

**What it shows:**
`LAUREL DUALBOOT: on: root = iosroot, LUN 0, first block 21633536, 8486395 blocks (33149 MiB), read-only (LAUREL-2950-IOSROOT-FENCE-V3)`
Or `LAUREL DUALBOOT: off: <reason>; no write anywhere`, then a restart after 30 s.

**After that line** [V code for the first two, U for the rest]: `su.writable` is false, so `ufs_write_blocks` refuses all and the log thread does not start. `rootrw` is absent, so the root mounts read-only (`vfs_subr.c`). `launchd` starts with no writable `/private/var`. **Expect no UI.** It may hang or panic; that is not a failure of this step. The USB log and the screen are the only output: nothing is written to `iosroot`.

**Why this boot stays: one extra flash and one boot.** It is the one way to compare the fence's numbers from real hardware with the plan, and to test "Android opens its data after an iOS boot" with no chance that iOS changed anything. A writable first boot with a wrong number could damage Android. The kernel's rules make that unlikely on the host; only the phone shows it. `ro-result` compares the line with the plan: first block, block count, marker, `read-only`.

`dual-boot.sh ro-result`, then Android must open its data (`android-check`); only then the guard lets a writable image go, from `flash-slot-b`, `flash-boot.sh`, `boot-test.sh` and the rest. A new marker needs a new read-only run. A sidecar with no mode line counts as writable.

## 6. What the iOS kernel can write: audit [V code, patch 2950]

The SCSI layer knows four commands: TEST UNIT READY, READ(10), WRITE(10), SYNCHRONIZE CACHE. `ufs_write_blocks` is the one place WRITE(10) is built.

| Writer | With 2950 |
| --- | --- |
| HFS+ on `ufsroot0`, `/dev/rufsroot0` | only inside `iosroot`, LUN 0 |
| Console log thread: last 1025 blocks of the partition, every 10 s | the last 1025 blocks of `iosroot`. Only with `ufsrw=1` |
| rmtfs (`TopazModem.cpp`) | writes answered ok, dropped; reads through `sweet_ufs_read_part`, read-only |
| `sweet_ufs_read_part`, `_part_info` (modem, IPA, BT firmware) | read-only |
| panic: `d_dump = eno_dump` | nothing |

The self-check, all reads, before a write can happen (`ldb_self_check`, `laurel_dualboot.h`): both GPT copies valid (signature, header and entries CRC, each at the block it names) and equal; 32 slots, 16 used, no hole; each partition follows the one before; slots 14, 15, 16 = `metadata`, `userdata`, `iosroot`; no second `iosroot`; `iosroot` on 2 MiB, up to the last usable block, attributes 0; an HFS+ volume with room for the log. The rules are general: no block number of this one phone. A failure: one `off` line, no write anywhere, restart after 30 s. Kill switch `laureldualboot=0`.

The fence compares each LBA with what the self-check found, and su's numbers too, and LUN 0, and stays shut if the self-check did not pass. `sweet_gpt_watch` panics if the GPT changes during the session. **A kernel without this patch takes `userdata` as its root and writes its log to the end of it**: `uefi-image.sh` refuses to build, and `android-guard.sh boot-image` refuses to flash, an image without the marker text `LAUREL-2950-IOSROOT-FENCE-V3`. The marker of the file design is refused too.

Below the kernel, not changed: Mu `PartitionDxe` writes a GPT only when one copy is invalid [V `Gpt.c`]; ABL writes slot attributes; Qualcomm DXE binaries are not audited.

## 7. Keys: the boot image header (S1)

- [V backup, header bytes] Lineage's `boot.img`: raw 0x220001aa = **17.0.0, 2026-10**. Stock image and the old iOS image: 11.0.0, 2022-08.
- [V ABL r12 `VerifiedBoot.c` lines 1437-1475] `SystemVersion` always comes from the header it loaded. `SystemSecurityLevel` comes from the slot's vbmeta property `com.android.build.boot.security_patch` when the keymaster TA has date support and the property is there; else from the header.
- [V backup, strings] `com.android.build.boot.security_patch` = 2022-08-01 in vbmeta_a, vbmeta_b, and Lineage's vbmeta.
- [V ABL `KeymasterClient.c` `KeyMasterSetRotAndBootState`] For state ORANGE the root-of-trust digest is the hash of only the unlocked flag, with no public key, and the boot state digest is zero. [I] So with an unlocked bootloader, Lineage and iOS give TrustZone the same root of trust.
- **Done:** the iOS image on `boot_b` now takes `os_version` and `os_patch_level` from `~/laurel-backup/lineage-*/boot.img` as a build input (`uefi-image.sh`). The guard refuses another value, and `switch` compares with `boot_a` on the phone (a sideload changes it).

**What this settles** [I]: in either branch of the source above, ABL sends TrustZone the same version and patch level for an iOS boot as for a Lineage boot. The specific cause "version 11 reported between two boots of version 17" is gone from what we send.

**What it does not settle** [U]: this phone's ABL may differ from r12. Whether TrustZone keeps anything across a boot. Other inputs differ between the slots: the vbmeta digest (`SetVerifiedBootHash`; slot b has stock vbmeta_b). Whether the keymaster TA reacts to any of it. **The risk is not gone. Only a phone run shows it:** step 11 of section 1 is that test, right after a boot where iOS could write nothing. A failure there costs Android's data since the format, and needs another Format data.

## 8. Recovery

| What you see | What it means | What to do | Who |
| --- | --- | --- | --- |
| **Any failed iOS boot** | | **Power + Vol Down, `CONFIRM=to-android dual-boot.sh to-android`.** Or wait out the 7 retries with Power | Owner |
| iOS line `LAUREL DUALBOOT: off: ...`, restart after 30 s | self-check said no; no block was written | as above; read the reason | Owner |
| `gpt-write` says "not the backup" | the table changed since the backup (slot attributes?) | stop. Nothing written. A new backup of the table, a new decision | Agent |
| `gpt-write` failed or adb lost, `Do not reboot` | a state of the plan or unknown | `CONFIRM=gpt-write dual-boot.sh gpt-write --resume`: goes on only from a state of the plan | Agent |
| `gpt-write` refuses with EPERM | SELinux or a read-only LUN [U] | steps 1, 2 are refused first: nothing destroyed. Old table rules | Agent |
| `after-gpt`: ABL shows other sizes | table not as planned | stop, do not format. Report it. `gpt-restore` needs Android or a root shell in recovery | Agent |
| Recovery does not start from `after-gpt` | [U] `reboot-recovery` [V in ABL source] on this ABL | Power + Vol Up [I], or `fastboot reboot` and let init format (section 4) | Owner |
| Android after the wipe: recovery prompt or logo loop | format did not run | Recovery: Format data again. Then `android-check` | Owner |
| Android does not start after iOS: logo loop or asks for reset | [U] Keymaster or slot state | Power + Vol Down, `to-android`; report the log. Then Format data costs only what Android holds | Owner |
| `android-check`: stale superblock | the format did not run | Recovery: Format data | Owner |
| `switch`: `xbl_b` etc. differ | slot b boot chain is not the backup's | stop. Do not set slot b active | Agent |
| `switch`: `boot_b ... is not` or `manual update`, or `boot_a` header differs | a sideload wrote slot b or a new Lineage | sideload the same zip again so that Android is on slot a; new backup of `boot.img`; steps 7, 8 | Agent |
| Slot stuck, ABL in fastboot ("no alternate slot") | slot a not marked successful | `to-android` | Owner |
| Android restarts on slot b without end, before the first `switch` | slot b is marked successful today | `to-android` | Owner |
| `boot_b` must go back | | `ANDROID_IMAGE=1 scripts/laurel/flash-boot.sh ~/laurel-backup/lineage-24.0-20261027/boot.img`, and Lineage's `dtbo.img` to `dtbo_b`. Only Lineage's hash passes the guard | Agent, owner yes |
| **The old table back** | a boot on the new table fails and the table is the suspect | Android or a root shell in recovery [U whether Lineage recovery gives one on this build]: `CONFIRM=gpt-restore dual-boot.sh gpt-restore`, then Format data | Agent, owner yes |
| **The old table, no shell anywhere** | | **Fastboot cannot restore only the table.** `dual-boot.sh gpt-restore-print` prints the last resort, runs nothing: `fastboot flash partition:0` **erases all of LUN 0**, needs unlock_critical [U], then each partition from the backup, `persist` included: a separate owner decision. `gpt_both0.bin` of the stock ROM is **not** this table (other values in all 15 entries, usable range ends at 1831431): use the printed image | Owner |

## 9. The old design, and why it was dropped

The root was a pinned, preallocated f2fs file in `/data`, written raw, reached by an extent table in the ADT; a seal froze `/data`, took a fingerprint of the checkpoint heads, and rebooted without unmount. It avoided the GPT write and the wipe. It was dropped (owner, 2026-11-02). Its safety depended on f2fs behaviour no host test here could prove on the 4.14 kernel (pin loss after failed GC blocks, freeze timing, a watchdog thaw), and every `switch` was an unclean shutdown for Android. All of its code is gone: `op10tool dualboot`, the ADT table, the seal, the fingerprint. Git history has it: 5f84bae.

## 10. Unproven: all of this needs the phone

- [U] `gpt-write` on the real `/dev/block/sda`: SELinux of the `su` domain, `O_DIRECT`, `BLKROGET`. Host tests use a file.
- [U] ABL reads the new table; `getvar partition-size:iosroot`; `fastboot flash iosroot` of a 34 GB sparse image in 512 MiB pieces (the 12 GB iOS 16 flash worked [V], and ABL can hang after it [V]).
- [U] Format data + first boot give f2fs at the new size with metadata encryption (sources read: section 4).
- [U] `by-name/iosroot` = sda16. [V] sde16 exists on this phone, so a partition 16 works in this kernel.
- [U] The iOS 26 kernel boots at all.
- [U] Android opens its data after an iOS boot. Biggest risk: section 7.
- [U] `bootctl` as this repo reads it, on this binary. [V source] true = stdout `1`, exit 0; false = stdout `0`, exit 70; a HAL error = text on stderr, exit 70. A form that differs stops `switch` with a clear message.
- [V] Read-back after `install` is only the first 1 MiB (`switch` compares it): a full read-back is left for later. A wrong root costs a failed iOS boot, not Android's data.

## 11. Owner decisions

| # | Decision | State |
| --- | --- | --- |
| D1 | Rooted debugging | Done; on again after the wipe |
| D2 | Lineage's Updater disabled. A sideload still writes slot b: `switch` refuses | Done |
| D3 | Selecting the OS from the device (owner requirement 2026-11-02), for example iOS writes slot attributes for a button "Android", and a switch on Android with no computer | **Not built here, and needed.** This branch needs a computer for `switch` and for the fast way back; with no computer only the 7 retries return to Android. A write of slot attributes from iOS needs its own fence: LUN 0 is the only LUN the fence allows, and only `iosroot` |
| D8 | One GPT write on LUN 0, one data wipe | Approved 2026-11-02 |
| D9 | First boot on the new partition is iOS 26 | Decided 2026-11-02 |

## 12. Build and test

- Kernel: `patches/laurel/xnu/2950-laurel-dual-boot.patch`, in both series. `scripts/laurel/kernel-ios26-linux.sh`, `scripts/laurel/kernel-linux.sh`.
- Host test: `scripts/bg.sh db-test scripts/laurel/test-dualboot.sh` (needs the kernel tree: `AUDIT=1 scripts/laurel/kernel-linux.sh`). It runs: op10tool tests with the real layout from the backup when present; `sweet_ufs.c` over a RAM disk; `ldbhelper-test.sh` (a sparse disk, a stop after each step); `android-guard-test.sh`, `dual-boot-test.sh` (fake adb and fastboot; PATH holds no real one, checked first).
- Do the tests find the defects: `scripts/bg.sh db-detect scripts/laurel/dualboot-tests-detect.sh`: each fix taken out of a copy; the test that names it must fail.
- Tools (first `scripts/setup/build-op10tool.sh`: `out/bin/op10tool` needs the `gpt` command): `op10tool gpt {plan,same,verify-new,image}`, `tools/laurel-dualboot/ldbhelper.c`, `laurel_dualboot.h`, `scripts/lib/laurel-layout.sh`, `scripts/laurel/gpt-fake.py` (fixture: names and numbers, no bytes of a real table).
- Guard: `scripts/laurel/android-guard.sh`, flag `config/laurel-android-data`. `userdata`: refuses the old whole-partition flash (`root-flash-test.sh`, `fastboot-drain.py`). `flash-root.sh` writes only `iosroot` and checks the size first. `boot-image`: marker, Lineage header, read-only gate. `ANDROID_IMAGE=1`: only Lineage's hash from the backup, and no iOS text. `other-device` for the OnePlus scripts, with `test-boot.sh` now among them.

Results: docs/plan.md, last entry.
