# Mi A3 iOS 26: why daemons jumped to 0x100000000, why launchd rebooted

Date: 2026-11-02. Boot: `logs/ios26-boot8.txt` of the main checkout, from line 10733. **The fix ran on the host only. No flash, no phone boot.** Labels: [V] read in code, disassembly or a file, or run here. [I] inference. [U] unknown. Addresses: unslid cache addresses, or `dyld+offset` of `usr/lib/dyld` 23F84.

## 1. Cause

**The lowering tool wrote LSE trampolines over `ANECompiler`'s `__text`, because a dead-image list said it never loads. It loads in most daemons. dyld runs its initializers, and they are now trampoline bytes.**

Chain, each link [V]:

| # | Fact | Evidence |
|---|---|---|
| 1 | `lower-userland.sh` passed `--dead-image ANECompiler.framework/ANECompiler`. The tool then does not lower that image, and offers its 21 MB `__text` to the trampoline planner | Script at 146e22c; `lower.rs` `lower_cache` |
| 2 | ANECompiler has `__init_offsets` of 8 bytes: offsets 0xd38 and 0xd84 from its header 0x1a753a000. They are the same in the original and in the lowered cache | Section table; `lowered/` |
| 3 | In the lowered cache 0x1a753ad38 is the head of a trampoline. 0x1a753ad84 is **the middle of another**: `ldaxr x10,[x8]; add; stlxr; cbnz; mov x22,x10; ldp x12,x13,[sp,#16]; ldp x10,x11,[sp]; add sp,sp,#176; ret`. The `sub sp,sp,#176` is 3 words before the entry | Disassembly, original against lowered |
| 4 | `dyld`, `findAndRunAllInitializers` block at `dyld+0x628d0`: frame of exactly 0xb0 = 176 bytes. `blr x9` at `dyld+0x62980` calls each initializer | Disassembly |
| 5 | The initializer at 0xd84 returns with sp 176 too high. dyld goes on: `ldp x29,x30,[sp,#0xa0]` at `dyld+0x6298c` reads two words of its caller's frame: 0 and 0x100000000. `add sp,sp,#0xb0; ret` | Trace below. **So the pc is a stale stack word, not an entry point** |
| 6 | Host replay: the program runs from dyld's first instruction on the old `lowered/`: `pc 0x100000000 lr 0x100000000 sp 0x16eebb090 fp 0`, the same four values as phone line `CRASH runningboardd pc 0x100000000 lr 0x100000000 sp 0x16eebb090 fp 0x0` (with the phone's exe slide 0xf40000). watchdogd: depth 0x4d50, the phone's depth. Those two runs had the first `apple[]` strings of the replay; each string moves sp in steps of 0x10, so the present default gives sp 0x16eebb070 for runningboardd | `scripts/laurel/ios26-user-emu.py` |
| 7 | Last blocks of the trace: `dyld+0x62958`, `ANECompiler+0xd38`, `ANECompiler+0xd54`, `dyld+0x62984`, `dyld+0x9778`, `dyld+0x6298c` (next initializer) `dyld+0x62958`, `ANECompiler+0xd84`, `ANECompiler+0xd94`, `dyld+0x62984` ... `dyld+0x6298c`, fault at 0x100000000 | `--trace-after` |
| 8 | Who dies: the run shows the initializers of ANECompiler run in the crashers (10 images with initializers up to it), and not in notifyd, keybagd, logd, fseventsd, remoted | Host runs |

The old report said [I] "they never load". That was wrong, and nothing tested it.

## 2. The lead, and what else was tested

| Claim | Result |
|---|---|
| SETEXEC exec gives a wrong pc (xpcproxy) | **False** [V]. `exec notifyd`, `configd`, `logd`, `remoted` go through the same xpcproxy and live. The depth also shows it: at entry sp is 0x320-0x400 below the stack top, and the crash is at 0x4d50-0xbb30 |
| The crash is at the entry | **False** [V]. sp is at the same depth in every boot for each binary, and deep: `prepare()` alone has a frame of 0x3c00 or more, which grows with the image count. That is the reason the depth follows the number of loaded images |
| `load_result.entry_point`, `thread_setentrypoint`, `exec_mach_imgact`, LC_MAIN, `dyld_start` | Not the cause [V]: dyld and the libSystem initializer run. The same files reach `main()` once the image is lowered |
| `ptrauth_disabled` | Not the cause [V]: this kernel does not pass it (`kern_exec.c` 7409, only under `ptrauth_calls`), and it plays no part: the host replay has no such string, and it gives the same crash and, with the fix, reaches `main()`. IOS-26-Hot 0129 passes it; not needed here so far |
| `blraa`/`retab` lowered wrong | Not the cause [V]: 5,553,303 retab rewritten, `a64-verify` none wrong; the bad return is a plain `ret` after a stack that an entry into the middle of a trampoline moved |
| cdhash closures | Not the cause [V]: dyld uses `JustInTimeLoader` for the program, and the crash is after the program's closure is done |
| Fixups, slide | Not the cause [V]: host replay applies slide v5 as the kernel does, and gets the same crash |
| Other pc values in the log | `0x...a40`, 4 times: UserEventAgent, section 4. `0x190627800` and 3 others: `devicerecoverytool`, `driverkitd`, Swift fatal errors (`brk` after a call that returned: pc = lr by design). Section 5 |

