# NegroniMetal: Management & Diagnostics Guide

This document describes how to control, enable, disable, and troubleshoot the **NegroniMetal** GPU acceleration stack on the OnePlus 10 Pro (NE2211, Adreno 730).

---

## 1. Quick Control (via SSH over USB)

Connect to the phone via USB (`192.168.7.2`):

```sh
# Helper command wrapper
scripts/net/ssh-phone.sh "<command>"
```

### Enable Metal for All Processes
To enable hardware Metal acceleration for all daemons and apps (including `backboardd`, `SpringBoard`, and user apps):

```sh
scripts/net/ssh-phone.sh "echo '*' > /private/var/db/negronimetal/clients && chmod 666 /private/var/db/negronimetal/clients"
```

### Limit Metal to Test Probes Only (Safe Mode)
If the UI becomes unstable or you want to restrict Metal to command-line probes (`metalprobe`, `m2vtest`):

```sh
scripts/net/ssh-phone.sh "echo 'metalprobe m2vtest' > /private/var/db/negronimetal/clients"
```

### Disable Metal Completely (Emergency Switch)
To immediately force every process to use CPU rasterization without rebooting:

```sh
# Touch the 'off' sentinel file
scripts/net/ssh-phone.sh "touch /private/var/db/negronimetal/off"

# To re-enable Metal later, simply remove it:
scripts/net/ssh-phone.sh "rm -f /private/var/db/negronimetal/off"
```

---

## 2. Watchdog & Dead-Man Strikes

### What are strikes?
`NegroniMetal` implements a **dead-man safety switch** to prevent permanent black screens. A start that fails after the
device opened gets a strike, recorded in `/private/var/db/negronimetal/strikes/<process_name>` (a sandboxed process:
`<its cache dir>/negronimetal-strikes/<name>`). The file holds `COUNT BOOT-UUID`; strikes from an earlier boot do not count.

Rules (NegroniMetal.mm, 2026-10-25):
* **Strike written** when the device has opened, when the open/self-test hangs past `NEGRONIMETAL_OPEN_MS`, or when the
  process crashes (SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGSYS, SIGABRT) during the open.
