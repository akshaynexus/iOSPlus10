# Mi A3: fixes from the ios-sweet / HackiOS / topaz forks (survey 2026-11-01)

Read on 2026-11-01 for the three open problems of branch `laurel-sprout` (console stops after `mbinit: done`,
no USB gadget on the host, boot 01:19 ends dark): the GitHub commit lists of every fork (`gh api
repos/<owner>/<repo>/commits`), the patch files named below (raw files at the pinned commits), and the
patched tree `out/laurel-kernel/xnu-src/xnu-8796.141.3`. Pins: `scripts/setup/get-references.sh`
(new: `ios-sweet-umi` 952cf3329, `ios-topaz-evergo` 3ed185041; `ios-sweet-upstream` 45263bee5 is still
the upstream HEAD, 2026-10-23; `MakrSas/ios-topaz` has no commit after our pin e4772911, 2026-10-22).
[V] = read in files or seen on the phone, [I] = inference.

## What the kernel does after `mbinit: done` (the base of every row below) [V code]

`bsd_init` (bsd/kern/bsd_init.c:720-880): mbinit -> audit, knote, aio, dlil, socketinit, domaininit,
memorystatus, bsd_autoconf, loopattach, net_init_run, `laurel_usb_net_attach` (2006, a thread), inittodr,
setconf -> `IOFindBSDRoot` -> `sweet_ufs_rootdev` -> `sweet_ufs_init` (bsd/dev/sweet_ufs.c). The first
line that normally follows `mbinit: done` on topaz is `SWEET UFS: "userdata" on LUN 0 ...` (topaz NOTES.md
boot 0028u/0029u), then `BSD root: ufsroot0`, then `hfs: mounted` or `cannot mount root, errno = 19`
(retried for ever, no panic). Nothing of that was on the 00:40 photo.

At the same time the IOKit thread runs `AppleCLCD::start` (iokit/Kernel/arm/SweetFramebuffer.cpp:379):
after `SWEET FB: DSI0 ctrl` (on the photo) it maps VIG0 0x5e05000 + CTL0 0x5e02000, allocates two flip
buffers and a console shadow, **moves the kernel console into the shadow** (`sweet_console_retarget`)
and points **VIG0** at it (`scanFrom`: SRC0_ADDR, stride, CTL_FLUSH 0x20001). topaz' ABL stages the splash on
VIG0; our shim (patches/laurel/shim/0001) had to look for the active pipe among VIG0/DMA0/DMA1 because
the Mi A3 ABL does not. If the panel is fed by DMA0 or DMA1, everything after the retarget (the UFS lines,
`cannot mount root`, every panic) goes into a buffer the panel never shows: the console "stops" at whatever
`bsd_init` printed last, which is `mbinit: done` on every boot (same timing). [I, strong: it explains the
stop at the same line with cpus=4 and 8 cores, no panic, and the 01:19 boot going further with a root
present: two flashes = backboardd's first swaps through the wrong pipe and the fade, then `display off`
(RequestPowerChange(0), topaz 0079/0106) = an AMOLED with no light, which looks like a phone that is off.]
Test: the shim's first lines `FB pipe=N` (0 = VIG0 would refute this) and the new `LAUREL FB SCANOUT:` line.

## Table

