# Mi A3: dual boot LineageOS and iOS, no wipe, no GPT change

Owner goal (2026-11-02): LineageOS 24 and iOS on one phone, Android keeps working. iOS 16 root first, because it exists, then iOS 26. **Nothing here has run on the phone.** Not one write step was run. Marks: [V] measured or read in source, [I] inference, [U] unknown.

## 1. Recommendation

| Part | Choice |
| --- | --- |
| Boot selection | A/B slots. Lineage on slot a (as now). Mu + DarwinBoot + XNU on `boot_b`, stock `dtbo_b`. |
| Android -> iOS | `dual-boot.sh switch`: root adb, `bootctl set-active-boot-slot 1`, then `ldbhelper seal`: `/data` frozen, pin + FIEMAP check, fingerprint, header, immediate reboot with no unmount. |
| iOS -> Android | `fastboot set_active a`, or ABL's fallback when the retries of slot b end. No iOS GPT write (owner decision D3). |
| iOS root | A pinned, preallocated f2fs file in `/data`, written raw on `sda15`. XNU reads a table of extents from the boot image and never parses f2fs. **Default size `SIZE=32G`** (owner, 2026-11-02: about 70 % Android, 30 % iOS). |
| Safety | One write fence in `ufs_write_blocks`. A self-check before any write, with one state that passes (BOUND) and a fingerprint from a frozen `/data`. Failure = no write anywhere, restart, ABL falls back to Android. |

## 2. Design answers

### Q1. Boot selection

