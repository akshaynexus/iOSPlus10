# Mi A3: can the iOS 26.5.2 23F84 userland run on an ARMv8.0 CPU?

Date: 2026-11-02. Branch `t3/laurel-ios26-userland`. **Host results only. Nothing here ran on the phone.**
Marks: **[V]** measured here (command, file, tool output). **[I]** inference or estimate. **[U]** unknown.

## 1. Verdict

**Viable only with the named conditions below. Not ruled out at the instruction level. Not proven to run.
Not a usable phone on this GPU today [I].**

- [V] The instruction problem is solved on the host. After the lowering, the cache keeps **0 proven non-hint PAC words**
  and **10 proven LSE words** (they use x30). Root binaries keep 5,462 proven LSE words in 16 files. The qemu test ran
  30,748 cases on 7,687 LSE words with 0 mismatches.
- [V] The harder problem is the renderer, not the CPU: in 23F84 the render server has **no GLES fallback**
  (`CA::WindowServer::AccelServer::renderer` is Metal or nothing). In iOS 16 the same function (`EAGLServer::renderer`)
  falls back to `GLESContext`. So our iOS 16 GL path does not carry over without a patch to QuartzCore.
- [V] Metal apps run on this GPU under iOS 16 (Turnip + metal2vulkan, first at the boot of 2026-11-01 18:40, `docs/plan.md`), with known black layers.
  But `backboardd` stays on GL (client rule `* -backboardd`, `metal.md`). **The compositor has never run on Metal on this GPU.** iOS 26 needs exactly that,
  or a GLES hook that nobody has tried.
- [I] zeta on Cortex-X1 + Adreno 660 is at the Home screen with black backgrounds and lag. Ours has a CPU about 3 to 5 times
  slower per core and a much weaker GPU. Expect a research boot, not daily use.

Conditions, all required:

| # | Condition | State |
|---|---|---|
| C1 | Kernel track: xnu-12377 for ARMv8.0 and 4 KiB pages with section 7 "kernel needs" | separate track, not boot-tested on this CPU |
| C2 | Undefined-instruction emulation in the kernel for what the tool leaves (section 5) | not written |
| C3 | The compositor on Metal through Turnip + metal2vulkan on the Adreno 610, or a hook that gives `AccelServer::renderer` a GLES context | [U] neither tried: iOS 16 keeps backboardd on GL |
| C4 | The commpage and `hw.optional` report ARMv8.0, so Apple's gated SME, SVE, AMX, MTE and SPRR code stays off | [I] zeta evidence, not tested here |
| C5 | The owner accepts low speed. No number exists for this phone | [U] |

If C3 fails, the plan stops. Next best real option: section 9.

## 2. Donor (owner decision)

**iPhone 11, `iPhone12,1`, N104AP, A13, iOS 26.5.2 23F84.** Not iPhone12,3: that is the negroni choice in
[../future-ios26.md](../future-ios26.md), and negroni stays unchanged (`scripts/ios26/donor.sh`, default `DEV=d421ap`).