* **No strike** when the process is killed (SIGKILL, e.g. launchd's "extension check-in timeout") before the device
  opened, or when the open is refused cleanly (a clean refusal also removes the old count).
* **Strike cleared (clean start)** at the first command buffer that completes after the open (the self-test's command
  buffer does not count), 15 s after the open, or at `exit()`. Log: `dead-man: strike N armed (device opened, limit L)`,
  then `dead-man: strike cleared (first command buffer completed T ms after the device opened)`.
* **Limit:** `NEGRONIMETAL_STRIKE_LIMIT` (default 2; the old name `NEGRONIMETAL_MAX_STRIKES` is still read). Processes whose
  name ends in `Poster`, `PosterExtension` or `PosterProvider` get twice the limit (default 4): PosterBoard relaunches
  them several times at boot.
* **Effect:** at the limit, `NegroniMetal` gives that process no device (`dead-man: N unclean starts in a row (limit L)`).
  Metal-only processes (the poster extensions) then fail; clear the strikes to re-arm.
* The backboardd GPU watchdog (`strikes/gpu-lost`) is separate: it does not clear the process strike.

### How to Check and Clear Strikes
When the UI feels slow and CPU-rendered despite Metal being enabled, check if strikes have been recorded:

```sh
# View current strikes
scripts/net/ssh-phone.sh "ls -la /private/var/db/negronimetal/strikes/"

# Clear all strikes to re-arm Metal for all processes
scripts/net/ssh-phone.sh "rm -f /private/var/db/negronimetal/strikes/*"
```

### Tuning Watchdog Timeouts
Environment variables in `/private/var/db/negronimetal/env` configure watchdog behavior:
```sh
# Example: relax open/self-test timeout (default 20000 ms) and watchdog timeout (default 60s for backboardd, 30s others)
scripts/net/ssh-phone.sh "printf 'NEGRONIMETAL_WATCHDOG_S=60\nNEGRONIMETAL_OPEN_MS=10000\n' > /private/var/db/negronimetal/env"
# Example: strike limit 3 (6 for the poster extensions); the env file is read before the strike check
scripts/net/ssh-phone.sh "echo NEGRONIMETAL_STRIKE_LIMIT=3 >> /private/var/db/negronimetal/env"
```

---

## 3. Logs & Diagnostics

### Refusal lines (flame/0008)
Every refused buffer, texture, library, render or compute pipeline is logged once per (what, reason) text:
`native-metal: refused (logged once per reason): buffer length 432 options 0x1: <runtime reason>`,
`... texture type 2 fmt 80 1170x2532x1 levels 1 ... options 0x0: ...`, `... render pipeline 'label' (vs / fs, color0 fmt 80, ...): ...`,
`... library /path (N bytes): ...`. A small buffer (< 1 MiB) refused with a CPU cache mode is made again without it, then with
options 0: `buffer length N options 0x1 (made again with options 0x0): <first reason>`. The plugin's MPS line
`MPS feature flags = NO (NegroniMetal A730 answer): ...` lists the MetalPerformanceShaders feature selectors answered NO.

### Protocol conformance and uncaught exceptions (flame/0012, 2026-10-26)
At device creation the frontend adopts the 20 public Metal protocols for its classes and logs `native-metal: Metal protocols
adopted by 20 of 20 frontend classes`. MetalPerformanceShaders checks `conformsToProtocol:@protocol(MTLCommandBuffer)` and
crashed SpringBoard (Siri orb) on the nil it answered before. In a process with a device, an uncaught Objective-C exception is
logged before the abort: `uncaught exception NAME: REASON` plus up to 10 frames (the extensions' stderr never reaches the
kernel log).

### Real-Time Driver Log
Inspect live driver initialization, frame presentation, and device answers:

```sh
scripts/net/ssh-phone.sh "tail -n 50 /private/var/db/negronimetal/metal.log"
```

The telemetry row `J nocopy-dealloc inflight=N used=N | hostinv n=N r=N kb=N` (flame/0006, m2v/0002) counts no-copy
buffers freed while GPU work was in flight (`used` = still listed by a runtime command buffer: should stay 0) and m2v's
host-import cache invalidations. No new env or file knob.

### m2v Device Policy (`NEGRONIMETAL_POLICY`)
The plugin loads `KEY=VALUE` lines of `/var/db/negronimetal/env` before the device opens. `NEGRONIMETAL_POLICY`
selects the metal2vulkan device policy (flame/0007, m2v/0003):

| Value | 8-bit linear filter | 8-bit colour writes | Bounds checks (containment) |
|---|---|---|---|
| `exact` | Metal's, emulated | Metal's rounding, emulated (unorm + sRGB) | on |
| `compositor` (default, also unset) | Turnip's own | Turnip's conversion for 8-bit unorm; sRGB emulated | on |
| `compositor-srgb` | Turnip's own | Turnip's conversion for 8-bit unorm and sRGB | on |
| `unsafe` | Turnip's own | as `compositor` | **off** (and guest isolation off) |

A/B test (restart the client, for example `killall backboardd`, after a change):

```sh
scripts/net/ssh-phone.sh "echo NEGRONIMETAL_POLICY=exact >> /private/var/db/negronimetal/env"
# back to the default: remove the line
scripts/net/ssh-phone.sh "cd /private/var/db/negronimetal && grep -v '^NEGRONIMETAL_POLICY=' env > env.new; mv env.new env"
```

The policy is in the shader-cache key, so the first frames after a change compile new pipelines. The log line
`images NegroniMetal 0x... text 0x... turnip 0x... text 0x... (m2v policy NAME)` shows the active value and the
load addresses for crash symbolication: `atos -o out/gpu/turnip/libvulkan_freedreno.dylib -l TURNIP_BASE PC`,
`atos -o NegroniMetal.dSYM -l BASE PC`.

### MSL source compile (`NEGRONIMETAL_MSL_FRONTEND`, flame/0009 + flame/0011)
WebGPU in Safari (WebGPU.framework, the GPU process `com.apple.WebKit.GPU`), ANGLE's Metal back end (WebGL) and apps compile
Metal Shading Language text with `newLibraryWithSource:options:error:`. Since flame/0011 the plugin compiles it **in the
calling process** with Apple's own MSL front end (libGPUCompiler `MTLGPUCompilerBuildFromSourceToBuffer`, the call
MTLCompilerService makes; `userland/metal/plugin/negroni_msl.h`). No MTLCompilerService XPC is used. The metallib goes to
metal2vulkan like a file's. A compile error answers nil + an NSError with the compiler text.

