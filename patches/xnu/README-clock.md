# Clock and clonefile patches (0203, 0204, 0212)

Two kernel problems from the live logs `logs/usblog-20261024-195455.txt` and
`logs/usblog-20261024-235438.txt`:

- (A) userland timestamps are `1969-12-31 16:17:35` (no calendar source);
- (B) `hfs_clonefile: cluster_write failed - 34` (5 times in the first log, 85 times in the
  second log, one each ~7 s during the SpringBoard crash loop).

Base: branch `base` of `out/kernel/xnu` + 0200, 0210, 0211 (worktree `out/kernel/wt-clock`,
branch `clock`, one commit per patch). Each patch is for NEGRONI only
(`ARM64_BOARD_CONFIG_NEGRONI`).

| Patch | Files | Boot-arg |
|---|---|---|
| `0203-negroni-calendar.patch` | new `bsd/dev/negroni_rtc.c`, `bsd/conf/files`, `iokit/Kernel/arm/NegroniPlatformExpert.cpp`, `iokit/Kernel/IOStartIOKit.cpp`, `bsd/kern/bsd_init.c` | `negronirtc=0` (no PMIC access), `negronirtcoff=<s>` |
| `0204-negroni-hfs-clonefile.patch` | `bsd/dev/negroni_ufs.c`, `bsd/negroni_hfs/core/hfs_readwrite.c` | `negroniclone=N` (bits, default 3) |
| `0212-negroni-usb-settime.patch` | `bsd/dev/negroni_usb.c` (command server of 0210) | `negronictl=0` (whole server) |

Why 0212 and not part of 0203: `build-local.sh` / dxb apply all patches in name order and
skip a patch that does not apply. 0203 is applied before 0210, so it cannot change the command
server that 0210 adds. The `settime` / `time` commands are therefore a separate patch after 0211.

## (A) Calendar: cause

- `clock_initialize_calendar()` (`osfmk/kern/clock.c`) reads `PEGetUTCTimeOfDay()`, which
  calls `gIOPlatform->getUTCTimeOfDay()`. `NegroniPlatformExpert` did not override it, so
  `IOPlatformExpert::getGMTTimeOfDay()` returned 0.
- `clock_initialize_calendar()` then sees UTC < uptime and sets the calendar to the uptime:
  `1969-12-31 16:17` in the phone's Pacific time zone = the epoch + 17 min of uptime.
- No driver publishes IORTC. 0200 removed only the 30 s wait for it.

## (A) Calendar: fix (0203 + 0212)

`bsd/dev/negroni_rtc.c`, called from `NegroniPlatformExpert::getUTCTimeOfDay()` /
`setUTCTimeOfDay()`:

1. **PMK8350 RTC.** SPMI SID 0, RTC_RW peripheral 0x61 (DT `rtc@6100`,
   `qcom,pmk8350-rtc`, reg `<0x6100 0x6200>`, no `allow-set-time`). Registers as Linux
   `rtc-pm8xxx.c` `pmk8350_regs`: CTRL 0x6146 (bit 7 = enabled), READ 0x6148..0x614b
   (32-bit little-endian seconds). The read is as `pm8xxx_rtc_read_raw()`: 4 bytes, then
   byte 0 again; if byte 0 got smaller (carry), read again. The SPMI path is the v7 arbiter
   that the keys driver already uses (core 0x0c400000, observer 0x0c440000, EE 0), through
   the header `bsd/dev/negroni_spmi_keys.h` (`sk_find_apid`, `sk_read8`). Observer reads
   only. **The PMIC is never written** (no RTC write, no SDAM/alarm spare registers).
   `bsd/dev/negroni_spmi.c` (battery, its own allow list) is not used or changed.
