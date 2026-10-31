# Building the laurel_sprout port on Linux (no Mac)

topaz builds its kernel and Mesa on macOS (Xcode 15.4, `blacktop/darwin-xnu-build`). Other ports
already build the same pieces on Linux. This page lists what replaces each macOS-only part.

## What needs macOS in topaz, and the Linux replacement

| Part | macOS tool | Linux replacement | Source (reference clone) | State |
| --- | --- | --- | --- | --- |
| Compiler | Apple clang (Xcode 15.4) | stock clang + `xnu-clang` wrapper (forces `-target arm64-apple-macos13.3`, `--ld-path=ld64`, drops Apple-only flags) | `ios-sweet-linux/linux/bin/xnu-clang` | [V] builds the SWEET kernel on ubuntu-24.04 |
| Mach-O linker, nm, strip, libtool | Xcode cctools / ld64 | cctools-port ld64 from the theos toolchain (`L1ghtmann/llvm-project test-210562a`) | `ios-sweet-linux` workflow; `xnu-linux-toolchain` builds cctools-port itself | [V] |
| `iig` (DriverKit IDL compiler, closed source) | Xcode 15.4 `iig` | headers from MacOSX13.3.sdk + generated stubs from the linker's undefined list (`gen-iig-stubs.py`); or the Python `iig` rewrite in `xnu-linux-toolchain` | `ios-sweet-linux/linux/gen-iig-stubs.py`, `xnu-linux-toolchain/toolchain` | [V] |
| MIG | Xcode `mig` | glibc port of Apple `bootstrap_cmds` | `setup-deps.sh` | [V] |
| `doconf` csh | `/bin/csh` | tcsh built from source | `setup-deps.sh` | [V] |
| macOS SDK | Xcode SDK | `MacOSX13.3.sdk` (joseluisq/macosx-sdks) | `setup-sdk.sh` | [V] |
| `libfirehose_kernel.a` | Apple internal SDK | built from libdispatch sources | `setup-deps.sh --stage2` | [V] |
| `sysctl`, `xcrun`, `codesign`, `plutil` | macOS | stubs on PATH | `ios-sweet-linux/linux/bin` | [V] |
| Mesa freedreno dylib (GPU) | `mk-mesa-mac.sh` | clang `-target arm64-apple-ios` + ld64 + iOS SDK; Linux path merged in Scion hackios PR #82 (`mk-gfx.sh`: `xnu-clang` and `llvm-nm` on Linux) | `hackios-scion` | [I] to port |
| Userland dylibs (inject, audio plug-in) | Apple clang | same clang/ld64 + iOS SDK; sign with `ldid` | theos | [I] to port |
| Root image (HFS+) | — | already Linux: `mkiosroot.sh` (apfs-fuse, hfsprogs) | `ios-topaz/tools` | [V] |

Facts from the reference READMEs [V]: `xnu-linux-toolchain` reports a 205 s cold build on 32 cores and
27 s for a one-line change; the UniXNU PR #100 pins cctools-port ld64 1030.6.3, because ld64-609 corrupts the
kernel link. ios-sweet-linux needed 3 small compiler fixes for stock clang (kalloc `void *` check, a missing
prototype, `SHA256SU0 0, 1` register syntax).

## Our script

`scripts/laurel/kernel-linux.sh` (run in tmux: `scripts/bg.sh laurel-kernel scripts/laurel/kernel-linux.sh`):

1. copies `external/ios-sweet-linux/linux/` into `out/laurel-kernel/` (no change inside `external/`);
2. patch set = `external/ios-topaz/xnu/patches/*` + `patches/laurel/xnu/*.patch` (our Mi A3 deltas);
3. theos at a pinned commit + the pinned cctools toolchain, MacOSX13.3.sdk;
4. applies the patches (`AUDIT=1`: every patch, report only), stage 1 deps, `exporthdrs`, stage 2, build with iig stubs;
5. copies `kernel.development.sweet` to `out/laurel-kernel/out/` and counts LSE/RCpc instructions (must be ~0, ARMv8.0).

Host: x86_64 Linux (the pinned theos toolchain is x86_64). Tested host: CachyOS, clang 23, 20 cores.
Note: clang 23 is newer than the clang 18 that ios-sweet-linux uses on CI; more stock-clang fixes may be needed
(they go into `patches/laurel/xnu-linux-fixes/`).

## Trust

The build runs third-party code: the ios-sweet-linux scripts (pinned commit), theos (pinned commit) and a
prebuilt toolchain tarball from `L1ghtmann/llvm-project` release `test-210562a`. Review them before the first run.
A stricter path builds cctools-port from source with `external/xnu-linux-toolchain/bootstrap.sh`.

## Measured (2026-10-31, CachyOS, 20 cores, clang 23)

| Step | Wall | CPU | Cores busy |
| --- | --- | --- | --- |
| fetch (toolchain, SDK, xnu tag from the local mirror `out/laurel-kernel/cache/xnu.git`; parallel) | 0-4 s | — | — |
| patch + deps (apply 201 patches **parallel with** stage 1 host tools) | 7.5 s | 1.9 s | 0.3 |
| kernel (make -j20 + iig relink) | 27.8 s | 426 s | **15.3 of 20** (the final link + dsymutil is serial) |
| total | 36 s | | |

Fixes found on the way:
- `libfirehose_kernel.a` was built without `-mcpu=cortex-a53` and had 11 LSE/LDAPR instructions (would trap on the
  Kryo 260 at the first kernel log). The script now builds it for cortex-a53 and **fails** on any LSE/RCpc instruction.
- clang 23: `-Wincompatible-pointer-types` is an error (`patches/laurel/xnu-linux-fixes/0101`).
- Install `ccache` (`pacman -S ccache` / `apt install ccache`): the script uses it when present.

## Multicore: PAGES=4k (default)

`PAGES=4k` sets `TOPAZ_4K=1` (topaz 0140/0141/0142): 4 KiB pages, so the Silver A53 cores (no 16K granule) can run
XNU. Gold A73 = P cluster (boot CPU 0x100), Silver = E cluster, Edge scheduler, `MAX_CPU_CLUSTERS 2`. The script checks
that the 4K code is in the kernel (`_sweet_early_fb_mapped`; kernel base 0xfffffff007... instead of 0xfffffe0007...).
`PAGES=16k` builds the topaz CI kernel (4 Gold cores only) as a fallback.
The ADT must list the 8 CPUs with `cluster-type` = `'P'` (0x50) for 0x100-0x103 and `'E'` (0x45) for 0x0-0x3
(`osfmk/arm64/machine_routines.c:1036`); topaz `mkadt.py` emits only the 4 Gold cores, so our ADT builder must do this.