| `NEGRONIMETAL_MSL_FRONTEND` | Behaviour |
| --- | --- |
| unset, `1`, `inproc` | in-process front end (default) |
| `xpc` | the base class's compile (MTLCompilerService XPC; faulted on 2026-10-26: diagnosis only) |
| `0`, `off` | clean refusal (nil + error, one log line per process; flame/0009 behaviour) |

Other knobs (all in `/var/db/negronimetal/env`):
- `NEGRONIMETAL_MSL_OPTIONS="..."`: extra front-end options after the ones from `MTLCompileOptions`.
- `NEGRONIMETAL_MSL_DRIVER=0|1`: `1` always puts the driver flags in front (`-x metal -finclude-default-header -internal-isystem
  DIR/include/metal`), `0` never. Unset: bare options first; when the front end answers "not allowed with 'C'",
  "'metal_stdlib' file not found" or "unknown type name 'using'", the call is made again with the driver flags, and the
  process keeps them.
- `NEGRONIMETAL_MSL_RESOURCE_DIR=DIR`: the front end's header directory (default: the first
  `/System/Library/PrivateFrameworks/GPUCompiler.framework/Libraries/lib/clang/*` with `include/metal/metal_stdlib`).
- `NEGRONIMETAL_GPUCOMPILER=PATH`: another libGPUCompiler (default the 20H392 one in the dyld cache).

Crash guard: while a compile runs, `/var/db/negronimetal/strikes/msl-<process>` (sandboxed processes: their temporary
directory) holds the boot session. A process that finds its own marker from this boot died in the front end: it refuses
MSL source from then on and logs `an earlier <process> died in the MSL front end this boot`. Remove the file to re-arm.

Log lines: `native-metal: newLibraryWithSource #N: C chars -> B bytes metallib (in process[, driver flags]) in T ms, library L ms`
(first 8, then powers of two), `native-metal: newLibraryWithSource: MSL front end refused ... : <compiler text>`.

```sh
scripts/net/ssh-phone.sh "/usr/local/bin/mslprobe"                       # front end only (built-in shader), no device
scripts/net/ssh-phone.sh "/usr/local/bin/mslprobe -O '-std=metal3.0' /path/x.metal -o /tmp/x.metallib"
scripts/net/ssh-phone.sh "/usr/local/bin/metalprobe --compute --render"  # MSL source -> device -> GPU
```

Argument buffers (flame/0011): `newArgumentEncoderWithArguments:`, `-[MTLFunction newArgumentEncoderWithBufferIndex:]` and
the encoder setters go to metal2vulkan's `ArgumentEncoder`; `useResource(s)`/`useHeap(s)` reach its residency.
`argumentBuffersSupport` is metal2vulkan's own answer for the device. Indirect draws and dispatches are bridged;
indirect command buffers are not: `newIndirectCommandBufferWithDescriptor:` answers nil (one log line, plus a MISSING
line), an `executeCommandsInBuffer:` is skipped (one log line). Decision 2026-10-26 (audit follow-up): metal2vulkan's
runtime has them (`crates/metal2vulkan-runtime/src/indirect_command_buffer.rs`), but the ios-flame bridge
(`out/metal/src/flame/phone/metal2/bridge/NativeMetalBridge.{h,rs}`) has no ICB entry point at all (creation, the
compute/render command setters, execute), so the frontend has nothing to call; the clean refusal stays until a WebGPU
or game test logs `executeCommandsInBuffer` skipped lines. Then the work is bridge + frontend (about 15 `nmb_*` calls).