| Item | Value |
|---|---|
| URL | `https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-26331/A86BA9CA-4666-4AD9-BF0D-14700375EF03/iPhone12,1_26.5.2_23F84_Restore.ipsw` |
| SHA-256, size (ipsw.me) | `174dc7eae48af470563db67c9ae380ceb34e8e3e91a327371fe481fef53f6cca`, 9,750,283,647 bytes |
| OS image | `094-55773-107.dmg.aea` 7,180,648,448 bytes; decrypted 8,409,579,520 bytes [V] |
| SystemOS | `094-56417-109.dmg.aea` 2,013,265,920 bytes; decrypted 5,221,908,480 bytes [V] |
| AppOS | `094-54871-112.dmg` 14,680,064 bytes [V] |
| Kernelcache, ADT, GPU firmware | `kernelcache.release.iphone12b`, `Firmware/all_flash/DeviceTree.n104ap.im4p`, `Firmware/agx/armfw_g12p.im4p` [V] |
| ADT `/product` | `artwork-scale-factor` **2** [V: this replaces the owner's inference], `artwork-device-subtype` 0x700, `device-perf-memory-class` 3, `artwork-display-gamut` "P3", `compatible-device-fallback` "iPhone11,8", `product-name` "iPhone 11" |
| ADT `/chosen` `display-scale` | 0 (a placeholder in the file, not the scale) [V] |

No iPhone12,3 file was counted. A wrong first start wrote iPhone12,3 partial files for about 8 seconds because tmux did not
pass `DEV`. I deleted them. Use `scripts/bg.sh NAME env DEV=n104ap SCRIPT`.

Commands (Linux, no root):

```sh
scripts/bg.sh ipsw-cli scripts/setup/get-ipsw-cli.sh
scripts/bg.sh op10tool scripts/setup/build-op10tool.sh
scripts/bg.sh ios26-donor env DEV=n104ap scripts/ios26/fetch-donor.sh
scripts/bg.sh ios26-os    env DEV=n104ap scripts/ios26/fetch-os.sh
scripts/bg.sh ios26-tree  env DEV=n104ap SYMBOLS=1 scripts/ios26/sysos-tree.sh
scripts/bg.sh census out/bin/op10tool a64-census --cache $T/cache/dyld_shared_cache_arm64e --root $T/root --out out/ios26/census-n104ap
scripts/bg.sh ios26-lower env DEV=n104ap scripts/ios26/lower-userland.sh
```

`T=~/op10-apple/ios26/23F84-n104ap/tree`. The fetch took about 4 minutes. The census takes 30 seconds to 5 minutes.

## 3. Census (Step 1)

Method [V]: `op10tool a64-census` (Rust, rayon) reads every instruction section of the 84 cache files and the stub islands, and
all arm64e slices of 3,451 root files. **llvm-mc 23.1.4 decodes every unique word**: first with `-mcpu=cortex-a73` (armv8-a + crc,
aes, sha2: the phone), then with all features, then one feature at a time. So class names come from LLVM's feature table.
Our hand decoders for LSE and PAC agree on every word (`decoder-check.txt` empty: LSE 6,478/6,478, PAC 918/918 unique words).

- **linear** = every word in a section, data included. **proven** = in a function range with no undecodable word, reached by a
  flow walk, or a stub. **A13** = LLVM's `apple-a13` decodes the word too. A word that fails this cannot run on a real iPhone 11, so
  Apple's own code gates it behind a CPU check.
- Size [V]: cache 784,854,119 words (2,993 MiB) in 4,301 images, 99.74 % proven. Root 254,969,221 words (972 MiB) in 3,413 arm64e
  slices, 99.99 % proven. 47,428,738 unique words. Shared region 0x180000000, size 0x1403d0000, max slide 0x20000000.

### 3.1 Must be handled (an A13 runs these, ARMv8.0 does not)

| Class | v8.0 result | Cache linear | Cache proven | Root proven | Top users |
|---|---|---:|---:|---:|---|
| Non-hint PAC (`braa blraa retab ldraa pacia autda xpacd pacga` ...) | UNDEF | 29,528,181 | **29,527,482** | **9,866,887** | all images |
| LSE (`cas swp ld<op> st<op> casp`) | UNDEF | 802,774 | **802,693** | **67,984** | WebCore 164,753, WebKit 65,335, Recon3D 58,046, AppleCV3D 49,488, libusd_ms 46,336, JavaScriptCore 40,561 |
| RCpc `ldapr` | UNDEF | 133,953 | **133,952** | **16,521** | MLIR_ML 23,070, MPSGraph 16,329, ANECompiler 11,957 |
| RCpc2 `ldapur stlur` | UNDEF | 111 | 1 | 1 | |
| FP16 (`fadd fmul fcmp fmov fmla` on h registers) | UNDEF | 69,866 | **69,770** | 177 | libBNNS 23,447, VideoToolbox 16,234, CoreGraphics 2,762, vImage 2,335, RenderBox 829, swiftCore 300, QuartzCore 280, JavaScriptCore 247 |
| FCMA (`fcmla fcadd`) | UNDEF | 25,057 | 25,045 | 0 | libBLAS 25,037 |
| SHA3/SHA512 (`eor3 bcax rax1 xar sha512h`) | UNDEF | 1,400 | 1,377 | 288 | libcorecrypto 272, libMobileGestalt 208, dyld 144 |
| DotProd (`sdot udot`) | UNDEF | 994 | 993 | 0 | AV1SW encoder 985 |
| JSCVT (`fjcvtzs`) | UNDEF | 461 | 461 | 0 | JavaScriptCore 449, WebCore 12 |
| FHM (`fmlal`) | UNDEF | 120 | 112 | 0 | libBNNS |
| RDM (`sqrdmlah`) | UNDEF | 7 | 0 | 0 | |
| AMX word `(insn & 0xfffffc00) == 0x00201000` | UNDEF | 664,069 | 419,408 (both neighbours decode) | 0 | libBLAS 152,788, libLAPACK 73,358, libBNNS 57,479, Hands 54,126 |
| Apple EL0 registers + `msr DIT`, `mrs DIT`, `sb` | UNDEF | 10,154 (with SME below) | 1,020 | 674 | `S3_6_C15_C1_5` 770 (SPRR/TPRO [I]), DIT 183 (corecrypto) |

Apple-only opcode space `0x00200000-0x00203fff` [V `apple-opcodes.tsv`]: 664,069 words in the AMX block `0x00201000`, 4 at `0x00200000`, 1 at `0x00202800`. LLVM decodes none of them. No other Apple-only group appears in the undecodable list.

### 3.1.1 LSE by size and operation (cache linear) [V `lse-forms.tsv`]

| op | byte | half | word | double | root (all sizes) |
|---|---:|---:|---:|---:|---:|
| cas | 15,588 | 45 | 3,227 | 23,519 | 2,155 |
| casp (2 words / 2 doubles) | | | 0 | 2,361 | 26 |
| swp | 1,571 | 26 | 372 | 5,506 | 2,590 |
| ldadd | 90 | 316 | 313,402 | 433,991 | 62,494 |
| ldclr | 53 | 43 | 1,080 | 111 | 348 |
| ldeor | 24 | 18 | 25 | 34 | 45 |
| ldset | 95 | 63 | 819 | 266 | 325 |
| ldsmax | 10 | 9 | 8 | 9 | 1 |
| ldsmin | 10 | 8 | 11 | 10 | 0 |
| ldumax | 2 | 18 | 2 | 5 | 3 |
| ldumin | 3 | 16 | 1 | 7 | 0 |

Cache by ordering: none 415,869, acquire 13,152, release 57,860, both 315,893. Unique LSE words in the cache: 6,150.

### 3.2 Harmless

| Class | v8.0 result | Cache proven | Root proven |
|---|---|---:|---:|
| Hint-space PAC (`pacibsp autibsp xpaclri` ...) | NOP | 11,662,031 | 3,472,773 |
| BTI | NOP | 197 | 2,171 |

### 3.3 Above A13: gated in Apple's own code

These cannot run on a real iPhone 11. They must stay gated on our CPU (C4).

| Class | Cache proven | Where |
|---|---:|---|
| SME + SME2 + SME-F64 + SME2p1 | 40,389 + 244,228 + 13,262 + 34 | libBLAS 49,182 SME2, Hands, AppleCV3D, SLOM |
| SVE + SVE2 | 215,133 + 6,269 | libBLAS 57,526 |
| `other` (LLVM needs several features at once: SME `fmla`, `fadd` on ZA) | 29,752 | libBLAS |
| MTE | 1,269 | libsystem_malloc, dyld (`dc gva`, `msr TCO`) |
| BF16, I8MM, CSSC | 1,179 + 485 + 492 | libBLAS, libBNNS |
| `smstart`/`smstop`, TPIDR2 | 9,102 of "system" | libBLAS and others |
| hbc, lut, mops, rcpc3, the, lse128, sm4, sve2-* | 0 proven (data) | |

The same image carries SME2 and AMX. So the binaries select at run time [I]. iPhone 11 has no SME and yet runs this cache: that is
the proof that SME paths are gated [I, by reasoning, not by reading each gate].

### 3.4 Auth pointers and slide info

| Item | Count |
|---|---:|
| Slide info v5 mappings, 16 KiB pages | 13 |
| Pages (with rebases) | 31,537 (24,694) |
| Plain rebases (with high8) | 18,284,984 (70,572) |
| **Auth rebases** | **10,069,319** |
| Key IA / DA | 5,369,901 / 4,699,418 |
| With address diversity / zero diversity | 9,631,591 / 779,282 |

Behaviour with no PAC key [V zeta README + xnu source, not retested]: `vm_shared_region_slide_page_v5` stores an auth rebase only
inside `__has_feature(ptrauth_calls)`. A non-PAC kernel leaves the raw entry, and the first load faults on a non-canonical pointer
(zeta saw `0x86be6afc6de6c600`). Our tool rewrites all 10,069,319 entries to plain rebases in the file, so **no kernel change is
needed for this**. Offset and `next` stay the same; `a64-verify` checks all 28,354,303 entries.

### 3.5 Hot paths and how often LSE runs

Static sites, measured [V] (linear count per image; names from the `.symbols` file):

| Image | Words | LSE sites | Non-hint PAC | Named hot functions with LSE |
|---|---:|---:|---:|---|
| libsystem_platform | 7,196 | 84 | 250 | `_os_unfair_lock_lock_slow` 2, `_os_nospin_lock_lock_slow` 2, `_os_once_gate_wait` 2, all `OSAtomic*` |
| libsystem_malloc | 60,693 | 485 | 1,692 | `_xzm_xzone_malloc_small` 18, `tiny_malloc_should_clear` 17, `small_malloc_should_clear` 15, `_xzm_segment_group_alloc_chunk` 14 |
| libobjc | 65,521 | 512 | 3,415 | `objc_retain` + `objc_release` families 27 + 27, `objc_loadWeakRetained` 6, `objc_initWeak` 4 |
| dyld | 148,943 | 45 | 5,269 | `os_unfair_lock` paths |
| libsystem_pthread | 10,868 | 97 | 297 | `pthread_mutex_*`, `pthread_rwlock_*`, `pthread_cond_*` |
| libdispatch | 62,399 | 688 | 1,716 | `_dispatch_lane_drain*` 7, `_dispatch_workloop_invoke` 13 |
| libswiftCore | 1,200,309 | 422 | 63,660 | `swift_retain` 30, `swift_release` 29 |
| QuartzCore | 900,710 | 2,268 | 22,175 | |
| launchd / backboardd | 91,390 / 193,113 | 5 / 1 | 2,388 / 5,077 | |

Check against zeta [V]: launchd 2,388 and dyld 5,269 non-hint PAC words are the same numbers its README gives for its donor.
`objc_msgSend` has no LSE [V `hotfn-libobjc.A.dylib.tsv`], so its restartable range is not touched.

Static density: 802,693 / 784,854,119 = **0.10 %** of cache words [V]. Dynamic rate, all [I], no measurement exists:

- Retain/release and locks run often. Assume 1 atomic in 200 executed instructions in ObjC-heavy code, 1.5 GHz average, IPC 1:
  **about 7.5 million atomics per second per busy core [I]**.

## 4. Which fix for which class (Step 2)

Cost numbers are [I]: A73 at 2.0 GHz, no measurement on the phone.

| Class | Fix | Why | Cost |
|---|---|---|---|
| Non-hint PAC | 1:1 word: `pacia/autia/xpac` -> NOP; `braa/blraa` -> `br/blr`; `retab` -> `ret`; `ldraa` -> `ldr`; `pacga` -> `movz 0` | All signers and checkers become plain together, so values stay plain everywhere. Same rule as zeta `zeta_userland_pauth.py` | 0 |
| Hint PAC, BTI | none | NOP on v8.0 | 0 |
| `ldapr` | 1:1 -> `ldar` | Stronger ordering, same result | small |
| `ldapur`/`stlur` offset 0 | 1:1 -> `ldar`/`stlr` | | small |
| `msr DIT`, `mrs DIT`, `sb` | 1:1 -> NOP, `movz 0`, `isb` | No DIT on this CPU; `isb` stops speculation [I] | 0 |
| **LSE** | Branch to a trampoline (section 4.1) | No one-word form exists | about 10 ns per atomic [I] |
| FP16, FCMA, DotProd, JSCVT, SHA3, FHM | Kernel emulation now (section 5); a trampoline is possible later | Each form needs its own NEON sequence and spills | about 2 µs per trap [I] |
| AMX | Stay gated (C4). If it runs: kernel log line + SIGILL | zeta's CPU has no AMX and reaches Home | |
| Apple registers `S3_6_C15_C1_5` etc | Stay gated (C4). If reached: emulate reads as 0 | zeta's CPU has no SPRR | |

Why not trap for LSE [I]: an emulated atomic costs an exception, decode, LL/SC, return: about 2 µs on an A73, more on an A53.
At 7.5 M/s that is 15 seconds of CPU per second of work: **about 15 times slower. Not usable for retain/release.** A trampoline
adds about 12 instructions and 3 memory operations, about 10 ns: **about 7.5 % on atomic-heavy code [I]**. The trap stays only
for rare words and for JIT output.

Atomicity [V by design]: the trampoline uses an LDXR/STXR or LDAXP/STLXP loop on the same address. Other cores run plain LL/SC or the
same trampolines, so all writers go through the exclusive monitor. A kernel emulator must do the same on the user address and must
not use a lock or stop other CPUs. Note: LSE on memory that is not cacheable can fail or loop with LL/SC on this CPU [I]. IOSurface
pages mapped write-combined must not hold atomics [U: not seen so far].

### 4.1 The LSE trampoline design [V, measured]

The site keeps its size: one word. Two shapes, chosen by a liveness walk of x30:

| Where x30 is dead | Where x30 is live |
|---|---|
| Site = `bl T` | Site = `b S` |
| `T` is shared by all sites with the same word | `S` = `str x30,[sp,#-144]!; bl T; ldr x30,[sp],#144; b site+4` |
| Cache 626,471 sites, root 57,511 | Cache 173,890 sites, root 5,011 |

`T` for `ldaddal w8, w9, [x0]`:

```
sub  sp, sp, #176            ; below the 128-byte Darwin red zone
stp  x10, x11, [sp]          ; scratch registers, none of Rs Rt Rn
stp  x12, x13, [sp, #16]
L: ldaxr w10, [x0]           ; A bit -> LDAXR
add  w12, w10, w8
stlxr w11, w12, [x0]         ; L bit -> STLXR
cbnz w11, L
mov  w9, w10
ldp  x12, x13, [sp, #16]
ldp  x10, x11, [sp]
add  sp, sp, #176
ret
```

- NZCV stays: CAS compares with `eor` + `cbnz`, max and min save NZCV with `mrs` and restore it. [V qemu]
- CASP writes the old pair back on a failed compare: a pair is single-copy atomic only with a store. [V qemu]
- The red zone stays. My first frame (144) broke it, and the test caught this. [V]
- Registers: x9-x17 chosen per word, x18 never. A word using x30 or SP as base stays for the kernel (cache 10, root 2; SP base 0).
- Range [V]: B and BL reach ±128 MiB. Text subcaches are at most 115 MB. The planner works in 16 MiB zones and uses slots within 127 MiB.
- Layout [V `layout.tsv`]: **the cache has no VM gap between text subcaches** (100 gaps of 0 bytes; only 6 gaps of 32 MiB, between data
  mappings). So the trampolines go in free bytes inside the r-x mappings: zero runs of 64 bytes or more that no section and no load
  command owns. **12,439,776 such bytes exist** across the cache, 3,689,848 needed by a first model. Per file it is short: `.11` (WebCore)
  has 53,296 and needs 709,148.
- With free bytes only: 47,522 sites in WebCore + WebKit have no slot in reach. With two dead images (`ANECompiler`, 21 MB `__text`:
  this phone has no ANE; `VisualGeneration`: Image Playground, needs a newer SoC) [I they never load]: **0 sites have no slot**. Used:
  trampolines 841,212 bytes (16,327, from 6,150 unique words) + stubs 2,782,240 bytes.
- Unwinding: trampolines have no unwind info. A frame-pointer walk still works (x29 stays). A fault inside a trampoline, on a bad
  pointer, gives a crash report with a PC outside any function. C++ and Swift unwinding never start there [I].
- `lr_dead` is conservative: any word with 30 in a register field, a `ret`, a tail call or a jump table counts as live.

### 4.2 Auth-call ABI [I, with zeta's hardware result as evidence]

- `objc_msgSend`, isa signing, `__auth_stubs`, C++ vtables, block invoke pointers: every signer and checker becomes a no-op at the same
  time, so all pointers stay plain and all discriminators stop mattering. No struct layout changes: PAC only used pointer bits.
- Sequences like `autibsp; eor x16,x30,x30,lsl #1; tbz x16,#62,ok; brk #0xc471` still pass: `autibsp` is a NOP and x30 has no signature.
- dyld signs arm64e chained fixups with `pacia`-class words. They become NOPs, so the file's auth fixups end up plain. zeta: the header
  goes to `CPU_SUBTYPE_ARM64_ALL`, and dyld then runs the process with keys off.
- **Hazard: JIT.** JavaScriptCore emits `pacib`, `blraa`, LSE and `fjcvtzs` at run time on arm64e [I]. No file rewrite can reach this.
  Kernel emulation must take it, or JIT stays off.

### 4.3 Boot time overhead [I]

Trampolines only: about 7.5 % on atomic-heavy code. FP16 by trap: small unless a loop reaches it. Named risk [V names, I effect]:
QuartzCore's software renderer has FP16 per pixel (`CA::OGL::SW::Blend::Mode<SDFUnion>::blend` 41 sites,
`CA::OGL::SW::scanline` 16, `rect_sdf_sampler` 21, `supercircle_sdf_sampler` 25). If the SW path ever runs on the CPU, these need
trampolines, not traps. RenderBox and CoreGraphics use FP16 per fill or only for half-float contexts.

