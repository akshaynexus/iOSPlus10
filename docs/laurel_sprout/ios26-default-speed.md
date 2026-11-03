# Mi A3 iOS 26: speed of the default stack (metal2vulkan + Turnip)

Date: 2026-11-03. Branch `t3/default-stack-glass-60fps`. Marks: [V] measured on the phone or read in code. [I] inference. [U] unknown.

## 1. Tools

| Tool | What it does |
|---|---|
| `scripts/bg.sh bench-NAME env TURNIP=FILE PLUGIN=FILE scripts/laurel/phone-lock.sh m2v scripts/laurel/ios26-default-bench.sh NAME [KEY=VALUE ...] [-- --only a,b]` | One measure: sets option default and the env, puts the files, restarts the UI, runs the UI test, puts all back. tmux gives no env to a job: pass `env` as here. A GPU left off by an earlier test: one reboot. Table: `logs/bench-NAME.txt`, kernel lines: `logs/bench-NAME.kernel.txt` |
| `LAUREL GPU PASS` (Turnip patch 0105) | GPU time per kind of pass and compute dispatch, from Turnip's timestamps, once per 5 s of work per process with at least 2 % GPU. Kill switch `NEGRONIMETAL_GPU_PASS=0` |
| `scripts/laurel/ios26-gpu-pass-sum.py FILE` | Sums these lines |
| `scripts/laurel/ios26-png-compare.py REF_DIR RUN_DIR [SHOT]` | Same picture? Shares of changed pixels per shot, status bar out |

## 2. Where the GPU time goes [V, `LAUREL GPU PASS`, kernel 3d4671dd68, real touch, DDR 1805 MHz]

Fixed UI test, backboardd, 115 s of work. `logs/bench-b2-base.txt`:

| Work | ms | Count | us each | Share of 21,616 ms |
|---|---:|---:|---:|---:|
| **Compute, all** | **15,881** | 1,388 | 11,441 | **73 %** |
| compute `64x1, 3x1560 groups` | 6,862 | 419 | 16,377 | 32 % |
| compute `64x1, 6976x1` | 944 | 24 | 39,333 | 4 % |
| compute `64x1, 14080x1` | 892 | 6 | 148,666 | 4 % |
| compute `64x1, 19200x1` | 813 | 4 | 203,250 | 4 % |
| Render passes, all | 5,735 | 985 | 5,822 | 27 % |
| pass `gmem 720x1560 108 tiles` | 5,272 | 441 | 11,954 | 24 % |

**The compute is not CoreAnimation's.** Local size 64 is metal2vulkan's own kernels [V `bind/*.rs`]. `3x1560` is `shadow_merge_image`: 720 words a row, 256 words a group, 1560 rows: one word-by-word merge of a full screen. One per frame. Cause [V, m2v notices on the phone]:

```
a 2D BGRA8Unorm texture over a buffer: the buffer's bytes are host pages imported by their pointer, and the device's check made no image over host pages ...
```

So every texture over an IOSurface is a **shadow**: an image of the runtime's, a copy in, a keep and a merge per pass. Four things hold that in place, each read in the code:

| # | Lock | Where | Fix |
|---|---|---|---|
| 1 | A render target over host pages is always a shadow | `in_place.rs` `in_place()` | `m2v-ios26/0002` |
| 2 | The check of the first move answers `Unchecked`: it makes no 40 MiB no-copy buffer here. The verdict stays in the shader cache | `in_place_check.rs` | `m2v-ios26/0002`: on Turnip a layout move writes no byte [V `tu_barrier`] |
| 3 | Turnip asks a dedicated import for any external image | `tu_image.cc` | Turnip `0107` |
| 4 | [I] A row pitch other than Turnip's own: refused, stays a shadow, one notice | `in_place_image.rs` `lies` | none yet |

My first guess was the APL kernels, and CA's compute blur: wrong. [V host] `supportsFamily:1004` answers NO, so CA's compute blur path is not taken (`CA::OGL::MetalContext::create_variable_blur_mip_surface`, flag `+0xdc4` bit 3).

## 3. Measures, one change each [V]

Baseline `b2-base`, same test, same kernel. "Pass" is the mean of `gmem 720x1560`.

| Run | Setting | Pass ms | Tiles | Compute ms of 3x1560 | Picture |
|---|---|---:|---:|---:|---|
| `b2-base` | none | 11.95 | 108 | 16.4 | reference |
| `b2-readers` | Turnip 0106: order only real readers | 12.03 | 108 | 16.2 | same: control center open 0.14 % off, closed 0.09 % off |
| `b3-nomemless` | `CA_ENABLE_MEMORYLESS=0` | **3.02** | **36** | 13.2 | Settings list 0.00 % off. Control Center did not open in that run: repeat |

- **`CA_ENABLE_MEMORYLESS=0`: render passes fall to a quarter.** Passes in all 5,735 -> 1,640 ms.
- 0106 alone gives no gain: all passes stay in GMEM, and the flush per overlap is not a large cost here.
- `TU_DEBUG=sysmem` and `CA_ENABLE_MEMORYLESS=0` each boot alone [V]. Together they stuck at the logo in one boot: not tested again yet.

## 4. CoreAnimation's own switches

[V 23F84] `init_debug` reads the environment once, before the bundle loads, so `/var/db/negronimetal/env` is too late for the `CA_DISABLE_*` table. `CA_ENABLE_MEMORYLESS` is read by its own `getenv` at the Metal context: env works. The table is reachable by Apple's exports: `CAGetDebugOptionEnvVariableName(i)`, `CASetDebugOption(i, v)`, 260 entries. `LAUREL CA OPTIONS` in the plug-in sets a list by name: `NEGRONIMETAL_CA_OPTIONS=A,B`. Only same-picture switches may go in the default list. Names that matter: `CA_DISABLE_APL_FILTER`, `CA_DISABLE_LUMA_COMPUTE`, `CA_DISABLE_COMPUTE_DOWNSAMPLE_BLUR`, `CA_DISABLE_COMPUTE_COPY_BASE_MIP`, `CA_DISABLE_COMPUTE_CLASSIC_VAR_BLUR`, `CA_DISABLE_TILE_SHADERS`, `CA_DISABLE_INPLACE_SHADERS`, `CA_DISABLE_SDF_CACHE`, `CA_DISABLE_FILTERED_LUMA`. Script of the offsets: `out/ios26/dis`, from `scripts/laurel/dsc-image.py`.

## 5. Traps of this work

- A job in tmux gets no env of the caller: `scripts/bg.sh NAME env KEY=V COMMAND`.
- ssh in a `while read` loop eats the rest of the list: `</dev/null`.
- `git -C DIR` in a build tree that a rebuild removed reaches the repo above. Do not `git init` in `out/ios26/gpu/turnip/mesa-*`: `make_tree` removes it at each new patch, and an edit there goes with it.
- A bench with Metal off gives an empty table: read `gpu/sub`.