2. **Offset.** Linux and Android do not write this RTC: wall time = counter + offset.
   The counter may count from an arbitrary epoch (not verified on this phone; the boot log
   prints it). Offset sources: boot-arg `negronirtcoff=<seconds>` (wins), else the offset
   saved in `/private/var/db/negroni_rtc` (text: `negroni-rtc 1`, `offset`, `rtc`, `wall`).
   The file is read in `bsd_init` after the root mount, before launchd. If the counter is now
   smaller than the saved `rtc` (counter reset), the offset is not used and the saved `wall`
   is a floor.
3. **Floor.** 00:00 UTC of the kernel build date (`__DATE__`) minus one day. The calendar
   never starts below it (or below the saved wall time).
4. **Set.** `settimeofday()` (iOS timed, `date`) and the USB `settime` both call
   `clock_set_calendar_microtime()` -> `PESetUTCTimeOfDay()` -> `negroni_rtc_set()`: the new
   offset = time - counter. A thread call writes it to the file (not on the caller's thread).
   The root is read-only until launchd remounts it: a failed write is tried again every 30 s,
   60 times. Without a readable RTC the clock is floor + uptime; a set moves it and the file
   keeps it as the next floor.
5. `IOKitInitializeTime()` (0200's NEGRONI branch) now waits up to 10 s for the platform
   expert before `clock_initialize_calendar()`. Without it, `PEGetUTCTimeOfDay()` gives 0.

No IORTC service is published: settimeofday reaches `setUTCTimeOfDay()` without it, and 0200
already removed the only wait for it.

USB commands (0212, UDP 5141, from 192.168.7.1 only):

- `settime <unix s>[.<fraction>]`: sets the calendar. Values below 2020-01-01 or from 2100 are
  refused. Reply `ok settime S (was OLD, RTC offset N)`.
- `time`: reply `time S rtc R offset N source ...` (`rtc none` without the RTC).

Host side:

- `op10tool ctl settime` sends this host's clock (UTC, with microseconds), `op10tool ctl time`
  shows the phone's clock and prints `phone - host = N s`. Both resend every 500 ms for 2 s.
- `scripts/debug/usblog.sh` sends `settime` each time the phone's interface comes up
  (`USBLOG_SETTIME=1`, default; under sudo pass it as `sudo USBLOG_SETTIME=0 scripts/debug/usblog.sh`).
  It retries for 30 s and logs `==== usblog: settime: <reply>`.

## (B) hfs_clonefile ERANGE: cause

`hfs_clonefile()` in `bsd/negroni_hfs/core/hfs_readwrite.c` is **not** `clonefile(2)`. It is
step 2 of `hfs_relocate()`: copy a file's data to newly allocated blocks inside the same file
(at file offset `writebase = old block count * 4 KiB`), then drop the old blocks. Callers:

- `hfs_vnop_open()`: "defragment on open" of a file with 8+ extents, <= `hfs_defrag_max`,
  after 3 min of uptime and not modified in the last 60 s;
- hot-file clustering (`hfs_hotfiles.c`).

Both run only when the volume is not `HFS_SSD`. `bsd/dev/negroni_ufs.c` answered
`DKIOCISSOLIDSTATE` with ENOTTY, so HFS treated the UFS flash as a hard disk.

Why ERANGE (34): on this 16 KiB-page kernel `writebase` is often not page aligned (stock XNU
has 4 KiB pages on HFS volumes, so with 4 KiB blocks it is always aligned).
`cluster_write_copy()` (`bsd/vfs/vfs_cluster.c`) then pre-reads the first page from
`trunc_page(writebase)` up to its `oldEOF` argument, which hfs_clonefile passes as
`writebase + offset`. That range is at or past `ff_size`, and `hfs_vnop_blockmap()` returns
ERANGE for reads at or past EOF (`if (ap->a_foffset >= fp->ff_size) retval = ERANGE`). Every
chunk after the first 128 KiB also starts unaligned, so larger files always failed.
`hfs_relocate()` then restores the file (truncate back to `ff_size`): no data loss, but each
open of such a file did the allocation and a partial copy again (the ~7 s rhythm in the second
log matches the SpringBoard restarts). With a correct clock (A) more files pass the "not
modified in 60 s" test, so the errors would grow.

## (B) Fix (0204), boot-arg `negroniclone` (default 3)

- bit 0: `DKIOCISSOLIDSTATE` = 1 in `negroni_ufs.c`. HFS sets `HFS_SSD`: `hfs_relocate()`
  returns at once, no defragment on open, no hot files. The VFS also marks the mount SSD
  (`MNTK_SSD`, I/O throttling and read-ahead tuning for flash).
- bit 1: `hfs_clonefile()` made safe for 16 KiB pages: the first chunk ends on a page
  boundary (later chunks start aligned, no pre-read), and the first chunk passes
  `oldEOF = max(trunc_page(writebase), ff_size)`, so the pre-read covers only bytes below EOF
  and a page that starts past EOF is zero filled up to `writebase` (bytes past EOF in the old
  blocks, which `hfs_relocate()` frees). Logs the first 20 copies:
  `NEGRONI HFS: clonefile done|failed: N bytes to 0x... (page offset 0x..., EOF 0x...)`.
- `negroniclone=0`: stock behaviour (both off). `negroniclone=2`: relocation on, with the fixed
  copy (to test bit 1). `negroniclone=1`: SSD only.

`clonefile(2)` itself is not changed. A ENOTSUP fallback like ios-flame 0100 is not needed for
this error.

## Verification

- Single-file syntax checks (Xcode 15.4 clang, `out/kernel/cc-gpu-kernel/cc.sh` against
  `out/kernel/buildtree`, kernel warning set): no new warnings in the changed lines except
  `-Wdeclaration-after-statement`, which all negroni files (and the kernel headers) give.
- All `patches/xnu/0*.patch` apply in name order on `base` (`git apply --check`).
- Full build (2026-10-25): `scripts/bg.sh kernel-local scripts/kernel/build-local.sh`, exit 0,
  `out/kernel/local-20261024-232438/kernel.development.negroni` (sha256 69af8f1a...). 0203, 0204
  and 0212 applied; only 0231 (not part of this work) was skipped. Not tested on the phone yet.

## What to look for on the phone

Boot log (`make usblog`):

- `NEGRONI RTC: PMK8350 RTC APID n (write owner EE e), ctrl 0x80 (enabled), counter N s`
- `NEGRONI RTC: boot calendar T s from the ...; floor F (build ...), offset O`
- `NEGRONI RTC: /private/var/db/negroni_rtc: ...` (first boot: `no saved offset yet`)
- `==== usblog: settime: ok settime ...` and `NEGRONI RTC: USB settime ...`
- later: `NEGRONI RTC: saved offset O (wall W) to /private/var/db/negroni_rtc` (after the root
  is read-write; before that `not written (error 30): again every 30 s`)
- `NEGRONI UFS: solid state (HFS: no file relocation, no hot files; negroniclone bit 0)`
- no `hfs_clonefile: cluster_write failed - 34`
- userland lines with the real date instead of `1969-12-31`; `op10tool ctl time` gives
  `phone - host` near 0. Next boot without usblog: the date is still correct (saved offset).

## Risks

- The RTC counter meaning is not verified on this phone (it may be from 1970 or from the last
  PMIC reset). The floor and the saved offset handle both cases; a counter reset loses the
  offset until the next `settime`.
- iOS timed may call settimeofday with its own (possibly stale) idea of the time; that value
  is then saved as the offset. A host `settime` corrects it.
- The kernel writes one small file on the root volume (`/private/var/db/negroni_rtc`).
- `HFS_SSD` also changes VFS I/O tuning for the root (flash profile). If I/O gets worse, test
  `negroniclone=2`.
- The 10 s platform-expert wait costs time only if the platform expert is not up by bsd_init
  (logged).
