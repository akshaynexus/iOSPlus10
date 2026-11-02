# Mi A3 iOS 26: why dyld mapped no cache on the first launchd boot

Date: 2026-11-02. Boot: `logs/ios26-boot7-dyld.txt` of the main checkout, line 10677 on. **The fix ran on the host only. No flash, no phone boot.** Labels: [V] read in code, disassembly or a file, or run here. [I] inference. [U] unknown. Addresses are of `usr/lib/dyld` 23F84 (lowered copy, `llvm-objdump --macho -d`; it has symbols).

## 1. Cause

**`a64-lower` wrote LSE stubs and trampolines into the headers of the cache files.** 19 of 84 files then fail a dyld check. dyld drops the reason for a subcache, and it never calls the kernel's map syscall.

Chain, each link [V]:

| # | Fact | Evidence |
|---|---|---|
| 1 | The headers are in the first r-x mapping. They hold long zero runs | `.01`: original bytes 0x188-0x1bf, 0x1d0-0x21f are zero |
| 2 | `zero_slots` takes zero runs of 64 bytes or more outside images and sections as free. The header belongs to no image | `tools/op10tool/src/lower.rs`, `taken` of `lower_cache` |
| 3 | `.01` offset 0x188 holds `ldr x30, [sp], #144`, 0x18c holds `b`: the tail of a stub | Lowered `.01`: `fe0749f8 d7410014`. Original: zero |
| 4 | Those two words are `subCacheArrayOffset` and `subCacheArrayCount`. dyld: `count > 0x7f` is "shared cache file subcache count exceeds limit" | `preflightCacheFile` 0x7e70c. `.01`: count 0x140041d7 |
| 5 | `mapSplitCacheSystemWide` gives `preflightSubCacheFile` its own local `SharedCacheLoadInfo` (0x7db50). On failure it returns false (0x7db70, 0x7dcd0). The message stays in the local copy | Disassembly |
| 6 | The main file passed, so `cacheFileFound` is 1 (0x7dff4) and `errorMessage` is NULL | Disassembly |
| 7 | `DyldCache` ctor: no load address + `cacheFileFound` prints `dyld cache '%s' not loaded: %s` (0x1bfd8) with the path field (never set at this point, always NULL) and that NULL message | Disassembly |
| 8 | The kernel never got a map call. A map call is followed by a third `check_np` (0x7de18), and every failed `check_np` prints. The log has two. A map failure also prints | Log + `bsd/vm/vm_unix.c` |
| 9 | Replay on the shared `lowered/`: `a64-preflight`: **65 of 84 pass, 19 fail, all with this check, first `.01`.** On the original cache: **84 of 84 pass** | `op10tool a64-preflight` |

zeta and IOS-26-Hot never saw this. Their tools edit words in place and add no code [V `rewrite-zeta-dyld-cache.py` text in the zeta README, `HANDOFF.md` of Hot]: their CPUs have LSE (Cortex-X1; A76). Only this CPU needs trampolines.

## 2. Answers to the questions

