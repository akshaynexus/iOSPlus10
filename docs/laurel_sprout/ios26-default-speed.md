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

## 7. Where a slow frame waits, read in the samples (branch `t3/ios26-frame-gap-root-cause`, 2026-11-03)

Tool: `scripts/laurel/ios26-sample-bins.py SAMPLES [--thread N] [--bin MS] [--abs] [--from MS --to MS] [--callers] [--stacks N] [--dis DIR]`. Run s11 (`bench-s11.samples`, backboardd thread 6 only, 50 Hz; `bench-s11.sb.samples`, SpringBoard main thread), Home swipes, 13.1 fps.

**The two threads do not alternate per frame [V].** On one clock (`--abs`, 100 ms bins): SpringBoard's main thread runs at 60-100 % for about 600 ms while the finger moves (UIKit, layout, commit), then idles; backboardd's render thread then runs 60-100 % for about 2 s while CoreAnimation animates the page by itself. The slow frames of the animation are the render thread's.

**In the animation the render thread is 49 % busy [V, 205 samples of 4 s].** Where the other half is:

| Wait | Share of the thread | What it is |
|---|---|---|
| `mach_msg2_trap` under `IOMFBServer::thread_body` | 33 % | the run loop waits for the next vsync message |
| `__psynch_cvwait` under `nmb_command_buffer_wait_scheduled` | 8 % | CA's `waitUntilScheduled` in `MetalContext::flush` -> `finish_update`: a condvar until metal2vulkan's scheduler thread has submitted |
| `mach_msg2_trap` under `io_connect_method` from Turnip | 8 % | kernel calls while recording: `tu_cs_reserve_space` -> `msm_bo_init` (`new`, 531 us each), `host_import_pages`, `redwood_drm_map` |

Busy time by image: metal2vulkan 45 %, QuartzCore 24 %, Turnip 13 %, libsystem_malloc 5 %. Over the whole run (28 s) the thread is 28 % busy; SpringBoard's 25 %.

**33 % in the vsync wait at 10-13 frames/s does not fit a thread that only finishes late [I].** A frame that ends inside a tick waits at most one tick (8 ms on average, 8 % of a 100 ms frame). The thread waits about 33 ms per frame. Either CoreAnimation skips ticks on purpose (its own pacing after a late frame), or the vsync message reaches it late, or a frame ends and the next commit is not there yet. The kernel's tick is not the cause: 1060 of 1162 windows have a mean tick of 16.6 ms and a worst tick under 20 ms; 32 windows hold one 33 ms tick, 7 one 50 ms tick, 15 one over 100 ms (`LAUREL FRAME: N ticks of U us, worst W`). Next: a sample of thread 6 at 500 Hz (`laurel-autotest sample PID 4 500 only=6`) through one animation, binned at 10 ms, gives the frame shape: encode, wait for the scheduler, vsync wait. Not run: the phone was down.

**The kernel's GPU wait [V code].** `gpuWait` looks every 200 us (`delay_for_interval`, a timer with up to 1 ms of slop for a kernel thread) and drops `gGPULock` while it sleeps. `LAUREL GPU TIME: fence 693 us x 963 per 5 s` is u_trace's worker thread (Turnip patch 0105 turns tracing on; `tu_trace_read_ts` waits for the fence of each chunk), not the render thread; 14 waits per submission, one of them real. A/B of `NEGRONIMETAL_GPU_PASS=0`: not run.

**What the CPU gives [NOT RUN].** `scripts/laurel/ios26-speed.sh` (`userland/laurel/speed/laurel_speed.c`, built, 0 words newer than ARMv8.0): the real clock of the core a thread lands on (dependent adds, 1 and 8 threads), L1/L2/DRAM load-to-use latency, memcpy, a syscall, `mach_absolute_time`, a semaphore and a mach_msg wake-up, how late a 1 ms and a 16.7 ms sleep ends, the cost of a first touch of a 4 KiB page. Reference on paper: A73 at 2016 MHz: 2.0 G adds/s, L1 2 ns, DRAM 100-140 ns, a wake-up 30-80 us. A result far from these is the constant factor behind "a draw costs 25-87 us here against 1.6 us on the host"; a result at these numbers puts the cost in the code (metal2vulkan's runtime first).