The boot itself is far slower than iOS 16 for other reasons: 5.2 GB cache, more daemons. No number [U].

## 5. What the tool leaves for the kernel

`scripts/ios26/lower-userland.sh` result, re-counted by `a64-census` on the output [V]:

| Class | Cache, live images (proven unless noted) | Root |
|---|---:|---:|
| Non-hint PAC | **0** proven; 699 linear, not proven code | **0** proven; 491 linear |
| LSE | **10** (x30); 81 linear, not proven | **5,462** (5,460 no free space in 16 files, 2 x30) |
| `ldapr` | 1 linear, not proven | 0 |
| RCpc2 with offset | 1 + data | 1 |
| FP16 | 69,361 | 177 |
| FCMA / DotProd / JSCVT / FHM / SHA3 | 25,045 / 993 / 461 / 112 / 1,377 | 0 / 0 / 0 / 0 / 288 |
| AMX | 419,408 | 0 |
| Apple registers (A13 column, DIT gone) | 837 | 656 |

The two dead images keep 2,322 LSE, 185,928 PAC and 11,956 `ldapr` words: they must never load.

Root files with LSE left (no free space in the file's `__TEXT`): CommCenter 2,661, libaxis 897, Measure 698, libdispatch_profile 227,
introspection libdispatch 215, diskimagescontroller 172, USDRendererExtension 126, wirelessinsightsd 124, locationd 92,
SearchPersonalization 89, CoreMLSegmenter 54, fairplayd.H2 45, logd 27, ASOctaneSupportXPCService 25, watchdogd 7, voiced 1.
`logd` and `watchdogd` run at each boot: their words go through the trap. Later fix: a new segment in those files [U dyld accepts it].

The 699 + 81 unproven words sit next to undecodable words in functions with data in code. zeta proved all but one PAC word with more
grades (unwind data, LSDA, code pointers). If one of ours is real code, the kernel emulator catches it.

## 6. The tool (Step 3)

`tools/op10tool`: `a64-census`, `a64-lower`, `a64-verify`, `a64-selftest`, `a64-abi`, `a64-dis`. Encodings in `src/a64.rs`, parser in `src/dsc.rs`.

```sh
op10tool a64-lower --cache CACHE --macho TREE --out DIR --rules all --page-shift 12 --dead-image X   # never in place
op10tool a64-verify --orig CACHE --lowered DIR --dead-image X --macho-orig TREE
op10tool a64-selftest --words DIR/lse-words.txt --out WORK
```

Rule set `--rules`: `all`, or a list of `pac rcpc lse sysreg slide`. Output: lowered files, `lower-report.md`, `verify-report.md`,
`cdhashes.tsv`, `macho-lowered.tsv`, `lse-words.txt`. It also reseals the corecrypto FIPS HMAC (`/usr/lib/system/libcorecrypto.dylib`, zeta's
contract) and rebuilds each CodeDirectory with 4 KiB pages (`--page-shift 12`), growing the file by the signature.

Results [V, `logs/ios26-lower.log`, tool at the commit of this document]:

| Check | Result |
|---|---|
| One-word edits, cache / root | 29,451,474 / 9,883,430 |
| LSE sites rewritten, cache / root | 800,361 / 62,522 |
| Slide info | 10,069,319 auth entries -> plain; 0 auth left; 28,354,303 entries same target and chain |
| New code | 905,844 words in free space (cache), 58,102 (root); **0 invalid on cortex-a73** (llvm-mc) |
| `a64-verify` every changed word | Problems: none |
| Signatures | 1,262,540 cache pages match, 0 do not; 427,263 root pages match, 0 do not |
| FIPS HMAC | 1 resealed, matches the new code |
| Real execution | `a64-selftest`: 7,687 words (1,632 synthetic + real words of the cache), 30,748 cases, **0 mismatches**: native words on `qemu-aarch64 -cpu max`, trampolines on `-cpu cortex-a53`; x0-x30, NZCV, red zone, memory compared |
| Determinism | Second run: same SHA-256 for all 84 cache files |
| Unit + synthetic tests | `tools/op10tool/tests/a64.sh`: 9 Rust tests (LSE, PAC, RCpc, reach, slots, synthetic Mach-O end to end incl. data in code and a second run), self test |
| Duration | Lowering the cache: about 12 seconds on 20 cores |

What these do **not** show: that dyld, the kernel or any process accepts this output. qemu tested the trampolines alone, on Linux user mode,
with one thread. Concurrency rests on the architecture, not on a test.

Apple files: `~/op10-apple/ios26/23F84-n104ap/` (`os/` 13.6 GB images, `tree/` cache + root, `lowered/` output, link `out/ios26/lowered-n104ap`).
Kept for the kernel track. 22H384 was deleted after its count.

## 7. Kernel needs (for the xnu-12377 track)

From this CPU's result and zeta's README. Not implemented here. The UniXNU patches zeta names are **not** in pinned `UniXNU-ios26` 68c5134
(head of branch `ios26`, 2026-10-22) [V `find`]: zeta's text describes them; write them again.

1. **4 KiB pages, 16 KiB slide pages.** `shared_region_pager_data_request` must handle slide v5 at 16 KiB on a 4 KiB kernel: read the earlier
   pages of the same slide page, validate each against the signature, slide in a scratch buffer, keep the requested page. zeta:
   `native-shared-region-small-pages.patch`. Without it: only the first quarter of each slide page slides, and the copy overruns.
2. **Auth rebases:** nothing needed; our cache has none left. Keep the kernel non-ptrauth. zeta's `native-shared-region-plain-auth.patch` is
   not needed with this cache.
3. **Grading:** lowered root files are `CPU_SUBTYPE_ARM64_ALL`, so no arm64e grading. The cache keeps magic `dyld_v1  arm64e` and its name.
4. **Code signing:** accept page shift 12. Trust: 84 cache cdhashes (`cdhashes.tsv`) + root files; our AMFI or a merged static trust cache
   (zeta: `make-zeta-trust-bundle.py`, attributes copied from the original entries).
5. **Cache location and SIP:** the cache must load from `/System/Library/Caches/com.apple.dyld/` on the root volume or the preboot cryptex volume
   (`bsd/vm/vm_unix.c`). If CSR is on, `lp-sip0` must allow it (zeta: `csr_config 0x2`; else "vnode is not SIP-protected").
6. **dyld flags:** skip libignition, it cannot graft the cryptex without an Apple manifest. Copy the low half of boot-arg `dyld_flags=0x8` to the
   comm page (zeta `XNU_DYLD_FLAGS_BOOTARG`). A boot-arg here is a feature input, not a probe.
7. **Commpage and sysctls report the truth (C4):** `_COMM_PAGE_CPU_CAPABILITIES64`, `hw.optional.arm.FEAT_*`, `hw.cpufamily`, `hw.cpusubfamily`: no AMX,
   SME, SVE, MTE, LSE, RCpc, FP16, FHM, FCMA, JSCVT, DotProd, SHA3, SHA512, DIT, SB, BTI, ECV, TPRO, SPRR. No Apple family value. User page shift stays
   14 (16 KiB, like TOPAZ_4K).
8. **Undefined-instruction emulation at EL0** (`sleh.c`, the uncategorized/undefined path), a real feature with a kill switch and one log line on
   failure. On by default. Order of need:
   - Non-hint PAC and LSE from JIT code and from the unproven words: PAC by the same rules as section 4; LSE by a loop on the user address.
   - LSE: LDXR/STXR on the user VA with a fault-safe path. No lock. Atomic with user LL/SC on other cores. Acquire and release as in the word.
   - FP16 scalar and vector, FCMA, DotProd, JSCVT, FHM, SHA3/SHA512, RCpc2 with offset, the 1 `ldapr`.
   - Unknown words, AMX, SME: SIGILL as today, with the word in the log. A failure turns off only that word's emulation.
9. **Reach of emulation counts:** one log line every N seconds with a count per class. It tells which class needs a trampoline next.
10. **Stack:** the trampolines go 176 + 144 bytes below SP, past the red zone. Stack-limit checks stay the same as for a call.
11. **Exclusive monitor:** `clrex` on exception return, as usual.

## 8. User-client ABI against iOS 16 (Step 4)

`op10tool a64-abi` finds each `bl`/`b` to `IOConnectCall*`/`__mac_syscall` (direct, stub or island) and reads immediates before the call. [V, static, on
20H392 and 23F84; the result is `scripts/ios26/abi-compare.py`.] A selector built at run time shows as "unknown". A static read cannot prove a call is reached.

| Interface | iOS 16 20H392 | iOS 26 23F84 | Changed |
|---|---|---|---|
| **IOSurface** | 0, 4-7, 9-13, 17-22, 24-27, 30-52 | 0, 4-7, 9-13, 17-22, 24-27, 30-36, 38-41, 43-44, 46-52, 54, 58 | New: 54 `IOSurfaceClientSetCoreVideoBridgedKeys`, 58 `IOSurfaceClientQueryTransactionList` (5 scalars). Gone: 37, 42, 45 (shared event signal, wait). **Same selector, new sizes: 10 `UpdateNonBulkValueCache` struct 9 -> 13, 27 `SetBulkAttachments` struct 136 -> 160.** No function changed its number |
| **IOMobileFramebuffer** | 3-8, 10-20, 22-31, 33-35, 41-44, 47-57, 66-69, 72-75, 77-86 | 2-8, 10-20, 22-31, 33-35, 41-44, 47-55, 57, 66-69, 72-75, 77-92 | New: 2 `UserCalibration_WriteEAN`, 87 `AnnounceNextSwapTimestamp`, 88 `OpenByName`, 89 `SetClamshellState`, 90 `GetDotPitchFloat`, 91 `SwapGetCurrent`, 92 `SwapCancelAllGetCurrent`. Gone: 56 (`KernelTests`). **`kern_SwapEnd` selector 5: size immediate 1132 -> 1416: the swap record grew by 284 bytes.** No function changed its number. 546 more symbols, nearly all "key sniff" helpers |
| **AppleKeyStore** | in `MobileKeyBag`: 0, 2-7, 9-24, 26-27, 30-31, 33-34, 36-38, 40-42, 44, 49-51, 53-55, 57-63, 65-108, 110-115, 117 | moved to `AppleKeyStore.framework`: 0, 4-5, 9-10, 12-13, 15-23, 26-27, 36-37, 40, 43-44, 51, 53-55, 58, 60, 63, 66, 70-71, 73, 78, 83, 86, 88, 91-95, 100-101, 105-108, 115, 118-122, 124-128, 133-134, 137-138, 141, 144-145, 149, 151, 156, 160, 162 (+ MobileKeyBag 5-7) | Service name stays `IOService:/IOResources/AppleKeyStore`. **Scalars grew: `aks_unlock_device` (9) 3 -> 4, `akstest_unwrap_key` (16) 1 -> 2, `akstest_new_key` (15) 1 -> 2, `aks_se_recover` (70) 3 -> 4.** New: `aks_lkgp_recover` 133, `aks_measure_and_seal_cryptex_manifest` 144, `aks_seal_cryptex_manifest_lock` 149, `aks_lock_cx` 141, and others. Selectors of our kernel stand-in (7, 10, 11, 17, 23, 31, 40, 100-103, 115): 7, 11, 31, 102, 103 no longer have a direct immediate call in this list. Selector 11 was `aks_unwrap_key`, 31 `aks_get_configuration`: re-read their new paths |
| **Sandbox** (`__mac_syscall("Sandbox", op)`) | 1-8, 10-13, 21-22, 28-30, 46, 52-53, 61-63, 65-67, 69, 71, 259-263 | 0-8, 10-13, 21-22, 28-30, 52-53, 61-63, 65-67, 69, 71, 75-77, 79-80, 83, 85-87, 259-263 | New: 0 `apply_bytecode`, 75-77 app containers, 79-80 extensions, 83, 85-86 disk image store, 87 `check_storage_class`. Gone: 46. Numbers stay. libsandbox 0, 15, 16, 22, 69: same |
| **IOAccelerator** | 0-11, 13 | 0-11, 13 | Same |
| **IOGPU** (Metal path) | 0-16, 18-22, 24-49 | 0-8, 12-15, 17-21, 23-31, 33-54 | **33 functions changed number**, e.g. `IOGPUMTLEvent dealloc` 21 -> 20. Only for a real IOGPU driver. metal2vulkan bypasses it [I] |
| **IOSurfaceAccelerator** | 0-5, 7-9 | 0-10 | `GetHistogram` 9 -> 7, `KernelTests` 8 -> 6 |

| SPI | iOS 16 | iOS 26 | Result |
|---|---|---|---|
| `OpenGLES.framework` symbols | 580 | 580 | **All 580 the same names** [V]. EAGL shim's outer face holds |
| `GLEngine` symbols | 1,896 | 2,105 | 1,891 same, 214 new, 5 gone (`gleCreatePluginPipelineProgram`, `gleDoDrawDispatchCoreGL3`, `gleInitPIndexTable`, `glGetClipPlane_Exec`, `___abort_calloc`) |
| `IOSurface` symbols | 1,085 | 1,283 | 1,066 same. Gone: `IOSurfaceSharedEvent*Listener`, notifier run-loop helpers. Check our shim's imports |
| `IOMobileFramebuffer` symbols | 373 | 919 | 369 same, 4 gone |
| QuartzCore `CA::OGL::GLESContext` | 50 symbols | 46 | Still there |
| QuartzCore `CA::OGL::MetalContext` | 175 | 219 | Grew |
| QuartzCore SW renderer symbols | 359 | 367 | Still there |
| QuartzCore `CA::WindowServer::EAGLServer` | present | **0 symbols** | Class gone; `AccelServer` took its place |

### 8.1 Is the GLES path reachable? [V static]

| Caller of | 20H392 | 23F84 |
|---|---|---|
| Server's renderer | `CA::WindowServer::EAGLServer::renderer`: `CAMetalContextCreate`, then if null: `EAGLContext initWithAPI:properties:` and `GLESContext` | `CA::WindowServer::AccelServer::renderer`: `CAMetalContextCreate`, then if null: **return 0** |
| `GLESContext` constructor | `EAGLServer::renderer`, `gles_new_context`, `-[CARenderer _initWithEAGLContext:options:]` | **only** `gles_new_context`, `-[CARenderer _initWithEAGLContext:options:]` |
| `new_metal_context` | server + others | `AccelServer::renderer`, `IOMFBDisplay::get_ctx`, `AsynchronousDispatcher::renderer`, `VirtualServer::renderer`, `CA::CG::AccelRenderer::acquire`, `CASDFGenerator`, `create_cgimage_from_iosurface`, ... |

So: 23F84 backboardd with no Metal device gets **no renderer from its server path**. `gles_new_context`, `sw_new_context`, `metal_new_context` have no `bl` and no `adrp+add` reference in `__text` [V xref]; `_CARenderOGLNew_` calls the first word of a table it gets [V disassembly], so they are callbacks for `CARenderOGLNew` clients, not the server [I]. Options:

| Option | What it needs | Evidence |
|---|---|---|
| (a) Metal with metal2vulkan + Turnip (zeta's way) | The compositor's pipelines on `a6xx_gen1_low`: no sampler min/max, no HW multiview, GMEM 132 KiB [V metal.md section 3] | zeta: Home on A660, slow. On the A610 under iOS 16: apps run, backboardd does not [V plan.md, metal.md]. Glass and blur load the GPU far more [I] |
| (b) Hook `AccelServer::renderer` in backboardd: make a `GLESContext` as iOS 16 did, on our EAGL shim | An injected dylib + symbol addresses for this build; `IOMFBDisplay::get_ctx` and others still want Metal | **Nobody tried** [U]. `GLESContext` has 46 symbols and may have gone stale. iOS 26 shaders for Liquid Glass have no GL form [I] |
| (c) `CA::OGL::SW` software renderer | A hook that makes `SWContext` | Works on the CPU only. FP16 per pixel (section 4.3). Far too slow for full screen [I] |

## 9. Zeta's state, and the next best real option

**UniXNU-zeta**, pin `eb48928` (2026-10-27, branch head, now in `scripts/setup/get-references.sh`); **UniXNU `ios26`** pin `68c5134` (2026-10-22, head). The brief's
"stopped at launchd PAC faults" is old. Its README now says [V its text, not my test]:

- iPhone18,2 26.5.2 23F84 on SM8350. 29,577,371 PAC words, all but one proven and lowered. launchd passed the PAC faults after the 4 KiB pager and plain-auth fixes.
- SpringBoard + backboardd run. 8 cores, 981 seconds idle with no fault. **Home screen reached by unlock**, with Metal through Turnip on the A660.
- Open there: black backgrounds, lag (55-83 ms per present), BO refusals, Settings crash in Turnip, bring-up details such as a shared region fix. Its CPU has LSE, RCpc, FP16, DotProd, RDM.
- Evidence this gives us: **FCMA, JSCVT, FHM, SHA3, FlagM, DIT, AMX, SVE, SME, SPRR words do not stop a UI boot on a CPU without them.** New on our CPU compared to zeta: **LSE, RCpc, FP16, DotProd**. Tool handles LSE and RCpc. FP16 and DotProd stay for the kernel, unproven.

**Next best option: iPadOS 18.7.11 22H384 on `iPad7,11` (iPad 7, A10, J171AP), plain arm64** [V api.ipsw.me]. Newest non-arm64e firmware. Other checks: iPhone X stops at 16.7.16 (`iPhone10,3`), iPad 6 at 17.7.11 (`iPad7,5`), iPad 8 (A12) gets 26.7.2 and is arm64e.

| Cache (census on this host) | Size | PAC proven | LSE proven | FP16 | AMX | Auth rebases |
|---|---:|---:|---:|---:|---:|---:|
| iOS 26.5.2 23F84 iPhone12,1 arm64e | 2,993 MiB | 29,527,482 | 802,693 | 69,770 | 664,069 | 10,069,319 |
| iPadOS 18.7.11 22H384 iPad7,11 arm64 | 2,122 MiB | 40 | 1,182 | 6,980 | 0 | 0 (no slide v5) |
| iOS 16.7.16 20H392 iPhone10,3 arm64 (**boots on this phone now**) | 1,485 MiB | 7 | 888 | 2,712 | 0 | 0 |

The iPadOS 18 cache has the same shape as the iOS 16 cache that boots here: LSE only in libdispatch, libsystem_pthread, libsystem_platform (gated) and a few libraries [V counts, I gated]. **No lowering needed.**

Cost:

- Kernel: xnu-11417 source exists (`xnu-11417.140.69`, macOS 15.6) [V git tag]. Port of our patch series: the 12377 base work does not apply directly [I].
- iPad idiom, 2160x1620 @2x, 4:3, on a 720x1560 panel: new identity, SpringBoard in iPad mode, or a patch to a phone-like layout [U].
- QuartzCore 18: not checked; check `EAGLServer` before starting.
- Same userland ABI work as above, smaller [I].
- iOS 16 stays the working fallback on this phone.

## 10. Stale facts this replaces

- `docs/plan.md` said iOS 26 "needs zeta-style PAC lowering": it also needs LSE trampolines, FP16 emulation and a renderer answer.
- `docs/future-ios26.md` section 1 said the GL path has a target in iOS 26. The classes exist, but the **server path does not reach them** in 23F84. This holds for negroni too.
- `docs/laurel_sprout/metal.md` line 4 ("Turnip has not run on the phone") is older than the boots of 2026-11-01 18:40 and later.

## 11. Evidence files

Text copies of the reports, no Apple code: [ios26-evidence/](ios26-evidence/) (`census-n104ap.md`, `classes-n104ap.tsv`, `lse-forms.tsv`, `slack.tsv`, `layout.tsv`, `slide.tsv`,
`census-lowered.md`, `lower-report.md`, `verify-report.md`, `abi-compare.md`, `census-20H392.md`, `census-22H384.md`). The tools make them again: section 2.