The value 0x100000000 is a local of `dyld`'s caller frame [V where it is read, I what it means]. That it equals the program's unslid base is likely no accident (a load address in a dyld local), but it plays no part.

### `LAUREL EMU: counts pac=1`

[V host] The first trap is `braaz x16` at 0x2a353075c, `libsystem_platform` +0x775c, the end of a variant resolver thunk (`bl` resolver, store, `ldp x29,x30`, `autibsp`, `braaz x16`). The report prints at the first trap, and then every 60 s, so it says 1. These words are in the tool's "left, not proven code" list (22 `braaz`, 207 `retab`, ...). The kernel emulator does what the tool would do. Not a blocker. Next hits in the same run: 0x2a35306f0 `braaz`, 0x180674f68 `retab` (`libswiftCore`), 0x1800d93c0 `retab` (`libobjc`).

## 3. Fix

- **`scripts/ios26/lower-userland.sh`:** `DEAD` has only `VisualGeneration`. Its 2.7 MiB `__text` has all 47,899 sites in reach, and they need 0.7 MiB. ANECompiler was never needed for space.
- **`op10tool a64-lower` and `a64-verify`:** a dead image with `__init_offsets`, `__mod_init_func`, thread-local initializers, `__objc_nlclslist` or `__objc_nlcatlist` is an error. Unit test `dead_image_with_load_time_code_is_refused`. VisualGeneration has none of them [V section table]: only lazy ObjC classes and Swift metadata, which are data until something uses them.
- **Host test `scripts/laurel/test-ios26-user-emu.sh`:** runs each program from dyld's first instruction until `main()`, under Unicorn on a cortex-a72 (no PAC, no LSE, as the phone). The kernel is a small fake: 40 syscalls and traps, slide v5 on demand. Not a proof of what follows `main()`.

### Results [V host]

| Check | Old `lowered/` | Scratch with the fix |
|---|---|---|
| `test-ios26-user-emu.sh` (runningboardd, watchdogd, DumpPanic, seld, powerexceptionsd, notifyd) | 5 of 6 `pc 0x100000000`, notifyd reaches `main()` | **6 of 6 reach `main()`** |
| `CRASHLOG=logs/ios26-boot8.txt` (the 48 programs with `sig 11` on the phone) | | 46 reach `main()`; routined alone: reaches `main()`; locationd alone: no result in 280 s (the replay spins or is slow there, [U]); on the phone it died with the others |
| LSE sites, no space | 0 | **0** |
| Bytes: trampolines + stubs | 840,928 + 2,782,240 | 844,268 + 2,785,632 |
| One-word edits | 29,451,474 | 29,625,698 (ANECompiler now lowered) |
| `a64-verify` | none | **Problems: none**, preflight 84 of 84 |
| `a64-selftest` | | 7,687 words, 30,748 cases, 0 mismatches |
| Determinism | | same SHA-256 in both runs |

What this does not show: that the phone boots past this. **That needs a new boot.**

## 4. UserEventAgent: a second, separate kill

```
CODE SIGNING: cs_invalid_page(0x1010e8000): p=25[UserEventAgent] final status 0x23003200, denying page sending SIGKILL
CRASH UserEventAgent[25] sig 9 ... pc 0x1010eba40 lr 0x10105f150 (dyld+0x8fa40 _mach_continuous_time, called from start)
```

[V] 23F84 signs this one file with CodeDirectory flags 0x3202 (CS_KILL, CS_ENFORCEMENT, CS_REQUIRE_LV). The lowered root keeps the flags. 2,133 other programs have 0x2, 57 have 0x2002, 20 have 0x10002, 2 have 0x12302: no other has CS_ENFORCEMENT. `vm_page_validate_cs()` validates nothing under `TOPAZ_4K` (`ubc_subr.c` 6128). So `vm_fault_cs_check_violation` sees an unvalidated code page in an enforcing map. It kills in dyld, before any code of the program. UserEventAgent is the host of LaunchEvents, so jobs that wait on its events do not start [I].

[U] Why dyld's first code page passes and page 0x8f000 does not. It does not change the fix.

**Fix: `post/9004-laurel-cs-no-page-hash.patch`** (12377 only, the iOS 16 path is not touched): under `TOPAZ_4K` an unvalidated code page is no violation. The other uses of CS_ENFORCEMENT stay (W^X in `vm_map_protect`, immutable pages). One line at the first such page: `LAUREL CS: off: no page hash check on 4 KiB pages: CS_ENFORCEMENT does not stop an unvalidated code page, first UserEventAgent`. Kernel builds: 0 errors, LSE/RCpc 0, printf OK, armv80 0.

## 5. Why launchd reboots again and again

