# Mi A3 iOS 26 kernel series (xnu-12377.121.6, SWEET machine config, Linux build)

Same method as `patches/xnu-12377` (negroni): **one series, data rules, base-owned files, a skip list with reasons**. The iOS 16
kernel and this kernel apply the same patch files: `external/ios-topaz/xnu/patches/*.patch` + `patches/laurel/xnu/*.patch`, in name
order. A driver fix lands once. Nothing of 8796 is copied. Build: `scripts/laurel/kernel-ios26-linux.sh`. Status: `docs/laurel_sprout/ios26-kernel.md`.

## Order (`scripts/ios26/apply-series.py --profile scripts/laurel/ios26-series.py`)

1. **Base**: `patches/xnu-12377/0001` (shared non-Apple SoC base) + here `0002` machine config, `0003` machine layer, `0004` platform and
   console, `0005` core. The negroni `0005` (native PAC) does not apply: this kernel is plain arm64.
2. **Stage scripts**: topaz `0020` BearSSL; here `stage/0019-stage-libpthread-539.sh` and `stage/0026-stage-hfs-715.sh` (the pairs in Apple's
   macos-265 release.json; same target folders as topaz, so the series patches stay).
3. **The series**, one result line per patch, in `docs/laurel_sprout/ios26-kernel-series.txt`:
   `applied`, `applied+rules(N)`, `base: ...`, `skipped: REASON`, `ERROR: ...`. Any `ERROR` stops the build.
4. **Post**: `post/9000-series-12377-api.patch`: 12377 API of files that the series creates, and the features below.

`stage/0090-stage-a64emu.sh` copies the EL0 emulator from `tools/laurel-a64emu` (the same files as the host test `scripts/laurel/test-a64emu.sh`); the build stamp counts them. Edit them there, not in the tree.

## Where the differences live

| Place | What |
|---|---|
| `scripts/laurel/ios26-series.py` `RULES` | data rules on patch text (kinds in `scripts/ios26/patch-rules.py`). A rule for named patches that matches nothing is an ERROR |
| `owned.txt` + `0002`-`0005` | a file the base owns, with the series patches whose hunks the base holds. A new series patch for that file is an ERROR until its change is ported |
| three-way merge (`3way FILE` in a result line) | a section that does not apply as text is merged with `git merge-file` from the same series walked on xnu-8796.141.3 (`src/shadow`, an input only). A conflict is an ERROR: the file goes to a base patch |
| `skip.txt` | one line per patch: `upstream:`, `not needed:`, `in base NNNN` or `replaced:` |
| `post/` | new code and API fixes after the series; generated, see below |

## Work flow

    scripts/laurel/ios26-series-tree.sh --dev     # src/xnu, one commit per step; conflict markers stay in the file
    # edit src/xnu; scripts/bg.sh ios26-make scripts/laurel/ios26-make.sh  (make -k, error list make-errors.txt)
    python3 -I scripts/laurel/ios26-base-refresh.py   # writes 0002-0005, post/9000, owned.txt from the tree
    scripts/bg.sh ios26-kernel scripts/laurel/kernel-ios26-linux.sh   # clean tree, every check, out/laurel-kernel-ios26/out/

## Root device (dual boot agent)

The root device code is outside the base and the post patch: `0028-sweet-ufs-root-device.patch` (`bsd/dev/sweet_ufs.c`,
`iokit/bsddev/IOKitBSDInit.cpp`), later UFS patches, `0029`, `0031`. A root-from-extent-table patch can go into `patches/laurel/xnu/` as
a normal series patch on these files; both kernels get it, and no rule is needed unless its text differs on 12377.

## Licenses

`patches/xnu-12377/0001` has UniXNU-ios26 code (BSD-2-Clause-Patent, THIRD_PARTY_NOTICES.md). xnu changes: APSL 2.0. No Apple binary, KDK
header or kernelcache is in git: they stay in `out/` and `~/op10-apple/`.

`post/9004`: `LAUREL CS`: no code signing kill for a page that this kernel cannot hash (`docs/laurel_sprout/ios26-entry.md`).

Host tests of what lives in `post/9000`: `scripts/laurel/test-a64emu.sh` (emulator), `scripts/laurel/test-slide.sh` (slide on 4 KiB pages), `scripts/laurel/test-apple80211.sh` (23F84 Apple80211).
