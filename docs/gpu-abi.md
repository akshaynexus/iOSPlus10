# RedwoodGPU user-client ABI (kernel patches 0230-0234)

This document is the kernel side of the GPU interface. User space (`userland/negronigl`,
header `userland/negronigl/drm/ngl_abi.h`) implements against it. Kernel source:
`iokit/Kernel/arm/NegroniGPU.cpp` (patches `patches/xnu/0230-negroni-gpu-surface-import.patch`,
`0231-negroni-gpu-present.patch`, `0232-negroni-gpu-host-import.patch` (selector 0x49),
`0233-negroni-gpu-per-client-va.patch` (own GPU tables per client), `0234-negroni-fb-zero-copy.patch`
(display scanout, no user-space call)). Background and test plan: `patches/xnu/README-gpu-kernel.md`.

Status: 0230-0234 build in the local full build (`scripts/kernel/build-local.sh`). **Not booted.**
Changes of 2026-10-25 (round 2): 0x49 USERPTR (section 4), `NegroniGPUABI` text (section 2), per-client
GPU tables with `negronigpu_pt=1` and the window that depends on it (section 5), host-import cache rules
(section 6), zero-copy scanout (section 8), new boot-args (section 9).

## 1. Which ABI

The user client has **two ABIs on the same connection**. Both match `ngl_abi.h` exactly:

| ABI | `ngl_abi.h` name | Selectors | Use |
|---|---|---|---|
| scalar | `NGL_ABI_SCALAR` | 10-16 | Mesa freedreno (GL) with sailfish's `sweet_drm.c` model |
| msm | `NGL_ABI_MSM_STRUCT` | 0x09, 0x40-0x4c (0x49 = USERPTR), 0x7e | Turnip (Vulkan, the Metal path) and freedreno through a libdrm pass-through |

- The scalar ABI is the ios-sailfish `SweetGPU` selector table 10-16 (section 3 lists every
  difference). It is the default of `NEGRONIGL_ABI=auto`.
- The msm ABI is the Linux `msm_drm.h` interface (DRM 1.x, softpin): selector = the request
  number, the Linux structure in and out. **Turnip must use the msm ABI**: it needs GEM_INFO
  (iova, SET_IOVA), submit queues, the bo list and the full submit structure.
- A process can use both on one connection. Handles are shared.

## 2. Service

| Item | Value |
|---|---|
| Class | `RedwoodGPU` (`IOServiceMatching("RedwoodGPU")`, provider `IOResources`) |
| Open | `IOServiceOpen(service, mach_task_self(), 0, &connect)` (type 0) |
| User client | `RedwoodGPUUserClient` |
| Property | `NegroniGPUABI` = `"scalar 10-16, msm 0x09 0x40-0x4c 0x7e, userptr 0x49, va shared"` (`va per-client` with `negronigpu_pt=1`). A kernel without 0232 has no `userptr` in the text. |
| Exists when | boot-args `negroniadreno=22 negroniadreno_keep=1` (and `negroniadreno_service` not 0), and all 22 ladder steps pass. The ladder runs when the root device is found, so the service appears after IOKit's first matching. Poll for it. |
| Memory map | `IOConnectMapMemory64(connect, handle, mach_task_self(), &addr, &size, kIOMapAnywhere)`: memory type = GEM handle. This is the `mmap()` of `MSM_INFO_GET_OFFSET` (`handle << 32`). |

Do not name a user-space or kernel class `IOAcceleratorES`: patch 0201 (boot-waits) defines
that class (an empty one on `AppleCLCD`, so QuartzCore stops its 30 s poll). A second class with
the same name is a kernel link failure.

### Return codes

`IOReturn` values. Suggested errno mapping (this is what `negroni_drm.c` `kr_errno` does):