- [V phone] Android runs on slot a: `ro.boot.slot_suffix=_a`, `/` = sda12 (system_a), `/vendor` = sde16 (vendor_a), `/vendor/firmware_mnt` = sde4 (modem_a).
- [V phone 2026-11-02, read by the owner's agent] The owner turned on Rooted debugging; `adb root` gives uid 0; SELinux is Enforcing. `/dev/block/*`, slot attributes and `/sys/fs/f2fs` need root. **What system_b, vendor_b, modem_b hold now: not read yet.** [I] They are stock: `docs/flash-lineageos.md` wrote only boot_b and dtbo_b on slot b, and the sideload wrote slot a. Check at step 2 of section 4.
- [V phone 2026-11-02] `bootctl` is `/system/bin/bootctl`: number-slots 2, current 0, active 0; slots 0 and 1 both bootable and **both marked successful**. `/data/gsi/{dsu,ota,remount}` exist. `/data` mount options: f2fs `background_gc=on,discard,mode=adaptive`.
- [V source, QRD-Development/abl uefi.lnx.3.0.r12-rel; I that this phone's ABL acts the same] `FindBootableSlot`: a slot not successful with retries > 0: retries - 1 and boot. Retries 0: mark unbootable, `HandleActiveSlotUnbootable` takes the slot with successful = 1, not unbootable, highest priority > 0, sets it active and resets. No such slot: boot fails to fastboot. The count does not fall in fastboot, recovery or charger mode (`IsABRetryCountUpdateRequired`).
- [V phone history] The fallback works from `fastboot set_active b` (device-state notes: "it moved from b to a by itself").
- [V source, LineageOS bootctrl lineage-24.0-caf, `boot_control.cpp`, `gpt-utils.h`] `set_active_boot_slot` writes byte 0x3F to slot b (priority 3, active, 7 retries) and only clears the active bit of slot a, so slot a keeps its priority and fallback stays possible. It also moves the UFS boot LUN to xbl_b. [I] This binary is on the phone (`android.hardware.boot-service.qti` [V present]).
- [V source] HAL `mark_boot_successful` is what sets slot a successful; iOS never does. So one `switch` gives iOS **at most 7 boots**, then the phone returns to Android [I].

**Slot b marked successful today: what it changes.**
- [V source, byte 0x3F = priority 3, active, 7 retries, successful clear, unbootable clear; I that this phone acts the same] `set-active-boot-slot 1` clears slot b's successful bit, so ABL counts down from 7. Slot a loses only its active bit: it stays successful, so it is the fallback target. `switch` checks all this and stops if it is not so: slot a bootable and successful before the flip; active = 1 and slot b **not** successful after it. A slot b that stays successful: `switch` goes back to slot a and makes no seal.
- [I] Until the first `switch`, slot b is a fallback target in ABL's rule (successful, not unbootable). If slot a ever fails in ABL (retries end after a `fastboot set_active a`, or its image does not verify), ABL lands on slot b, **with iOS on it after step 8, and successful set, so it does not count down**. For the data this is safe: the kernel compares the fingerprint, stays off and writes nothing. But the phone then restarts on slot b without end until `fastboot set_active a`. After the first `switch` this cannot happen: slot b's bit is clear.
- [I] From slot b the only fallback target is slot a. A fallback cannot land on an unexpected slot then: two slots exist, and slot b is not successful.
- [V source, I this HAL] `set-active-boot-slot 0` writes 0x3F to slot a, so it **clears slot a's successful bit**. Because of that, the way back after a failed `switch` is `set-active-boot-slot 0` + `mark-boot-successful`, both checked.
- [I from memory of ABL source, not read here] `fastboot set_active a` clears the successful bit too, until Android has booted to the end.

**Android -> iOS.** Needs root adb, because `bootctl` from shell says "Failed to get bootctl module" [V]. The order is fixed: section "The fingerprint".

**iOS -> Android**, three ways:
1. `op10tool ctl bootloader` (or Power + Vol Down), then `fastboot set_active a`. Needs a computer. No write from iOS. Recommended now.
2. Reboot iOS until the retries end. No computer. Up to 7 boots. ABL writes the attributes, not iOS.
3. iOS writes the slot attributes in the GPT of the boot LUN. Not built. Decision D3. A bug there can destroy a GPT, and today the kernel cannot write a GPT at all (`ufs_write_blocks` fence, LUN 0 only).

**Updates: a manual sideload still writes slot b [V partition list, I behaviour].** Lineage's Updater is disabled (owner decision, 2026-11-02). A manual update (sideload) from slot a writes all 22 partitions of slot b (list below) and makes b active: `boot_b` and `dtbo_b` are gone, Android moves to b, iOS has no boot image. The file in `/data` stays. `dual-boot.sh switch` refuses when:
- Android does not run on slot a, or `bootctl` says the current slot is not 0;
- slot a is not active (an update is done and waits for its reboot);
- `boot_b` or `dtbo_b` on the phone are not the image and the stock dtbo on the host (it reads them with `head -c N | sha256sum`).

The way back after a manual update, with no wipe: the table and the file stay, so only the slot b steps come again.
1. Sideload the same zip once more: it goes to slot a, and Android is on slot a again. (Do not use `fastboot set_active a` here: slot a holds the older system, and Android refuses or damages data on a downgrade [I].)
2. Check: `dual-boot.sh status` says slot a current and active.
3. Section 4 steps 7, 8: `dual-boot.sh image`, then `flash-slot-b`.
4. `dual-boot.sh switch`: its seal takes a new fingerprint.

The sideload also rewrites `modem_b`, `vendor_b` and others: section Q2 says iOS gets the same firmware.

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
- Offset: [V phone] `/data` = dm-40, f2fs. [V phone 2026-11-02] `dmctl table userdata` = `0-226307992: default-key, aes-xts-plain64 - 0 8:15 0 3 allow_discards sector_size:4096 iv_large_sectors`: the f2fs volume maps 1:1 to 8:15 (sda15) from start 0. 226307992 sectors x 512 = 115869691904 bytes, equal to `blockdev --getsize64` of userdata. So the offset is 0 and the target covers the whole partition. `check_dm` holds this exact format against the kernel's numbers: one target, range `0-<sectors of sda15>`, device = `/sys/class/block/sda15/dev`, iv offset 0, offset 0, and `/sys/block/<fs device>/slaves` = sda15. Anything else stops the script. `check-map` is still the proof: it writes through the file and sees exactly the named raw block change.
- dm-default-key encrypts what goes through dm-40. Our image goes to raw `sda15` by `ldbhelper`, and XNU reads raw. Reading the file through f2fs gives noise; nothing does that.

**What can damage or move the blocks, and what happens:**

| Android event | Effect | What stops harm |
| --- | --- | --- |
| Foreground GC with the disk nearly full: each failed try counts; **over 2048 tries f2fs clears the pin** (`f2fs_pin_file_control`, `gc_pin_file_thresh`) [V] | later GC moves the blocks and reuses them for Android data. iOS writing there would corrupt Android | keep >= 8 GiB free (`allocate` checks). `seal` re-pins, refuses >= 1024 failures, and compares FIEMAP with the table. The fingerprint below |
| GC of an encrypted file counts also in background GC (`move_data_block`) [V] | as above, sooner | The file is in the new top-level `/data/laurel-ios`, no FBE policy [I]. op10tool accepts the flag; `status` shows it (`lsattr`: `E` = encrypted) |
| `rm`, app, script | blocks freed, then discarded ([V phone] the mount has `discard`) | immutable flag (`lock`). `dual-boot.sh remove` zeroes the headers first: discard is no promise |
| Factory reset, Format data, `fastboot -w` | new filesystem, new metadata key | The fingerprint in the header (taken on the frozen `/data` at the last seal) no longer fits: iOS off, no write. On Android: file and record are gone, so `install` and `seal` refuse before any block |
| Android runs after a seal (retries ended, `fastboot set_active a`, then `fastboot set_active b`, or iOS never reached) | anything above may have happened | Android's mount and first write give a new checkpoint: the fingerprint no longer fits, iOS off until `switch`. No state exists that skips this compare |
| Manual update (sideload) | slot b overwritten and active; `/data` untouched | `switch` refuses: section Q1 |
| fsck.f2fs at boot (fstab `check`) | [I] fixes metadata, does not relocate data | FIEMAP check at seal |
| FITRIM / idle maintenance | free segments only; urgent GC is background GC | pin |
| `gsid` | works only in `/data/gsi` [I] | another folder |
| userdata checkpoint | no `checkpoint=` in the fstab [V] | not used |
| F2FS resize, defragment, move-range ioctls | nobody calls them [I]. Defragment refuses a pinned file [V `f2fs_should_update_inplace`] | seal |

**The fingerprint.** The property: **no header state lets the kernel write against a filesystem that changed since the last verified pin and FIEMAP check.** Any doubt = off, no write. A false refusal costs one `switch`; a false pass costs Android's data.

The old design failed this: a state FRESH on flash passed against any filesystem, and XNU took the fingerprint itself at first boot. FRESH stayed on flash if slot b never reached the bind (boot hang, fallback, failed `bootctl`). Pin loss, a format or a removal, then `set_active b`: writes into Android's blocks. That state is gone, and the kernel no longer writes the header at all. Only BOUND passes, and the kernel compares at every boot.

Order of `switch`, each step with its real exit code:
1. Checks: identity, root, helper version, `check_dm`, table for this partition, slots (above), image has the fence kernel and this table, `boot_b` and `dtbo_b` are those files.
2. `bootctl set-active-boot-slot 1`, read back. It goes through binder and the HAL, which must not meet a frozen `/data`. A crash from here: slot b boots, the old header's fingerprint no longer fits, off, ABL returns.
3. `ldbhelper seal`:
   a. record says the image was read back for this table and this file; immutable flag; `SET_PIN`; FIEMAP = table. Not frozen yet: `SET_PIN` needs `mnt_want_write_file` and can dirty the inode.
   b. `sync`, then `FIFREEZE` on `/data`. Up to 3 tries.
   c. Frozen: failure count, FIEMAP = table again, raw fingerprint blocks hashed. All-zero block: refused.
   d. Header BOUND with that fingerprint to area block 0 by raw write, `fsync`, read back. The fingerprint is read again: it must be the same.
   e. `reboot(2)` `LINUX_REBOOT_CMD_RESTART` directly: no unmount.
   Any failure in c-e: header set to OFF, thaw, exit 1, and the script goes back to slot a.

[V source, `external/laurel-kernel-los` 8aaa002b]
- Why no clean reboot: `f2fs_put_super` writes a checkpoint with `CP_UMOUNT` whenever the last one was not by unmount (`fs/f2fs/super.c`), so a shutdown after the seal changes the fingerprint and iOS stays off. `reboot(2)` with RESTART: `kernel_restart` runs reboot notifiers + `device_shutdown`, no sync and no unmount; `fs/f2fs` registers no reboot notifier.
- `FIFREEZE`: `freeze_super` blocks writers, then page faults, runs `sync_filesystem` (a checkpoint if dirty), blocks internal writers, and `f2fs_freeze` returns `-EINVAL` if still dirty (then the fs is unfrozen again: that is why step b retries). After it: GC thread skips (`frozen >= SB_FREEZE_WRITE`), discard and evict wait in `sb_start_intwrite`, `f2fs_write_checkpoint` with CP_SYNC on a clean fs does nothing, so a `sync` from another process writes nothing.
- The raw write goes to sda15, not to the frozen dm device: `file_start_write` is only for regular files [V general kernel], and a non-exclusive open of a held block device is allowed.
- `msm-poweroff.c`: no command = `PON_RESTART_REASON_NORMAL`; download mode only in panic or when set. [U] on this phone, `CONFIG_QCOM_DLOAD_MODE` is off in `xiaomi-trinket.config`.
- A pinned block cannot be reused without a checkpoint: a freed block stays valid in `ckpt_valid_map` until the next checkpoint, and allocation respects that map (`__next_free_blkoff`, `segment.c`), and discard comes after a checkpoint. So "no checkpoint changed" = "the pinned blocks are as verified", also after a crash with roll-forward data.

**Effect on Android's data of the non-clean reboot [V source for the mechanism, I for the effect].** At the freeze a checkpoint has all file data and nodes on flash. The reboot then is like a power loss right after `sync`: nothing that was written before the seal is lost; what an app held only in memory is lost, as in any power loss. No `CP_UMOUNT` flag: the next mount runs roll-forward, finds nothing after the checkpoint, and `fsck.f2fs -a` (fstab `check`) reads the flags. `/metadata` (ext4) gets a `sync` and no unmount: its journal handles that. **Every `switch` is an unclean shutdown for Android.** [U] how Lineage reports it (boot reason), and whether many of them have an effect that a host cannot show.

**Risks this design adds [I, not run].**
- `/data` frozen: Android writers block, about 1 s in normal cases. A writer that holds up `sb_wait_write`, or much dirty data, makes `FIFREEZE` itself slow; during that time Android hangs. The system watchdog can restart `system_server`, or a kernel hung-task panic can reboot: data stays as in a crash, and a slot b boot is off.
- The helper dies while frozen (kill -9, crash): the freeze stays after it. A child process thaws after 20 s. HUP, INT, TERM, PIPE are ignored, so a cable pull does nothing to the helper. If the child also fails: hold Power; the state is that of a crash.
- A thaw by the child at the wrong time: only a false refusal.
- `reboot(2)` from the `su` domain: [U] with SELinux Enforcing. If it is refused, the call returns: header OFF, thaw, slot a, exit 1. No loss.
- `FIFREEZE` needs CAP_SYS_ADMIN: same [U]. Refused = nothing written.
- A checkpoint that changes nothing in the three blocks cannot exist while the fs is live [V: `checkpoint_ver` in the head]. FNV-1a is 64 bits and not against an attacker. Not defended: a person with root who wants this.

[I] Blocks of the file during `install`: Android runs. `write` repeats the file checks every 1024 frames (about 1 GiB) and at the end.

**Write only into a proven file.** `install` writes 12 GB of raw blocks. `ldb_lba_allowed` only compares against the table, and a table can be stale: file removed, `/data` reset, file moved. So `ldbhelper write TABLE PART PATH` opens the file and, before the first block, checks: pin, immutable flag, FIEMAP = table, the same device size as the table, and the record `root.area.ldbok` on `/data`: table id, table hash, inode, state. `check-map` writes the record only when it passed; a format or a reset takes it away with the file. `write` sets it back to "mapped" and clears any old header; `verify` sets "verified" only when all frames are right; `seal` needs "verified". fstab has `fsync_mode=nobarrier`, so `fsync` can lose a new file in a crash: `alloc` runs `syncfs` and then requires a raw checkpoint head to have changed; if not, it stops. A crash after that loses nothing; a crash before it loses the file, and then `open` fails in `check-map`, `write`, `seal`.

**adb [V source, `client/commandline.cpp`].** `adb exec-in` copies stdin and returns 0 when stdin ends: no remote output, no remote exit code, and the remote side can still run. `adb exec-out` has no remote exit code. `adb shell ... | tr` returned `tr`'s code. So: `ash` appends a marker with the real exit code, and no marker = unknown = stop. `install` has the helper write its text and exit code to a file on the phone and waits for that file; then it compares the frame count with what was sent. `verify` is a plain `adb shell` command with the index as a pushed file, and its numbers are checked on the host. `logs` checks the output size.

**Size [V measured].** The existing iOS 16 root: HFS+ 16 GiB, 12010 MiB used. iOS 16 donor images 7484 MB -> root 12010 MiB: 1.68 x. iOS 26 donor iPhone12,1 23F84, decrypted on disk 2026-11-02 (the userland agent's files, nothing downloaded here): OS 8409579520, SystemOS 5221908480, AppOS 14680064 bytes (encrypted in the IPSW: 7180648448, 2013265920). `dual-boot.sh size ios26`: root about 21.4 GiB [I: 1.68 x from iOS 16; not measured for iOS 26], + 8 GiB /private/var (`VAR_GIB=`, `EXPAND=`, `DONOR_BYTES=`) = at least SIZE=30G. iOS 16 alone: 16.01 GiB.

**Owner decision 2026-11-02: about 70 % Android, 30 % iOS.** userdata = 115869691904 bytes (107.9 GiB) [V phone]; 30 % = 32.37 GiB. **The default is `SIZE=32G`: `dual-boot.sh allocate` with no size makes an area of 32 GiB + 6 MiB (34366029824 bytes: volume + 1 MiB header + 4 MiB + 4 KiB log, in whole 2 MiB segments).** Build the root with `SIZE=32G`. An older 16G root also fits; the rest stays empty. `allocate GIB` still takes another area size.

**This is a reserved file, not a partition.** The GPT does not change, and userdata stays one f2fs. Android cannot use those 32 GiB, and it can use everything else, in any place on the partition. `df` on Android shows the file as used space. `allocate` refuses if under 16 GiB of `/data` stay free after it (f2fs needs room, or GC reaches the pinned file, and Android must work), and it names the numbers. `/data` had 104 GiB free [V], so about 72 GiB stay.

The HFS+ size is `SIZE=` of root.sh; the area must be >= volume + 1 MiB header + 4 MiB + 4 KiB log (both tools refuse less).

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
| 2 | Agent | `adb root`, `dual-boot.sh status` (pushes nothing), and `sha256sum` of `/dev/block/by-name/{modem,bluetooth,boot,dtbo}_b` against the stock ROM | nothing |
| 3 | Agent | `dual-boot.sh size ios26` (or `ios16`): what fits in the default `SIZE=32G` | nothing |
| 4 | Owner yes, agent | `CONFIRM=allocate dual-boot.sh allocate` (default 32 GiB + 6 MiB; refuses under 16 GiB free after it); it prints the extent count and writes `out/laurel/dualboot/table.ldbt` | a file in `/data`, a checkpoint |
| 5 | Owner yes, agent | `CONFIRM=check-map dual-boot.sh check-map`: mapping proof, record, then immutable | that file, the record |
| 6 | Owner yes, agent | `CONFIRM=install dual-boot.sh install` (tmux: `scripts/bg.sh db-install ...`, 10 min for 12 GB): file checks, raw write, reads back by hash | raw sda15, only in the table |
| 7 | Agent | `scripts/bg.sh db-image scripts/laurel/dual-boot.sh image`: boot image with the table; refuses a kernel without the 2950 text. Root must also pass the usual `flash-check` | host only |
| 8 | Owner yes, owner cable | `adb reboot bootloader`, `CONFIRM=flash-slot-b dual-boot.sh flash-slot-b` (the phone must answer `laurel_sprout`, also before the second flash); slot a stays active; `fastboot reboot`; **Android must start and open its data** | `boot_b`, `dtbo_b` |
| 9 | Owner yes, agent | `CONFIRM=switch dual-boot.sh switch`. **An unclean reboot for Android, each time** (section "The fingerprint") | slot attributes, area header, then reboot |
| 10 | Owner | Watch iOS. Expected line: `LAUREL DUALBOOT: on: root = ... MiB in N extents of userdata, table ..., seal 1, writes fenced to the table (LAUREL-2950-DUALBOOT-FENCE-V2-SEAL-AT-FREEZE)` | iOS root only |
| 11 | Owner or agent | Back: `out/bin/op10tool ctl bootloader`, `CONFIRM=to-android dual-boot.sh to-android` (must answer `laurel_sprout`). **Android must open its data** | slot attributes |

Daily use: step 9, step 11. To read the iOS log from Android: `dual-boot.sh logs`. `root-update.sh` works over SSH when iOS reports `kern.laurel_dualboot=1`.

## 5. Recovery

| What you see | What it means | What to do | Who |
| --- | --- | --- | --- |
| iOS screen log `LAUREL DUALBOOT: off: ...`, restart after 30 s | self-check said no; **no block was written** | wait: ABL returns to Android after the retries; or Power + Vol Down, `fastboot set_active a`, `fastboot reboot` | Owner |
| `off: Android ran or /data was formatted` | normal after a fallback | on Android: `dual-boot.sh switch` | Agent |
| `off: area is not sealed`, `area header damaged` | a failed seal (header OFF), or a header of the old version | on Android: `dual-boot.sh switch` | Agent |
| `switch` says `UNKNOWN`: adb lost the phone during the seal | a reboot or a lost cable | look at the phone. If iOS does not say `on`, ABL returns to Android. No data at risk: a header that does not fit stays off | Owner |
| `switch` says `boot_b ... is not` or `manual update` | a sideload wrote slot b, or the image is newer | section Q1 "Updates" | Agent |
| Android hangs in `switch` and does not reboot within a minute | `FIFREEZE` or the reboot is stuck | wait for the 20 s thaw; or hold Power: as a crash | Owner |
| Android restarts on slot b without end before the first `switch` | ABL fell back to slot b: its successful bit is set today | `fastboot set_active a`, `fastboot reboot` | Owner |
| `off: no header ...` or `another table` | not installed, file allocated again, or old boot image | steps 7, 8 (table), or `remove` and step 4 on | Agent |
| `seal` or `install` says "the file moved", "shorter" or "cannot pin" | f2fs moved or lost it; the root content is gone | `remove --unverified`, free space, steps 4-9. Android is fine | Agent |
| `install` says "no record that check-map passed" | new file, a reset, or a new table | step 5, then step 6. If `check-map` says "already installed": `remove`, steps 4-9 | Agent |
| iOS hangs, no USB, not the off line | kernel problem | hold Power: each boot costs a retry; ABL falls back | Owner |
| Slot stuck, ABL in fastboot ("no alternate slot") | slot a not marked successful | `fastboot set_active a`, `fastboot reboot` | Owner |
| Android does not start after iOS: logo loop or asks for reset | [U] Keymaster or slot state | **Do not wipe.** Power + Vol Down, `fastboot set_active a`; report the log. Lineage recovery from boot_a | Owner |
| Android on slot b after a manual update | it wrote slot b | section Q1 "Updates": sideload again to slot a, steps 7, 8, 9 | Owner + agent |
| boot_b must go back | | `BOOTIMG=~/laurel-backup/lineage-24.0-20261027/boot.img ANDROID_IMAGE=1 scripts/laurel/flash-boot.sh`, and Lineage's dtbo.img to dtbo_b | Agent, owner yes |
| Remove all iOS | | `CONFIRM=remove dual-boot.sh remove` (refuses with slot b active or running): zeroes the area header and the HFS+ header by raw write after the file checks, then removes the file and its record; then the line above | Agent, owner yes |
| The file no longer fits the table | no raw write can be right | `CONFIRM=remove dual-boot.sh remove --unverified` | Agent, owner yes |
| Clean iOS install again, Android given up | | owner says so; `git rm config/laurel-android-data`; `root-flash-test.sh` | Owner |

## 6. Unproven: all of this needs the phone

- [U] `set-active-boot-slot` as root in the `su` domain with SELinux Enforcing; HAL on this ABL; slot b's bits and retry count after it; `get-active-boot-slot` and `mark-boot-successful` as the script expects them. `bootctl` was read, not written [V read].
- [U] **`FIFREEZE` on the live `/data`: how long it takes on a running Android, what blocks, whether `f2fs_freeze` says -EINVAL under load (3 tries). `reboot(2)` from the `su` domain, and that the ABL then boots slot b. Not run anywhere: the host test stubs these.**
- [U] **Android mounts and opens its data after the unclean reboot of a `switch`.** The mechanism says yes: section "The fingerprint".
- [U] Android opens its data after an iOS boot. **Biggest risk.** No backup of `/data` exists here; decision D5.
- [U] pin, FIEMAP, `check-map`, the record on `/data`, `syncfs`, extent count (limit 4096); helper's aarch64 build has compiled, not run; SELinux of the su domain. `dmctl table` format is [V read]; the rest of `check_dm` is not run. `head -c`, `lsattr`, `/sys/block/<dm>/slaves` as the script uses them.
- [U] The OnePlus 10 Pro's fastboot `product` (`android-guard.sh` lists `OP516FL1`, `taro` from documents, not read from that phone). A wrong entry costs a false refusal.
- [U] XNU boots from the table: the mapping code ran on a host against a RAM disk through the real `sweet_ufs.c`, with the SCSI command replaced.
- [U] Write speed over `adb exec-in`, HFS+ on the area at full load.
- [I] A checkpoint happens whenever Android has written. A crash right after boot could leave the checkpoint unchanged with new data in roll-forward nodes: the blocks of the pinned file are still not touched by that (`ckpt_valid_map`, section "The fingerprint").
- Not defended: someone with root deleting the flag and file on purpose.

## 7. Owner decisions

| # | Decision | Recommendation |
| --- | --- | --- |
| D1 | Done [V 2026-11-02]: Rooted debugging on, `adb root` gives uid 0 | - |
| D2 | Done, owner decision 2026-11-02: Lineage's Updater is disabled. A manual sideload still writes slot b and flips the slots: `switch` refuses, section Q1 "Updates" | - |
| D3 | iOS writes slot attributes (GPT of the boot LUN) for a button "Android" | Not now. If wanted: a Mu or XNU piece with its own fence, later |
| D4 | Fallback: shrink userdata (GPT write + Android wipe) | Only if pinned files fail on the phone |
| D5 | Back up Android's data before step 8 | Yes: apps' data cannot be restored when the keys fail |
| D6 | Done, owner decision 2026-11-02: about 30 % of userdata, `SIZE=32G`, area 32 GiB + 6 MiB. A `SIZE=16G` root fits; later only a new volume | - |
| D7 | Every `switch` is an unclean reboot for Android (the fingerprint needs it) | New: the owner should know before step 9 |

## 8. Build and test

- Kernel: `patches/laurel/xnu/2950-laurel-dual-boot.patch`. `scripts/laurel/kernel-linux.sh`.
- Host test: `scripts/bg.sh db-test scripts/laurel/test-dualboot.sh` (needs the kernel tree: `AUDIT=1 scripts/laurel/kernel-linux.sh`). It runs `ldbhelper-test.sh` (the real helper, a real file, stubs only for pin, freeze, reboot), `android-guard-test.sh`, `dual-boot-test.sh` (fake adb and fastboot; PATH holds no real one, checked first).
- Do the tests find the defects: `scripts/bg.sh db-detect scripts/laurel/dualboot-tests-detect.sh [REV]` runs them against the old code. `[R]` in a test name = regression, `[N]` = a refusal of a command the old code does not have: those may pass there. The rest must fail there.
- Tools: `op10tool dualboot {table,check,show,stream,size}`, `tools/laurel-dualboot/ldbhelper.c`, `laurel_dualboot.h` (kernel + helper share it; it holds `LDB_KERNEL_MARKER`), `scripts/laurel/ota-partitions.py`.
- Guard: `scripts/laurel/android-guard.sh`, flag `config/laurel-android-data`. Refuses in: flash-root, root-flash-test, update-phone, root-update (real + rollback), flash-boot, boot-test, fastboot-drain.py (userdata, metadata, boot), scripts/flash/{ios16,all,restore,reflash-root via ios16}. No environment switch (`PHONE_SSH` is gone); `ANDROID_IMAGE=1` passes only an image with no iOS payload. `boot-image` needs the 2950 marker text in the image. `other-device` needs a positive answer (`OP516FL1` on adb; `OP516FL1` or `taro` in fastboot [I, not read from that phone]): phone off or in iOS = refused, so start `reflash-root.sh` and `make flash-restore` with the phone on. `other-device-fastboot` asks again right before a write (`restore.sh`, each write of `ios16.sh`). No `timeout` tool (stock macOS): `perl alarm`; neither: refused.
- Results [V, host only] 2026-11-02, commit 5f84bae075: kernel 310/310 patches, 0 LSE/RCpc, printf check OK, marker found, sha256 2c1a08392077bfa9...; iOS 26 kernel: series 211 applied, 83 applied+rules, 7 skipped, 11 base, 0 errors, 0 LSE/RCpc, printf check OK, marker found, sha256 65d0b0301ecbff38...; `test-dualboot.sh` PASS: 11 op10tool tests, 40611 checks in the real `sweet_ufs.c` (37k random I/Os across extents, 0 blocks outside the table changed; 12 bad addresses + wrong LUN fenced; every header state x every changed fingerprint block: a root only for BOUND with the fingerprint as sealed, no boot wrote a block), helper 28/28, guard 51/51, script 60/60. `build-honest-test.sh` 60/60, `root-update-test.sh` 94/94. Against the old code 037cd81: 48 script, 17 guard, 22 helper tests and test_kernel fail.
