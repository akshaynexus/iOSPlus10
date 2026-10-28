# iOS 26 kernel series (xnu-12377.121.6)

The iOS 26 kernel uses the **same patch series as the iOS 16 kernel**. A driver fix lands once, in
`patches/xnu/` (or in slop), and both kernels get it. This directory holds only what is different on 12377.

## Order (scripts/ios26/apply-series.py)

`scripts/ios26/build-kernel.sh` runs `scripts/ios26/apply-series.py` on the xnu tree right after the
darwin-xnu-build (dxb) 26.0 patches. The tool applies:

1. **Base** `patches/xnu-12377/NNNN-*.patch` (12377 only):
   `0001` non-Apple SoC base (UniXNU), `0002` machine config, `0003` machine layer, `0004` platform expert and
   console, `0005` native PAC (stage 2).
2. **Slop stage scripts** `external/slop/negroni-ios/xnu/patches/*.sh` (unless in `skip.txt`).
3. **The series**: `external/slop/negroni-ios/xnu/patches/*.patch` and `patches/xnu/*.patch`, sorted by file
   name, without slop `0127` (as `scripts/kernel/build-local.sh` does). The iOS 16 patch files are read as
   they are; the tool changes only its in-memory copy.

One result line per patch: `base`, `ran`, `applied`, `applied+rules(N)`, `replaced`, `skipped: REASON` or
`ERROR: ...`. Any `ERROR` stops the build (exit 1). So a new iOS 16 patch that does not apply on 12377 shows
at once in the build log and in `out/kernel/local-ios26-*/series-report.txt`.

## Where the 12377 differences live

| Place | What | When to use it |
|---|---|---|
| `scripts/ios26/patch-rules.py` `RULES` | data rules on the patch text: `sub` (also `multiline`/`regex`), `insert_after`, `drop_hunk`, `drop_file`, `rename_file`, `post_sub` | an API, symbol, include or context line changed in 12377; a file moved; a hunk is not needed |
| `scripts/ios26/patch-rules.py` `BASE_OWNED` | files that the base owns, with the series patches whose hunks for that file the base already holds (dropped) or that still apply (kept) | the base patch holds the ported change of that file |
| `scripts/ios26/patch-rules.py` `GLUE_FILES` | build lists (`*/conf/files*`, `*/conf/Makefile.template`): each `+` line goes next to its context line wherever it is in 12377 | automatic |
| `skip.txt` | one line per patch: `NAME REASON` | 12377 has it (`upstream:`), the base has it (`in 12377 base 000N`), 12377 does not need it (`not needed:`), or it is not ported yet (`open:`) |
| `parts/NAME` (rule kind `port`) | the 12377 port of one or more files of a patch; the rest of the patch applies as is | only when no text rule can express the change |
| `replace/NAME` | a full same-name replacement | only when the iOS 16 patch cannot apply at all (none today) |

Every rule names the patches it serves and one line `why`. A rule for named patches that no longer
matches is an `ERROR` (stale rule). A series patch that changes a base-owned file without being listed in
`BASE_OWNED` is an `ERROR`: port its change into the base patch, then list it.

### Port parts (no text rule can express them)

| Part | Why |
|---|---|
| `parts/0395-negroni-cpuperf.patch` | 12377 scheduler: `choose_processor` picks an idle CPU from `idle_map` after the perfcontrol preferred and avoided maps (8796: `idle_primary_map`); `pset->primary_map` exists only with `CONFIG_SCHED_SMT`; the realtime CPU choice moved from `sched_prim.c` to `sched_rt.c` (non-SMT `pset_choose_processor_for_realtime_thread`). The driver part of 0395 (`bsd/dev/negroni_cpuperf.c`, touch boost) applies as is. |

## Work flow for a patch that fails on 12377

1. `scripts/ios26/series-tree.sh --dev` makes `out/kernel/local-ios26/work`: 12377 + dxb 26.0 + the series,
   one git commit per step. In `--dev` mode a failing patch is applied with `--reject` and its result line
   names the rejected files.
2. Look at the reject, find the 12377 code, and write the smallest rule in `scripts/ios26/patch-rules.py`
   (or a skip line with a reason). Run `scripts/ios26/series-tree.sh` again until it ends with `0 errors`.
3. Compile check: `scripts/ios26/kernel-make.sh` (incremental) or a clean `scripts/bg.sh ios26-kernel
   scripts/ios26/build-kernel.sh`.