| Question | Answer |
|---|---|
| Syscalls from dyld start to the print, in order | `shared_region_check_np` (0x3a80, `hasExistingDyldCache`: log line 1); `sandbox_check` of `map_with_linking_np`, `__mac_syscall` (0x18de8, 0x1bd08: `SWEET Sandbox: launchd op 2`); open of `/System/Library/Caches/com.apple.dyld/` (0x1c308); `shared_region_check_np` (0x1582c, `reuseExistingCache`: log line 2); `fstatat` of `.development` (no file); `openat`, `fstat64`, `pread` 16 KiB, `fcntl(F_ADDFILESIGS_RETURN)`, `mmap` + compare, `munmap`, `pread` of the subcache table for the main file; the same for `.01`, which stops at the count. [V] |
| Not on this path | `__shared_region_map_and_slide_2_np` (0x7ddd4: not reached), `csr_*` (dyld has no such syscall or symbol), cryptex paths and libignition (commpage bit 3 skips `ignite`, 0x1c13c: **this replaces the [I] of `ios26-userland.md` 7.1 item 6**), `kern.dyld_flags` (0x1c04c, later). [V] |
| Does the system-wide path need an apple[] string or a platform flag? | No. Only `DYLD_SHARED_REGION=private` with env vars allowed selects the private path (0x1bd20). [V] |
| Does `check_np` returning 1 mean a region is present? | No. 0x1 is `KERN_INVALID_ADDRESS`: `sr_first_mapping` is -1, no mapping yet. `check_np` returns `ENOMEM`, and dyld goes on. **Both lines are normal on the first process** and stay after the fix. [V `vm_shared_region.c` 1093, `vm_unix.c`] |
| Wrong arch for a plain arm64 process? | No. dyld has the name `dyld_shared_cache_arm64e` (0x7df08) and the magic `dyld_v1  arm64e` (0x15844, 0x7e348) as constants. It reads no subtype here. zeta runs the same subtype on the same 23F84 cache to Home. Hot keeps arm64e with `ptrauth_disabled=1` and grades arm64e on the host. Ours: `ml_grade_binary` as `ios26-kernel.md` section 4. [V] |

## 3. Fix

- **Lowering rule** (`dsc.rs` `reserved_ranges`, `lower.rs`): a file's header and mapping tables are never free; all of a main file with no image is never free.
- **`a64-verify`:** a changed word in those ranges is a problem. It also runs the replay below.
- **`op10tool a64-preflight --cache FILE`:** the checks of `preflightCacheFile` 0x7e288, and of the kernel's `F_ADDFILESIGS_RETURN` (page shift, hash, 40 MiB limit, end offset) and map path (each mapping signed), on each file, with the reason dyld drops. `ios26-root.sh` runs it first and stops on a failure.
- **Kernel, `post/9003`:** one line for the result of each shared region map: `LAUREL DYLD: cache on: launchd[1] mapped 85 files, 107 mappings, slide 0x...`, or `cache off: ...` with the error.
- `lower-userland.sh`: `LOWERED=DIR` is a scratch output; the shared folder and link stay.

Results [V host], scratch run with `LOWERED`:

| Check | Result |
|---|---|
| `a64-verify` | Problems: none. `dyld preflight: files that pass` 84, fail 0 |
| Headers against the original | 84 of 84 the same, except `codeSignatureSize` |
| LSE sites | 626,471 bl + 173,890 stub, **0 no space** (the same as before) |
| Trampolines | 16,321 (was 16,327); 840,928 + 2,782,240 bytes |
| Free bytes offered | 36,327,508 (was 36,360,036) |
| Root Mach-O files | `macho-lowered.tsv` the same; `dyld`, `launchd` the same bytes |
| Determinism | Same SHA-256 for all cache files in both runs |
| Selftest, census | Exit 0 |
| Unit test | `lower_keeps_cache_headers_and_preflight_finds_code_there`: a stub at 0x188 gives this failure |
| Kernel | 0 errors, 0 LSE/RCpc, `printf-arg-check` OK, armv80 0 |

What this does not show: that dyld maps the cache on the phone. **That needs a new boot.**

## 4. Next boot

Expected, in order. A missing line is the result:

```
shared_region: ... check_np(...) vm_shared_region_start_address() returned 0x1     twice, normal
SWEET Sandbox: launchd op 2
shared_region: ... map(...:'dyld_shared_cache_arm64e...'): not in trust cache      84 lines [V code]: normal, see 5.3
LAUREL DYLD: cache on: launchd[1] mapped 85 files, 107 mappings, slide 0x...
```

No `dyld cache '(null)'` and no `Library not loaded`. Then `<Notice>: boot-args = ...`, `Doing boot task`, `exec mount` (`ios26-first-boot.md`, stages 4 and 5).

