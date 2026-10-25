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

### On-Device XNUtils App
The installed **XNUtils** app (`/Applications/XNUtils.app`) displays:
* Active Metal Device Name (`Turnip Adreno (TM) 730` or `Software Renderer`)
* Hardware Acceleration status
* Supported Metal Feature Sets and VRAM limits
* Quick power controls (Reboot to Bootloader, Restart System, Shut Down)
