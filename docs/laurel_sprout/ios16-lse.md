# Mi A3 iOS 16: EL0 LSE emulation of topaz 0081, fixed by laurel 2960

Date: 2026-11-02. Branch `t3/laurel-ios16-lse`. **Host only. Nothing here has run on the phone. No flash, no reboot, no adb, no fastboot.** Labels: [V] seen here (source, disassembly, host test), [I] inference, [U] unknown.

The iOS 26 kernel work found bugs 1 and 2 (`ios26-userland.md` 7.3). Owner order: fix on iOS 16, as a new patch; do not risk the first iOS 26 boot.

**No evidence that these bugs caused the owner's random crashes on iOS 16.** 41 boot and USB logs in `logs/` of the main checkout: 2 files hold one `Kernel data abort` (the same event): esr 0x96000047, far 0xfffffff94bc40000, a kernel address, no `_sweet_lse` name. That is not this bug: here the far is a user address. [U] how often the iOS 16 userland reaches an LSE word at all. The test to run on the phone: a panic with pc in `__sweet_lse_*` and a low far before this patch; none after it.

## 1. The bugs

| # | Bug in 0081 | Effect | How read |
|---|---|---|---|
| 1 | Its 4 `COPYIO_RECOVER_RANGE` entries come after `copyio_recover_table_end`, because 0081 appended the code after the line "THIS MUST STAY LAST" | `find_copyio_recovery_entry()` misses them. `handle_kernel_abort()`: `recover == 0`, so vm_fault on `kernel_map`, it fails, `Kernel data abort` **panic**. Each fault in an emulated word: first write to a COW page, a page not there yet, a bad pointer | [V] old kernel (`copyio-table-check.py`): section 0x180 bytes, table 0x120 bytes, 12 entries, outside the table 0x60 |
| 2 | LDUMIN: `csel ..., lo` runs after `cmp w1, #6`, with w1 = 7 | C is set, `lo` is false: memory always gets the operand. Old value below the operand: wrong memory | [V] source; host test: 4 of 4 sizes fail before, pass after |
| 3 | A bad pointer, or an unaligned word: `return false`, so EXC_BAD_INSTRUCTION | The real word gives EXC_BAD_ACCESS. Found by the truth test (and `ios26-userland.md` 7.3) | [V] host test |
| 4 | A top byte on the pointer: above the limit, so EXC_BAD_INSTRUCTION | The real word ignores it (TBI0) | [V] host test |
| 5 | LDAPR: A and R not checked: `A = 0` or `R = 1` ran as a load | These words are undefined | [V] host test |

## 2. The fix: `patches/laurel/xnu/2960-laurel-lse-emulation.patch`

- `machine_routines_asm.s`: the table end moves to the end of the file, after the LSE code. `cmp` of the values before the LDUMIN `csel`.
- `sleh.c`: `sweet_lse_bad_access()`, `sweet_lse_fault()`: EFAULT gets a second `vm_fault` (THREAD_ABORTSAFE), as `handle_user_abort()` does. Success or KERN_ABORTED: back to EL0 on the same word. Else EXC_BAD_ACCESS with the real code and address, PC on the word, no register changed. Same design as `laurel_abi.c` of iOS 26.
- Address: the top byte is stripped before the access. Bit 55 stays in the value, so an upper half address is above the limit and never reaches the access [V rules: 0 calls]. Alignment first, as the CPU.
- No boot-arg and no log line: this repairs a path that exists.

Real kernel [V]: `copyio-table-check: section 0x180 bytes, table 0x180 bytes, 16 entries, outside the table 0x0`. Entries 12-15 of the built table are `__sweet_lse_b/h/w/x`, length 216, recovery `copyio_error`. Disassembly of `__sweet_lse_h`: `cmp w1, #0x6; b.eq; cmp w10, w2; csel w11, w10, w2, lo`.

`scripts/laurel/copyio-table-check.py` now runs in `kernel-linux.sh` and in `ios26-kernel-check.sh`: a range outside the table stops the build.

## 3. iOS 26: not applied

`patches/laurel/xnu-12377/skip.txt` has 2960, reason in the file. This kernel has its own LSE path (`laurel_a64emu`) and post/9000 moved the table end. Its 0081 text stays only behind `laurelemu=0`, with bug 2 in it: not changed, on purpose.

Baseline f1f8216 against the branch, same checkout and path [V]:

| Check | Result |
|---|---|
| `diff -r` of the source trees (no `.git`, no `BUILD`) | 1 file: `bsd/dev/laurel_build_stamp.h`, its stamp |
| Git trees of each series step (`--dev`) | all equal |
| Kernel size | 20,176,520 and 20,176,520 bytes |
| Bytes that differ | 91, in 10 runs: LC_UUID, the series hash, the stamp (2 copies), date and tree name of the version string (2 copies) |
| Series report | one new line `skipped: not needed`; 7 skipped becomes 8 |