Sync switch: `NEGRONIMETAL_SYNC=1` (env) or the file `/var/db/negronimetal/sync` (NMTL_DIR/sync since flame/0013; the
host test's own directory on a Mac) makes every commit wait for completion; `NEGRONIMETAL_DEFER_SCHEDULED=1` keeps the
scheduled handlers until completion.

### Idle load knobs and measurement (flame/0010, scripts/metal/idle-stats.sh)
* `NEGRONIMETAL_SURFACE_FLUSH=0|1` (env file): the per-command-buffer CPU cache invalidate (`dc civac`) over every
  IOSurface a command buffer rendered into, run on the completion thread in every process but backboardd. `0` = off
  everywhere, `1` = on everywhere, unset = unchanged (on except backboardd). m2v/0001 already invalidates every host import
  a command buffer used, so this is a second pass over the same bytes; the telemetry row `J surface cache n= bytes= us=`
  measures it. Correctness risk when off: a CPU reader of a GPU-written IOSurface (snapshots) can see stale lines [I].
* `CA_FORCE_TRIPLE_BUFFERING=1` is no longer set by the plugin: the 20H392 QuartzCore has no such string (only
  `CA_LOG_TRIPLE_BUFFERING`), so it never did anything.
* `scripts/metal/idle-stats.sh [-s SECONDS]`: from `logs/usblog.log`, seconds with `presents/s 0` versus seconds with
  presents, mean swaps/presents per second, and the share of `GPU WATCH` samples with RBBM busy; `idle-stats.sh telemetry
  [SECONDS]` pulls backboardd's telemetry twice and prints command buffers, passes, full-screen passes and blits per second
  and the flushSurfaces cost. Needs `touch /var/db/negronimetal/telemetry`.

### On-Device XNUtils App
The installed **XNUtils** app (`/Applications/XNUtils.app`) displays:
* Active Metal Device Name (`Turnip Adreno (TM) 730` or `Software Renderer`)
* Hardware Acceleration status
* Supported Metal Feature Sets and VRAM limits
* Quick power controls (Reboot to Bootloader, Restart System, Shut Down)

---

## 4. On-phone test plan (2026-10-26, audit follow-up; the phone ran Android when this was written)

Inputs: Metal bundle `out/metal/stage` (NegroniMetal sha256 7473f41b99b41c4faca0ec957084b3bb1f9010cbd4fd72e55f2be4dfa35ed628, flame/0001-0013, dSYM
`out/metal/NegroniMetal.dSYM`), GL stage `out/gpu/stage` (2026-10-26, `RedwoodWaitsForGPU` check), kernel image
`out/ios16-gl2` (0289). Every step: start `make usblog` first (kernel log in `logs/usblog-*.txt`), and keep
`scripts/net/phone-log.sh tail` running in a second tmux window for the crash reports. Mark each result in docs/notes.md
with [V] and the time.

1. **Boot `out/ios16-gl2` with the current Metal bundle.** `scripts/flash/ios16.sh` with `IOS16_OUT=out/ios16-gl2`
   (after the charge and the userdata step of docs/plan.md "Next"). Then `scripts/metal/phone-test.sh push`, then
   `scripts/net/ssh-phone.sh "rm -f /private/var/db/negronimetal/strikes/*; echo '*' > /private/var/db/negronimetal/clients"`.
   Read in usblog: `RedwoodGPU: registered (the IOSurface lock waits up to 50 ms for the GPU)` (0289 in), then the
   `NMTL[... backboardd]: device opened` and `native-metal: Metal protocols adopted by 20 of 20 frontend classes` lines.
   Pass: backboardd and SpringBoard stay up 3 min (`CRASH` lines in usblog: none for them).
2. **AegirPoster abort reason** (audit 1.1, row 1). Within the first 2 min after SpringBoard is up, run
   `scripts/net/ssh-phone.sh "grep -a 'uncaught exception' /private/var/db/negronimetal/metal.log"`. Expected: one
   `NMTL[pid AegirPoster]: uncaught exception NAME: REASON` line with up to 10 frames (flame/0012 logger). Record NAME,
   REASON and the first frame in notes.md; that names the selector or nil answer to fix next. If there is no such line
   but usblog has `CRASH AegirPoster ... sig 6`, read `scripts/net/ssh-phone.sh "tail -n 40
   /private/var/db/negronimetal/pipelines.log"` and the `MISSING` lines of metal.log (`grep -a MISSING`).
3. **SpringBoard restart + Siri orb on flame/0012** (row 2). `scripts/gpu/phone-gl.sh restart` (kills backboardd; SpringBoard restarts with it), wait for the home screen,
   press the side button for Siri. Pass: usblog shows no `CRASH SpringBoard`, the orb animates; metal.log has no new
   `MISSING` line for SpringBoard. Fail: the `MISSING ... (answered nil)` line names the next MPS selector, or a
   `commandBuffer does not conform` stderr line means the protocol adoption did not take.
4. **FitnessWidget jetsam A/B** (row 3). `scripts/net/ssh-phone.sh "printf '*\n-FitnessWidget\n' >
   /private/var/db/negronimetal/clients"`, then restart SpringBoard as in step 3. Read usblog for 2 min: with
   `-FitnessWidget` there must be no `CRASH FitnessWidget ... sig 9` (jetsam ns 1 code 7). Then put `*` back and restart
   again: the crash returns 0.3 s after `NMTL[pid FitnessWidget]: device opened`. Both results together prove the
   plugin's footprint is the cause (fix candidates: a per-process cap or a lazy Turnip load for widget extensions).
5. **WebKit GPU-process crash with a dSYM** (row 4). clients = `*` (the GPU process is `com.apple.WebKit.GPU`). In
   Safari open a WebGL page (for example `https://get.webgl.org`, then `https://webglsamples.org/aquarium/aquarium.html`).
   Watch usblog for `CRASH com.apple.WebKit.GPU ... sig 11` with `far` in a guard page and a `lr` inside NegroniMetal; the
   `images NegroniMetal 0x... text 0x...` line of that process in metal.log gives the load address. On the Mac:
   `atos -o out/metal/NegroniMetal.dSYM/Contents/Resources/DWARF/NegroniMetal -arch arm64 -l TEXT_BASE PC LR`. Record the
   function; the audit's candidates are a `char *` to a stack buffer kept by a dispatch source in the frontend's journal/log
   path. Pass without a crash: the page renders for 2 min and the GPU process pid does not change (`ps -A | grep WebKit.GPU`).
6. **GL A/B on backboardd with kernel 0257 + 0289** (row 6; `out/ios16-gl2` has both). First switch Metal off for
   backboardd: `scripts/net/ssh-phone.sh "printf '*\n-backboardd\n' > /private/var/db/negronimetal/clients"`. Then
   `scripts/gpu/phone-gl.sh push`, `scripts/gpu/phone-gl.sh backboardd`, `scripts/gpu/phone-gl.sh on`,
   `scripts/gpu/phone-gl.sh restart`. Read `scripts/gpu/phone-gl.sh log` and usblog. Pass: `negronigl: preflight PASS
   renderer=FD730 ...`, `negronigl: flush = glFlush + kernel fence (default: RedwoodWaitsForGPU)`, a `NEGRONI SURF: wrap
   client memory sel 6: ...` line, no `IOSurface wrap of client memory refused` line, no backboardd `CRASH ... far 0x30`,
   and the home screen is drawn (presents in `NEGRONI FB STAT`). Fail cases: a far 0x30 crash = 0257 did not take; a
   `flush = glFinish (the kernel has no RedwoodWaitsForGPU ...)` line = the kernel is not 0289. Back: `phone-gl.sh off`,
   `phone-gl.sh restore`, clients `*`, `phone-gl.sh restart`.
7. **flame/0011 on the phone** (row 7). `scripts/net/ssh-phone.sh "/usr/local/bin/mslprobe"` (front end only, no device:
   pass = a metallib size line, no `died in the MSL front end`), then `scripts/net/ssh-phone.sh "/usr/local/bin/metalprobe
   --compute --render"` (pass = `PASS compute`, `PASS render`; metal.log `newLibraryWithSource #1: ... in process[, driver
   flags] in T ms` says which option form the 20H392 front end took). Then in Safari a WebGPU page (for example
   `https://webgpu.github.io/webgpu-samples/?sample=helloTriangle`; WebGPU must be on in Settings > Safari > Advanced >
   Feature Flags). Pass: the triangle, no `CRASH com.apple.WebKit.GPU`; `grep -a 'executeCommandsInBuffer' metal.log` empty
   (a hit = the ICB item of section 3 is needed). A `strikes/msl-com.apple.WebKit.GPU` file left behind = the front end
   crashed the GPU process: read the CRASH line and `rm` the file to re-arm.
8. **0289 on a CPU reader.** Take a screenshot (side + volume up) with Metal on: the Photos thumbnail must show the
   current screen, not an older frame; usblog may show at most a few `NEGRONI SURF: ... not done after 50 ms` lines.
   Repeat with `negronisurf_gpuwait=0` (rebuild `out/ios16-gl2` with `BOOTARGS_ADD="negronisurf_gpuwait=0 negronipanic=30
   negronipanicreason=2" scripts/gpu/build-test-image.sh`): `ioreg -l | grep RedwoodWaitsForGPU` shows `No` and the GL log
   says `flush = glFinish`.