Line: `<Critical>: rebooting due to critical process crashes: runningboardd` [V log, each boot, about 11 s after `exec launchd`]. Then launchd runs `/usr/libexec/devicerecoverytool`, which stops with a Swift error (`could not get registry entry`, signal 5). Then the `shutdown` state list and `Rebooting to device recovery environment`.

| Item | |
|---|---|
| Who asks | launchd, code at 0x100021c4c. Not watchdogd, not a panic [V] |
| Test | Crash exit, and service flag bit 60 (`[x19,#0x587]` bit 4), and crash count in the last 60 s == `[x19,#0x414]`. Default count 3 (0x100009320, 0x10000641c) [V]. The window: `ios26-backboardd.md` section 4 |
| Why runningboardd first | Its job has `ThrottleInterval 1` [V]: 3 crashes in 1.5 s (pids 27, 105, 107). Other jobs have 10 s, so they reach 2 before this [I] |
| Where the flag comes from | Handlers at 0x10000b668 (`_RecoverOnCrash`, a job key) and 0x10000ea18 (`RecoverOnCrash`). The job has no such key. **Source found in boot 9: the key in the jetsam file: `ios26-backboardd.md` section 4** |
| The feature gate | 0x100049f9c: returns true when launchd is younger than 300 s or a byte is 0. False prints `Feature disabled, device would have rebooted due to %s` [V] |
| Does the fix of section 1 settle it? | [I] Yes: runningboardd reaches `main()` [V host]; the rule needs 3 crashes in a row |
| A clean way to stay up with SSH | Boot 9 needed it: `no_recover_on_crash()` in `ios26-root-spec.py`: `ios26-backboardd.md` section 4 |

## 6. Next boot

Expected, in order. A missing line is the result:

```
LAUREL DYLD: cache on: launchd[1] mapped 85 files, 107 mappings, slide 0x...
LAUREL EMU: counts pac=1 ...                                                 the first trap, as before
Early boot complete. Continuing system boot.
exec UserEventAgent
LAUREL CS: off: no page hash check on 4 KiB pages: ... first UserEventAgent
LAUREL SSH: on: dropbear pid ...
exec runningboardd
```

And **no** `pc 0x100000000`, **no** `rebooting due to critical process crashes`, **no** `CODE SIGNING: cs_invalid_page`.

| You see | Meaning |
|---|---|
| `pc 0x100000000` still | The root still has the old cache: check `dead images` in `lowered/lower-report.md` |
| `CRASH ... pc` in a `0x1...` not `0x100000000`, with a frame | Real work of that daemon now. Section 7 |
| `rebooting due to critical process crashes: X`, X new | That X loops: read its first `CRASH` |

## 7. Next likely blockers

| # | Item | State |
|---|---|---|
| 1 | **What daemons do after `main()`, first real run**: IOKit user clients, `AppleKeyStore`, entitlement checks, memory limits | [I] most likely. Host replay stops here: it has no workqueue and no launchd |
| 2 | `driverkitd`: Swift fatal at sp 0xd20 at shutdown, `exceeded mem limit: ActiveSoft 6 MB` (non-fatal). Text of the error [U] | Seen in boot 8, 4 times. Read `driverkitd.swift`-class line in the next log |
| 3 | `devicerecoverytool` `could not get registry entry` | [V] only on the reboot path. Not a blocker if nothing reboots. A registry key is missing: reads at the next log if it runs |
| 4 | `LAUREL EMU` kernel path, the real load: 10 LSE words with x30 in the cache, 5,460 LSE words in 16 root files (`logd`, `watchdogd` 7 words), FP16 | [I] Sign: `LAUREL EMU` counts, SIGILL. Host runs emulated only PAC branches, no LSE reached |
| 5 | Compositor: backboardd on Metal, `ios26-metal.md` section 7 | Not reached yet |
| 6 | SpringBoard: `laurel-springboard` start, notch and status bar hooks on 23F84, `ios26-first-boot.md` section 8 | Not reached yet |
| 7 | `launchd`: `Could not opt into 50 MB Jetsam high watermark: 22`: a log line, boots go on | [V log], not a blocker |

Also read: `ANECompiler` now runs its initializers. Its code is lowered like any other image. If a daemon uses it, it runs on the CPU; this phone has no ANE, and callers test that first [I].

## 8. Commands

```sh
scripts/bg.sh op10tool scripts/setup/build-op10tool.sh
scripts/bg.sh ios26-lower env DEV=n104ap scripts/ios26/lower-userland.sh    # rewrites the shared lowered/, about 1 minute
scripts/bg.sh ios26-user-emu scripts/laurel/test-ios26-user-emu.sh          # PASS: 6 programs reach main()
scripts/bg.sh ios26-kernel scripts/laurel/kernel-ios26-linux.sh
scripts/bg.sh ios26-root env FORCE=1 scripts/laurel/ios26-root.sh
scripts/bg.sh ios26-image scripts/laurel/ios26-image.sh
```

Then the root and boot image go to the phone with the steps of `dual-boot.md` (owner's yes for each write).

One program by hand, with the images whose initializers ran:

```sh
EMU_LOWERED=DIR scripts/laurel/ios26-user-emu.sh /usr/libexec/runningboardd --inits
```