| source fix | problem it solves | ported as | not ported (why) |
| --- | --- | --- | --- |
| our shim 0001 scan-out detect (VIG0/DMA0/DMA1 by SRC0_ADDR) [V] | console lost after the AppleCLCD start; GUI and panics invisible; 01:19 "dark phone" (problems 1 and 3) | `patches/laurel/xnu/2008-laurel-fb-scanout-pipe.patch`: AppleCLCD uses the pipe that fetches the boot framebuffer (dpu_5_4_sm6125 offsets, CTL_FLUSH bits VIG0 0 / DMA0 11 / DMA1 12 + CTL 17); none or not 32 bpp: direct scanout off, console stays on the boot framebuffer, CPU copy (one `LAUREL FB SCANOUT: off:` line). Kill switch `laurelfb_scanout=0` | |
| ios-sweet-umi 0157 `sweetfb_alwayson` (panel never blanked while there is no input to wake it) [V] | problem 3: backboardd turns the display off (auto-lock, power key) with no touch to wake it | topaz already has the same switch: `sweetfb_stayon=1` (SweetFramebuffer.cpp:1660); added to the shim boot-args (`scripts/laurel/shim.sh`) | 0157 itself (duplicate of topaz) |
| our 2007 pattern (GCC self-check before touching a block) + gcc-sm6125.c UFS offsets [V] | a UFS host register access with the GDSC or clocks off hangs the bus for ever with nothing printed (a second candidate for problem 1 on the cold path) | `2009-laurel-ufs-clock-check.patch`: `laurel_ufs_clock_check` reads ufs_phy_gdsc 0x45004, axi 0x45010, ahb 0x45014, unipro 0x45040, ice 0x45044 before the first host access; one line `SWEET UFS: host 0x4804000 powered and clocked: ...` or `off: unpowered or unclocked` + ENXIO (the root panic then names the reason) | a UFS power-up from cold (PHY + link bring-up): not needed until the line says off |
| wlw333554/ios-topaz (evergo) 0105e: the persistent-log thread (topaz 0047) retries instead of exiting on the first failed write [V] | the only full log of a boot was lost after one write error | same file, `2009` patch (second hunk, "laurel 2010"): rate-limited `SWEET LOG: flush failed (%d) ... retry` and `continue` | the extra `first_block/nblocks` prints of 0105e (diagnostics) |
| topaz tools/sweet-log-pull.sh + sweet-log.py (reader of the 0047 ring: last 4 MiB + 1 block of userdata) [V] | read the console log of a failed boot later (Android/TWRP) | `scripts/laurel/log-pull.sh` (adb with block access; decodes with the topaz sweet-log.py; refuses a tail without the SWEETLOG header) | the kernel side is already in (0047, `ufsrw=1`); needs a recovery on boot_b or root in Android: owner decision |
| dipa-studio/ios-sweet 1664d638d: mkadt `/pram` + `embedded-panic-log-size` (XNU panic log region) [V] | upstream sweet hung after "kdp_core zlib memory" without it | | topaz kernel passes that point (0043/0044 crash-log patches); nothing reads the region after a reset; candidate when we want a panic log that survives a reboot (the 0047 ring and the USB panic hold cover it now) |
| ios-sweet-umi 0153: `fVsync->enable()` ("setTimeout only arms an enabled source") [V] | panel timer never fires (umi) | | not a bug here: `IOEventSource::init` sets `enabled = true` (iokit/Kernel/IOEventSource.cpp:169) and `start()` arms it with `setTimeoutUS` (SweetFramebuffer.cpp:528); topaz shows the GUI with this code |
| ios-sweet-umi 0154/0155 timer INTID report, PPI candidates; 0152 vsync deadline + stack sample; 0156 quiet boot; 0140 EDL deadline [V names + 0154/0156 read] | umi (SM8250) timer PPI not known; diagnostics | | diagnostics (CLAUDE.md "No probes"); the topaz timer PPI 19 (0017, from the ADT) is the SM6125 virtual timer too (sm6125.dtsi `GIC_PPI 3`) [I] |
| ios-sweet-umi 0158-0162 ST FTS touch, 0159 rpmh first match, 0161 rail cycling [V names] | umi touch hardware | | umi hardware (Mi 10); the Mi A3 touch is FT3518/GT9883 on QUP0 SE2 (hardware-map) |
| Scion-Project/hackios-xnu-kernel d97a609b0 `hakios.dwc3.c`: USB gadget on DWC3 (Galaxy S9, CDC-ACM): stop a running controller first (RUN_STOP off, wait DEVCTRLHLT, mask events) before CSFTRST; GSBUSCFG0/1 bursts; GUCTL REFCLKPER; 100 ms halted wait after RUN_STOP [V] | USB gadget bring-up from the state a bootloader left | | problem 2 has no stage line read yet (photo pending); the sweet sequence (2005/2007) differs only in the stop-before-reset and the bus/refclk tuning; port as 2011 if the panel shows `soft reset STUCK` or `running` with the link never leaving "disconnected". Exynos PHY glue does not apply |
| hackios `usb_gadget=N` CDC-ACM line console [V] | kernel log over USB | | we have CDC-ECM + the negroni ctl protocol (2005), host tools exist |
| gs240333/ios-topaz (wayne, SDM660): eMMC driver with wall-clock timeouts, TWRP-style boot header + stock DTB appended ("ABL needs a DTB in the kernel blob"), gzip kernel, shim MMIO [V names] | eMMC phone, SDM660 ABL | | Mi A3 is UFS and boots our v2 image + stock DTB already (the same DTB finding) |
| squeeeezy/HelioDarwin 9bcc26630 "service TOPRGU independently of display power" [V name] | MTK watchdog reset when the display is off | | MT6789 TOPRGU; the SM6125 APSS watchdog is armed by Linux, not by ABL [I]; no watchdog reset seen (the 01:19 phone stayed dark, no reboot) |
| wlw333554 evergo 0088e-0092e, thread_ro / shared-region / special-port tolerance patches [V names] | userland crashes under the sweet kernel (code signing, jetsam, shared region) | | first needed when launchd/backboardd run on our root; evergo's QEMU RAM-disk root (0091e) and spinlock diagnostics are not for the phone |
| myh120405/ios-sweet-linux `linux/fixes` 0005/0009/0010/0011 (sweetquiet, draw diagnostics, framebuffer write tests) [V names] | CI drawing diagnostics | | diagnostics; our Linux build takes only the generic compiler fixes (kernel-linux.sh) |
| edi194/ios-fajita: block-level root-image updates (`push-image-blocks`), Metal plugin selection 0175, GPU arena 0169-0174 [V names] | 12 GB root reflashes; Adreno 630 Metal | | later: GPU stage; the block pusher is a host tool idea for `flash-root.sh` (not now) |
| oosexgang/hackios-xnu-kernel HEAD (redwood 120 Hz, cputop, IOSurfaceWrapClientImage) [V names] | UI performance on redwood | | not a boot problem |
| ls9875/hackios-umi 6ac5eee touch diagnostics [V name] | umi touch | | diagnostics, umi hardware |

## Still open after this survey

- Problem 2 (USB): no fork solves a cold DWC3 start on Qualcomm; 2007 stays the plan. The next photo must show
  the `LAUREL USB:` stage lines (now visible for the whole boot when 2008 keeps the console on the panel).
- Whether the Mi A3 panel is on VIG0, DMA0 or DMA1: the shim's `FB pipe=` line, and the `LAUREL FB SCANOUT:` line.