| IOReturn | errno | Meaning here |
|---|---|---|
| `kIOReturnSuccess` | 0 | |
| `kIOReturnBadArgument` | EINVAL | bad handle, size, flags, structure, fence that no submission has had |
| `kIOReturnNotFound` | ENOENT | no such handle (scalar) or IOSurface ID |
| `kIOReturnNoMemory`, `kIOReturnNoResources` | ENOMEM | no memory, no GPU address, no handle left |
| `kIOReturnTimeout` | ETIMEDOUT | the fence is not done in the time given |
| `kIOReturnBusy` | EBUSY | CPU_PREP with "do not wait" (NOSYNC, scalar 16): not done yet |
| `kIOReturnNotReady` | ENODEV | the GPU is stopped (hang detected) or not kept |
| `kIOReturnUnsupported` | ENOSYS | selector or flag that is not implemented |
| `kIOReturnNotPermitted` | EPERM | 0x49 from a task that did not open the connection |
| `kIOReturnBusy` (submit) | EBUSY | `negronigpu_pt=1`: the GPU did not get idle within 60 s for a table switch |
| `kIOReturnVMError` | EIO | copyin/copyout or wiring failed |
| `kIOReturnNotOpen` | EIO | the client is closing |

## 3. Scalar ABI (selectors 10-16)

`IOConnectCallScalarMethod` unless noted. Scalars are `uint64_t`.