| You see | Meaning |
|---|---|
| Same `(null)` line, no `cache on` | A subcache fails again: `op10tool a64-preflight --cache` on the files of that root |
| `cache off: ...` | The kernel refused: the line before it names the check |
| `cache on`, then `CRASH launchd` or a fault | Section 5 |

## 5. Next likely blockers

| # | Item | State |
|---|---|---|
| 1 | **Slide pager on 4 KiB pages, first real run** (`shared_region_pager_data_request`). The slide is tested on the host; the VM part never ran | [I] most likely next. Sign: SIGBUS or SIGSEGV in `__DATA_CONST` or libdyld, `CRASH launchd`. Zeta hit this point twice |
| 2 | **`LAUREL EMU` kernel path, first real run** (cache: 10 LSE words with x30, FP16; root: `logd`, `watchdogd`) | [I] Sign: `LAUREL EMU` lines, panic in `sleh`, SIGILL |
| 3 | SIP, `lp-sip0` | **Not a blocker** [V]: `0x6f` in `out/laurel-ios26/uefi-rw/laurel.adt`, has `CSR_ALLOW_UNRESTRICTED_FS`. Zeta's "vnode is not SIP-protected" should not show. This kernel builds the macOS branch (string in the binary): trust cache miss prints a line per file, then the root check; the manifest has uid 0 |
| 4 | Code signing page shift | **Not a blocker** [V]: shift 12 accepted, replay passes, `cs_validate_range` returns at once under `TOPAZ_4K` |
| 5 | Region size | **Not a blocker** [V]: `SHARED_REGION_SIZE_ARM64` 0x180000000; cache 0x1403d0000 + max slide 0x20000000 fit. `_SR_FILE_MAPPINGS_MAX_FILES` 256: 85 used |
| 6 | Page-in linking | **Not a blocker** [V both sides]: dyld mode 2 (0x18d48). launchd chains have page size 0x4000; the kernel answers `KERN_INVALID_ARGUMENT` with no print for `mwli_page_size != PAGE_SIZE`; dyld then links in-process (0x2aed0). Cost: CPU at each start |
| 1a | **Seen at boot 8**: `pc 0x100000000` in 48 daemons, launchd reboots: not the slide pager. `ios26-entry.md` | [V] fixed on the host |
| 7 | dyld closures | [I] not a blocker: lowered launchd has a new cdhash, so its prebuilt set is refused and dyld uses `JustInTimeLoader`; header UUIDs stay. Zeta has the same |
| 8 | Dynamic region | [V code] dyld stops with `dyld shared region dynamic config data was not set` if the file ID is empty (0x1c098). HFS gives device and inode: [I] fine |
| 9 | Boot task `mount -P 1` | [V code]: no `/filesystems/fstab`: "failed to get filesystem info", not fatal. Env 0: "data volume missing, but not required". `_APFSContainerGetBootDevice` fails: up to 5 tries, a delay. 23F84 `mount` has no `boot-manifest-hash` string. `cc_fips_test`: HMAC resealed [V host], never run. `init_data_protection`, `tzinit`, `fsck -qL`: [U] |
| 10 | `launchd.plist` cache | `launchd_unsecure_cache=1` is in the boot-args [V]; `ios26-first-boot.md` section 2. Never run |
| 11 | `KERNEL SERIES DIFFERS` at boot 7 | The root is older than the kernel. Build the kernel first, then the root |

## 6. Commands

```sh
scripts/bg.sh op10tool scripts/setup/build-op10tool.sh
scripts/bg.sh ios26-lower env DEV=n104ap scripts/ios26/lower-userland.sh    # rewrites the shared lowered/, some minutes
scripts/bg.sh ios26-kernel scripts/laurel/kernel-ios26-linux.sh
scripts/bg.sh ios26-root env FORCE=1 scripts/laurel/ios26-root.sh           # stops first if a cache file fails the replay
```

Then the root and boot image go to the phone with the steps of `dual-boot.md` (owner's yes for each write).
