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
`NegroniMetal` implements a **dead-man safety switch** to prevent permanent black screens. If a process (like `backboardd` or `SpringBoard`) crashes or fails to present a frame within the watchdog window, it receives a strike recorded in `/private/var/db/negronimetal/strikes/<process_name>`.

* **Strike Limit:** 2 consecutive unclean starts or watchdog timeouts.
* **Effect:** Once a process reaches 2 strikes, `NegroniMetal` automatically revokes the GPU device from that process and forces it into CPU fallback mode.

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
# Example: relax open/self-test timeout (default 6000 ms) and watchdog timeout (default 60s for backboardd, 30s others)
scripts/net/ssh-phone.sh "printf 'NEGRONIMETAL_WATCHDOG_S=60\nNEGRONIMETAL_OPEN_MS=10000\n' > /private/var/db/negronimetal/env"
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

### On-Device XNUtils App
The installed **XNUtils** app (`/Applications/XNUtils.app`) displays:
* Active Metal Device Name (`Turnip Adreno (TM) 730` or `Software Renderer`)
* Hardware Acceleration status
* Supported Metal Feature Sets and VRAM limits
* Quick power controls (Reboot to Bootloader, Restart System, Shut Down)