| Sel | Name | In | Out | Notes |
|---|---|---|---|---|
| 10 | BO_NEW | size | handle, GPU VA, user address | Zeroed, wired. Size rounded up to 16 KiB, at most 256 MiB; at most 1 GiB of own buffers per client. The user mapping is made by the kernel in the caller (**cached**, see section 6). |
| 11 | BO_FREE | handle | | Waits up to 1 s for the buffer's last submission. If the GPU does not finish, the memory stays wired and mapped for the GPU for good (leak, on purpose). |
| 12 | BO_IMPORT | IOSurface ID | handle, GPU VA, size | The surface's own pages, whole 16 KiB pages from the first page of its memory. The surface's first pixel is at `GPU VA + offset` (the surface's offset in its memory: 0x7e returns it, normally 0). The kernel retains the surface while the handle lives. Free with 11. |
| 13 | SUBMIT | struct (below) | fence | `IOConnectCallMethod`, struct in, 1 scalar out. Struct up to 1 MiB (IOKit passes more than 4 KiB as a descriptor; both work). |
| 14 | WAIT | fence, timeout ms | | 0 ms: only ask. Capped at 60000 ms. Does not take the client lock (other threads may submit). |
| 15 | INFO | | chip id, GMEM size, GMEM base, max freq (Hz), 0 | 5 scalars out. Values: `0x07030001`, `0x200000`, `0`, `818000000`, `0`. |
| 16 | BO_CPU_PREP | handle | | `kIOReturnBusy` if the buffer's last submission is not done (no wait). Else the CPU's cache lines over the buffer are dropped. |

Submit structure (little endian, packed, `ngl_submit_hdr` / `ngl_submit_ib`):

```c
struct { uint32_t nr_ibs, nr_bos; } hdr;           /* 1 <= nr_ibs <= 512, nr_bos <= 16384 */
struct { uint64_t iova; uint32_t dwords, pad; } ib[nr_ibs];   /* = {iova_lo, iova_hi, dwords, pad} */
uint32_t handles[nr_bos];                          /* every buffer the IBs touch */
/* total length must be exactly 8 + 16 * nr_ibs + 4 * nr_bos */
```

Each IB must lie inside one of the listed buffers, 4-byte aligned, 1..0xfffff dwords. The
kernel runs the IBs in order as `CP_INDIRECT_BUFFER_PFE` (Linux `a7xx_submit` framing: thread
control, IFPC off/on, CCU invalidate, cache clean, BV and BR fence). The out scalar is the fence.

### Differences from ios-sailfish SweetGPU (so `sweet_drm.c` can be reused)

1. Service name `RedwoodGPU`, not `SweetGPU` (`connect_dev()`).
2. Selectors 0-3 (map user memory, map IOSurface, unmap, quad) are not implemented:
   `kIOReturnUnsupported`. `sweet_drm.c` does not call them.
3. `get_param` in `sweet_drm.c` must answer for the A730: `GPU_ID` 0 (not 530), `CHIP_ID`
   `0x07030001`, `HIGHEST_BANK_BIT` 16, `UBWC_SWIZZLE` 6, `MACROTILE_MODE` 1, `RAYTRACING` 0
   (`ngl_abi.h` has these constants). The msm selector 0x40 answers all of them too.
4. An IB outside the listed buffers: `kIOReturnBadArgument` (sailfish: `kIOReturnNotPermitted`
   for an IB outside any mapping). sailfish accepted an IB in any mapping of the client.
5. At most 512 IBs per submission (sailfish 256), 1 GiB own memory per client (sailfish 768 MiB).
6. INFO out[4] is 0, as sailfish today (no fence page). Poll with 14.
7. Wait: the kernel declares the GPU stopped when the completed fence does not move for 2 s
   while a wait is outstanding (sailfish: same idea). After that, every submit and wait answers
   `kIOReturnNotReady`. There is no GPU recovery; a reboot is needed.
8. Fences are one global 32-bit sequence (all processes, all queues). Compare with
   `(int32_t)(a - b) >= 0`.

## 4. msm ABI (selectors 0x09, 0x40-0x4c, 0x7e)

`IOConnectCallStructMethod(connect, selector, &req, sizeof(req), &req, &size)`: the structure
is copied in and, on success, copied back (as many bytes as came in). Selector =
`DRM_COMMAND_BASE (0x40) + DRM_MSM_*`, or 0x09 for `DRM_IOCTL_GEM_CLOSE`. Structures are the
ones of Linux `include/uapi/drm/msm_drm.h` (Mesa 25.0.7 `include/drm-uapi/msm_drm.h`).

| Sel | Request | Status | Details |
|---|---|---|---|
| 0x40 | GET_PARAM | implemented | table below |
| 0x41 | SET_PARAM | stub | `SYSPROF`, `COMM`, `CMDLINE` accepted and ignored; others EINVAL |
| 0x42 | GEM_NEW | implemented | flags: `GPU_READONLY` honored; `SCANOUT` ignored; `CACHED`, `WC`, `UNCACHED` accepted (section 6); **`CACHED_COHERENT` refused (EINVAL)**, so Turnip reports no cached-coherent memory type |
| 0x43 | GEM_INFO | implemented | `GET_OFFSET` = `handle << 32`; `GET_IOVA` (maps at a kernel address again after SET_IOVA 0); `SET_IOVA` (section 5); `GET_FLAGS`; `SET_NAME`, `SET_METADATA` accepted, not kept; `GET_NAME`, `GET_METADATA` ENOSYS |
| 0x44 | GEM_CPU_PREP | implemented | waits for the buffer's last submission until `timeout` (absolute `CLOCK_MONOTONIC`), `MSM_PREP_NOSYNC`: no wait, EBUSY; then drops the CPU's lines (not for pool buffers) |
| 0x45 | GEM_CPU_FINI | stub | success; the CPU's writes are cleaned at the next submission that lists the buffer |
| 0x46 | GEM_SUBMIT | implemented | see below |
| 0x47 | WAIT_FENCE | implemented | `fence` up to the last submitted one (else EINVAL); `timeout` absolute `CLOCK_MONOTONIC`, capped at 60 s; `queueid` ignored (one ring); no client lock |
| 0x48 | GEM_MADVISE | stub | `retained` = 1 (nothing is purged) |
| 0x49 | redwood_drm_userptr | implemented (0232) | not Linux (Linux: GEM_SVM_NEW, unused by Mesa): a buffer over the caller's own pages (below) |
| 0x4a | SUBMITQUEUE_NEW | implemented | returns id 1, 2, ...; `prio` must be 0 (PRIORITIES = 1); `flags` (ALLOW_PREEMPT) ignored. All queues share the one ring. |
| 0x4b | SUBMITQUEUE_CLOSE | stub | success (input: bare `uint32_t` id) |
| 0x4c | SUBMITQUEUE_QUERY | implemented | `MSM_SUBMITQUEUE_PARAM_FAULTS` only: a `uint32_t` (1 after a GPU hang, else 0) copied to `data` (up to `len` bytes); `len` set to 4 |
| 0x09 | GEM_CLOSE | implemented | as BO_FREE (waits up to 1 s) |
| 0x7e | redwood_drm_surface | implemented | not Linux: IOSurface import / describe (below) |

GET_PARAM (`struct drm_msm_param`, `pipe` ignored):

| Param | Value |
|---|---|
| `GPU_ID` 0x01 | 0 (a7xx: identified by CHIP_ID) |
| `GMEM_SIZE` 0x02 | 0x200000 (2 MiB) |
| `CHIP_ID` 0x03 | 0x07030001 (A730) |
| `MAX_FREQ` 0x04 | 818000000 |
| `TIMESTAMP` 0x05 | `mach_absolute_time()` (19.2 MHz, the same counter as RBBM always-on) |
| `GMEM_BASE` 0x06 | 0 |
| `PRIORITIES` 0x07 | 1 |
| `PP_PGTABLE` 0x08 | 0 |
| `FAULTS` 0x09 | 1 after a GPU hang, else 0 (Turnip: device lost) |
| `SUSPENDS` 0x0a | 0 |
| `VA_START` 0x0e, `VA_SIZE` 0x0f | the client's own window (section 5): start, 4 GiB |
| `HIGHEST_BANK_BIT` 0x10 | 16 |
| `RAYTRACING` 0x11 | 0 |
| `UBWC_SWIZZLE` 0x12 | 6 |
| `MACROTILE_MODE` 0x13 | 1 |
| others | EINVAL |

GEM_SUBMIT (`struct drm_msm_gem_submit`):

- `cmds[]`: type `MSM_SUBMIT_CMD_BUF` and `CTX_RESTORE_BUF` run as IBs (CTX_RESTORE every
  time: there is one context); `IB_TARGET_BUF` is skipped (reached from another IB). Each cmd:
  `submit_idx` < `nr_bos`, `nr_relocs` 0, `size` and `submit_offset` 4-byte aligned, inside the
  buffer. 1..512 cmds.
- `bos[]`: up to 16384; `flags` (READ/WRITE/DUMP/NO_IMPLICIT) and `presumed` are ignored. Every
  listed buffer gets this fence (for CPU_PREP, GEM_CLOSE and the present path).
- `flags`: `FENCE_FD_IN`, `SUDO`, `FENCE_SN_IN` refused (ENOSYS). `FENCE_FD_OUT`: success with
  `fence_fd` = -1 (no sync_file in this kernel). `NO_IMPLICIT`: ignored (no implicit sync).
  `SYNCOBJ_IN` / `SYNCOBJ_OUT`: the kernel ignores `in_syncobjs` / `out_syncobjs` (section 7).
- `queueid`: ignored. Out: `fence`.

0x7e `struct redwood_drm_surface` (`userland/negronigl/drm/xf86drm.h`, HackiOS redwood-drm layout):

```c
struct redwood_drm_surface {
	uint32_t surface;                       /* in: IOSurface ID */
	uint32_t handle;                        /* in: 0xffffffff = only describe; anything else = import. out: GEM handle */
	uint64_t size;                          /* out: buffer size (whole 16 KiB pages of the surface memory) */
	uint32_t offset, row_bytes;             /* out: first pixel in the buffer, bytes per row */
	uint32_t width, height, pixel_format, planes;   /* out */
};
```

0x49 `struct redwood_drm_userptr` (`userland/negronigl/drm/xf86drm.h`, `ngl_abi.h` `NGL_MSM_SEL_USERPTR`), 24 bytes
exactly (else EINVAL):

```c
struct redwood_drm_userptr {
	uint64_t pointer;       /* in: address in the caller, 16 KiB (PAGE_SIZE) aligned */
	uint64_t size;          /* in: bytes, a multiple of 16 KiB, at most 256 MiB */
	uint32_t flags;         /* in: NGL_USERPTR_READ_ONLY (0x1): the GPU only reads; other bits EINVAL */
	uint32_t handle;        /* out: GEM handle */
};
```

- For VK_EXT_external_memory_host (Turnip) and `newBufferWithBytesNoCopy:` (Metal).
- The kernel wires the pages while the handle lives (`IOMemoryDescriptor::withAddressRange` +
  `prepare`). The GPU keeps the pages that were there at import, also when the program unmaps or
  remaps the range later. Free with 0x09 (GEM_CLOSE).
- Without `READ_ONLY` the pages must be writable (else `kIOReturnVMError`, EIO). With it, read-only
  memory can be imported and the GPU mapping is read-only.
- Only the task that opened the connection (else EPERM). At most 1 GiB of host imports per client
  (else ENOMEM), apart from the 1 GiB of own buffers.
- GEM_INFO works as for other buffers (GET_IOVA, SET_IOVA, GET_FLAGS = `MSM_BO_CACHED` (+
  `GPU_READONLY`)). `GET_OFFSET` answers, but `IOConnectMapMemory64` of such a handle is refused
  (`kIOReturnUnsupported`): the program has its own mapping.
- Cache rules: section 6 ("host import" row).

## 5. GPU addresses

- One SMMU context (the 3D core's), 39-bit, 4 KiB pages. Two layouts (boot-arg `negronigpu_pt`):

| | `negronigpu_pt=0` (default): shared | `negronigpu_pt=1` (0233): per client |
|---|---|---|
| Tables | one set for every client | one set per open connection; the kernel's part (0..4 GiB: ring, microcode, scratch, the present's mappings) is the same in each |
| Isolation | **none: a client's GPU commands can read and write every other client's GPU memory** | a client's commands reach only its own buffers and the kernel's part |
| Kernel-chosen addresses | 0x1_0000_0000 .. 0x40_0000_0000, shared | the client's own 0x10_0000_0000 .. 0x40_0000_0000; the kernel's own 0x2000_0000 .. 0x1_0000_0000 |
| `VA_START` / `VA_SIZE` | a 4 GiB window reserved for this client in the shared range (different per client) | 0x1_0000_0000 / 16 GiB, the same in every client (Linux A730: 16 GiB) |
| Cost | none | the GPU must be idle to switch tables: a submission of client B after one of client A waits until A's work is done (up to 60 s, else EBUSY); kernel present copies need no switch |

  User space must take `VA_START` / `VA_SIZE` from GET_PARAM and not assume values. The table
  switch is done by the CPU (TTBR0 of the context, then TLBIASID), not by `CP_SMMU_TABLE_UPDATE`
  from the ring: that needs the CP's SMMU aperture on our context (a TrustZone call, context 2
  here, Linux puts the GPU in context 0) and nothing of it is tested on this phone
  (`patches/xnu/README-gpu-kernel.md` section 8). If the context does not take the new tables, the
  GPU is declared stopped (FAULTS = 1, every submit `kIOReturnNotReady`).