## 4. Truth test: `scripts/laurel/test-lse0081.sh`

Same harness as `test-a64emu.sh` (`tools/laurel-a64emu/test/harness.c` with `-DLSE0081`, parts in `tools/laurel-lse0081/`). It compiles the text of the **patched kernel tree** (`extract.py`), not a copy. Truth: the real word on qemu 11.1.3 `cortex-a76` (LSE, RCpc, no LSE2: an unaligned atomic faults, as on an A11). The emulator: the same stream on `cortex-a53`: the word traps, then `sweet_emulate_lse` and `_sweet_lse_*`. Compared per case: x0-x30, SP, NZCV, V0-V31, FPSR, memory, outcome. Faults go through a table of the kernel's layout, and a table miss counts as a panic. qemu is the truth here, not an A11.

Fault cases in the stream: unmapped, above the limit, kernel addresses, bit 55, top byte, unaligned, read-only page, zero fill, COW (the last two only for the emulator: for the real word the kernel handles the page fault).

| Run | Cases | Mismatches | Table misses | Rules |
|---|---:|---:|---:|---|
| After (0081 + 2960) | 2,000,010 | 0 | 0 | 138 checks, 0 failures |
| Before (2960 taken back) | 200,010 | 79,810 | 33,244 | 138 checks, 79 failures, 10 panics |

The "before" run must show the bugs, or the script fails: the test sees them.

Real word by outcome in the "after" run [V]:

| Word | ok b | ok h | ok w | ok x | fault b | fault h | fault w | fault x |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| ldadd | 7227 | 6601 | 6446 | 6412 | 1760 | 2206 | 2484 | 2587 |
| ldclr | 7166 | 6801 | 6377 | 6345 | 1751 | 2292 | 2487 | 2567 |
| ldeor | 7225 | 6582 | 6501 | 6329 | 1833 | 2274 | 2502 | 2575 |
| ldset | 6998 | 6785 | 6351 | 6339 | 1860 | 2160 | 2446 | 2567 |
| ldsmax | 7015 | 6783 | 6391 | 6319 | 1834 | 2241 | 2508 | 2650 |
| ldsmin | 7168 | 6847 | 6542 | 6364 | 1783 | 2145 | 2460 | 2538 |
| ldumax | 7093 | 6714 | 6442 | 6344 | 1791 | 2281 | 2404 | 2604 |
| ldumin | 7119 | 6548 | 6628 | 6260 | 1752 | 2256 | 2472 | 2588 |
| swp | 64077 | 60083 | 58291 | 56888 | 16331 | 20024 | 22616 | 23539 |
| cas | 60931 | 57050 | 55107 | 54637 | 12623 | 16660 | 18441 | 19219 |
| ldapr | 76194 | 71668 | 68701 | 68244 | 13169 | 17994 | 20458 | 21072 |

Not in 0081, must stay undefined: 740,273 cases, 740,273 undefined on the real word.

Threads, `cortex-a53`: LDADDAL trap x4 + user LL/SC x4: 1,600,000 of 1,600,000. A lock by CASAL trap x4 + LL/SC x4, plain counter under it: 1,600,000 of 1,600,000.

The iOS 26 test still passes with the changed `harness.c`: `CASES=400000 EXH=0 test-a64emu.sh lse rcpc casp`: 400,010 cases each, 0 mismatches, rules 203, `test-a64emu: PASS`.

## 5. What the test does not show

The kernel path never ran: `vm_fault`, exception delivery, signal, preemption, a real A53 or A73 exclusive monitor. The memory order is not tested: qemu has no weak order to show. Shim names in `lse0081_shim.c` stand in for the kernel's; only the compile of `kernel-linux.sh` checks the real ones.

## 6. Known and not changed

| Item | State |
|---|---|
| CAS with a failed compare on a read-only page | qemu faults; this code gives the old value and no fault. The iOS 26 emulator does the same. Kept: it cannot make a new crash. It is in the rules, not in the stream |
| CASP | Not in 0081: stays EXC_BAD_INSTRUCTION |
| No bound on the LL/SC loop | A store-exclusive that always fails (memory with no monitor) holds the thread in the kernel. The iOS 26 emulator stops after 4096 tries. [U] on this phone. Not found by a test; not changed |
| SP as base, not 16-byte aligned; single step over a word | iOS 26 handles them; here not. qemu shows neither |
| LDAPR on the commpage (above `MACH_VM_MAX_ADDRESS`) | Still refused, now with EXC_BAD_ACCESS. [U] whether a word does this |
| iOS 26 `laurelemu=0` path | Still has bug 2 |
