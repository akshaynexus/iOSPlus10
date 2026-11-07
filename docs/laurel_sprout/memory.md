# Mi A3 iOS 26: RAM use, the VM compressor and swap (2026-11-07, RAM agent; kernel patch 3080 + post/9024, root floors)

Owner's order, 2026-11-07: "swap ram and ram usage work efficiently". Budget: 6 GB SoC RAM, 4078 MiB for XNU (patches 2100/2974/3022, Mu 0104),
a 1 GiB GPU pool at 0x80000000 outside the kernel window. Marks: [V] verified, [I] inferred, [U] unknown.

## 1. What the phone had before (read from the code and the USB logs; no SSH: the phone was in a watchdog loop, then in fastboot)

| Item | Finding | Mark |
|---|---|---|
| Compressor mode | First reading [V nm]: the SWEET config has jetsam compiled (`_memorystatus_jld_enabled`, `_memstat_critical_threshold`) and no `CONFIG_FREEZE` (no `_memorystatus_freeze_enabled`), no phantom cache, no secluded memory; so the expected default was `VM_PAGER_COMPRESSOR_NO_SWAP` (2). **Corrected by the first boot of 3080 [V phone 06:34:54]: `LAUREL SWAP: off: already with swap: mode 0x4 stays`.** The kernel is built for the macOS platform (`XNU_SDK` MacOSX.platform, `MakeInc.def`: `PLATFORM_FOR_CONFIG` MacOSX -> `-DXNU_TARGET_OS_OSX`; the TOPAZ_4K guard in `vm_compressor_init` exists for that reason), so `VM_COMPRESSOR_CONFIG_DEFAULT` = `VM_PAGER_COMPRESSOR_WITH_SWAP` (4) and every `XNU_TARGET_OS_OSX` branch of the swap store is in: swap files in `/System/Volumes/VM/swapfileN`, 256 MiB to 1 GiB each, up to 100 (`VM_MAX_SWAP_FILE_NUM`), `vnode_setswapmount`. No `/defaults` node with `kern.vm_compressor` in our ADT [V grep], no `vm_compressor=` boot-arg | [V] |
| Swap | None in practice: `/System/Volumes/VM` does not exist on the root [V ls], so the first swap file could never be made: compressor only. A full compressor ends in `memorystatus: killing largest compressed process` (iOS 16 text `low swap: ...`, mediaserverd at 2689 MB in the 11-04 logs). Had the directory existed, macOS's limits would have applied: 100 x 1 GiB on a root with 12 GB free | [V] code; [V] old logs |
| A real iPhone (iOS 26, 4 GB) | `CONFIG_FREEZE` + `VM_PAGER_FREEZER_WITH_SWAP` (0x20): the compressor plus swap files in `/private/var/vm`, 128 MiB each, at most `VM_MAX_SWAP_FILE_NUM` = 5 (640 MiB) on a non-macOS kernel; the freezer swaps suspended apps out whole | [V] code: `vm_compressor_backing_store.c`, `vm_compressor_backing_store_internal.h` |
| Compressor pool | `compressor_pool_size = max_mem` (4078 MiB), multiplier 1 (`max_mem` > 2 GiB), `c_segments_limit` from it; with swap active the limit grows by `vm_swap_get_max_configured_space() / c_seg_allocsize` | [V] `vm_compressor.c:866-944` |
| Jetsam bands | `max_mem` 4078 MiB is above `MEMORYSTATUS_SMALL_MEMORY_THRESHOLD` (3 GiB) and below the medium one (6 GiB): "large" class, as an iPhone 11 (3.8 GB): delta 4 % = 163 MiB, critical 4 % = 163 MiB, jetsam loop window 6 s. Nothing to change in the kernel | [V] `kern_memorystatus.c:280-298, 2057-2075` |
| A daemon with no memory key | 6 MB (launchd's own default). The root spec raises floors, never lowers (`JETSAM_FLOORS`) | [V] log; [V] spec |
| Still crossing a watermark with the floors in place (log 05:00-05:30, 9 boots) | pkd 15 MB x 8 (1 kill, code 7), CategoriesService 6 MB x 6 (3 kills), AppPredictionIntentsHelperService 6 MB x 2, siriactionsd 25 MB x 1. All logs since 11-03: biomed 12 MB x 22, geod 19 MB x 8, UserEventAgent-System 15 MB x 8, liveactivitiesd 24 MB x 8 (the floor) | [V] `crossed memory high watermark` lines |
| Memory at boot | 290-294 MiB wired, 2041-2117 MiB free right after the wired guard starts; later in a boot 364-366 MiB wired and 767-827 MiB free (the rest: active, inactive, file cache: no counter in the log before 3080) | [V] `LAUREL WIRED` lines |
| GPU pool | 1024 MB; 409-418 MB free early in the UI (28 MB kept), the lowest seen 71 MB free (30 MB kept) at 05:26:39: the UI storm uses up to 953 MB. The pool is sized for its peak; it is RAM the kernel cannot use | [V] `RedwoodGPU: buffers` lines, 256 samples |
| Wired guard (2906) | surfaces refused above 2242 MiB wired (55 % of 4078); never reached in these logs (max 366 MiB) | [V] |
| Our buffers | USB panic console ring 1 MiB (3031), UFS bounce 512 KiB (2971, off), kernel log ring (2014): small. Not RAM waste | [V] patch text |
| RAM XNU does not get | 6144 - 4078 = 2066 MiB: GPU pool 1024, modem 16, firmware carve-outs 508, the UEFI FD and heap fragments in bank A 463 (`0x65E00000-0x7CC00000`, not contiguous with the window: XNU manages one range) | [V] `clocks-on-motion.md` "RAM"; a second range: [U] |

## 2. Kernel: laurel 3080 + 3081 `LAUREL SWAP` (+ post/9024 on xnu-12377)

- 3081 (`vm_compressor_backing_store.h`/`_internal.h` and `.c`): on `ARM64_BOARD_CONFIG_SWEET` the three swap blocks take the `!XNU_TARGET_OS_OSX` (iPhone) values: `/private/var/vm/swapfileN`, 64 to 128 MiB each, at most 5 = 640 MiB. The on line prints whenever the mode has swap: `LAUREL SWAP: on: already with swap: mode 0x4: compressed pages go to /private/var/vm/swapfileN, at most 5 x 128 MiB, 4078 MiB RAM; off with laurelswap=0`. Host test: 3 SWEET blocks in the patch, the path in the line.
- `osfmk/vm/laurel_swap_core.h` (pure, host test `scripts/laurel/test-swap.sh`: 21 cases PASS): the decision. `NO_SWAP`, `NOT_CONFIGURED`, `DEFAULT` -> `COMPRESSOR_WITH_SWAP` (4); a freezer kernel `FREEZER_NO_SWAP`/`FREEZER_DEFAULT` -> `FREEZER_WITH_SWAP`; a mode with swap stays; `laurelswap=0` or a `vm_compressor=` boot-arg given by hand: the kernel's own choice stays.
- `osfmk/vm/laurel_swap.c`: `laurel_swap_choose()` runs before `vm_config_init` reads the mode (xnu-8796: in `vm_fault_init` after the boot-arg parse; xnu-12377: the mode is a `TUNABLE_DT` and `vm_config_init` is a `STARTUP(KMEM)` in `vm_pageout.c`, so post/9024 puts the call there and the series rule drops the vm_fault.c section). `laurel_swap_start()` at the end of `vm_compressor_init` prints `LAUREL SWAP: on: compressor without swap: mode 0x2 -> 0x4: compressed pages go to /private/var/vm/swapfileN, at most 5 x 128 MiB, 4078 MiB RAM; off with laurelswap=0` and starts the minute thread.
- The swap files are the kernel's own: the swapfile create thread makes `/private/var/vm/swapfile0` (128 MiB, `O_CREAT`, preallocated, encrypted by the portable AES of topaz 0020) the first time the swapout thread needs room; nothing is written while the compressor has room. `/private/var/vm` exists on the root [V manifest of `ios26-root.img`]. `rootrw=1` is in the boot-args of every rw image.
- Self-check and limit: the first file made -> `LAUREL SWAP: swapfile 0 made: 128 MiB of swap in 1 file(s), at most 640 MiB`; the first failure (root read-only, no directory, no space) -> `LAUREL SWAP: off: /private/var/vm/swapfile0 could not be made (...): compressor only, N puts failed`, once; the kernel then runs as before (`vm_swap_out_of_space` -> the same kills). The limit is the kernel's `VM_MAX_SWAP_FILE_NUM` = 5 files = 640 MiB on this (non-macOS) kernel; `vm_swap_get_max_configured_space()` says so in the line.
- The minute line, the running self-check: `LAUREL SWAP: free F MiB, active A, inactive I, speculative S, wired W; compressor P MiB of pages in B MiB, N of L segments; swap U of T MiB in F files; level L %`. Read it with `scripts/laurel/mem-stat.sh` (SSH: `sysctl vm.*`, `/private/var/vm`, the 12 largest processes, kills from the USB log; `watch MIN` for a series; `launch BUNDLE` for an app launch time).
- Risk [I]: swap I/O goes through HFS+ cluster I/O to the UFS driver with `ufsqueue=0` (the synchronous path; the async worker of 2971 that hit `pmap_assert_free` is off). First boot: watch for a panic with `vm_swapfile_io` or `vnode_pageout` in the stack; then `laurelswap=0` is the fallback.

## 3. Root: jetsam floors added (ios26-root-spec.py `JETSAM_FLOORS`; live: `ONLY_JETSAM=1 scripts/laurel/ios26-live-update.sh` + reboot, or `ios26-update-kernel-limits.sh`)

| Job | Was | Now | Evidence |
|---|---|---|---|
| `com.apple.pluginkit.pkd` | 15/15 | 32/32 | 71 crossings in all logs, 8 + 1 kill in the 05:00 log |
| `com.apple.siriactionsd` | 25/18 | 48/48 | crossed 25 |
| `com.apple.geod` | 19/19 | 48/48 | 8 crossings |
| `com.apple.biomed` | 12/12 | 32/32 | 22 crossings |
| `com.apple.UserEventAgent-System` | 15/15 | 32/32 | 8 crossings |
| `com.apple.liveactivitiesd` | 24/24 (floor) | 48/48 | crossed the floor 8 times |
| XPCService `com.apple.proactive.AppPredictionIntentsHelperService` | none (6) | 24/24 | crossed 6 MB, killed |
| XPCService `com.apple.ctcategories.service` | none (6) | 24/24 | CategoriesService.xpc: 28 crossings, 3 kills. Id [I]: the service id next to its bundle in the root image |

No limit lowered, no job removed (owner's rule). Spec self-test PASS (43 of 43 hooks).

## 4. Measurements

Before (kernel 43eed8b7b8, 390 patches, no 3080; boot 06:10:24, `vm_stat` of the root over SSH, 16 KiB pages) [V]:

| Time after boot | free | active | inactive | speculative | wired | file-backed | anonymous | in compressor | compressions | pageins |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 30 s (06:10:56) | 266 MiB | 1651 | 902 | 740 | 518 | 2114 | 1178 | 0 | 0 | 123169 |
| 80 s (06:11:45) | 56 MiB | 1725 | 1373 | 369 | 551 | 2023 | 1445 | 0 | 0 | 142160 |

So 80 s after boot the free list is at its floor (56 MiB of 4078), half the RAM is file cache (2 GiB file-backed: the shared cache and the
boot storm's reads), the compressor has not started (0 compressions): the pageout thread reclaims file pages first, so no process
has been compressed yet, and nothing could have been swapped. Largest RSS: UserEventAgent 79 MiB, locationd 74, chronod 72,
backboardd 56, audiomxd 56. Kills in these 10 minutes: 0 jetsam, 0 compressor-full, 0 watermark crossings (the floors of 11-03
are on this root; the new floors are not yet). The root has Apple's `vm_stat`, `footprint`, `taskinfo`, `zprint`, `ltop` in /usr/bin
and no `sysctl`: `mem-stat.sh` uses `vm_stat`.

After, boot 1 of the 3080 kernel (8c7f0143db, 394 patches; flashed 06:34:34 through `ios26-fast-flash.sh` with `KERNEL=out/ram-3080/...`,
`EXTRA_ARGS="ufsqueue=0 laurelpmicwdog=0 laurelucache=0"`) [V USB log]:

| Line | What it says |
|---|---|
| 06:34:54 `LAUREL SWAP: off: already with swap: mode 0x4 stays` | the macOS-platform default (section 1): 3080's choice is a no-op on this kernel; 3081 fixes the path and the sizes |
| 06:35:08 link gone, 06:36:10 `LAUREL BUILD: 8c7f0143db 394 patches` | the first boot ended 14 s after launchd with no panic line and no CTL command [U why]; the second boot came up |
| 06:36:40 minute line | free 54 MiB, active 1736, inactive 1123, speculative 613, wired 531; compressor 0 of 52198 segments; 0 swap files; level 86 % |
| 06:37:40 | free 68, active 1689, inactive 1674, speculative 14, wired 599; compressor 64 MiB of pages in 14 MiB (4.6:1), 317 segments; level 84 % |
| 06:38:40 | free 69, active 1667, inactive 1644, speculative 23, wired 615; compressor 146 MiB of pages in 39 MiB (3.7:1), 767 segments; level 83 % |
| 06:39:10 | the log stops in a backboardd `SMP` backtrace dump (20 `SMP` lines); no pong on USB control after it, no bark, no panic: a hang; 0 swap files, so not the swap path [V]. The stuck-CPU work (3050-3059) owns this |

So on this kernel the compressor starts about 60 s after boot and holds 146 MiB of pages in 39 MiB two minutes in; the free list stays at
its floor (54-69 MiB) while the file cache (inactive + speculative, about 1.7 GiB) is what pageout eats first. `c_segments_limit`
52198 = the 4078 MiB pool. Kills in the 3 minutes: 0 (`mem-stat.sh watch` got one snapshot before the hang: UserEventAgent 79 MiB,
locationd 74, chronod 72 RSS).

Still pending: a boot of the 3081 kernel (snapshot build `ram`), `swapfile 0 made` under load, the 10 minute series and the launch times.

## 5. How to test

1. `scripts/laurel/test-swap.sh` (host, seconds).
2. Flash the kernel (`docs/notes.md` 2026-11-07 flash path, `EXTRA_ARGS="ufsqueue=0 laurelpmicwdog=0 laurelucache=0"`), boot, `grep -a 'LAUREL SWAP' logs/usblog.log`: the `on` line, then a line a minute.
3. `scripts/laurel/mem-stat.sh` once the UI is up; `scripts/laurel/mem-stat.sh watch 10` for the 10 minute series; `scripts/laurel/mem-stat.sh launch com.apple.Preferences` for launch times.
4. Fill the compressor on purpose: open the camera and Safari pages until `swapfile 0 made` shows; then `ls -la /private/var/vm` over SSH and `sysctl vm.swapusage`.
5. The limits: `ONLY_JETSAM=1 scripts/laurel/ios26-live-update.sh`, reboot, then count `crossed memory high watermark` lines in 10 minutes: pkd, CategoriesService, AppPredictionIntentsHelperService must be gone.