- Kernel-chosen addresses: first fit in 0x1_0000_0000 .. 0x40_0000_0000, 64 KiB granule. A
  buffer keeps its address while it lives.
- Userspace-chosen addresses (Turnip's `has_set_iova`): the first `GET_PARAM VA_START` or
  `VA_SIZE` reserves a 4 GiB window for this client. `GEM_INFO SET_IOVA` with a value in the
  window, 16 KiB aligned, not overlapping another of the client's SET_IOVA buffers, moves the
  buffer there (it waits up to 1 s for the buffer's last submission, else EBUSY). `SET_IOVA 0`
  takes the address away (Turnip's zombie-VMA path). The window is given back on close.
- Imported surfaces and own buffers can both be moved. The kernel maps every 16 KiB page as
  four 4 KiB SMMU pages.

## 6. Memory and caches

| Buffer | CPU mapping | GPU view | Who keeps them coherent |
|---|---|---|---|
| own (scalar BO_NEW, msm GEM_NEW `CACHED` or pool off) | **cached**, kernel memory XNU manages | non-cacheable | the kernel: at each submission it cleans the pages the CPU wrote since the last one (pmap modified bit); CPU_PREP drops the CPU's lines. |
| pool (msm GEM_NEW `WC`/`UNCACHED`, boot-arg `negronigpu_pool=MiB`) | write-combined, RAM XNU does not manage | non-cacheable | nobody needs to: no cacheable view of it exists |
| import (IOSurface) | cached (the IOSurface's own mapping) | non-cacheable | the kernel cleans and drops the lines at import and cleans written pages at each submission |
| host import (0x49) | cached (the program's own mapping) | non-cacheable | as import: clean + drop at import, written pages cleaned at each submission that lists the buffer; after GPU writes the program calls CPU_PREP (0x44) or drops the lines itself (`dc civac`, Turnip's `vkInvalidateMappedMemoryRanges`). Expose such memory as `HOST_CACHED` without `HOST_COHERENT`. |
| IOSurface in a display slot (0234, backboardd's framebuffers with `negronifb_zerocopy=1`) | cached, RAM XNU does not manage | non-cacheable | the kernel cleans and drops the whole surface by kernel address at import. Its pages have no pmap modified bit, so **CPU writes after import are not cleaned at submit**: a GPU-rendered framebuffer must not be written by the CPU. |

Rules for user space:

1. CPU writes, then GPU reads: nothing to do; list the buffer in the submission.
2. GPU writes, then CPU reads (own and import buffers): call CPU_PREP (msm 0x44 or scalar 16)
   after the fence. Without it the CPU can read stale lines. Freedreno GL does this already.
3. Turnip `HOST_COHERENT` memory (`MSM_BO_WC`): only the pool is truly coherent. Without the pool
   a Vulkan application that reads GPU results through a mapping without
   `vkInvalidateMappedMemoryRanges` can see stale data. Turnip's own `MSM_BO_CACHED` memory
   (`HOST_CACHED`, not coherent) is handled by Turnip itself (`dc civac` from EL0: XNU sets
   `SCTLR_EL1.UCI`). **Boot with `negronigpu_pool=512` (or more) for Turnip.**
4. Why not write-combined own buffers: a write-combined view of memory XNU manages is a
   mismatched alias of its cacheable physical aperture (ios-sailfish froze, boot 0150a;
   ios-flame lost data). The slop 0118 GEM_NEW did exactly that (`kIOMapWriteCombineCache`
   on an `IOBufferMemoryDescriptor`); see README-gpu-kernel.md for why that is the likely cause
   of the 0119-0123 panic.
5. A buffer the GPU has not finished with when it is freed is never given back (no use after
   free by a running GPU).

## 7. Sync objects and fence fds

The kernel has no DRM syncobj and no sync_file. Fences are global 32-bit ring sequence
numbers, and one ring runs every submission in order. User space emulates syncobjs:

- A binary syncobj = "no fence" or a fence number (or "signaled").
- `SYNCOBJ_OUT` / `FENCE_FD_OUT`: after GEM_SUBMIT, give the returned `fence` to the out
  syncobjs.
- `SYNCOBJ_IN`: a syncobj with a fence from an earlier submission needs no wait: the ring
  orders it. A syncobj with no fence: wait in user space (`WAIT_FOR_SUBMIT`) before the submit,
  or return EINVAL as Linux does.
- `drmSyncobjWait` / `TimelineWait`: WAIT_FENCE (0x47) or scalar 14 on the fence numbers.
- Export / import (sync file, opaque fd): the fence number is valid in every process (one
  global sequence), so a sync-file "fd" can carry it (for example a pipe or a small file with
  the 4 bytes). Timelines: Mesa's `vk_sync_timeline` emulation on top of binary syncobjs.
- **Later item (not in 0230/0231):** kernel syncobj selectors (create/destroy/wait/reset/signal,
  export as a Mach port) if cross-process sharing through a real fd is needed. The number
  space 0x20-0x2f is kept free for them.

## 8. Present (patches 0231 and 0234, no user-space call)

User space does not call anything to present. When an IOSurface that was imported (scalar 12
or 0x7e) is listed in a submission, the kernel marks it "GPU-written" with that fence. When
backboardd swaps it into the framebuffer (IOMobileFramebuffer SwapEnd), `AppleCLCD` holds the
surface in use (`IOSurfaceIsInUse`, state page +0x18) and the A730's 2D engine copies the
visible rectangle into the panel memory, queued behind the render on the same ring. The hold
ends when the copy's fence is done, so CoreAnimation renders the next frame into another
surface of its swap chain. Requirements for this path: BGRA 4 bytes per pixel, surface offset
and bytes per row multiples of 64 (the IOSurface stand-in asks for 64-byte rows). Other frames
take the CPU copy. Boot-args: `negronifb_gpu=0` (CPU only), `negronifb_gpuhz` (default: every vsync
tick, 120).

Zero-copy (0234, `negronifb_zerocopy=1`): backboardd's canvas-sized BGRA framebuffers (1125x2436)
are placed in display slots of the splash region (3 slots after the panel memory at 0xB8000000). A
frame that is one such framebuffer alone, full canvas, is not copied: the display engine's pipes are
pointed at it (crop 22,12, the centred 1080x2412 part) and it is on screen from the next 120 Hz frame.
A GPU-rendered one is flipped at the first vsync tick after its fence is done. The shown framebuffer
and the pending one are held in use; `SwapWait` (IOMobileFramebuffer selector 6, called by
CoreAnimation) waits at most 50 ms until the swap it names is on screen. For the GL/Metal drivers
this means: import the framebuffer (0x7e or scalar 12), render, submit, then let CoreAnimation swap;
nothing else. Do not CPU-write a framebuffer after the GPU rendered into it (section 6).

## 9. Boot-args

| Boot-arg | Default | Effect |
|---|---|---|
| `negroniadreno=22 negroniadreno_keep=1` | off | GPU kept on, RedwoodGPU published |
| `negroniadreno_service=0` | 1 | GPU kept, no RedwoodGPU (bisect aid) |
| `negroniadreno_watch=0` | 1 | no GPU state watcher thread |
| `negronigpu_pool=MiB` | 0 | write-combined pool of RAM XNU does not manage, for msm `WC` buffers (max 2048) |
| `negronigpu_poolbase=PA` | 0x980000000 | pool start (16 KiB aligned; refused if XNU manages it) |
| `negronifb_gpu=0` | 1 | present GPU-rendered surfaces with the CPU |
| `negronifb_gpuhz=N` | 120 | GPU copies per second (vsync ticks) |
| `negronigpu_pt=1` | 0 | per-client GPU tables (section 5) |
| `negronifb_zerocopy=1` | 0 | zero-copy scanout of backboardd's framebuffers (section 8); needs `negronifb_noconsole=1`, no `negronibadge`, no `negronifb_shift` |
| `negronifb_dpuprobe=0` | 1 | do not read (log) the display engine's registers at boot |
| `negronifb_ctl=N` | auto | the display engine's CTL for flushes (auto: the one driving DSI0, else 0) |
| `negronifb_hz=N` | 10 | CPU presents per second (unchanged) |
