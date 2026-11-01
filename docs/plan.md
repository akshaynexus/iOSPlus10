# Plan and status

## Branch `laurel-sprout`: Xiaomi Mi A3 port (2026-10-31)
iOS 26 userland round (2026-11-02, branch t3/laurel-ios26-userland, host only, NOT RUN ON THE PHONE; no flash, no phone write): owner "can iOS 26.5.2 23F84 run on the Mi A3 CPU, with numbers; build the lowering tool". Donor fixed by the owner: iPhone 11, iPhone12,1, N104AP, A13 (ADT `artwork-scale-factor` 2 [V]).
Verdict: viable only with named conditions, docs/laurel_sprout/ios26-userland.md section 1. Instruction level not ruled out [V host]. The renderer is the harder wall [V static]: 23F84 `AccelServer::renderer` = Metal or nothing, no GLES fallback; iOS 16 keeps backboardd on GL, so the compositor has never run on Metal on the A610. zeta (now at the Home screen on SM8350, with lag) has LSE and FP16; we do not. Next best: iPadOS 18.7.11 22H384 iPad7,11 plain arm64, no lowering, iPad idiom.
Census [V llvm-mc on every unique word]: cache 784.9 M words; non-hint PAC 29,527,482 proven; LSE 802,693 proven (0.10 %); ldapr 133,952; FP16 69,770; FCMA 25,045; auth rebases 10,069,319; AMX words 664,069. Root 3,413 arm64e files: PAC 9,866,887, LSE 67,984.
Tool done: `op10tool a64-census a64-lower a64-verify a64-selftest a64-abi a64-dis`, `scripts/ios26/lower-userland.sh`. Result [V]: 29,451,474 one-word edits, 800,361 LSE sites through trampolines in free r-x bytes (+ 2 dead images), 0 proven PAC left, 10 + 5,462 proven LSE left, all auth rebases plain, signatures rebuilt with 4 KiB pages, 30,748 qemu cases 0 mismatches (native on -cpu max, trampoline on -cpu cortex-a53), verify "Problems: none", same SHA-256 on a second run.
Left for the kernel: FP16, FCMA, DotProd, JSCVT, SHA3, FHM, JIT output: section 7 "kernel needs" (the other agent). ABI table against iOS 16: section 8: IOSurface and IOMFB numbers stay, sizes grew (`kern_SwapEnd` 1132 -> 1416, `SetBulkAttachments` 136 -> 160); AKS scalars grew; OpenGLES 580/580 symbols same.
Next: owner decides C3 (compositor on Metal on A610, or GLES hook, or the iPadOS 18 option). Kernel track takes section 7. Apple files: ~/op10-apple/ios26/23F84-n104ap (28 GB), out of git.
Dual boot round (2026-11-02, branch t3/laurel-dual-boot, patch 2950; built + host-tested, NOTHING RUN ON THE PHONE): owner: LineageOS 24 + iOS without a wipe or GPT change; no flash until asked. Design + steps + recovery: docs/laurel_sprout/dual-boot.md.
Choice: Lineage on slot a, Mu + XNU on boot_b + stock dtbo_b; root = pinned f2fs file in /data, written raw on sda15; XNU maps it from an ADT table. Found [V]: every existing kernel writes its console log into the last 4 MiB of userdata whatever it holds: a boot of one would damage Android; the guard and 2950 close that. All firmware in Lineage's OTA is byte-identical to stock. Size for iOS 26: 30.01 GiB [I expand 1.68].
Next: owner decisions D1-D6 in that doc; first step is Rooted debugging, then read slot b.
Dual boot fix round (2026-11-02, branch t3/laurel-dual-boot-fix, not merged; built + host-tested, NOTHING RUN ON THE PHONE): an independent review found 13 defects; all verified in code and fixed. Seal now: slot b active, `/data` frozen, pin + FIEMAP + fingerprint in one frozen period, header BOUND, `reboot(2)` with no unmount; state FRESH gone. `ash` returns the real remote exit code. `install` writes only after pin, immutable, FIEMAP = table and a check-map record. Kernel and image must hold the 2950 marker. fastboot steps need a positive phone identity. Owner: `SIZE=32G` default, Updater disabled.
Results [V host]: kernel-linux 310/310, 0 LSE/RCpc, printf OK; kernel-ios26 0 errors, 0 LSE/RCpc, printf OK; test-dualboot PASS (test_kernel 40611, helper 28, guard 51, script 60); the new tests fail on 037cd81 (`scripts/laurel/dualboot-tests-detect.sh`). Unproven: FIFREEZE on live /data, reboot(2) with SELinux Enforcing, set-active on this HAL, Android after an unclean reboot, Android after an iOS boot.
Next: merge after review; then the owner's yes for each step in docs/laurel_sprout/dual-boot.md section 4. Before step 9 the owner must know: each `switch` is an unclean reboot for Android (D7), and D5 (no backup of /data exists).
iOS 26 kernel round (2026-11-02, branch t3/laurel-ios26-kernel, not merged; COMPILE AND LINK ONLY, NEVER RUN, nothing flashed): docs/laurel_sprout/ios26-kernel.md.
Done: every Mi A3 patch on xnu-12377.121.6, plain arm64, native Linux (`make laurel-ios26-kernel`): 309 result lines, 210 applied, 83 applied+rules, 11 base, 5 skipped, 0 errors. Linked; 0 LSE/RCpc; armv80-check 0; printf-arg-check OK. New: `LAUREL PACEMU`, `LAUREL CE` (DER entitlements), auth rebases written as plain pointers, arm64e accepted, donor parameter (N104AP), iOS 26 boot image script (`make laurel-ios26-image`, own folder).
Open [U]: no boot; no iOS 26 root; user-client ABIs of 23F84 not traced; the "kernel needs" list of t3/laurel-ios26-userland not read (not on origin yet).
Next: merge when the owner agrees; T1 only when the owner asks for a flash (section 8 of that page). The userland list, when it exists, goes against section 4.

AirPlay and AirDrop round (2026-11-01, branch t3/laurel-airplay-airdrop, patches 2930 + 2931, NOT RUN ON THE PHONE): owner "AirPlay and AirDrop both aren't working: enable or fix them". docs/laurel_sprout/airplay-airdrop.md.
Done: `LAUREL AWDL` self-check (only looks at scanned frames; sends nothing; awdl=0); `laurel-airplay` job and `LAUREL AIRPLAY` line (airplay=0, AIRPLAY=0); AirDrop preferences for en0 (AIRDROP_LAN=0); wifip2pd stays out.
[V] qcacld monitor device has no Tx, OWL needs injection; negroni 0347 has no data path and never ran. [I] no awdl0 is the right state now. [V] mirroring has no AppleAVE2Driver. [I] Apple TV/HomePod may fail at /fp-setup or PTP. [U] AirPlay audio on en0: no blocker found, no run log.
Results [V]: see the airplay-airdrop section in docs/notes.md. Next: root with t3/laurel-safari-net merged, boot, test steps in section 7 of the doc; the log decides the AirPlay fix; `first AWDL frame heard` decides whether the IBSS test is worth doing.
Microphone round (2026-11-01, branch t3/laurel-mic, patch 2920 + plug-in mic-input.patch, built + host tests, NOT BOOTED): owner "Voice input is not working."
Done: AMIC1 -> WCD937x ADC1 -> SoundWire TX -> TX macro DEC0 -> TX_CDC_DMA_TX_3 -> ADM -> ASM session 2 -> /dev/redwood-mic -> plug-in "Codec". On by default, mic=0, `LAUREL MIC: on|off`, `LAUREL MIC: first capture: rms N`. Capture gain (HAL + ioctl). XNUtils row. Camera hook stays, with a line that decides. Headphones + earpiece not done.
Results [V]: 297/297 patches, 0 LSE, printf check OK, kernel sha256 570f52c889b9bece; plug-in 2a4afb9a810dc0ed; armv80-check kernel 21 (no new), plug-ins 0; mic-host-test + xnutils-test PASS. Nothing ran on the phone. Next: boot image + root flash (owner approves), docs/laurel_sprout/audio.md "Microphone", test steps.
XNUtils round (2026-11-01 21:30, branch t3/laurel-xnutils, built + host test + dry run, NOT RUN ON THE PHONE): owner "build and install XNUtils as a system app, extend it with more info and stats".
Done: native Linux build (xnutils-build.sh, in build-all.sh), system app + setuid helper in the root (root-xnutils.sh, XNUTILS=0 skips), 18 live sections every 2 s while visible, nothing when hidden; Copy + Share; Metal Auto/All/Probes/Off on the gate's files, GL switch = new file /private/var/db/laurelgl/off read by bbd_wrap.c; kernel 2912 `kern.laurel_stats`: parses the console ring on read + in the log thread, live values from driver variables.
Results [V]: kernel 293/293 patches, 92 laurel, 0 LSE, sha256 763609fb...; app + helper + pmregister 0 instructions newer than ARMv8.0, no Metal link; xnutils-test.sh PASS on the sample and on the real boot 20:02 log (crash table = system-features.md); root-dry-run.sh PASS with XNUtils. Unproven: section 5 of docs/laurel_sprout/xnutils.md (app start, setuid path, layout, power actions).
Next: root + boot image + flash (owner), docs/laurel_sprout/xnutils.md section 6.
System features round (2026-11-01 20:45, branch t3/laurel-system-features, built + dry run, NOT BOOTED, root not built: needs sudo): owner "a lot of system apps and features are disabled".
Main cause [V 7z of the 19:51 root]: root.sh never moved the 32 staged Apple apps (Calendar, Clock, Mail, Notes, Maps, Weather, ...) to /Applications; negroni and the other ports do. Done: root-system-features.py (32 apps; aggregated back = power log for Settings > Battery, limit 32 MiB), kernel 2910 (priv 10001, 12001, 1003 by entitlement), infra merge: 2902, 2904 (AKS selectors + passcode), 2905 (poll rule changed: the live log alone does not hold 200 us), 2906, SSH userland; parked 2900, 2901, 2907 (patches/laurel/parked). Stays off with reasons: CommCenter, vmd, fairplayd.H2, syncdefaultsd, activityawardsd, nanotimekit, wifip2pd, ReportCrash, spindump, tailspind, addaily, BTAudio (BTAUDIO=1).
Results [V]: 291/291 patches, 0 LSE, kernel sha256 a60e5633...; root-dry-run.sh PASS: 532 -> 520 jobs, 173 apps, 0 staged. Next: root.sh + flash (owner), boot; read `laurel system:` lines, `LAUREL SANDBOX: ... entitled`, `LAUREL AKS:`, count the icons, Settings > Battery, `LAUREL CPU TOP` for aggregated. Table, costs, test steps: docs/laurel_sprout/system-features.md.
Render round (2026-11-01 21:30, branch t3/laurel-render-fixes, built, NOT BOOTED): boot 20:02, owner: widgets blank, Astronomy false colours, wallpaper black.
[V] Widgets: every opaque RenderBox layer is `_RB4` (RGB8_444_2P); `-attachImage:` refused it and CA does not read the answer: empty texture. RB_COLOR_MODE=fixed does not touch that path. Now converted (surface_formats.c, eagl 0004), every OSType has a picture. [I, numbers fit] Astronomy: kernel keeps `w30r` as BGRA, GL read BGR10_XR words as bytes: flame/0020 + GPU pass. [V] backboardd sig 11 = Mesa NULL after the kernel could not make a page table from an empty pool: 2895, Mesa 0001. [U] wallpaper: only one screen-sized surface reaches GL; `contents` line decides. Needs kernel + root (libtopaz-gl, libOSMesa, NegroniMetal). Next: boot, metal.md 12.4.
HEVC round (2026-11-01 21:00, branch t3/laurel-heic-driver, built + host-tested, NOT BOOTED): owner "Do not convert HEIC to PNG; write a proper HEIC driver". PNG step removed. `HEVCH8.videodecoder` = FFmpeg 7.1.1 hevc in VideoToolbox's empty slot, rating ahead of Apple's VCPHEVC; `laurel_hevc=0` / HEVC=0 fall back to it.
[V cache] The plan line below is wrong: 20H392 has a software HEVC decoder with no gate (VCPHEVC.videocodec, ARMv8.0 clean). Where HEIC fails on this phone: [U], no log shows it. Host: 48 images + 42 alpha images bit-exact with libde265; B-frame, 10-bit, mono clips PASS. Not run anywhere: NEON assembly. Next: root + boot, `docs/laurel_sprout/hevc.md` section 8 (its table splits decoder fault from CA/Metal fault).
Real-GPU round (2026-11-01 19:30, branch t3/laurel-metal-realgpu, built, NOT BOOTED): boot 18:40 = first Metal on the GPU; owner: home wallpaper black.
Most likely cause [I]: default wallpaper 7400 is HEIC layers, no HEVC decoder here (ios-flame found the same black layer) -> root-wallpaper.sh wrote PNGs (removed, see the HEVC round above). Also: launchd's 5 s extension
kill loop (AegirPoster) -> boot-arg launchd_disable_all_timeouts=1, poster strike rule; device open 3-10 s [I flat lookups of 3312 weak imports] -> macho-weak-self.py;
173 surface imports refused (kernel's GL rule) -> stand-in falls back to 0x49; RB_COLOR_MODE too late -> launchd job env; heap sizes from the runtime; one line per cause; gpuCoreCount 1.
mediaserverd "low swap" kills: [I] camera frame leak, open. Needs root + boot image rebuild. Next: boot, metal.md section 11.5. Details: docs/laurel_sprout/metal.md section 11.
Target: Xiaomi Mi A3 (`laurel_sprout`, SM6125, ARMv8.0, no PAC, Adreno 610). iOS 16 first, iOS 26 later (research:
no PAC, needs zeta-style PAC lowering). Done: device facts (`scripts/device/info.sh`), 7 pinned reference trees
(ios-topaz, Mu-Silicium, MiCode `laurel-r-oss`, Lineage kernel/device/common, mainline), port plan with the topaz
comparison. Next: owner sets phone-safety targets (active slot is `_b`), root + backup, live FDT, port the topaz shim.
Details: `docs/laurel_sprout/port-plan.md`.
RAM + screen surfaces + canvas (2026-11-01 05:00, area A, built, NOT BOOTED): kernel 2100 (XNU 3264 MiB at 0xE1004000 above the
device pools, self-check, 768 MiB fallback, USB/UFS DMA below 4 GiB), 2101 (6 x 12 MiB contiguous screen-surface pool below 4 GiB;
other surfaces from wired pages), 2103 (native 720x1560 canvas at scale 2 by default, first-frame self-report); Mu 0101 ("Pool RAM"
0x80000000-0xE1000000 reserved: GPU pool 0xC0000000 + 512 MiB, modem pool 0xE0000000 + 16 MiB; "Kernel RAM" 0xE1000000-0x1C0000000)
+ 0102 (DarwinBoot shrinks the window instead of "NO WINDOW") + 0103 (SMBIOS 64-bit only, DarwinBoot limits); late layout
`MU_RAM_LAYOUT=late` as the fallback; mkadt `--dram auto`. Review fixes 05:15: low RAM used last (vm_himemory_mode), spool 6 x 12 MiB,
2102 merged into 2103. Test = boot_b flash (no fastboot boot). Next: boot, read `LAUREL RAM:`, `LAUREL SPOOL:`,
`LAUREL FB CANVAS:`, `LAUREL FB CANVAS: first frame`, photo of the lock screen. Details: `docs/laurel_sprout/uefi-boot.md` "RAM, memory map".
+ 0102 (DarwinBoot shrinks the window instead of "NO WINDOW"); mkadt `--dram auto`. Next: boot, read `LAUREL RAM:`, `LAUREL SPOOL:`,
`LAUREL FB CANVAS:`, `LAUREL FB: first iOS frame`, photo of the lock screen. Details: `docs/laurel_sprout/uefi-boot.md` "RAM, memory map".
Kernel log over the UI (2026-11-01 08:08, branch t3/laurel-fb-text2, built, NOT BOOTED): after 2104 the owner still saw
white-on-black kernel text over the UI whenever something moved (boot 07:45). Cause [V source + boot-args]: `serial=3` makes
the fbcon (pe_serial.c) the kernel console, and it drew every printf/IOLog line straight into 0x5c000000 = surface 1, which
GL frames use and the MDP scans directly since 2104. Kernel 2870: fbcon moved into the console shadow at AppleCLCD start
(muted if it cannot move; a panic draws and shows it), scanout owner (scanFrom refuses kernel text after the first iOS
frame, `LAUREL FB OWNER: refused:` once per caller, panic excepted), shadow + flip buffers cleared to black after the first
iOS frame; kill switch fbowner=0. 251/251 patches, 0 LSE, kernel sha256 31d2ccf0.... Next: GL boot, read `LAUREL FBCON: on:`
and `LAUREL FB OWNER: on:`, no `refused` line, use the UI: no text. Details: `docs/laurel_sprout/gpu.md` "Kernel log over
the UI".
GPU zero copy (2026-11-01 08:35, branch t3/laurel-gpu-zero-copy, built, NOT BOOTED): owner "still CPU rendered". Causes [V log
07:45 + source]: (1) surface 1 (boot framebuffer) refused by 2154's stage-1 import (no guard rows) -> glReadPixels 31-62 ms every
2nd frame; (2) GEM_SUBMIT pushed 13-16 MB out of the CPU cache per submission (gpu_cached=1 in stage 1 pushed every mapped Mesa
buffer, write-combined pool ones too; surface "4 ms" rule re-fired because the push took > 4 ms): 24-43 % of wall time;
(3) "the GPU worked 0 us" stub; (4) false SMMU fault line. Kernel 2158 (scratch guard page, push per CPU write, request 0x7d,
per-buffer CPU_PREP, wrapDelta offset; kill switch gpuseed=0), 2159 (CP time stamps: GPU busy %, measured core clock); Mesa
redwood-drm 0001 + eagl 0002 (GPU-drawn seed, frame-time line every 10 s); Metal client gate (m2vtest self-check at boot ->
clients "* -backboardd"). GPU clock not raised (RPM/CX state unknown, frames not GPU-bound): next after 2159's numbers.
Build: kernel 252/252, 0 LSE; userland 0 ARMv8.1+; metal check PASS. Needs: new boot image (kernel) + root rebuild
(libOSMesa, libtopaz-gl, backboardd wrapper, laurel-metal-gate, clients mark). Next: boot, read `LAUREL GL DRAWN: on`,
`0 pictures copied out` on every frame, the 10 s `redwood-gl: N frames ...` line, `KB out of the cache` near 0, `GPU busy`,
`core C MHz`, `LAUREL METAL CLIENTS:`. Details: `docs/laurel_sprout/gpu.md` "Zero copy, cache upkeep, GPU time".
Metal for all of iOS (2026-11-01 17:30, branch t3/laurel-metal-everywhere, built + host-tested, NOT BOOTED; Turnip has never run on the A610): owner "GPU acceleration on wallpaper choice is broken".
Causes [V boot 15:27 + source]: the gate ran as user mobile (no m2vtest, no list), its lines never reached the USB log, m2vtest needs host pages (no 0x49), 16 KiB rules on a 4 KiB kernel, no CCU invalidate at submit.
Done: launchd job as root + 3 tries + quick test decides (`* -backboardd` in /var/db and the bundle), kernel 2160 (host pages), 2161 (CCU invalidate), 2851 (real buffer limit in the line), Turnip 0103, poster refusal pause, memory limits, A610 shader profile.
Build: kernel 262/262, 0 LSE; Metal stack check PASS. Needs: new boot image AND root rebuild. Next: boot, read `LAUREL GPU HOST PAGES: on`, `LAUREL METAL CLIENTS: testing`, then `on:` or `off: <reason>`; GL frames must stay 8-13 ms (2161 is the suspect if not). Details: `docs/laurel_sprout/metal.md` 6.1-6.5, 10.
Cellular step 2 (2026-11-01, branch t3/laurel-cellular-ipa3, built + host-tested, NOT BOOTED): patch 2775 = one shared
TrustZone PAS loader (`bsd/dev/topaz_pas.c`; the GPU zap shader is now its caller, same lines); patch 2780 (renumbered from
2770, which is the camera) = IPA v4.2 AP side: IPA thread at modem READY (RPM clock, SMMU, registers, firmware PAS 15 from
vendor_<slot> through the ext4 reader, GSI check, SRAM tables, SMEM 497), then QMI 0x31 (server 0x31:0x101 port 0x4015,
INIT_MODEM_DRIVER to 0x31:0x201, CMPLT) -> `LAUREL IPA: on|off`, sysctl kern.laurel_ipa, kill switch ipa=0; laurel_cell
sets the radio ONLINE only when `laurel_ipa_state()` is on. Results [V]: 253/253 patches, 0 LSE; test-ipa.sh PASS; test-cell 8/8.
Next: boot; read the IPA lines; watch for a modem crash after ONLINE (stops Wi-Fi too); fallback ipa=0. Details:
`docs/laurel_sprout/cellular.md` section 6.
Console flash fix (2026-11-01 07:50, branch t3/laurel-fb-console-flash, built, NOT BOOTED): with GL, the idle UI showed
kernel log text. Cause [V log + source]: backboardd presents surface 1 (= boot framebuffer 0x5c000000, GL draws into it)
between GPU-pool frames; the copy path skipped it and flipped to a back buffer that still held a boot console frame. Kernel
2104: surface-1 frames scanned directly, boot text cleared from 0x5c000000, stale flip buffers cleared, `LAUREL FB HANDOFF:`
self-check (console only in its shadow, panic still draws); kill switch fbhandoff=0. Also 2760's bsd/conf/files hunk rebased
on 2720 (laurel-int-1 1c04a5e did not apply: 247 of 249). 249/249 patches, 0 LSE, kernel sha256 793f6122.... Next: GL boot,
read `LAUREL FB HANDOFF: on:` + `swap N shows surface 1`, leave the UI idle 1 min: no kernel text. Details:
`docs/laurel_sprout/gpu.md` "Console flash".
Clock + status bar (2026-11-01 07:30, branch t3/laurel-rtc-statusbar, built, NOT BOOTED): lock screen showed 1969-12-31 4 PM
(no time source; usblog `settime: error: unknown command`) and the red rdar:45025538 bar. Kernel 2720: calendar from the PM6125
RTC (SID 0 0x6000, via the one SPMI core, reads only) + own offset in /private/var/db/laurel_rtc, build-date floor, USB ctl
`settime`/`time` (queued, set by ud_thread); 245/245 patches, 0 LSE, kernel sha256 c895d70f.... Root: `scripts/laurel/root-statusbar.py`
sets UIKit's own override `UIStatusBarVisualProviderClassName = _UIStatusBarVisualProvider_FixedSplit` (720 px is no Split class
width -> nil provider -> red Fallback bar; read in UIKitCore 20H392). Needs a root rebuild + userdata flash (owner). Next: boot,
read `LAUREL RTC: on|off:`, `LAUREL CTL: settime ...: clock set`, photo of the lock screen (date, no red bar).
Details: `docs/laurel_sprout/rtc-statusbar.md`.
Top bar for the waterdrop (2026-11-01, branch t3/laurel-statusbar2, host test only, NOT BOOTED): [V 20H392] the notch rect, safe area
and home affordance come from SpringBoard's screen-type table; 360x780 @2 falls back to D22Zoomed (iPhone X notch 178 pt wide,
centred for 320 pt) -> with FixedSplit the time sits at x 41.5. MobileGestalt cannot pick another type (bounds first). Done:
liblaurel-notch.dylib in SpringBoard returns the Lineage waterdrop {135.2, 0, 89.6, 26.5} pt (time at x 73.5, group at 286.5,
89.6 pt free centre); laurel-springboard start program (notch=0, crash guard); notch-build.sh; root-statusbar.py installs both +
`--check ROOT` / `--expect`. Safe top 38 / bottom 29 / bar 47 stay. Next: `scripts/bg.sh sb2-build scripts/laurel/notch-build.sh`,
root rebuild + userdata flash (owner), read `LAUREL NOTCH: on:` in /var/tmp/laurel-notch.log, photo of lock + home screen + an app.
Details: `docs/laurel_sprout/rtc-statusbar.md` "C".
Bluetooth (2026-11-01 05:30, area G, built, NOT BOOTED): kernel 2600 (WCN3990 on QUP1 SE9 GENI UART, RPM rails, power pulses,
EDL version, 3000000 baud, crbtfw21.tlv + crnv21.bin from bluetooth_b at run time, HCI reset, BD_ADDR; iOS transport as negroni),
mkadt /arm-io/bluetooth, userland/laurel/bt + root-bt.sh. Next: boot, read `LAUREL BT: on|off:`, then bluetoothd log + a scan.
Details: `docs/laurel_sprout/bluetooth.md`.
Camera step 1 (2026-11-01 08:30, branch t3/laurel-camera, built, NOT BOOTED): Camera.app does not work (no frame path, no iOS
side). Path decision: RDI raw frames (CSIPHY -> CSID -> ISPIF -> VFE0 RDI, no ISP/CPP, no firmware on this CAMSS generation) + the
negroni/HakiOS mediaserverd plug-in with CPU ISP and the `NCFRAME1` device ABI. Sensors [V stock vendor libraries, DT,
camera_config.xml]: rear IMX586 (or IMX582) 0x1a, depth GC2375H 0x17 / OV02A10 0x3d, front S5KGD1 0x2d, ultrawide S5K4H7 0x10.
Kernel 2770: camss_top GDSC + CCI clocks (37.5 MHz) + CCI controller (polled), power-up order of each library (GPIO LDOs + L12A via
the RPM), chip ID per slot, everything back as the boot left it; one `LAUREL CAMERA: on|off:` line, sysctl kern.laurel_camera, kill
switch camera=0. Host test scripts/laurel/cam-test.sh 69/69. 249/249 patches (2760 context refreshed after 2720), 0 LSE, kernel
sha256 e0707f0d.... Next: boot, read the `LAUREL CAMERA:` lines; then step 2 (IMX586 1280x720 RDI frames, tables from a root copy of
the vendor libraries). Details: `docs/laurel_sprout/camera.md`.
Flashing (2026-10-31 23:58): `fastboot boot` is refused by this ABL; the shim image goes to `boot_b` with
`scripts/bg.sh laurel-flash scripts/laurel/flash-boot.sh`. The script runs `fastboot reboot bootloader` first:
a session entered with Power+VolDown has a broken ABL USB state (garbled commands, uploads stall at 16 MiB); after the
warm reset the plain full-size flash takes 0.5 s. Latest `out/laurel/laurel-boot.img` (23:16 build, kalloc fix 0102)
flashed and booted at 23:58; result (photo) pending.

Status date: 2026-10-27 (12:15).

## Priorities (2026-10-27 20:55, owner)
1. GPU acceleration working (Metal; 0389/0395/0398/0399 in test).
2. Video playback working (0390 plane layout + 0399 wired-memory guard; t29/t29b froze from wired-memory exhaustion).
3. Audio working (never worked: the ADSP start drops USB; audio agent on it).
RAM for GPU (2026-10-27, RAM agent; compile/host checks only, not booted, not committed): kernel patch 0401 +
patches/mu/0002 + config `[ram]` give XNU 7 GiB (was 3 GiB) at 0x841004000..0xA01004000; the GPU pool (1536 MiB) moves to
0xA20000000 (`negronigpu_poolbase`, added by build.sh to every image). Self-check in the kernel (bank, ADT sizes, GPU region/pool) and
in adt-extra.py (Mu FD "Kernel RAM"); fallback 3 GiB; kill switches `negroniram=0` / `XNU_RAM=0`. Next: rebuild Mu
(scripts/uefi/prepare.sh + build.sh), one combined image, `fastboot boot`, read `NEGRONI RAM:` and `hw.memsize`.
Details: docs/notes.md section 90.
TODO later (owner): cellular. 0397 boots the modem for GNSS only (never ONLINE). 4G/5G data and SIM detection need the
modem ONLINE, IPA, QMI DMS/NAS/WDS/UIM and the iOS CommCenter side.

## TODO (2026-10-27, end of the night session; owner: "bluetooth works, wifi doesn't")
State 2026-10-27 14:50: the phone runs stock Android + Magisk again (restore.sh --magisk, userdata formatted: no iOS root on
the phone). An iOS test session starts with a full iOS flash (scripts/flash/ios16.sh order) and ends with restore.sh --magisk.
Earlier state: boot_a = out/ios16-safe. Latest reviewed kernel out/kernel/local-20261027-023416 (all committed
patches up to 0379 + 0345/0374/0375/0376; no 0380). Test image out/ios16-t23 (ADSP off, Wi-Fi MSI on, camera ADT nodes,
watchdogs 0371=60 s / 0375=30 s). Details: docs/notes.md sections 57-63, patches/xnu/README-*.md.

1. **Wi-Fi does not work for the owner (priority 1).** Proven: with 0344 MSI the chip reaches WMI SERVICE_READY and
   iOS has en0 (t21, notes 57). Not proven: scan and join. 0345 (wifid answers + join fix) is committed, never booted.
   Next: boot t23, open Settings > Wi-Fi, read `NEGRONI WLAN iOS` lines (scan request? scan done? SCAN_RESULT? join?).
   If wifid never asks for a scan: 96 VIRTUAL_IF_ROLE, 51 COUNTRY_CODE, event 55 (README-wifi.md "0345" risks).
   **Owner test on t23 (12:11-12:14, logs/usblog-20261027-060101.txt):** [V] the radio works: the driver's own
   passive scan saw 19 BSS (27 beacons/probe responses). [V] wifid sent NO scan request; it asked twice
   `user client type 0 asked of en0's service: none (ioctl path)` and only polled a few ioctls (CARD_CAPABILITIES,
   SSID ENXIO). Correction (Wi-Fi agent, 2026-10-27, IO80211.framework 20H392 disassembly): [V] when IOServiceOpen
   type 0 fails, Apple80211BindToInterfaceWithService falls back to the ioctl path, and event monitoring falls back to
   the kernel event socket; [V] in boot 16 (02:54) wifid had the same "none" line and still sent SCAN_REQ. So the
   user client is probably NOT the blocker. [V] In two boots wifid's full init (POWER, 106, 254, 207) started within
   1 s of an `exit bluetoothd` line; [I] wifid may wait on bluetoothd (BT/Wi-Fi coex?). [V] The t23 log has a gap
   12:12:18-12:13:04, so "no scan" is proven only for the logged windows. Next: boot with 0345, open Settings > Wi-Fi,
   capture the full log (no gap), and watch bluetoothd state. User-client facts (selectors 0-6, 0x3c30-byte request,
   event ring 0x30-byte records) are in this agent's report if the path is needed later; its run was stopped by a
   safety classifier, no patch exists.
   **Wi-Fi analysis 2 (2026-10-27, README-wifi.md "0346 analysis", notes 66):** the Bluetooth lead is wrong
   (bluetoothd crashed every 10 s in boot 16; the timing was chance). [V] wifid's own init stalls in
   WiFiManagerScheduleWithQueue for up to minutes in about half of the boots with en0; during the stall the WiFiManager
   server is not up, so Settings gets no interface. After the stall wifid powers on and scans (boot 16). Kernel side OK.
   [I] a synchronous wait on another process (runningboardd / cfprefsd / accountsd?). Next test: during the stall run
   scripts/wifi/wifid-stall.sh (spindump of wifid) to name the blocking call; work-around to try: kill wifid over SSH
   (launchd restarts it).
2. **USB data watchdog 0375: first phone test inconclusive.** t23 12:12: armed (`reboot after 30 s without USB data`),
   but 45 s of `ifconfig en10 down` on the Mac did not fire it, so frames still reached the phone (or macOS kept the
   link busy). A second 20 s down at 12:14 lost the link at 12:14:51 (cause not read yet: read `make bootlog`, boot 13
   end mark). Prove 0375 fires before any more ADSP tests (keep-usb-reachable rule).
3. **ADSP + Type-C fix 0374** (notes 58): t22 05:05 got the Mac back as host 6 s after the drop, but the data path
   died and the phone needed a button reset. Retest only with 0375 proven.
4. **Camera.app**: test images now carry the camera ADT nodes; run `scripts/camera/phone-camera.sh push`, boot t23,
   open Camera.app (docs/camera-ios-2026-10-27.md section 7).
5. **Passcode 0221** (committed): owner test in Settings > Passcode (README-aks-amfi.md "0221 passcode").
6. **Sensors**: 0376 (SLPI start, phase 1) committed, needs the ADSP-area write (`scripts/fw/build-areas.sh`,
   `write-areas.sh`; owner approval) and `negronislpi=1..3` tests. Phase 2 (0380 FastRPC file server + sns_client) is
   HELD, unreviewed, outside the repo in out/hold/sensors-phase2-final-20261027-0806/ (its agent run was stopped by a
   safety classifier once); owner decides: review + commit, or leave.
7. Audio (needs the ADSP, item 3), VOOC fast charge (default off, after item 3), location services (not started),
   watchdogd fixed (0378), Bluetooth works (owner, 2026-10-27).

## Next (owner + main session, older list of 2026-10-26)
1. Charge in fastbootd to > 60 %. Then `scripts/flash/ios16.sh userdata` (fastbootd; writes the root + firmware areas),
   `vendor_boot`, `vbmeta`, `dtbo`, `boot` with `IOS16_OUT=out/ios16-all2` (safe baseline) or `out/ios16-everything`
   (diagnostic: every addition on), `active`.
2. First boot: charger test (`out/ios16-chg3` or everything + `negronichg_glink=1`): expect `write USB_INPUT_CURR_LIMIT
   1500 mA ... ok` and ibat positive by hundreds of mA. Then display perf (`out/ios16-perf`): presents/s 100-120 while
   scrolling, clock still. Then by eye: Siri orb (MPS), lock-screen poster `uncaught exception` line, WebGL page.
3. Reviews/audits: docs/audit/2026-10-26-*.md (resume the agents after 17:20), then fold into this plan. Metal/GL audit
   follow-up done without the phone (notes.md section 26): kernel 0289 (IOSurface lock waits for the GPU fence,
   `RedwoodWaitsForGPU`) in `out/ios16-gl2` (boot_a 78c23259...), Metal bundle 7473f41b (flame/0013), GL stage with the
   RedwoodWaitsForGPU check; the on-phone steps are docs/metal-management.md section 4 (8 steps).
4. Open code items: 0331 BT HCI; panel wake 0268 + double buffer 0269 built (`out/ios16-dpu`), phone test pending;
   Wi-Fi step 25+ (WLAN_CFG/MODE, CE/HTC/WMI, iOS 80211 glue); audio stage c (amps) + mic; camera: phone test of levels 0-5 (`negronicam=5`, see "Camera levels 3-6" below);
   fingerprint stage C/D; haptics UI path built (out/ios16-hap2, phone test pending); GPU recovery/idle/KGSL parity built (out/ios16-gpur,
   section "GPU recovery and CPU idle status"), phone test pending.

## Done
- Charger over GLINK (2026-10-26, battery agent; patch 0274, docs/charger-glink-plan.md, README-battery.md section 9):
  the HLOS cannot write the PM8350B charger (no APID, debug arbiter fused off); the ADSP charger PD owns it. 0274
  `negronichg_glink=1` (with `negroniadsp=1`) opens GLINK PMIC_RTR_ADSP_APPS, reads battery/USB status and the
  external-gauge SoC every 20 s, and after the PD answers sets the USB input limit (`negronichg_ma`, default 1500) and
  charging enable over pmic_glink. Built: kernel out/kernel/local-20261026-084835 (6acdaacf...), image out/ios16-chg3
  (boot_a 9286b5e3...). Not booted. Next: owner `fastboot boot`s out/ios16-chg3 (ADSP firmware area must be on
  userdata); check `GLINK UP`, `glink: ... READY`, the property dump, `input limit read back`, and that ibat goes
  clearly positive at idle on the charger. If PMIC_RTR_ADSP_APPS never opens: try `negroniadsp_step=10` (servreg locator).
- Camera levels 1-2 (2026-10-26, camera agent; patches 0310, 0311, patches/xnu/README-camera.md, docs/camera-plan.md):
  0310 `negronicam=1`: GCC camera clocks, camcc titan top GDSC, camcc AHB/CAMNOC/CCI0 clocks from the 19.2 MHz TCXO,
  CCI0 reset (proof `level 1 OK`). 0311 `negronicam=2`: rear main IMX789 power-up in the module-file order (5 RPMh
  rails with the live-DT voltages, reset gpio120, MCLK0), CCI0 M0 chip-ID read (expected `chip id 0x0789 ... MATCH`),
  vendor power-down; failure path powers down in that order, all waits bounded. Built: kernel
  out/kernel/local-20261026-082431 (sha256 fe5d2ef5...), image out/ios16-cam (boot_a 280e1223...). Not flashed.
  Next: owner boots out/ios16-cam with a charged phone (`fastboot boot` first); read the `NEGRONI CAM:` lines; then
  level 3 (TPG -> CSID -> IFE RDI, apps SMMU check) on a D-PHY sensor or the C-PHY main sensor.
- Camera levels 3-6 (2026-10-26 evening, camera agent; patches 0312-0316, patches/xnu/README-camera.md "Levels 3-6",
  docs/camera-plan.md): 0312 RPMh MMCX NOM + camera NoC BCM votes (CN0/MM1/MM0/SH0/MC0, new `negroni_rpmh_cam_bcm`)
  before the first camcc access at every level (audit 2026-10-26 part A), level 3 CPAS/CAMNOC + apps-SMMU check of the
  IFE/ICP streams (`negronicam_smmu=0|1|2`); 0313 level 4 camcc PLL0/PLL3 + capture clocks + CSIPHY1 C-PHY 3 trios;
  0314 IMX789 FTM table (OnePlus cam_sensor_settings.h:6017, stream on) + frame-counter proof; 0315 level 5 CSID0 +
  IFE0 RDI0 -> memory, TPG13 frame then IMX789 4000x3008 RAW10 frame, `/dev/negronicam-tpg|-sensor`,
  scripts/camera/pull-frame.sh + raw-to-png.py; 0316 level 6 ICP PAS 33 + HFI init + SYS_INIT (CAMERA_ICP in the ADSP
  area: scripts/camera/extract-icp-fw.sh, mkadsparea.py). iOS: AppleH10CamIn user-client table (94 selectors) found in
  the D22 kernelcache (scripts/camera/ios-re.sh); design = own NegroniCamera service + capture app first.
  Build: full kernel out/kernel/local-20261026-173833/kernel.development.negroni, sha256 4e4d155111db6c7329e1b542111c5bc48f9c42afcbeb278eb0ceb378d79a158b (after the review fixes: HFI_Q_WORDS 239, BCM enable x = 0 / y = 1, MXC NOM; all patches applied incl. 0310-0316; skipped only the 4 usual dxb patches). No image (owner rule: the main session builds one combined image).
  Next: the combined image with `negronicam=5` (boot-args table: README-camera.md "Boot-args"; the safe default
  `negronicam_smmu=1` stops before DMA if the IFE streams are not in bypass, then `negronicam_smmu=2`); read the
  `NEGRONI CAM:` lines; `scripts/camera/pull-frame.sh`. Level 6 needs the new ADSP area on userdata.
- Display TE lock + VRR (2026-10-26, display-refresh agent; patch 0259, docs/display-refresh-plan.md,
  README-gpu-kernel.md section 17): Android's path read from live.dts/display-drivers (TE pin -> INTF_1 tearcheck,
  CTL kick per commit, oplus ADFR min-fps DCS `BD[0x14]=N` down to 1 Hz, 60/90/120 timing-switch sets).
  0259: `negronifb_te=1` phase-locks the vsync tick to the panel TE through INTF_TEAR_INT_COUNT_VAL (per-second
  `NEGRONI FB TE:` line with te/s, period, phase, locked ticks); `negronifb_vrr=1` idles the panel at
  `negronifb_vrr_fps` (10) Hz after `negronifb_vrr_ms` (3000) without a swap (min-fps DCS + auto-refresh divider),
  `=2` 60/90 Hz timing switch, `=3` divider only; wake on SwapEnd. Kernel local-20261026-075816 (a39f24e5...),
  image `out/ios16-vrr` (config args + `negronifb_te=1 negronifb_vrr=1`, boot_a b7d9ef7c...). Built, not run.
  Next (phone charged, owner approval): boot out/ios16-vrr, read the `NEGRONI FB TE:` boot line (te pin 1,
  autorefresh 0x80000001) and `locked`, then the lock screen idle -> `NEGRONI FB VRR: idle 10 Hz`, touch ->
  `active 120 Hz`; compare battery mA idle with `negronifb_vrr=0`; on a blank panel boot with `negronifb_vrr=0`.
- WebGPU / MSL source on Metal (2026-10-26, Metal agent; flame/0011, built, phone off, not run): `newLibraryWithSource:`
  compiles in the calling process with Apple's own front end (libGPUCompiler `MTLGPUCompilerBuildFromSourceToBuffer`,
  `userland/metal/plugin/negroni_msl.h`), no MTLCompilerService XPC; argument buffers (`newArgumentEncoderWithArguments:`,
  `newArgumentEncoderWithBufferIndex:`, residency via `useResource`/`useHeap`) and indirect draws/dispatches over
  metal2vulkan; indirect command buffers refused cleanly (nil, one log line). Host test with MoltenVK (`msl` case of
  scripts/metal/host-plugin-test.sh) [V]: MSL text -> in-process front end -> metallib -> m2v -> argument-buffer kernel and
  indirect dispatch give correct results; a compile error answers nil + the compiler text. New probe `mslprobe` (front end
  only). Bundle NegroniMetal sha256 f4f515b3...cc99 (after the review fixes), check-imports PASS. Next (phone on): push the bundle, `mslprobe`,
  `metalprobe --compute --render`, then Safari on a WebGPU/WebGL page with `com.apple.WebKit.GPU` in clients
  (docs/metal-management.md "MSL source compile"); then indirect command buffers if WebGPU render bundles need them.
- GPU power collapse (2026-10-26, power agent, patch 0285, README-gpu-kernel.md section 16): the GX domain was powered
  the whole boot (OOB GPU_SET held since step 18). 0285 asks the GMU for IFPC (HFI FEATURE_CTRL, KGSL gen7 recipe:
  power-up register list in ME_INIT, OOB GPU_SET released after step 22, fenced WPTR, no GX read while collapsed);
  if the GMU refuses (or GX never collapses), slumber after 2 s idle with a warm GMU/GPU restart on the next
  submission. Boot-args `negronigpu_ifpc` / `negronigpu_slumber` (both default 1; both 0 = old behaviour). WATCH line:
  `pm ifpc GX collapsed N% ...`. Kernel `out/kernel/local-20261026-074105` (sha256 27fc0bf8...), image
  `out/ios16-ifpc` (config args, boot_a 22d76f2f...). Built, not run. Next (phone on, owner approval):
  `fastboot boot` / flash out/ios16-ifpc, read `NEGRONI GPU PM:` lines and `GX collapsed`; compare THERMAL gpu C
  and battery mA with out/ios16-pwr under Metal; on a hang boot with `negronigpu_ifpc=0`.
- Wi-Fi levels (2026-10-26, Wi-Fi agent): patches 0263 (`negroniwlan=N` levels 2-4 with `step N NAME` / `failed: REASON` lines, badge, BHI heartbeat, MHI window 0..36-bit, read-only DMA-path check of the PCIe NoC/TBU clocks and the apps SMMU stream 0x1c01; `negroniwlan_smmu` default 1, =2 writes a bypass entry and needs owner approval) and 0264 (IPCR RX/TX buffers on MHI 20/21). Old `negroniwlan=2` = new `negroniwlan=4`. Kernel + image `out/ios16-wlan3` (`negroniwifi=10 negroniwlan=4 negronipanic=30 negronipanicreason=2`): kernel local-20261026-073643 sha256 3be2d780..., boot_a sha256 4ee03eff... (after the review fixes). Not run (phone flat). Next: charge the phone above 50 %, owner-approved boot of out/ios16-wlan3, read the `NEGRONI WLAN: step` lines; then level 5 QRTR and level 6 QMI WLFW (0265/0266, not written).
- Wi-Fi levels 5-6 (2026-10-26, Wi-Fi agent; build-only, phone off): patch 0265 = QRTR over MHI IPCR 20/21 (`negroniwlan=5`: step 16 HELLO, step 17 WLFW service 0x45 lookup; bounded v1/v2 decoder, RX queue, RESUME_TX), 0266 = QMI WLFW client (`negroniwlan=6`: steps 18-24 IND_REGISTER, HOST_CAP, firmware memory REQUEST_MEM/RESPOND_MEM, FW_MEM_READY + CAP with chip/board/firmware ids, BDF regdb.bin type 4 + bdwlan.elf type 1, M3_INFO, FW_INIT_DONE) with a generic QMI TLV coder and field tables (`negroni_wlfw_tables.h`). Host test `scripts/wifi/qmi-host-test.sh` ALL PASS. Kernel out/kernel/local-20261026-083218 (sha256 ae4c817f..., after the review fixes), image `out/ios16-wlan6` (config args + `negroniwifi=10 negroniwlan=6 negronipanic=30 negronipanicreason=2`, boot_a 15cda991...). Not run. Next: owner-approved boot (after wlan3 proves levels 2-4), read `step 16 QRTR HELLO from node N`, `step 17 WLFW service at node N port P`, `firmware version ... build "..."`, `step 24 FW_INIT_DONE_IND received`; then step 25+ (WLAN_CFG/WLAN_MODE, cold-boot calibration, CE/HTC/WMI: README-wifi.md "What step 25+ needs").
- Wi-Fi levels 7-10 + SMMU S1 (2026-10-26, Wi-Fi agent; build-only, no image per the owner rule): patches 0320 (QMI WLAN_CFG with the ath11k wcn6855 CE pipes / service map / 30 shadow registers + WLAN_MODE mission, steps 25-26; keep-alive poller, DMA-address seam, `negroniwlan_hostcap=android`, M1 -> M2 fix), 0321 (copy engines on HAL SRNG through the BAR0 window, polled, steps 27-28 HTC READY), 0322 (HTC connect + WMI SERVICE_READY/EXT, INIT, READY with the MAC vs ADT, steps 29-32), 0323 (channel list, STA vdev, passive scan: `BSS N: SSID "..." RSSI`, steps 33-35), 0324 (apps-SMMU stage-1 context for stream 0x1c01 with Android's IOVA window, `negroniwlan_smmu=3`, owner approval). Host tests `scripts/wifi/wmi-host-test.sh` and `qmi-host-test.sh` ALL PASS. Kernel out/kernel/local-20261026-173712 sha256 38927346... after the 0324 review fixes (patch-report: 0320-0324 applied, only the 4 usual dxb skips; 0324 sha256 ad81bdaa...). Boot-args for the combined image: `negroniwifi=10 negroniwlan=10 negronipanic=30 negronipanicreason=2`. Not run. Next: prove levels 2-6 on the phone (firmware area first), then 7-10; then 0325+ (join, WPA2 supplicant, HTT data path, en0 + Apple80211 ioctls: README-wifi.md "Final stage design").
- Vibration (2026-10-26, haptics agent): patch 0300 `negronihap=1` = PM8350B HV haptics direct play over SPMI (owner log, census, 300 ms boot buzz) + API `negroni_haptic_play(ms, strength)`; 0301 = iOS "vibrator" IOService (FigVibrator legacy IOKit path, setProperties `hertz_millisecs`/`repeat`). Kernel out/kernel/local-20261026-072436 (sha256 0f22dbf4...), image `out/ios16-hap` (config args + `negronihap=1`, boot_a sha256 99a1123a...). Built, not run. Next: owner-approved boot of out/ios16-hap, check the `NEGRONI HAPTIC:` lines and the buzz, then a ringtone vibration preview (`NEGRONI VIBRATOR: start`). UI haptics (CoreHaptics) need an Actuator HAL device: large, later (docs/haptics-plan.md). Update (evening): UI haptics built: 0302 (`negronihap_ui=1`: /product/haptics closed-loop node + `/dev/negroni-haptic` envelope -> direct play, CAL_EN toggle), 0303 (CL brake ff 3f 1f + hBoost-ready wait), NegroniAudio Actuator -> node (host test PASS), scripts/haptics/{build-haptics-kernel,root-add-haptics,phone-haptics}.sh. Kernel local-20261026-125419 (6c35b3f5...), `out/ios16-hap2` boot_a e479ff37.... Next: `scripts/haptics/phone-haptics.sh push`, boot out/ios16-hap2 (owner approval), feel taps; keyboard needs Settings > Sounds & Haptics > Keyboard Feedback > Haptic. Proof lines: docs/haptics-plan.md 8.3.
- Wi-Fi/audio (2026-10-26): 0262 rebased on slop 0125; `negroniwifi=10` on the phone: PCIe link UP Gen2 x1 and the QCA6490 answers (17cb:1103, MSI at 0x50) [V]. Stage 1 (`negroniwlan=2`, image out/ios16-wlan2 in boot_a) is untested: the phone browned out at 16 % battery before it logged. ADSP step 1 ran (SMEM OK, PAS query answers 0 -> patch 0241 logs it only); HAL plug-in pushed to the live root (scripts/audio/phone-audio.sh): 3 clean boots, 2 boots with the old SIGABRT, undecided. Next: charge the phone, flash khz12 back, then wlan2 + `negroniadsp_step=4` with `negronipanic=30 negronipanicreason=2`.
- Screen-off freeze (2026-10-26, wake agent): patch 0275 `0275-negroni-display-off-fast.patch` (after 0259; 0260-0264 are WLAN). The 0251 fade read the write-combined panel memory pixel by pixel: ~1 s per vsync tick, 7 s UI freeze per screen-off (`fade 7055 ms`, `late ticks 136`, `swaps/s 0`). 0275 writes black with stores only on tick 0 and calls the backlight on tick 1. Kernel + image `out/ios16-wake` (config args + `negronipanic=30 negronipanicreason=2`): see docs/notes.md section 15 for the hashes. Verify: `display off: black in N us` (N < 10000) and `display off (fade N ms, DCS sleep ok)` with N <= 25, `late ticks 0` around it, then apps open after a wake.
- Audio stage (a) step 9 + stage (b) (2026-10-26, audio agent; patches 0242, 0243; build-only, phone off): 0242 adds ADSP step 9 (GLINK over SMEM: items 478/479, FIFO 480, version 1, channels IPCRTR + adsp_apps) and a per-step time limit + `step N (name) failed: reason` line. 0243 adds `bsd/dev/negroni_audio.c` with steps 10..15 (QRTR, GPR SPF-ready, PRM TER MI2S clock 3.072 MHz + I2S pins, GRAPH_OPEN WR_SH_MEM_EP->PCM_CNV->MFC->I2S_SINK + SET_CFG + PREPARE, SHARED_MEM_MAP + START, and `/dev/negroni-audio` S16->S24 sink). A stage-(b) failure tears the graph down and leaves the ADSP up (no SoC re-reset). After the review fixes: kernel sha256 c4761483... (local-20261026-082825, 0242/0243 applied, no 02xx skipped); out/ios16-audio boot_a.img sha256 edda5229... with `negroniadsp=1 negroniadsp_step=15 negronipanic=30 negronipanicreason=2`. Userland: the mediaserverd `__xpc_api_misuse` crash is BTAudioHALPlugin (XPC to absent bluetoothd); `root-add-audio.sh`/`phone-audio.sh` move it to HAL.disabled by default. NegroniAudio.c stage 1 (ring + writer thread) built, sha256 7770ccb4.... `negroniadsp=1` alone stops at step 9 (GLINK, no audio). Nothing on the phone yet. Next: with the ADSP up (steps 1..8 first), step through `negroniadsp_step=10..15`.
- Audio amps + guard + tone + earpiece + graph + crash watch (2026-10-26 evening, audio agent; patches 0244-0248; build-only, phone on Android). [V] Paths: speaker = 2x TFA9874 (I2C 0x34/0x35) on TERT MI2S (0243's port is right); earpiece = 0x34 alone, profile "receiver" (not the WCD938x); WSA SoundWire amps disabled in the DT; headphones = RX macro + WCD938x; main mics = TX-macro DMIC3/4 with WCD938x bias. 0244 fixes 0243's TLMM base (0x0f100000, 32 KiB map), adds the speaker guard (cap -20 dBFS, high-pass, power/peak limiter, soft start; host test PASS after it caught a sign bug) and the TFA9874 cold start from the vendor driver + container table (`scripts/audio/tfa-cnt.py` -> tfa-init.bin in the ADSP area), TDMSPKG (an attenuation: gain = 21 dB - value) held at a floor (9 speaker = 12 dB, 15 receiver = 6 dB; never louder than the vendor), amps off on silence/fault/panic. 0245: `negroniaudio_tone=1|2` 1 kHz 2 s. 0246: route ioctl + sysctls `kern.negroni_audio_route`/`kern.negroni_audio_tone`. 0247: mainline graph values (`negroniaudio_graph=1` = old). 0248: ADSP FATAL watch + stop + PAS shutdown. Kernel out/kernel/local-20261026-174012 sha256 daf42c44..., 0242-0248 applied, only the 4 dxb skips (no image: owner rule). Not done: mic, headset (weeks: SoundWire + WCD938x + TX macro), HAL receiver route (iOS side [U]). Boot-args for the combined image: `negroniadsp=1 negroniadsp_step=15 negroniaudio_amp=1 negroniaudio_tone=1`. Next: owner writes the new ADSP area, boots the combined image and listens.

- Phone bought: OnePlus 10 Pro NE2211, PAC confirmed by adb.
- Bootloader unlocked (orange state). Auto updates off; stay on 16.0.3.530.
- Stock backup: official full OTA (MD5 checked) and extracted images in `~/op10-backup/`.
- Research: stack map, PAC analysis of xnu-12377, GPU path (`docs/research-report.md`).
- UEFI firmware check: NE2211 `uefi.img` matches the build the negroni Mu patches target.
- Root: Magisk 30.7 in `boot_a`; adb root works.
- Unique partitions and GPT dumped (`scripts/backup/dump-partitions.sh`, 121 partitions, 540 MB gz).
- RAM measured (`docs/device-facts.md`): 9 GiB contiguous at 0x840000000, so the port's memory
  map and `--dram 840000000:C0000000` need no change for 12 GB.
- Build environment: `docker/Dockerfile` (x86_64, Rosetta on macOS), `scripts/uefi/setup-mu.sh`
  (Mu submodules at the pinned commits; Silicium-ACPI at its real base 2d465ad + patch),
  tmux runner `scripts/bg.sh`.

- Mu UEFI built (`out/mu/SILICIUM_UEFI-DEBUG.fd`, 3 MiB; x86_64 container, all 7 r0q patches ported).
- Boot images built natively and checked: `out/ios16/boot_a.img` (shim + Mu FD + 64 MiB payload,
  kernel run 40007883255), `vendor_boot_a.img` (mainline DTB only), `negroni.adt`, `esp.img`.
- iOS 16.7.16 DMGs downloaded (CRC-32 checked).
- GPU reference found: ios-sailfish (`docs/gpu-plan.md`).
- Native macOS Mu build works too (`make mu-build-macos`: Homebrew LLVM, BaseTools from source, no
  Docker/Rosetta/Mono) -> `out/mu/SILICIUM_UEFI-DEBUG-macos.fd`. The first boot uses the container
  build (`SILICIUM_UEFI-DEBUG.fd`).
- iOS root built on macOS (`make root`): 11 GiB used of 16 GiB, 173 apps, fsck_hfs OK;
  sparse image `~/op10-apple/ios16-root.simg` (11.6 GB, sha256 d5d4437d...).
- Vsync raised to 120 Hz in slop patches 0046/0056/0061 (`NEGRONI_FB_VSYNC_US` 8333); patch set
  re-applies cleanly (129 applied, 4 usual skips). Next: rebuild the kernel image and boot it.
- 120 Hz tools (2026-10-25): patches 0252 (`NEGRONI FB STAT:` line once a second, `negronifb_stats`, default 1)
  and 0235 (`negronigpu_level=N`, GX perf level, default 0 = old 220 MHz vote), and 0253
  (`IOMFBDisplayRefresh` property + vsync interval for CoreAnimation, `negronifb_carefresh`, default 1). Kernel
  `out/kernel/local-20261025-170531` (sha256 a0d0d018...): every 02xx patch applied except 0262 (Wi-Fi power-up;
  conflicts with the new slop 0125 XO_CLK pulse, needs a rebase). Not booted. Next: (1) heartbeat env lever on
  the current phone (`scripts/metal/phone-heartbeat.sh on` + reboot), then owner-approved `boot_a` tests with the
  new kernel: (a) `negronifb_zerocopy=1`, (b) + `negronigpu_level=12`, (c) 0253 A/B with `negronifb_carefresh=0`
  (patches/xnu/README-gpu-kernel.md section 12).
- 0254 (2026-10-25): fixed-deadline 120 Hz vsync, no GPU fence wait on the vsync tick (pending frame waits for
  its fence; give-up only on a client close + 500 ms or 2 s without GPU progress), SwapWait busy until the swap is
  on screen (all modes); STAT line + `gpu-wait skips N gave-up N`. Phone test of the first image: tick OK, but CPU copies 51-54 ms (latest fence);
  amended to swap-time fences: kernel `out/kernel/local-20261025-175017` (sha256 e51e7339...), image `out/ios16-0254b`.
  Amended image not booted.
- 0236 (2026-10-25): GPU clock probe (gpucc PLL/GX dumps, `gxclk N MHz` from CP perf counter 0, step-22 blit timing, revote after GPU_SET with `negronigpu_level>0`); images `out/ios16-clk` (level 12) and `out/ios16-clk1` (default). Phone: gxclk 5 MHz at level 12 (vote does not reach the clock); amended with a late report + third vote from the watch, image `out/ios16-clk2`.
- Metal compositor policy (2026-10-25): m2v/0003 + flame/0007, env `NEGRONIMETAL_POLICY` = exact | compositor (default:
  Turnip 8-bit unorm filter + colour writes, containment on) | compositor-srgb | unsafe; plugin logs `images NegroniMetal
  0x... turnip 0x...` for crash symbolication. Built, check-imports PASS; not on the phone. Next: A/B GPU ms per CA frame.
- GL path for backboardd (ios-spes route, 2026-10-25): `scripts/gpu/gl-build.sh` stages negronigl.dylib + a backboardd with
  a weak load command + the gate `/var/db/negronigl/clients`; `scripts/gpu/phone-gl.sh` pushes and switches it
  (docs/gpu-userland.md "GL path"). Built, check-imports PASS, not run on the phone. Kernel deltas from spes:
  patches/xnu/README-gpu-kernel.md section 13.

- GL ES completion (2026-10-26, build only): flush = glFlush + the kernel's swap-time fence (glFinish only with
  `NEGRONIGL_FINISH=1` / `phone-gl.sh finish on`); CAEAGLLayer `renderbufferStorage:fromDrawable:` and
  `presentRenderbuffer:` (3 forms) on Mesa through `userland/negronigl/view.c` for the backboardd shim and the bundle;
  NegroniGL.bundle as the app GL driver with a bundle-local app gate (`phone-gl.sh apps on|off`), linked with chained
  fixups (the old bundle imported `dyld_stub_binder`, missing in 20H392); `ngl_test --layer`. `gl-build` exit 0,
  check-imports PASS for dylib, ngl_test and bundle. Next (phone on): kernel 0257 image, `phone-gl.sh push`,
  `test --layer`, backboardd A/B (`backboardd`, `on`, `restart`), then `apps on` and one GL app (docs/gpu-userland.md).
  Kernel to add: IOSurface CPU lock waits for `gpuFence` (notes.md 15a).

- GPU clock root cause (2026-10-25): PERF_TABLE sent MHz, the GMU wants kHz; GPU ran at ~5 MHz (0236 probe). Patch 0237
  fixes the units. Next: boot it, read `gxclk`, then the GL path (scripts/gpu/phone-gl.sh) and Metal A/B.

- Metal at the real clock (2026-10-25 23:35): backboardd on Metal 150 s, no crash, 4.5-8 ms per command buffer,
  up to 83 GPU presents/s, late ticks 0. Next: Metal for all processes (SpringBoard), GL path A/B, zero-copy flip,
  then a GPU DCVS governor instead of the fixed level 12.

- Poster extensions on Metal (2026-10-25): XR10 answer NO in every process (AegirPoster XR10 pipelines were refused),
  dead-man ignores SIGKILL before the device opened, strike limit env NEGRONIMETAL_STRIKE_LIMIT (4 for *Poster*).
  Built, not tested on the phone (notes.md section 16 end).

- Clock-shift fragments (2026-10-26): the kernel's `negronifb_clockshift` shift ran before the GPU 2D copy had
  reached the panel memory (fence wait result ignored) and covered 150 rows (54 pt, into the lock screen's date).
  Patch 0256: shift after the fence (deferred to a later tick when needed), 120 rows (44 pt status bar),
  `negronifb_clockrows=N`. Images `out/ios16-noshift` (control, no shift) and `out/ios16-0256`. Visual check: owner.

- IOSurface wrap of client memory (2026-10-26, patch 0257, README-gpu-kernel.md section 12 "0257"): IOSurfaceRoot
  selectors 6/7 (WrapClientImage/WrapClientMemory, CoreAnimation's GL renderer) wrap the caller's page-aligned memory
  as a cached surface and answer the normal lock result; bad input returns kIOReturnUnsupported instead of a zeroed
  success (the backboardd far 0x30 crash of notes 15a). Built: `out/ios16-0257`. Not flashed (phone off). Test: the GL
  path (`scripts/gpu/phone-gl.sh backboardd/on/restart`), no `IOSurface wrap of client memory refused` line.

- Power off (2026-10-26, patch 0214): "Shut down" and `op10tool ctl poweroff` rebooted because PSCI SYSTEM_OFF only
  drops PS_HOLD and the PMK8350 PS_HOLD reset type was a reset [V, log timing]; 0214 sets the type SHUTDOWN
  first (PON GEN3 registers +0x52/+0x53; 0211 used +0x5a/+0x5b) and prints the PMIC PON log at boot. Built; phone
  test pending (battery empty, hold). Fastboot-menu power off is ABL: not covered (notes.md section 22).

- Power (2026-10-26, patches 0280 thermal / 0281 GPU DCVS / 0282 USB reset, README-thermal.md): TSENS readings and a
  70/60 C cap policy (GPU levels, CPU rows), a busy-based GPU governor (idle -> 350 MHz), and the CDC-ECM endpoints
  rebuilt after a host bus reset (the "gone/up, then silence" drops). 0272 amended with per-poll charger diagnostics
  (the phone read 0xff: the SMB5 blocks are not reachable from EE 0 or not in the APID map; the diag tells which).
  All in the `kernel-pwr` build, image `out/ios16-pwr` (config args). Not flashed (phone flat). Next: boot it, read
  `NEGRONI THERMAL`, `NEGRONI GPU DCVS`, `charger diag`; then IFPC/slumber between frames and the charger via the
  debug arbiter or the ADSP charger PD.
- CPU governor (2026-10-26, patch 0284, README-cpufreq.md): a 100 ms thread moves each cluster's EPSS row from
  the kernel's per-CPU busy time (`processor_cpu_load_info`, recount): > 70 % -> +1 row to the cap (0280 thermal cap
  stays the bound), < 30 % for 300 ms -> -1 row to the floor = the ABL row (0098, never lower; floor_mhz only raises
  it). With the ABL rows of boot 0097 only d0 moves (rows 12..14); d1/d2 stay at the top. Logs the LMh limit (`lmh`)
  and `cpu N/N/N MHz` on the GPU WATCH line. Built: `kernel-cpugov5`, image `out/ios16-cpugov`. Not flashed.
  Next: boot it, read `dN table`/`governor on`/minute lines and `lmh`, compare THERMAL cpu C and battery mA with
  `ios16-pwr`; then decide (owner) whether d1/d2 may go below the ABL row (boot 0097 ran d1 15 / d2 14).
- Display sleep / power key (2026-10-26, patch 0258, README-brightness.md, README-reboot.md "0258"): the kernel
  power-key fast-off (0250/0251: < 700 ms press = DBV 0 at once) is removed; the key goes to iOS only. Lock =
  iOS fade, then DBV 0 + DCS 0x28/0x10 (panel sleep, DT off-command timings 21/101 ms); wake = 0x11, 133 ms, 0x29,
  last DBV, redraw; `negronifb_sleep=0|1|2` (default 1; 2 = 1). Panic wakes the panel. Code check: slide to
  power off ends in `negroni_power_off()`; no 0215. Built (review fixes in): `kernel-power4` job (all patches/xnu),
  kernel `out/kernel/local-20261026-072629` (sha256 220a82de...), image `out/ios16-power` (config args;
  boot_a fa6a7f0c...). Not flashed. Next: owner test (short press, press again, long press -> slide, unplugged).
- Charger input (2026-10-26, patch 0272, README-battery.md section 7): the phone drained to 0 % on USB (16 % at 01:31,
  -458 mA, cable in). 0272 logs the PM8350B SMB5 charger registers with the battery line and sets the USB input limit
  to `negronichg_ma` (default 500 mA), un-suspends USBIN and enables charging. Kernel + image `out/ios16-chg` built
  by the `kernel-chg` job (sha256 in logs/kernel-chg.log and `out/ios16-chg/SHA256SUMS`). Not flashed. Next: the owner
  flashes it when the phone has charge; check `charger ...` lines, then the thermal/DCVS work (0280/0281).
- Charger ownership + debug arbiter (2026-10-26, patch 0273, README-battery.md section 8): [V] the ADSP charger PD owns
  the PM8350B charger (DT `qcom,pmic_glink` charger_pd; OnePlus driver uses GLINK only), so EE 0 cannot write it.
  [V] 0272 read three status registers at SMB2 offsets (now DCDC 0x1107/0x1108/0x110b) and set CMD_ICL_OVERRIDE = 1
  (HC mode needs 0): fixed. 0273 adds the EE-independent debug arbiter (0x10b14000; fuse bit 18 of 0x221c8784; AOP
  QMP QDSS clock vote), `negronichg_arb=auto|normal|debug` (default auto, chosen at poll 3), writes still only the
  six 0272 registers with `negronichg_ma` (500). [V] `usbin` channel is right (VADC 0x311 1/16); it is measured only
  with negronibatt=4/5, so the image has `negronibatt=5`. Built: `kernel-chg3` (review fixes) -> out/kernel/local-20261026-073259
  (sha256 461b94bc...; all 52 patches/xnu; 4 usual dxb skips); image `ios16-chg2`
  -> out/ios16-chg2 (boot_a sha256 baa05286...). Not flashed. Next: owner flashes/boots out/ios16-chg2 with the cable
  in; read the `charger route`, `debug arbiter: fuse`, `check read`, `charger blocks`, `charger ...` and `usbin=`
  lines. Fuse bit clear or a hang at "first access": boot `negronichg_arb=normal`; the only path left then is the
  ADSP charger PD over GLINK (after the audio agent's ADSP boot).

## First boot (2026-10-24, 19:48)

- Battery percentage (2026-10-26, patch 0276, README-battery.md section 10): [V] "12 % -> 9 %" was a reboot at 13:32:30
  (two boots; 0271 restarts from the first sample, which was under the 1.24 A boot load); within a boot the value froze
  (never down on a charger, net current ~0). [V] True SoC now about 9 % (rest 3662-3669 mV at 0 mA), losing ~1 % per
  10 min with the cable in. [V] The percent cannot come from a PMIC register (no QG here; the gauge is on an ADSP-only
  bus): 0276 uses 0274's GLINK SoC when fresh, else the OCV estimate with a 1 %/30 s rate limit and a filtered current
  for the direction and `charging`; a 1 s plug tick (`negronibatt_fast`) publishes ExternalConnected within 1 s of
  the cable (`external 0->1 ... after N ms`). 0276 applies with or without 0274 (0274 was rebased by its agent
  before the build). Kernel out/kernel/local-20261026-084328 (sha256 20026d62...; 0274 + 0276 applied, 4 usual dxb
  skips), image `out/ios16-soc` (config args + `negronibatt=5 negronipanic=30 negronipanicreason=2`; boot_a sha256
  400f1f95...). Not booted. Next: boot it
  with the cable in; check `soc src=ocv ocv= target=` and that the percent follows the target within 10 min; with 0274
  active `soc src=glink`. Later: keep `fSoc` across boots (file like the RTC offset).
- Flash: userdata from fastbootd (45 x 256 MiB, 303 s), then vendor_boot_a, vbmeta_a, dtbo_a,
  boot_a, slot a: all OKAY.
- Screen: the ABL log text, then **DarwinBoot's green bar** ("the kernel entry code ran"), then
  nothing. Debug image (`negronifb_noconsole=0`, `negroniusb=2`): same screen, no USB device.
  -> the kernel stops before its console starts.
- Likely cause: Mu "Kernel RAM" was 0x840000000+0x140000000 (the port's later iOS 17 / 4K value; the
  notes say that setup hangs right after the green bar). The 16K iOS 16 kernel needs
  0x841000000+0x13F000000, so DarwinBoot's window (0x841004000) keeps a 32 MiB-aligned VA-PA delta
  (slop NOTES 2026-10-20). Fixed in `patches/mu/0001-negroni-kernel-ram-16k.patch` (applied by
  `scripts/uefi/prepare.sh`); Mu and both boot images rebuilt. (2026-10-27: 0001 is in the Mu submodule commit and
  deleted; patches/mu/0002 makes the region 0x1DF000000 for the 7 GiB window of 0401, docs/notes.md section 90.)

## iOS 16 boots on the NE2211 (2026-10-24, 20:10)

With the Kernel RAM fix (debug image: `negroniusb=2`, `negronifb_noconsole=0`), the live USB log
(`make usblog`) shows the iOS userland: backboardd ("NEGRONI FB: display on"), SpringBoard
(AppleKeyStore calls), com.apple.datamigrator (first-boot migration), thermalmonitord,
CAReportingService, localizationswitcherd, symptomsd. bluetoothd and fairplayd.H2 are relaunched
every ~10 s (no hardware; the port dropped their jobs in its later root). Next: the screen state,
then the normal image (`make flash-boot`).

## Power status (2026-10-26 evening, power agent; build only)

Done [V build]: 0277 charge loop over GLINK (FV/FCC per the DT JEITA bands every 5 s, thermal FCC level), 0278 (percentage
across boots, cell temperature, XO/skin to the hub, BCL MONITOR_EN, QDSS vote release), 0283 (per-zone DT thermal
trips + BCL levels), 0291 (`negronicpufreq_floor=abl|lut`). Build `pwr-build` (scripts/battery/build-pwr-image.sh, lock out/kernel/.lock held over kernel + image): kernel out/kernel/local-20261026-124827/kernel.development.negroni sha256 01363704dab977e2259aecbe1fb81141133ba5458ec97a59a6b6abf86b981fa3; patch-report applies every patches/xnu patch 0270-0291 incl. 0277/0278/0283/0291 (and the other agent's 0287/0288), only the 4 usual dxb skips; strings `loop: battery`, `store: soc restored`, `trip %s %s (value`, `negronicpufreq_floor`, `QDSS clock vote released` in the kernel. Image out/ios16-pwr was built in that same locked job from that kernel (local-20261026-124827, sha256 01363704...; [V] three 64 KiB pieces of it found byte-equal in out/ios16-pwr/esp.img; the image SHA256SUMS lists only the image files). It is BEFORE review fix 1 (0277 BATT_CHG_EN restart log bound); per the owner the fix gets a kernel-only proof build, the main session builds the combined image. Review fixes 1-4 (2026-10-26 18:5x): kernel-only proof build `pwr-kernel` (IMAGE=0, lock held): out/kernel/local-20261026-132431/kernel.development.negroni sha256 4786905de90c56b9150153d01f33f69ed87bc7769611e494dd111a1c32974b34, 0277/0278/0283/0291 applied, only the 4 usual dxb skips, string `further failures are not logged` (fix 1) in the kernel. 0277 sha256 now in the report. Image (config args + `negronibatt=5 negroniadsp=1 negronichg_glink=1 negronichg_ma=1500 negronifb_sleep=0 negronipanic=30 negronipanicreason=2`): boot_a.img 72ee45050d399b14a1805b55c65c7cd927a90ed45d6b3c8d5596b6582afc9394, vendor_boot_a.img c29329ee..., esp.img 01f9330f..., negroni.adt 12b7654d... (out/ios16-pwr/SHA256SUMS). Not booted. Patch sha256: 0277 cd22073c..., 0278 047a4652..., 0283 564c7390..., 0291 fa95dcd5...
Observations vs guesses: all code facts are [V] (file:line in README-battery.md s.11-12, README-thermal.md "0283",
README-cpufreq.md "0291"); the PD's acceptance of FV/FCC writes, its FV unit and the BCL bits are [U] until a boot.
Next: (1) boot out/ios16-pwr (fastboot boot, owner approval; ADSP firmware area on userdata, battery > 30 %):
`grep "glink: loop\|BATT_VOLT_MAX\|NEGRONI THERMAL\|store:"`; expect `band normal`, `BATT_VOLT_MAX reads 8870: pack mV`,
`write BATT_VOLT_MAX ... = 8870: ok`, FCC 1100000 ok, ibat > +500 mA. A `REFUSED`/`unknown unit` line = the loop
stays out (safe). (2) Then a `pwr-lut` image (`negronicpufreq_floor=lut`) after the owner decides. (3) Wi-Fi/BT rail
release on failed stages: proposal in docs/audit/2026-10-26-power.md section 6 for the radio owners.

## Fingerprint status (2026-10-26)

- Done: docs/fingerprint-plan.md (DT facts, driver/TEE analysis, display HBM flow, staged plan, iOS design); patches
  0350 (`negronifp=1|2`: SE clocks, GENI SPI probe, LDO, reset, chip-ID frames, IRQ poll) and 0351 (`negronifp_hl`:
  highlight disc + panel HBM set); scripts/fp/extract-vendor-fp.sh, build-test-image.sh. Built: kernel local-20261026-084051 (f8e2b492...), image out/ios16-fp (boot_a 1926dc56...); notes.md section 25.
- Done (evening): stage C probes. Public sources pulled (`scripts/fp/get-references.sh`: the OPLUS G7 HAL source with
  `gf_delmar_types.h`, the OPLUS kernel shim, goodix-fp-dump); facts in docs/fingerprint-plan.md section 7: the HAL and
  the shim carry no SPI frame (all TA commands: `GF_CMD_DELMAR_SENSOR_READ_IMAGE = 101`), the module has a Goodix MCU
  (fw app/bootcode, GW183 sensor die), the origin frame is 364 x 252 x 16 bit. Patches 0352 (`negronifp=3`: public
  Goodix MCU message-pack frames over plain SPI and the 5120-SPI transport, IRQ watch, decoded answers; ldoc11 EBUSY
  retry + stop) and 0353 (`negronifp=4`: HBM on, 2 TE frames via the new `negroni_fb_te_wait`, get-image frame, bounded
  read, `/dev/negroni-fp` 0600, `scripts/fp/raw-to-png.py`). Stage D decisions in section 4.3 (SourceAFIS Rust port /
  libAFIS / NBIS, passcode injection vs SBLockScreenManager, template storage). Build: see notes 25 (fp3 image).
- Not done: a run on the phone; the real G7 readout (the public get-image command is a guess [I]); the TA was not
  found in vendor/odm firmware (partition scan result in `out/fp/lists/ta-scan.txt`, notes 25); stage D code.
- Next: phone test `out/ios16-fp3` (owner approval: GCC/TLMM/RPMh writes); read `MCU probe result` and `irq40 changed`;
  then the fp4 capture image when step 10 answered; find the stock icon position (runtime property).

## Bluetooth status (2026-10-26)

- Done: docs/bluetooth-plan.md (facts, firmware list, iOS analysis); scripts/bt/fetch-sources.sh, fetch-firmware.sh;
  patch 0330 (`negronibt=1`: rails, QUP2 clocks, GENI UART, BT_EN sequence). Build results: notes.md section 24.
- Done (build-only): patch 0331 (HCI stage: `negronibt=2` reset/version/3 Mbaud, `negronibt=3` + rampatch/NVM from
  the BT pack in the WLAN area, reset, BD address); scripts/bt/mkbtpack.py, mkbtarea.sh, build-test-image.sh.
  Kernel local-20261026-123344 (2c5d53ca...), out/ios16-bt boot_a d01f3d6d... (after the review fix: h4_next deadline on every pass) (`negronibt=3`); out/firmware/wlan-area.bin
  now holds the BT pack (f8e96b65...). Not run on the phone.
- Next: owner approval, write the WLAN area (AREAS=1 root-simg.sh), boot out/ios16-bt; read steps 5, 7, 9-19
  (README-bluetooth.md 0331 table). Then stage B (iOS transport).
- Done (build-only, 2026-10-26, BT stage B agent): patch 0332 (`negronibt=4`: step 20 ADT BD address -> 0xfc14; kernel
  control `com.apple.uart.bluetooth` + `/dev/uart.bluetooth`, `/dev/cu.bluetooth`, `/dev/btwake`; RX thread 1/5/20 ms poll with
  RFR flow control and QCA IBS), patch 0333 (HCI shim: every host OGF 0x3f command answered in the kernel, QCA vendor
  events dropped), userland/bluetooth (`negroni-bluetool` BlueTool stand-in, `hcitest`; out/bt/userland, sha256
  c396870e... / 27ac9492...), scripts/bt/bt-launchd.py, root-add-bt.sh (`BT=1`), phone-bt.sh, `ADT_BT=1` in
  scripts/ios16/adt-extra.py (config `[adt.bluetooth]`). The stock cache has no bluetoothd job: `BT=1` / `phone-bt.sh on`
  add it from LaunchDaemons/com.apple.bluetoothd.plist (the DROP entry in root-tweaks-extra.py removes nothing). Review
  fixes: 0332 makes rx_drain stop at a full ring (RFR holds the controller), h4_close wakes readers. Kernel local-20261026-174538 sha256 cfd8af00... (after the review fixes; first build local-20261026-132747 a94e8f3c...) (0330-0333
  applied, only the 4 usual dxb skips; compile-one clean for the 4 BT files). No boot image (owner rule).
  Boot-args for the combined image: `negronibt=4 negronipanic=30 negronipanicreason=2`; the image needs `ADT_BT=1`.
- Next (BT): combined image + `BT=1` root (or `scripts/bt/phone-bt.sh on`), WLAN area with the BT pack; then
  `phone-bt.sh test` (hcitest), `phone-bt.sh log`, Settings > Bluetooth. [I] Open: bluetoothd chipset id, sandbox on the
  PF_SYSTEM socket, VSCs whose status 0x01 may be fatal.

## Display performance status (2026-10-26)

- Done: measurements (README-gpu-kernel.md section 18: presents/s mean 43.5, DCVS 350-421 MHz, CA's SwapWait busy
  173/s, Metal ctc 15.6 ms); patches 0267 (vsync notification after the frame is queued; clock shift inside the
  GPU/CPU copy, no read of the panel memory) and 0286 (GPU DCVS UI floor 640 MHz at >= 30 swaps/s); host test
  patches/xnu/tests/fb-clock-copy-test.c PASS; scripts/display/build-perf.sh -> kernel
  local-20261026-082629 (sha256 92f50f3a...), `out/ios16-perf` (boot_a 2583f0ab...), `out/ios16-perf-noshift` (boot_a 50d09e1b...).
- 0268 (panel wake = Android's full on-command 94 packets + 0x0A PPS, long DSI packets by memory DMA, auto-refresh
  paused during the set, TE check; `negronifb_wake` 2/1/0) and 0269 (panel double buffering: 3 buffers, SSPP_SRC0_ADDR +
  CTL_FLUSH after the copy's fence; `negronifb_dbuf=1`, default 0): built into `out/ios16-dpu` (config args +
  `negronifb_sleep=1 negronifb_dbuf=1 negronipanic=30 negronipanicreason=2`, scripts/display/build-dpu.sh); README-gpu-kernel.md
  sections 19/20. Not booted. Check on the phone: the `NEGRONI FB: DPU ...` probe lines, `0269 double buffering on`,
  `0269 flip N ... taken after N us`, `NEGRONI FB DBUF:` per second, and after a lock/unlock `display on (on-command 94
  packets, PPS ok, TE on ...)` with a correct picture. Fallbacks: `negronifb_wake=1`, `negronifb_wake=0`,
  `negronifb_sleep=0`, `negronifb_dbuf=0`.
- Not done: phone test; zero-copy test (0234).
- Next: owner flashes `out/ios16-perf`, scrolls, sends the FB STAT / GPU DCVS lines (goal: presents/s 100-120,
  timeouts < 100/s) and says whether the top-left strip is still; then `out/ios16-perf-noshift` for the A/B.

## GPU recovery and CPU idle status (2026-10-26, GPU-recovery agent)

- Done [V build, not booted]: 0287 GPU hang detection + recovery (KGSL gen7_gmu_reset path, `NEGRONI GPU RECOVERY:` lines,
  failed fences -> kIOReturnError / Turnip device lost, max 3 per 60 s); 0288 CPU idle via PSCI CPU_SUSPEND with the DT params
  (`negronicpuidle`, kernel default 0, broadcast wake timer frame 0); 0298 KGSL parity from docs/audit/2026-10-26-gpu.md
  (HWCG, slumber from IFPC, GMU busy counter for DCVS, CP_PROTECT/CHICKEN/ME_INIT BIT(11), rptr shadow, HFI 100 ms, guard page,
  bus votes from cmd-db + CNOC, DCVS bw = DT bus-freq). Review fixes in kernel `out/kernel/local-20261026-174403` (sha256
  dfa9a8a5..., no image: the PSCI feature bits; 0288 idles only with this kernel). Previous kernel `local-20261026-131716` (7804fca8...),
  image `out/ios16-gpur` (boot_a 526eba93..., config args + `negronigpu_recover=1 negronicpuidle=1 negronipanic=30
  negronipanicreason=2`). Details: patches/xnu/README-gpu-kernel.md sections 21 and 27, README-cpuidle.md, notes sections 17 and 22.
- Not done: ACD (needs the AOP QMP mailbox), preemption, GPU completion interrupt. Owner rule: no more images for this work.
- Next (phone): flash `out/ios16-gpur`; check step 17 `bw table` / `CNOC` lines and step 20 `KGSL settings (0298)` line, the WATCH
  `pm ifpc ... slumbers N wakes N busy N%`, `NEGRONI CPUIDLE:` lines (PSCI features, wake timer, per-core `down %`), and the
  battery current at idle against `negronicpuidle=0`. Trouble bisect: `negronigpu_protect=0`, `negronigpu_hwcg=0`,
  `negronigpu_ifpc_slumber=0`, `negronigpu_bwcalc=0`, `negronicpuidle=0`.

## Display DSI/DPU status (2026-10-26, DSI agent; build only)

- Done (code, default off): 0292 DSI command sets by batched memory DMA like Android (`negronifb_dsidma`), 0293 DCS
  reads + ESD 0x0a check + panel ID + re-init through 0268's wake (`negronifb_esd`), 0294 tearcheck vsync_count on a VRR
  mode 2 switch, 0295 TE rd_ptr interrupt (first SPI of the port, `negronifb_teirq`), 0296 clock/GDSC probe
  (`negronifb_pwrprobe`) and Android's no-transfer idle (`negronifb_idle=2`). Details: patches/xnu/README-gpu-kernel.md
  sections 22-26 (boot-arg table at the end), docs/notes.md section 15 (end), docs/display-refresh-plan.md section 8.
- [V] Build: `scripts/display/build-dsi.sh` (kernel only, owner rule), kernel `out/kernel/local-20261026-174206`
  sha256 a0b050bf05d91e0878af954bc4a4033899f5977aa734198a24df76d0efb26d3c (after the review fixes: ESD re-init cap 3, read under the set lock, 0294 counter off/on); 233 patches applied incl. 0268, 0269, 0292-0296; only the 4 usual dxb skips.
  compile-one: every intermediate state 0292..0296 compiles; 0300-0353 apply after them.
- Next (phone, one at a time): config args + `negronifb_dsidma=1 negronifb_esd=1 negronifb_pwrprobe=1` (expect `NEGRONI
  DSI: set of ... rc 0`, `NEGRONI DSI: panel ID ...`, `NEGRONI DSI ESD: power mode 0x9d ok`, `NEGRONI DPU PWR:` lines);
  then `negronifb_te=1 negronifb_teirq=1` (`negronicpuidle=1` + `negronifb_teirq=1` untested together: test apart
  first); then `negronifb_idle=2` with the battery current A/B. Then clock gating in
  idle (README section 26 table), and the 0269 flip + `idle=2` together.

## Phase 1: iOS 16 (existing negroni port)

1. ~~Measure the 12 GB memory map~~ (done over adb root). Optional: shim probe with `fastboot boot`.
2. Mu UEFI: extract DXEs from the OTA `uefi.img`, run `portpatch2.py` / `mkbinaries.py`, fix
   MemoryMapLib for 12 GB, build `negroniPkg` DEBUG.
3. Kernel from slop CI run 40007883255; ADT with the new `--dram`; payload; `boot_a` image.
4. ~~iOS 16.7.16 (iPhone10,3, 20H392) HFS+ root~~ (done).
5. **Next:** writes with `scripts/flash/ios16.sh`, each approved first. Order: `userdata` from fastbootd
   (8 GiB ABL sparse issue), then in the bootloader `vendor_boot_a`, `vbmeta_a`, erase `dtbo_a`, `boot_a`,
   `set_active a` + reboot.

## Phase 2: iOS 26 kernel and userland

1. xnu-12377.121.6 arm64e from a VMAPPLE-based NEGRONI config.
2. Native PAC keys instead of the VMAPPLE hvc calls (one global key set first).
3. Clear SME/SME2, PAN3, paravirt CTRR in the config.
4. A13 iPhone IPSW (iPhone12,1 / iPhone12,5) as userland.
5. Port the 128 negroni patches, or prelink Apple's arm64e A13 kexts.
6. Find out whether iOS 26 QuartzCore renders without Metal.

## Phase 3: GPU (Adreno 730)

1. Fix the RedwoodGPU user client panic in slop's A730 path.
2. Port UniXNU NativeAdreno board code (GMU, RSC, votes, cmd-db, SMMU) to SM8450.
3. Port NativeMetal (metal2vulkan via Turnip FD730) to the iOS 26 Metal interface.

## Mi A3 (laurel_sprout): speaker audio built (2026-11-01 04:40, area F, branch t3/laurel-audio-speaker-adsp)
Done [V build]: patch 2500 (ADSP PAS 1 from modem_b/modem_a via a FAT16 reader, GLINK + QRTR + pd-mapper, APR on
apr_audio_svc, AFE SEC_MI2S_RX + ADM + ASM, MAX98927/98937 at 0x3a, /dev/redwood-audio early, self-check + one
`LAUREL AUDIO: on|off:` line, kill switch `adsp=0`/`laurelaudio=0`); RedwoodAudio.driver built on Linux
(`userland/laurel/audio/build.sh`); `scripts/laurel/root-audio.sh` in root.sh. Kernel 7158a9c3..., image
out/laurel/uefi/laurel-uefi-boot.img d82f593b.... Not booted. Root image change: plug-in + VirtualAudio back +
BTAudio off (apply to the current image: `scripts/bg.sh laurel-root-audio sudo scripts/laurel/root-audio.sh --image
$APPLE/laurel-ios16-root.img`, then flash userdata with owner approval).
Review fixes (ACCEPT-WITH-FIXES) done on top of laurel-int-1: 4 GiB checks for ADSP buffers, token/volume/re-queue/idle
fixes, root-audio.sh fsck gate + skip; rebased on area E 282bc27: own FAT reader removed, `topaz_part_fw_*` (2400).
Next (coordinator): boot the image, read the `TopazAudio:`/`LAUREL AUDIO:` lines; with the new root, play a ringtone
(Settings > Sounds). Mic, headset, earpiece need the WCD937x codec (not started). docs/laurel_sprout/audio.md.

## Mi A3 (laurel_sprout) status (2026-11-01, branch laurel-sprout)

Done: kalloc assert fix (0102); SMP CPU_ON -4 panic: shim 0002 (Silver boot core CPU_OFF) + kernel 2004
(SweetCPU soft-fail, dead cores off-line, boot goes on); USB log channel 2005 (negroni protocol: ECM,
UDP 5140 log, UDP 5141 commands, panic hold over USB; docs/laurel_sprout/usb-debug.md); host loop
`scripts/laurel/boot-test.sh`; 2006 early USB start (raw frames from STARTUP(EARLY_BOOT)); 2007 USB power-up by
the kernel (GDSC, clocks, reset, QUSB2 PHY, core) + one line per stage + `no host yet` heartbeat + ue0 attach thread;
`flash-boot.sh BOOT=continue` (ABL boots boot_b without a reset, USB left as fastboot had it).
Boots: 00:40 (2006, `fastboot reboot`): console stops after `mbinit: done`, no USB device, no `LAUREL USB:` line
visible (panel wrapped). 01:03 (2007, `fastboot continue`): no USB device on the host in 180 s; photo pending.
01:19 (2007, `fastboot reboot`, iOS root on userdata): console as usual, then two flashes, then the panel dark.
01:40 fork survey (`docs/laurel_sprout/fork-fixes.md`): the console stop after `mbinit: done` is most likely the
AppleCLCD start moving the kernel console to a shadow buffer scanned through VIG0 while the Mi A3 panel is fed by
another pipe (our shim 0001 finding); 2008 picks the pipe that fetches the boot framebuffer or keeps the console on
it; `sweetfb_stayon=1` stops backboardd's display-off; 2009 checks the UFS GDSC/clocks before the first host access
and keeps the persistent-log thread alive (evergo 0105e); `scripts/laurel/log-pull.sh` reads the 0047 ring.
Image 01:39 (cpus=8, 17481728 bytes) not booted: the phone is off.
Next: owner powers the phone on (Power+VolDown for fastboot) -> `scripts/bg.sh laurel-test scripts/laurel/boot-test.sh`
(warm path) and a film of the panel: `FB pipe=`, `LAUREL FB SCANOUT:`, `SWEET UFS: host`, the `LAUREL USB:` stage lines.
Then `BOOT=reboot` (cold path). If `FB pipe=0` the scan-out theory is wrong and the next suspect is the UFS line.
Exact results go to docs/notes.md.

## Mi A3 (laurel_sprout): UEFI boot path built (2026-11-01 02:10, branch laurel-sprout)

Owner decision 2026-11-01: replace the topaz shim path by the negroni-style chain stock ABL -> Mu-Silicium UEFI
(laurel_sproutPkg) -> UniXNU boot manager + DarwinBoot -> our XNU -> iOS root on userdata. Details and reasons:
`docs/laurel_sprout/uefi-boot.md`.
Done [V]: `scripts/laurel/mu-build.sh` (`make laurel-mu`): native stuart build of the akshaynexus Mu fork's
laurel_sproutPkg + UniXNU + DarwinBoot + NegroniBootMemoryDxe with `patches/laurel/mu/0001` (52 images, 11 s EDK2 time,
Device-Binaries has laurel_sprout, no ROM extraction); kernel patches 2011 (boot_args command line 1024 = DarwinBoot
layout) and 2012 (boot CPU may be Silver 0x0 under TOPAZ_4K: UEFI/DarwinBoot stay on the ABL's core, no Gold
hand-off); `scripts/laurel/mkadt.py --boot silver --darwinboot`; `scripts/laurel/mkdarwinboot.py` (UniXNU payload
FAT); `scripts/laurel/uefi-image.sh` (`make laurel-uefi-image [MU_ONLY=1]`): boot image v2 with
gzip(BootShim + FD) as kernel, the payload FAT as ramdisk, stock DTB. Images: `out/laurel/uefi/laurel-mu-only-boot.img`
(2.5 MB, Mu alone) and `out/laurel/uefi/laurel-uefi-boot.img` (52.9 MB, full chain). Kernel 213 patches, 0 LSE/RCpc.
First boot 02:16 (Mu-only image) [V photo]: ABL inflates and starts Mu; 11 drivers load, display console works,
NEGRONIMEM reads the live FDT (3 memory banks, 21 reserved ranges, adds 0x1D000000 bytes of holes below 4 GiB),
RamManagerDxe maps the RAM partitions (0x45700000.. holes and 0xC0000000-0x1C0000000). Then a synchronous exception
in the Qualcomm DDRInfoDxe (called by SmBiosTableDxe): data abort, translation fault level 3, FAR 0x0447D220.
Fix 02:21 [V build]: upstream laurel_sproutPkg lacks the "MCCC_MCCC_MSTR" 0x0447D000 MMIO region every other
NicobarPkg device maps (ginkgo, willow, lime, fog, ...); `patches/laurel/mu/0001` adds it. `0002` logs each DT memory
bank (`NEGRONIMEM: DT memory bank`) to confirm the 6 GB layout; `uefi-image.sh` pads the Mu-only ramdisk to 4096 bytes
(the 94-byte cpio gave "initrd ... is not a whole number of sectors") and names it `laurel-mu-only-boot.img`.
Both images rebuilt 02:23. NOT BOOTED since the fix: the phone sits in the Mu ASSERT, not on USB.
Next (owner): phone into fastboot (Power+VolDown, hold until the fastboot screen), then
`scripts/bg.sh laurel-flash sh -c 'BOOT=reboot scripts/laurel/flash-boot.sh out/laurel/uefi/laurel-mu-only-boot.img'`;
photo of the Mu screen (step 1). Then the same with `laurel-uefi-boot.img` + `scripts/laurel/boot-test.sh
IMG=out/laurel/uefi/laurel-uefi-boot.img NOFLASH=1` (usblog is up): UniXNU menu, `DARWINBOOT: ... pa=0x81004000`, green
bar, `LAUREL CPU: boot cpu mpidr=0x0`, USB Ethernet + `op10tool ctl ping`. Fallback if the Silver boot fails: DarwinBoot
PSCI hand-off to Gold 0x100 + `--boot gold`. Restore Android: `BOOTIMG=~/laurel-backup/stock/images/boot.img
scripts/laurel/flash-boot.sh`.

## Mi A3: full UEFI chain boots XNU (2026-11-01 02:28); hang after trust caches; patches 2013/2014 (02:58)

Done [V]: boot 02:28 of commit ccb5eaa reached the kernel console through Mu -> UniXNU -> DarwinBoot on Silver 0x0 (photo:
FB scan-out on VIG0, USB `running`, `LAUREL USB: on`, last line `SWEET: trust caches unavailable`). The host saw the DWC3
connect but got no EP0 answer (GET_DESCRIPTOR timeouts): the USB service thread never ran, nor did `SweetCPU::startAll`
(no CPU_ON lines), nor bsd_init. Analysis (`docs/laurel_sprout/uefi-boot.md` Status, `usb-debug.md` "Patches 2013 and
2014"): the next bootstrap step `PE_lockdown_iokit` = `ml_wait_max_cpus` sleeps until startAll finishes; every waiter
needs the timer interrupt on the boot CPU. Patch 2013: USB gadget served from a 1 ms timer_call (no scheduler) + panel
self-check of the timer interrupt at STARTUP(LOCKDOWN) with the GIC/CNTV/ICC state; pe_init_fiq clears ICC_AP1R0.
Patch 2014: kprintf (bootstrap and bsd_init step names) into the console ring = USB log. Kernel 215 patches, 0 LSE;
image `out/laurel/uefi/laurel-uefi-boot.img` 02:56.
Next (owner): Power+VolDown into fastboot; the tmux job `laurel-test` (started 02:56:51) flashes boot_b and boots. Photo
of the panel: the line after `trust caches` must be `LAUREL USB: timer service: on, first tick after N us` (then the host
enumerates and `logs/laurel-boot-*.log` shows the last `kernel_bootstrap_thread:`/`SWEET CPU:` step before the hang) or
`... NO tick in 50 ms: ...` with the register values (then the fix is in the GIC/timer bring-up after Mu: read ISPENDR0,
ISR, RPR, CNTV_CTL per the table in usb-debug.md). Then: the secondary-CPU start under the UEFI path (startAll waits
for Silver 0x1-0x3 and Gold 0x100-0x103 with PSCI CPU_ON from Silver 0x0; 2004 keeps the boot going with dead cores).
Boot 02:57 (image f196ef7) [V host]: same host result (HS device, no EP0 answer at 02:58:12). The panel photo decides:
`timer service: on` (EP0/DWC3 fault, next: compare DEPCFG/TRB/event path with ABL usbfn and hackios dwc3) or `NO tick`
(GIC/timer after Mu on Silver CPU0: read the register values, next fix in pe_init_fiq or a Gold hand-off in DarwinBoot).

## Mi A3: boot 02:57 = no timer PPI enable on Silver CPU0; kernel 2015 GICR init with read-back (2026-11-01 03:20)

Done [V]: photo of boot 02:57: `timer service: NO tick`, CNTV fired, ICC/GICD fine, GICR WAKER 0, ISENABLER0 bit 19 = 0 after
pe_init_fiq wrote it. Patch 2015 (commit 93fa4fd): per-CPU redistributor init with read-back and retry (TYPER-nonzero frame match,
clear/deactivate, group/priority, enable 19/18/SGI1, GICR_PWRR attempt), `LAUREL GIC:` report on the panel at LOCKDOWN; 2013 line
split. Boot 03:14:50: host result unchanged (HS device, no EP0 answer, unable to enumerate 03:15:29).
Next: panel photo of boot 03:14 (`LAUREL GIC: on|off ...`, `timer service:`). `on` + `timer service: on`: EP0 path (DWC3) is the
fault, read `logs/laurel-boot-*.log` if the ECM comes up. `off`: the enable is refused from NS on this frame; options: (a) use the
frame/INTID Mu used (PPI 18 physical timer works for Mu on the same core?), (b) PSCI hand-off to Gold 0x100 + `mkadt --boot gold`
as the shim did, (c) check IIDR/TYPER of the matched frame (a zero frame = wrong frame). Then the secondary start under Mu.

## Mi A3 (laurel_sprout) status 2026-11-01 04:10 [V]

- UEFI chain (ABL -> Mu-Silicium -> UniXNU -> DarwinBoot -> XNU) boots iOS 16 userland to SpringBoard on the Mi A3; the kernel
  hands the boot from Silver 0x0 to Gold 0x100 with PSCI CPU_ON at its entry (patch 2016); all 8 cores up; USB CDC-ECM log and
  commands work; `ctl bootloader` reaches the ABL fastboot without buttons (2018). Details: docs/laurel_sprout/uefi-boot.md,
  notes.md sections of 2026-11-01 03:20-04:10.
- Next: UI on the panel (no GPU), touch scaling to 720x1560, battery SPMI reads, full early log over USB.

## Mi A3: touch 720x1560, keys, brightness, panel power (2026-11-01 04:40, area C, build only)

Done [V build]: patches 2200 (touch: FT3518 raw = panel pixels per DT and log, GT9883 Normandy path, TLMM edge latch, HID map from the
framebuffer layout), 2201 (panel detect from INTF_1 timing, DCS max 2047/4095, AppleARMBacklight only with the GPU renderer, apollo
0154 slider protocol, 300 ms fades, AMOLED off/on timing with a wake retry), 2202 (keys self-check line; the topaz key code is right
for trinket). Revised after the review (05:00): inclusive touch maxima, GT9883 inversion, power-change serialization.
`uefi-image.sh` drops `sweetfb_stayon=1`. Not booted.
Next (coordinator): boot and check `LAUREL TOUCH: on:`, `LAUREL TOUCH: display map:`, `LAUREL KEYS: on:`, `LAUREL BACKLIGHT: on: DCS max
2047 (Samsung s6e8fco ...)`; press volume up; move the brightness slider (`SWEET BL: ... -> DBV`); lock/unlock with the power key (panel
dark, then back with a fade). Details: notes.md, same date, 04:40.

- Vibration (area H, patch 2700, build only, NOT BOOTED): PMI632 LDO ERM over SPMI SID 3 + "vibrator" IOService +
  /dev/redwood-haptic; expected line `LAUREL HAPTIC: on: PMI632 LDO vib SID3 0x5700 3000 mV (...)`. Test: Settings > Sounds &
  Haptics > Ringtone > Vibration preview. UI/keyboard taps wait for the RedwoodAudio plug-in + VirtualAudio in the root
  (docs/laurel_sprout/haptics.md).
## Mi A3: GPU (Adreno 610) path built, not booted (2026-11-01 05:00, area B, branch t3/laurel-adreno-610-gpu)

Done [V build]: kernel patches 2150 (TopazAdreno trinket values, on by default, `gpu=0` kill switch, own zap shader + SQE from
the root, run-time GPU pool 0xC0000000+512 MB with midmem fallback, CP fence self-check, `LAUREL GPU: on|off`), 2151 (IOSurface
placement by GPU state, 720x1560 screen surfaces from the pool), 2152 (`SWEET FPS` every 10 s by default); 222 patches, 0 LSE.
Linux builds: `scripts/laurel/gpu-firmware.sh` (stock vendor image -> a610_zap + a630_sqe.fw), `mesa-linux.sh` (Mesa 25.0.7
freedreno, 47 s), `gpu-userland.sh` (libtopaz-gl, libtopaz-inject, backboardd wrapper), `root-add-gpu.sh` (root.sh calls it).
Details and expected log lines: docs/laurel_sprout/gpu.md.
Next: rebuild the root (`sudo scripts/laurel/root.sh` after gpu-firmware.sh + gpu-userland.sh as the user), flash userdata
(owner approval), boot the 2150-2152 kernel; check `LAUREL GPU: on: Adreno 610 chip 0x06010000 ...`, backboardd
`libtopaz-gl.dylib loaded`, `SWEET FPS` lines. Then CX/MX vote and clocks; Turnip + metal2vulkan (Metal) later.

Review fixes 2026-11-01 05:10 (rebased on laurel-int-1) [V build]: RedwoodGPU only for backboardd while the SMMU passes
through; pool/scanout placement by "backboardd loaded GL" (asked per create); our backboardd wrapper (userland/laurel/gpu,
gpu=0/gl=0 whole-word, crash guard after 2 fast exits, checked before install); 2151 on area A's 2101 (GPU pool -> scanout/
SPOOL only without GL -> LAUREL SURF -> contiguous below 4 GiB); GPU pool from ADT laurel-ram-reserved (else midmem); no
0x1060 write; gpu_mhz removed (CX not voted); fence self-check writes seqno back; SWEET FPS only while GL is loaded;
pinned pip hashes; wider ARMv8.1 check. Kernel 230 patches, 0 LSE. Image out/laurel/uefi/laurel-uefi-boot.img (worktree).
**Owner decision (CLAUDE.md "macOS and Linux"):** the laurel GPU scripts (gpu-env/-firmware/-userland, mesa-linux,
root-add-gpu) are Linux x86_64 only, like kernel-linux.sh and mu-build.sh (pinned theos toolchain is x86_64). Accept this
exception, or ask for a macOS path (Xcode clang/ld/codesign in gpu-env.sh).
## Mi A3 Metal path, AREA J (2026-11-01 04:45)

- Done [V]: path decided (metal2vulkan + Turnip, negroni stack, docs/laurel_sprout/metal.md); whole stack built natively on
  Linux (`scripts/bg.sh laurel-metal scripts/laurel/metal-build.sh`: Turnip for the A610, bridge, NegroniMetal.bundle,
  probes, ldid, import check PASS vs 20H392, 0 LSE); `scripts/laurel/root-add-metal.sh` (called by root.sh, METAL=0 skips);
  kernel patch 2850 (Metal plug-in names on IOAcceleratorES after a self-check) builds, 220 patches, 0 LSE.
- Not done: phone test; 0x49 host import (impossible with the pass-through SMMU); Turnip on the A610 never ran.
- Next: AREA B's GPU driver + 2850 kernel, root with the Metal stage; test plan metal.md section 8.
- Review fixes (2026-11-01 05:05, rebased on laurel-int-1): 2850 never delays the UI on a GPU failure (bundle check first,
  100 ms poll, stop on topaz_gpu_wanted/failed); clients default = probes only; Turnip 0101 caps buffers at the kernel's
  RedwoodMaxBuffer (< 64 MiB); macOS path runs the negroni scripts unchanged; LLVM >= 18 floor; wider LSE check.
  Merge: A -> B (2150-2152; B adds root-add-gpu.sh before root-add-metal.sh in root.sh) -> J 2850.
## Mi A3: GPU upstream sync + full-acceleration work (2026-11-01 06:45, branch t3/laurel-gpu-upstream-opt, build only)

- Done [V build]: upstream check (docs/laurel_sprout/upstream-2026-11-01.md, `scripts/setup/upstream-check.sh`);
  metal2vulkan f6a96b7d -> 219f013 (rollback sets kept); Turnip 0102 (the A610 reported **Vulkan 1.0**, metal2vulkan needs
  1.2: Metal had no device); kernel **2154** stage-1 SMMU tables on by default with self-check and fallback (lifts the
  backboardd-only rule, scattered buffers/surfaces, 256 MiB buffers); compiled target `-mcpu=cortex-a53` (measured with
  llvm-mca against `-mtune=cortex-a73`) + A53 erratum fix + ThinLTO (Turnip, Rust) + dSYMs; full ARMv8.0 check
  (`scripts/laurel/armv80-check.py`); metal2vulkan cache caps 32 MiB / 1 GiB; eagl still surfaces every 8th frame.
  Kernel 242 patches, 0 LSE; GL, Turnip, bridge, plug-in: check PASS, import check PASS.
- Next (coordinator, phone): kernel with 2154 + root with GPU + Metal stage; read `LAUREL GPU:`, `LAUREL GPU SMMU:`,
  `LAUREL METAL:`; then `vkprobe` (expect `TU DARWIN API: on` and apiVersion 1.3), `m2vtest`, `metalprobe`; then
  METAL_CLIENTS steps (metal.md section 8). If `LAUREL GPU SMMU: off`, send the reason line: stage 1 then needs work on
  the register access or the >4 GiB reach.
- Open: fence IRQ (polled 200 us), GX/CX idle power collapse, CX/MX vote for > 300 MHz, 0x49 host import (possible now),
  HakiOS RedwoodGPU fixes G3/G4/G11/G13/G14, gpu_recover, metal2vulkan 6e88d18 warm start, per-process GPU tables.

## Mi A3 Wi-Fi speed + 5 GHz: patches 2405-2411 built, NOT run on the phone (2026-11-01, branch t3/laurel-wifi-5ghz-speed)
- Done: join with HT/VHT/QoS and the AP's width (was 11a/11g: 54 Mbit/s, no A-MPDU); scan = what wifid asks, limited while joined and under traffic (was 37 channels x 150 ms each time); 5 GHz first at -70 dBm or better (was strongest AP); real AP, RSSI, rate for wifid; `LAUREL WIFI: link ...` line each 10 s under traffic. Kill switches `wifi_ht=0`, `wifi_band=0`, `wifi_scanlimit=0`.
- Results [V]: 266/266 patches, 0 LSE, kernel sha256 782caf57...; host test passed. [U] Speed on the phone not measured.
- Next: owner test (docs/laurel_sprout/wifi.md "Speed and 5 GHz"): 5 GHz router, speed test, 3 `link` lines. Separate facts and estimates: the same section.

## Mi A3 Wi-Fi: patches 2400-2402 built (2026-11-01 04:35, area E, branch t3/laurel-wifi-modem-firmware)

- Done [V build]: 2400 modem firmware through a runtime FAT16/FAT32 index of `modem_<active slot>` (GPT A/B bit; Mi A3: modem_b),
  replaces topaz's HyperOS offset tables; 2401 Mi A3 values (carve-out 0x4b000000+0x7e00000, MSA 0x53300000, SMMU SID 0x80, WCN3990
  supply votes over RPM), on by default (`modem=0`/`wifi=0` kill switches), `LAUREL WIFI: on|off:` line; 2402 fallbacks for the
  WLAN.HL.3.0.2 firmware. `op10tool fatls` + `scripts/laurel/modem-fw-check.sh` (host model of the parser: stock NON-HLOS FAT16,
  420 files, 0 fragmented). Kernel 221 patches, 0 LSE; image `out/laurel/uefi/laurel-uefi-boot.img` in the area-E worktree.
  Details: `docs/laurel_sprout/wifi.md`. No root-image change (the ADT `wlan` node for wifid is in mkadt.py already).
- Not booted. Next (coordinator): boot, read `TopazModem: firmware:`, `smmu:`, `wlan: RPM`, PAS, `wlfw:` lines and `LAUREL WIFI:`;
  then Settings > Wi-Fi. If `off`, the reason names the step (wifi.md "Next").
- Review fixes 2026-11-01 04:56 [V build]: 2400-2404 rebased on origin/laurel-int-1 (232 patches, 0 LSE, kernel sha256 545cab2a18a1c392...):
  FAT bounds, MSA 2 MiB, RPM refusal -> Wi-Fi off, TrustZone/SMMU locks shared with TopazAudio, pool vs XNU RAM check (area A map:
  pool 0xE0000000-0xE1000000 unchanged). `tools/op10tool/tests/fatls-test.sh` all ok. No image built in this round (needs the Mu FD
  with area A's 0101); the coordinator builds it.


## Mi A3: battery, charger, charge mode, power off, thermal + cpufreq built (2026-11-01 04:30, area D, patches 2300-2303)

Done [V build]: 2300 PMI632 SID 2 SPMI reads + owner-checked writes; 2301 `laurel_pmi632.c` (QG gauge, ADC5 NTC, SoC model
with SDAM save, SMB5 input limit + software JEITA, full IOPMPowerSource key set incl. AdapterDetails); 2302 charge-only boot
(cold charger power-on -> no launchd, battery line every 10 s, power key = boot iOS, unplug = power off) + PS_HOLD SHUTDOWN
type before PSCI SYSTEM_OFF (boot showed type 0x01 = warm reset); 2303 OSM governor (Silver + Gold) + TSENS caps instead
of the topaz Gold pin. Kernel builds (223 patches, 0 LSE). Not booted. Details: `docs/laurel_sprout/battery-power.md`.
Next (coordinator): boot; check `LAUREL BATTERY: on: PMI632 QG soc N% ...`, `LAUREL CHARGER: on: ...`, `LAUREL CPUFREQ: on`,
`LAUREL THERMAL: on`, `LAUREL CHARGE MODE: on: normal boot (pon ..)`; iOS battery % = the logged soc; plug/unplug -> the
`LAUREL CHARGER: on: SMB5 usbin ...` line and the bolt; `ctl poweroff` -> `PS_HOLD_RST_CTL 0x01 -> 0x04 (shutdown)` and the
phone stays off; then power off + plug in the charger -> `charger power-on` line (charge mode).
Review fixes built 04:47 (B1 NTC-gated charger + 30 s NTC watchdog, M1 hard JEITA check + boot limits restore, M2-M7, minor
m4-m7): `areaD-k2304`, 223 patches, 0 LSE. Not booted. Table in `docs/laurel_sprout/battery-power.md` "Review".
Safety re-check fixes built 05:01 on laurel-int-1 (MUST 1-3, SHOULD 4-6): `areaD-k2305`, 231 patches, 0 LSE. Not booted.
Unattended-safety follow-up built 05:10 (F1-F5, safe limits before system sleep): `areaD-k2306`, 231 patches, 0 LSE. Not booted.

## Mi A3: Bluetooth SE9 GSI -> FIFO interface (2026-11-01 06:05, branch t3/laurel-bt-se9-fifo, patch 2600)

Observed [V boot 05:52]: rails on, clocks run, SE9 FW 0x20c (UART), then `LAUREL BT: off: QUP1 SE9 FIFO interface is off (GSI
only)`. Cause [V Linux 6.18 geni_load_se_fw]: GENI_IF_DISABLE_RO (0x64) shows the writable SE_FIFO_IF_DISABLE (SE + 0x2008).
Done [V build]: `fifo_if_on` clears it (after DMA mode off, GSI events off, DMA_IF_EN on) and checks 0x64 again. Kernel builds:
241/241 patches, 0 LSE, kcheck syntax OK, kernel.development.sweet.4k sha256 1b59818b... Not booted.
Next: boot; expect `LAUREL BT: geni: FIFO interface was off (GSI from boot): FIFO_IF_DISABLE 0x1 -> 0, ..., RO 0`, then
`uart: 115200 8N1 RTS/CTS, RX on`, `chip: ...` and `on: WCN3990 ...`. Details: docs/laurel_sprout/bluetooth.md.

## Mi A3: first combined phone tests on laurel-int-1 (2026-11-01 05:29-06:15, coordinator)

Observed [V, USB log logs/usblog-20261101-001446.txt]:
- 05:29 (A-J merged, old root): Mu -> UniXNU -> XNU -> SpringBoard. RAM window 3264 MiB (495 MiB below 4 GiB, used last), SPOOL
  6 x 12 MiB, native 720x1560 canvas (first frame 29 s), touch FT3518, keys, audio (ADSP, MAX98937), Wi-Fi WLFW (MAC 00:..:00),
  haptics. Endless vibration (iOS repeat with no stop) -> fixed in 2700 (60 s cap + key stop, eba6218).
- 05:52 (new root: GPU, Metal, audio, BT userland): GPU start hung in the zap PAS call (no shared SCM lock) -> fixed by 2153 (cdec424).
  BT off: SE9 left in GSI mode. Charger `on: ... zone 3 ... charging`, charge mode, thermal, backlight lines seen.
- 06:07 (BT 228d505): the BT thread stalls at the first read of SE+0x2008 (register absent on this QUP [I]); no panic.
- 06:12 (2153): `LAUREL GPU: on: Adreno 610 ... RedwoodGPU published`, `LAUREL METAL: on: Turnip a610 ...`, backboardd GL loaded
  (screen surfaces from the GPU pool), AppleARMBacklight in use, first frame 31 s after boot.
Next: BT in SE DMA mode (t3/laurel-bt-se-dma); GPU upstream sync + SMMU stage-1 + Metal optimisation (t3/laurel-gpu-upstream-opt);
Wi-Fi MAC; charging stays supervised.
## Mi A3: Bluetooth SE DMA mode, no SE + 0x2000..0x2008 (2026-11-01 06:25, branch t3/laurel-bt-se-dma, patch 2600)

Observed [V boot 06:07, 228d505]: `LAUREL BT: geni: QUP 0x20000000 ...`, then no BT step line for 4 min, no panic
(`fifo_if_on` read/wrote SE + 0x2008/0x2004). [I] The access to 0x2008 stopped the CPU. [V source] Only mainline's SE
firmware loader writes these registers (for an SE with no firmware); the 4.14 laurel kernel never does and drives the BT port
in SE_DMA. Done [V build]: `fifo_if_on` removed; FIFO interface off -> SE DMA mode (new laurel_bt_dma.c: apps SMMU identity
for the QUP1 stream 0x143, 4 KiB TX + 2 KiB RX in the modem pool, polled TX/RX, RX ended by the stale timeout, faults ->
`off: <why>`). Kernel build: 242/242 patches, 0 LSE, kcheck syntax OK, kernel.development.sweet.4k sha256 3adfb8a1b055601b...
Not booted. Next: boot; expect `TopazModem: smmu: QUP1 Bluetooth identity (sid 143 mask 0) ... -> OK`,
`LAUREL BT: geni: FIFO interface off (boot left GSI): SE DMA mode, ...`, `uart: 115200 8N1 RTS/CTS, SE DMA, RX on`, `chip:`,
`on: WCN3990 ...`. If `off: SE DMA TX does not finish with CTS ignored`: SE DMA is blocked with the FIFO interface off (then
GPI DMA is the only path). Details: docs/laurel_sprout/bluetooth.md "SE9 left in GSI mode".

## Mi A3: phantom key presses fixed in the kernel (2026-11-01 06:40, branch t3/laurel-spmi-phantom-keys, patch 2710)

Observed [V, USB log, boot 06:17]: power + vol-down / vol-up "presses" every 10 s with nobody at the phone; SPMI status 0x9
(DROPPED). Cause: keys, battery/charger and vibrator used the SPMI arbiter without one lock [V source; I hardware model].
Done: one SPMI core in sweet_spmi.c (one lock, one channel map, status check, timeout), all users moved to it; keys need 2
agreeing clean polls. Built 243/243, 0 LSE (sha256 94981b65...). Not booted.
Next: boot it; leave the phone untouched 5 min: no `SWEET KEYS: key=` line; `LAUREL SPMI: on: ... users: pon keys battery
haptic; spmi errors ...` and the 5-min `LAUREL BATTERY` line show the error counts.

## Mi A3: Apple-logo "GL stall" = lsd's first LaunchServices seed; ADT MACs + GPU watchdog 2155 (2026-11-01 06:45, branch t3/laurel-gl-stall)

Observed [V, logs/usblog-20261101-001446.txt, SMP samples decoded with scripts/debug/smp-symbolize.sh]: in every boot of the
root of 05:41 (GL on or off) SpringBoard waits in a sync XPC to lsd (`_LSCopyServerStore`, from Control Center's module
repository) and stops after `IOK SpringBoard: path IODeviceTree:/buttons`; backboardd is idle except one thread in the same
lsd call. Frames 1-3 are the boot scene; no GPU wait. Same stack in the 05:52 boot without GL.
Cause [I, strong]: the ADT has no /chosen mac-address-wifi0/-bluetooth0/-ethernet0 and RedwoodWLAN is no IONetworkController,
so MobileGestalt waits 5 s per WifiAddress answer during lsd's first seed of the fresh /var (negroni 1697e28, ios-flame).
Done [V build]: scripts/laurel/mkadt.py writes the three MACs; kernel 2155 GPU watchdog + sysctl kern.laurel_gpu; bbd_wrap.c
skips the GL loader when the kernel says the GPU is off. kernel-linux.sh 243/243 patches, 0 LSE; gpu-userland.sh 0 LSE.
Not booted. Needs: new boot image (ADT + kernel) and `/usr/libexec/backboardd` (the wrapper) in the root (root-add-gpu.sh).
Next: boot; expect `SWEET AMFI: user client selector 6 from lsd` ~1 s after `exec lsd`, SpringBoard past `/buttons`,
redwood-gl frames past 3 and `SWEET FPS` lines. If not: `sweetsample=SpringBoard,backboardd,lsd`, then
`scripts/debug/smp-symbolize.sh LOG lsd`.

## Mi A3: cellular step 1 built (2026-11-01, branch t3/laurel-cellular-dual-sim, patch 2760; build + host test, NOT BOOTED)

Path decision (docs/laurel_sprout/cellular.md §4): (c) kernel QMI client + IPA + a data interface first, (b) a status-bar
bridge later, (a) a fake AppleBasebandPCI for CommCenter last (CommCenter needs Apple's PCIe QMUX, BBUpdater boot and Apple
QMI services [V strings / I effort]).
Done [V build, V host test]: `bsd/dev/laurel_cell.c` on TopazModem's QRTR: UIM card status for SIM1 + SIM2, hot swap,
provisioning (first card -> primary GW, second -> secondary GW), DMS revision + operating mode, NAS client per subscription,
WDS profile-1 APN; one line `LAUREL CELL: on|off: ...`, sysctl `kern.laurel_cell`, kill switch `cell=0`. 246/246 patches,
0 LSE. `scripts/laurel/test-cell.sh` 8/8.
Not done: radio ONLINE / registration / signal (self-check `ipa_up` is false: no AP IPA side; scion: ONLINE without it crashed
the modem, which here also stops Wi-Fi), data, SMS, voice, iOS UI. No root change.
Next: boot; expect `LAUREL CELL: on: SIM1 present (USIM ready), SIM2 ...; modem low power; radio off: ...` and Wi-Fi unchanged.
Then step 2: IPA v4.2 AP side (RPM IPA clock, PAS 15 from vendor, SMMU 0xE0, QMI 0x31 INIT_MODEM_DRIVER) -> `ipa_up` ->
ONLINE -> registration + signal.

## Mi A3: GPU-drawn iOS UI runs without panic (2026-11-01 07:21-07:28, coordinator)

Observed [V, usblog 07:20:52 boot, laurel-int-1 at e2c29b4 + EXTRA_ARGS=gpu_smmu=0, root of 07:16 with GPU-Opt userland]:
- `LAUREL GPU: on`, `LAUREL METAL: on: Turnip a610 ...`, backboardd GL; first frame 29 s after boot.
- 7+ min of use (103 touch/key events, 160 logged GL frames): no panic; pool 2156 lines `0 frees refused, 0 lost, 0 bad
  ranges passed over`; SWEET FPS up to 61 frames/s while scrolling, 17-50 in heavier moments (longest gap up to 474 ms).
- Thermal 37 C idle. Only daemon crashes: syncdefaultsd, webbookmarksd (no network).
Open: 2154 SMMU stage-1 faults on the CP ring and turns the GPU off (fix agent t3/laurel-smmu-pool-bt), so tests use
gpu_smmu=0 until then; BT rampatch check rejects apbtfw10.tlv (same agent); RTC/status bar (2720 + root-statusbar.py, merged,
needs a root rebuild); cellular step 1 (2760) merged, step 2 IPA in progress.
## Mi A3: GPU stays on after a failed stage-1 check; Bluetooth picks cmbtfw12 (2026-11-01 07:45, branch t3/laurel-smmu-pool-bt, 2157 + 2600)

Observed [V boot 07:19, usblog-20261101-001446]: `LAUREL GPU POOL: free of 0x1000000+0xef000000 refused` (2154's VA seed through
2156's checked pool free), the stage-1 check's first ring fetch faulted at 0xc0020040 (terminated: CP hung), the fallback did not
recover the CP, `LAUREL GPU: off`. Same kernel with gpu_smmu=0 (07:21): GPU on. BT: chip product 0x000f rom 0x0102, `off: the
rampatch is for another product` (apbtfw10.tlv = product 0x000a).
Done [V build, 248/248 patches, 0 LSE, no warnings in the changed files; sha256 64df80382164...]: 2157 `va_seed()` (no pool free),
check steps logged with the decoded fault, stall-on-fault during the check + retry in pass-through, `cp_recover()` (fence, or power
cycle + zap resume + CP start), Linux's context-bank values. 2600/2601: names from the EDL ROM version (Linux), the rampatch header
picks the file (cmbtfw12.tlv + cmnv12.bin for this chip), NVM speed byte from the file. [V host test] scripts/laurel/bt-fw-test.sh.
Not booted. Next: boot; expect `LAUREL GPU SMMU: check 1..2`, then `on: stage 1` or `check failed: ... FSR .. (..) ..` +
`pass-through: the CP goes on` + `LAUREL GPU: on ... SMMU pass-through`; BT `fw: cmbtfw12.tlv ...` and `on: WCN39xx product 0x000f`.
The failure line's FSR/FSYNR0/walk text decides the next table fix. Details: docs/laurel_sprout/gpu.md "Stage-1 check failure",
docs/laurel_sprout/bluetooth.md "The chip is WCN3950 family".

## Mi A3: SMMU stage 1, Bluetooth, RTC, SIM status on the phone (2026-11-01 07:45, coordinator)

Observed [V, usblog boot 07:44:5x, laurel-int-1 8660387, root of 07:16]:
- `LAUREL GPU SMMU: on: stage 1, context bank 0 ... any process may open the GPU` (checks 1-4 passed, fences 56/61 us);
  `LAUREL GPU: on: ... SMMU stage 1`; `LAUREL METAL: on`.
- `LAUREL BT: on: WCN39xx product 0x000f rom 0x0102, cmbtfw12.tlv + cmnv12.bin, 3000000 baud` (SE DMA, WCN3950 family).
- `LAUREL RTC: saved offset ...` after the host settime.
- `LAUREL CELL: on: SIM1 present (USIM detected), SIM2 absent; ... radio off: no AP IPA driver yet`; NAS1 BIND_SUBSCRIPTION error
  0x3, DMS GET_OPERATING_MODE error 0x4a (to check in step 2).

## Mi A3: camera step 2 built: rear RDI raw frames + picture over USB (2026-11-01, branch t3/laurel-camera-rdi, patch 2771; NOT BOOTED)

Done [V]: kernel patch 2771 (CSIPHY1 D-PHY, CSID1, ISPIF, VFE0 RDI0 write master into 3 GPU-pool buffers, SMMU identity
0x420/0x421, MCLK 24 MHz from GPLL9, sensor init + 1280x720 tables parsed at run time from the stock library on the root,
simple AE, 2 s self-check with fps line, `camframe`/`caminfo`/`camread` on the USB command server); root step
`scripts/laurel/root-camera.sh` (in root.sh, CAMERA=0 skips); host `op10tool camframe` + `scripts/laurel/cam-frame.sh`
(RAW10 -> PNG with demosaic). Build 252/252 patches, 0 LSE, kernel sha256 dcbae3a4...; host tests pass (cam-test,
cam-frame-test). Details: docs/laurel_sprout/camera.md section 8.
Next: owner flash (root with tables + boot image), read `LAUREL CAMERA: rear stream:` and run `scripts/laurel/cam-frame.sh`;
then step 3 `/dev/negronicam` (NCFRAME1) and step 4 the iOS plug-in.

## Mi A3: camera steps 3 + 4 built: Camera app path (2026-11-01, branch t3/laurel-camera-app, patch 2772 + 2903; NOT BOOTED)
Why the app did not open: the process waits for capture servers that nobody starts [V log + root setting; I the wait itself, negroni chain]. Done: `/dev/negronicam` (NCFRAME1 by read, session only while a client reads, exposure + gain + frame length, 30 fps),
TCC tokens (2903), plug-in built on Linux with `userland/laurel/camera/build.sh`, 8-bit preview scaler, `root-camera.sh` (plug-in), `mkadt.py` (camera nodes), `scripts/laurel/camera-cache-check.sh` PASS, cam-test OK (mock client).
259/259 patches, 0 LSE, kernel sha256 04a59dd9.... Not done: front (S5KGD1 tables do not parse), user-space mapped buffers (ENODEV in XNU; read instead).
Next: owner flash (root + boot image), open Camera, compare `LAUREL CAMERA:` lines; expected preview + photo [I]. Details: docs/laurel_sprout/camera.md section 9.
## Mi A3: brightness slider fix (2201) + flashlight (2780 + LaurelFlashlight.driver) built (2026-11-01 08:10, branch t3/laurel-brightness-torch; build only, NOT BOOTED)

Brightness [V log 07:27, V DT, V Linux source; cause I]: the slider values were sent (the missing `panel level` lines are
the 8-line log cap) but in LP mode with no DMA line; the Samsung s6e8fco DT sends brightness/on/off in HS and Linux
schedules each command DMA at the front-porch line (DSI_DMA_SCHEDULE_CTRL 0x100). 2201 now does both per panel, with a
start self-check fallback (unscheduled, then LP). Also: one blWork at a time (THREAD_CALL_OPTIONS_ONCE), no stale fade
step, wake at the user's level, one line per settled value. No ambient light sensor for iOS (stk3x3x on the ADSP hub):
`root-brightness.py` sets BKEnableALS false. Details: docs/laurel_sprout/brightness.md.
Flashlight: 2780 PMI632 flash LED torch (SID 3 0xD300, LED1, 12.5..150 mA, auto-off 600 s, off at OTST/fault, quiesce at
halt/panic, `torch=0`), `/dev/laureltorch`, `/product/camera flash` (Control Center button) only with the plug-in;
`userland/laurel/flashlight` (mediaserverd: FigFlashlight vendor hook + FigFlashlight server). Details:
docs/laurel_sprout/torch.md.
Also: 2760's bsd/conf/files hunk refreshed (it did not apply after 2720 on laurel-int-1).
Build [V]: kernel-linux.sh 252/252 patches (merged laurel-int-1 16b1a73), 0 LSE, no warnings in the changed files, kernel.development.sweet.4k sha256
468b1abc685ceb351d8a87e13f9cb40d6edb2d3392ca602f7992079ea25195e9. LaurelFlashlight.driver built (userland/laurel/flashlight/build.sh).
Next: boot image with this kernel + root rebuild (root.sh: root-flashlight.sh + root-brightness.py; owner approves the
userdata flash). Check `LAUREL BACKLIGHT: on: ... DCS HS, DMA at line 1567`, move the slider (panel must follow, one
`brightness N of 255 ... -> DBV` line per stop), `LAUREL TORCH: on:`, `LAUREL TORCH UI: on:`, `LAUREL FLASHLIGHT: on:`,
Control Center flashlight tap. If the panel still does not follow: DCS read 0x52 (negroni 0293 port).

## Mi A3: IPA handshake crash analysed, GSI channels added (2026-11-01, branch t3/laurel-ipa-gsi, patch 2782; NOT BOOTED)
Phone [V]: modem assert `Failed to initialize GSI channel: CHID 1 errval 6` 105 ms after INIT_MODEM_DRIVER stopped Wi-Fi. Cause [V stock + mainline, I for this
assert]: on IPA v4.2 the AP must allocate all GSI channels, the modem's too; 2780 did not. Done: 2782 (channels, self-checks before any message to the modem), host tests
gsi_test + gate_test. Not done: ipa=0 stays in uefi-image.sh + shim.sh: no self-check can see a modem firmware assert.
Next: owner test `IPA_TEST=1 scripts/laurel/uefi-image.sh` + `fastboot boot`; evidence list in docs/laurel_sprout/cellular.md section 8. Then laurel_cell.c: read the DMS mode
again (one old read blocks ONLINE).

## Mi A3: flashlight one owner (2783, camera plug-in) + backlight reads the panel back (2871) built (2026-11-01 19:30, branch t3/laurel-torch-bl-fix; build only, NOT BOOTED)
Owner, boot 18:40: Control Center flashlight and brightness slider do nothing; camera works.
Flashlight [V log + code]: the button reaches the camera plug-in's stream, which only logged `NOT TAKEN`; LaurelFlashlight.driver saw the camera
plug-in's hook on the same method and turned itself off. Now: the camera plug-in writes `/dev/laureltorch`, LaurelFlashlight.driver only in a root
without it, the kernel's start results repeat at the first open. Cap 150 mA, auto-off, thermal off unchanged.
Brightness [V log]: the slider reaches the kernel, 52 writes for one drag, 0 failed; root-brightness.py broke nothing; `brightness-nits = 0` and the
cap do not stop it. [U] Why the panel does not follow: not settled by the log. 2871 aligns the send with Linux (FIFO watermarks off, line + 1, FIFO
reset, `53 20` at start), adds the TPG FIFO path, reads 0x0A / 0x52 / 0x54 back at start and at each settled value and picks the way that works.
Build: 273/273 patches (72 laurel), 0 LSE, kernel.development.sweet.4k sha256 2271c044eb39beaa10a0cb7a99aa0e9981357625caf3ef99e21f8b5d3c173030; NegroniCamera.driver sha256 12e332d07c6555b0..., LaurelFlashlight.driver built.
Next: boot image with this kernel + root rebuild (root-flash-test.sh; owner approves the flash). Lines and the decision table: docs/laurel_sprout/brightness.md, torch.md.

## Mi A3: camera quality (2026-11-01, branch t3/laurel-camera-quality, patch 2773; NOT BOOTED)
Owner on the first working Camera app: "buggy, no proper focus or clarity". Found in the log [V]: real line time 2.57x shorter than the library says (fixed from the PLL registers), mediaserverd killed at 2.6 GB every 10 s (Metal out of mediaserverd [I]), a jump to data at the frame handler (guarded, cause [U]), 19 % of frames lost to copies (4 buffers). Added: 1920x1440 preview window at 96 % of the sensor with fallback to stock modes [I that the sensor takes it], 4000x3000 photograph mode switched without a power-down, DW9800W focus over CCI + contrast AF with AFStatus in the metadata, colour matrices + lens shading from the phone's stock tuning at the root step, 5x5 demosaic, sharpen, chroma filter. Open [U]: frames at black level in all sessions of that boot. Build 274/274, 0 LSE, cam-test OK, cache check PASS. Next: inventory again, root + boot image, owner test. Details: docs/laurel_sprout/camera.md section 10.
## Mi A3: Wi-Fi stalls, page load and bars (2026-11-01, branch t3/laurel-wifi-stall, patches 2880-2886; build + host test; booted 20:02: on lines only, no join in that boot, so no traffic has crossed them)
Owner: "fast.com and speedtest do not load fast enough, you made it worse, the signal level is wrong." Log 19:07.
Causes [V log + code]: every lost frame (13715) = the one 128-frame Tx queue full, shared by all flows; scans 0.5 s and 7 s after the join, over the first fetches of a page; bars frozen at the join (iOS event 39 was never sent).
[I] The fall after the burst = the speed test's end, the 16 s line gap = the line's own rule; [I] in the 40 s before the burst the CPU, not the link, was full (drop 0, 1.9-20 Mbps): crash loops and WebKit are the next suspects. The log has no DNS or TCP counters: new `path` line.
Done: en0 output queue with flow control (kill switch wifi_txq=0), Rx 1 copy, Tx 2 copies, batches, 128 Tx slots, ring 512, Rx/Tx turns, no scan in the first 30 s or under any traffic, smoothed signal (beacons first), event 39 + RSSI_BOUNDS, drops by reason, thread cost, request log per link.
Build: 280/280 patches (79 laurel), 0 LSE, kernel.development.sweet.4k sha256 f6d6b604dfe6cb05b9eaa4052b45854765b6b39e606add3101509d386cf2ebd6; wifi-phy-test.sh passes.
Next: boot with this kernel; docs/laurel_sprout/wifi.md "Test": read `link` + `path` during fast.com; compare wifi_txq=0.

## Mi A3: black screen after the lock, boot 19:34; display off keeps the panel awake (2026-11-01, branch t3/laurel-wake-blank, patch 2872; booted 20:02: LAUREL PANEL: on; lock and wake not checked in a log)
Owner: phone locked, screen never came back; iOS and the kernel alive. [I, strong] 2871's FIFO made 0x28/0x10 reach the panel for the first time; 0x11 + 0x29 with video running do not bring the picture back (power mode 0x9f -> 0x9d at the first sleep [V]). Suspects timing, frames, DBV: refuted by code and log; table in docs/laurel_sprout/brightness.md.
Change: display off = fade to DBV 0 + black frame, no 0x28/0x10. Wake: one 0x0A with the light out, sleep-out sequence once only if the panel is off. Last direct iOS frame shown again if none is new. No reads after the start except that check.
Build: 276/276 patches (75 laurel), 0 LSE, kernel sha256 9e57a0b5f9e35f81.... Next: boot image (`scripts/laurel/uefi-image.sh`) with this kernel, owner approves the flash, test in brightness.md. Open: real panel sleep (video stop, reset, whole on-command set, video start) if the battery needs it.

## Mi A3: GPU and CPU clocks (2026-11-01, branch t3/laurel-clock-perf, patches 2890-2892; NOT BOOTED)
Owner: "fix Metal fully and GPU and CPU acceleration fully". Done [built, host test only]: GPU 300 <-> 600 MHz by demand with MX+CX NOM held, clock read back, thermal cap; DDR read and vote rule; 5 s line split (the measured clock never reached a log: line cut at 255 bytes); CPU governor 120 ms to the top (was 300 ms, host only), touch and GPU-work holds, Silver floor row 0, time per row, `LAUREL CPU TOP`; three restart-loop jobs out of the root.
What "fully" can mean on this GPU [I]:
| Part | Gain to expect | Limit |
| --- | --- | --- |
| GPU 600 MHz | GPU time per submission up to half (3.6-10 ms now) when the core clock is the limit; less if DDR is the limit. Fewer late frames in heavy scenes. Not measured | A610 stock top is 950 MHz, 1 CCU, 132 KiB GMEM: a low-end part |
| CPU ramp + holds | First frames after a touch: up to 6.7x more CPU clock in the first 120-300 ms. No change in steady scrolling if Gold was already high | A73 at 2016 MHz |
| DDR vote | Unknown until `LAUREL DDR` is read: zero if DDR is already at 1017+ | RPM scaling |
| Dropping 3 jobs | Under 2 % of a Gold core; idle power | - |
Stays CPU-bound [V profile lines + I]: about 9 ms of CPU per frame (3 in GL, 6 outside: CoreAnimation), "handing on" 2.4-5.7 ms, metal2vulkan encode and shader translation, first-use shader compile. A clock raise does not remove these; the GPU rarely holds the CPU back ("waiting" 0.5-0.9 ms). Metal "fully" is not a clock matter: 8 of 21 QuartzCore shader pairs and 4 of 7 kernels still fail in m2vtest (19:36:55) [V], which metal.md tracks.
Next: kernel + root + boot image, owner test (gpu.md and battery-power.md "Test"). Then decide from the lines: PLL levels, RPM scaling, PSCI idle states.

## Mi A3 area I: debug channel, calendar, generic negroni ports (2026-11-01 04:50) [built, not booted]

Done [V build]: patches 2900 (console head buffer, live log from byte 0 after the host's first frame, `ctl log` = all,
boot log area N-28673 in the negroni 0367 format with `bootlog`/`bootlog read` and /dev/laurelbootlog, panic + end marks),
2901 (PM6125 RTC calendar, saved offset, USB `settime`/`time`), 2902 (UFS solid state), 2903 (sandbox privileges
1002/1007/12000 + extension tokens), 2904 (negroni AppleKeyStore: missing selectors + software passcode), 2905 (USB poll
200 us / 4 ms / 20 ms, TX queue 128, ENDTRANSFER at bus reset), 2906 (wired guard for IOSurfaces). Kernel 226 patches,
applied=226, 0 LSE. Host: userland/ssh builds on Linux (fetch-sdk.sh + build.sh), root.sh installs SSH, phone-ssh.sh,
log-pull.sh reads the boot log area, op10tool texts. Not done: 0288 cpuidle, 0361 ring, 0366 watchdog.
Next (coordinator, phone): boot it; check the LAUREL BOOTLOG/CALENDAR/SANDBOX/AKS/USB POLL/WIRED/SSD lines and that the live
log starts with the first kernel line; `op10tool bootlog`; rebuild the root with SSH and flash it (owner approval).

### Area I review fixes (2026-11-01, rebased on laurel-int-1)

M1 live-log burst limit (half the TX queue, 1 ms per 32 datagrams; ctl replies keep room), M2 patch 2907 (SPMI init
mutex, PON spinlock, try-lock in panic), M3 wired guard: backboardd/SpringBoard exempt, 55 % of the 2100 window
(3264 MiB -> 1795 MiB), m4 flush retry time, m5 `bootlog read` try-lock + busy replies, m6 phone-ssh.sh exit code,
m7 tuning boot-args removed (laurelrtcoff, laurelusb_pollus/_idle_ms/_nohost_ms, laurelaks bit mask, laurelaks_log);
new kill switches laurelusb_poll=0, laurelaks_passcode=0. **Owner-approval exception to the "=0 kill switch only" rule:
`laurelaks_reset=1`** (2904): ignores the stored software passcode for one boot, the only way back into a phone
whose passcode is lost (no SEP, no other reset path). m9 TODO: RTC lane into sweet_spmi.c after area D merges.
m10 host-wait behaviour documented in usb-debug.md.

## Mi A3: camera crash loop, photo path, black frames (2026-11-01, branch t3/laurel-camera-photo; plug-in only; build + mock tests, NOT BOOTED)
Owner: "Photos do not get taken, and the camera flashes in and out." Cause [V]: with Metal off in mediaserverd, Camera.app's filter thumbnail node derefs a nil Metal filter 1 s after each session starts: 6 of 6 crashes.
Done: Metal stays out; hooks 10 + 11 prepare that node without a filter and copy unfiltered thumbnails through the CPU; a photograph with no pool buffer is retried, not counted as given; sharpness without its noise term; no scan in the dark or on a flat sweep; line `picture: no light on the sensor`.
Not fixed, cause [U]: every frame so far holds noise only (mean 0, top 3-10 at up to 133 ms x 16x). Scene or VANA: the next boot in a lit room decides. Never seen on the phone: an `encoded` line, a saved photo, the 4000x3000 mode. Photo file is 4032x3024.
Build: 291/291 patches, 0 LSE; plug-in sha256 320ac73d62013137...; cam-test, cam-leak-test OK; cache check PASS.
Next: root + userdata flash (owner approves), docs/laurel_sprout/camera.md section 11 "Test steps".

## Mi A3: honest build (2026-11-01, branch t3/laurel-build-honest, patch 2912; RESULTS below; NOT BOOTED)
Owner: "a build must never look good when a part is missing". Docs: docs/laurel_sprout/build-honest.md. Audit rows 18, 19 fixed, 22 mostly, 20 listed.
Linker lines [V]: 2 failed links per good build = DriverKit stub rounds. The kernel was new. Real hole found: the last relink can fail and leave the stub kernel.
Done: kernel-linux.sh checks (this run's file, last round, embedded stamp, patches unchanged), patch 2912 boot lines, stamps on kernel, image, root; root.sh preflight, one feature table (12 rows) in the console and in /usr/share/laurel/root-manifest, exit 1 unless a feature has its own =0; no sparse image then; build-all.sh builds all (SSH, audio, BT, firmware new), names each failure; root-flash-test.sh checks before the phone; fsck no longer `|| true`; the race: main() + input hashes.
Build [V, honest-all2, merge commit 66d75a4f47 on 4cbe2ec]: real `build-all.sh`, every stage: exit 0, 294/294 patches, 0 LSE, 2 linker lines (stub rounds), kernel sha256 64e552f178b8780f..., series 8c6e2af34bbd614d, Metal 145 s, check PASS. The first run (honest-all) stopped with `build-all: FAILED: metal` and no new image: this worktree lacked a submodule commit (notes.md gotcha). root-dry-run.sh on a copy of the 20H392 OS image with those stages: PASS, 12 installed, 0 off, 0 missing. build-honest-test.sh 58 of 58; xnutils-test.sh PASS. flash-check on the current ~/op10-apple image: refused (no sidecar). Not run: `sudo root.sh`, any boot.
Next: owner's next `build-all.sh && root-flash-test.sh` needs the `SSH` stage to build once; read the 3 `LAUREL BUILD:` lines. Owner decides on `zet=5000`.

## Mi A3: mediaserverd with Metal (2026-11-01, branch t3/laurel-mediaserverd-metal; root only; built + host-tested, NOT BOOTED)

Owner's decision: Metal in mediaserverd. Done: clients `* -backboardd`; `makeAliasable` real (the filter's prewarm heap: 1 of 20 -> 20 of 20 [V host]); `newBufferWithIOSurface:`, `newCommandQueueWithDescriptor:`; live Metal counts; memory guard in the camera plug-in (a line at each +256 MB with VM tags, counts, busiest thread's stack; 768 MB stops the session's strip and new pipelines). Host leak test on Intel ANV: +0.0 KiB a frame over 3000 frames, 32 pipelines +11 MiB. Evidence: the kill comes 3-4 s after the prewarm, 650+ MB/s, not per frame. **The allocator of the 2.6 GB is still unknown [U]**; Metal may not be the cause. Next: root build, boot, open Camera 2 minutes, read `memory guard:` and `memory at frame` (docs/laurel_sprout/metal.md section 12.5).

## Mi A3: camera: no light in the stream, review + self-check (2026-11-01, branch t3/laurel-camera-light, patch 2784; build + host test, NOT BOOTED)
Result: no code fault explains the dark frames; cause [U]. Rails, delays, MCLK, tables, exposure, gain, pedestal and RAW10 reading equal stock or are right: evidence table in docs/laurel_sprout/camera.md section 12. One stock difference fixed: L12A high power mode vote. New self-check: rails from the pads and the PMIC, register read-back, all table values read back, the sensor's colour bars in memory, raw statistics in the kernel and in the plug-in.
Next: boot image + root flash (owner approves), then the 5 scene steps of section 12: the lines decide scene, path, or the sensor's analog side.

## Mi A3: frame budget after the owner's boot 22:08 (2026-11-01, branch t3/laurel-lag, patches 2913, 2914, eagl 0005, Mesa 0002, plug-in; built + host test, NOT BOOTED)
Owner: 20 fps, touch lag, Astronomy lag and purple, widgets intermittent. Details and every number: docs/laurel_sprout/gpu.md "Frame budget". Observed: the 40 ms "present + latch" and 16300 MHz are wrong lines (fixed); the tick ran at 57 a second against a 60 Hz panel; glFlush 5.9 ms is the largest stage; chronod's `primitive_image` / `primitive_gradient` on `_RB4` are refused and their draws skipped (widgets). Done: tick locked to the panel, one sleep to the latch, touch on the latch edge at 2 ms, hash for `image_of`, zero-copy A008/L008/LA08, `_RB4` by the GPU, seed from clients' GPU writes, direct rendering above 2 tiles, Mesa threads interactive, RenderBox answered family 2 on the 610. Guess: render thread 9-10 ms from 13.1. Not proved: any frame rate; purple cause is unknown (`mean R G B` will say where).
Build [V, c629c23, merge with origin/laurel-sprout 7737e7d]: kernel-linux.sh 300/300 patches, 0 failed, 0 LSE, printf-arg-check OK, kernel sha256 d15aa997c73c15d1..., stamp series 06755d0c455d18b6; Mesa + gpu-userland.sh: libtopaz-gl dc226e3a38555bb4, libOSMesa d5fdc49a1514cdc8, armv80-check 0 on all; metal-build.sh plugin + check: PASS, NegroniMetal 796655fd62d06f0e; host: gpu-surface-test (with `_RB4` contents, image hash 2 million steps) PASS, xnutils-test PASS, build-honest-test 58 of 58; root-dry-run PASS with FEATURES=0 (this worktree has no camera, notch, XNUtils or ssh stages: a full build-all is the next step).
Next: kernel boot image + root (owner approves), one scroll + one Astronomy switch, read the lines in gpu.md "Lines at the next boot".
## Mi A3: cellular reaches iOS, IPA test prepared (2026-11-01, branch t3/laurel-cellular-online, patch 2786, `userland/laurel/cell`; build + host test, NOT BOOTED)
Owner: "Cellular modem is not working or being detected." Docs: docs/laurel_sprout/cellular.md sections 9, 10. Audit rows 3, 4.
Decision [V evidence in 9.1]: (b) SpringBoard bridge built; (c) data next, only after the IPA test; (a) CommCenter stays out (scion: 20 crashes on 2 drivers).
Done: kernel: mode read every 10 s until online (the blocker), NAS bind retries (false SIM2 risk), `part:` line, `kern.laurel_cell_state` with bars only when registered. iOS: `liblaurel-cellbar.dylib` answers for `STTelephonyStateProvider`, so Apple's code makes bars, name and `No Service`.
Not built, and said so: data, SMS, voice, Settings pane content. Modem restart: not realistic blind, reasons in 9.5. A modem assert with `IPA_TEST=1` still stops Wi-Fi for that boot.
Build [V, merged with 80072a9]: 297/297 patches, 0 LSE, printf-arg-check OK, kernel sha256 010bc6a6ebc346dc, series 6affe41bed8fd86f; armv80-check 21 (kernel, same count as before), dylib 0, laurel-springboard 0. test-cell 15/15, test-ipa PASS (vendor image part skipped), build-honest-test 60/60, xnutils-test PASS. Root image not built: no sudo here.
Next: step A then step B of section 10, on the phone.
## Mi A3: camera "heavily buggy, 1 or 2 fps" (2026-11-01, branch t3/laurel-camera-analog, patch 2913 + plug-in; build + host tests, NOT BOOTED)
Results [V boot 22:08]: the pixel array works (22:19:19 max 842, frame 10 max 1023, kernel top 959, real focus curve; older dark sessions were dark scenes: no rail change). The `low swap` kills are the capture audio's silence: guard: malloc large 293 -> 2013 MB in 3.5 s, stack `_createSampleBufferForTimestampedAudioBufferList:` <- `_generateSamples`; Metal flat. Reads 2.5-5 a second in those sessions; backboardd 25-36 fps.
Done: `_silenceFramesFillingDisabled` set in the start hook; fast preview `camera_fast.c` (host 27.6 -> 7.1 ms one thread, same picture); AE capped at 30 fps; session starts at the shortest frame; read() through a write-back alias with clean + invalidate and a self-check; `speed:` lines a second for each stage and node; console opened per line (pid 28 said nothing); guard stacks whole.
Unproven: all phone timing; the graph's own cost (`nodes:`, Espresso [I]); why audio time stamps jump [U]; photo path not exercised; kernel panic hold 22:22 has no reason text [U].
Next: boot + root, owner approval; camera.md section 13 "Test steps". Next fix follows the `speed:` line.

## Mi A3: Wi-Fi up, no page loads; SSH login (2026-11-01, branch t3/laurel-safari-net, patch 2888, `userland/ssh/laurelnet.c`; build + dry run, NOT BOOTED)
Owner: "Wi-Fi is fine, but fast.com and speedtest don't load." Docs: docs/laurel_sprout/wifi.md "No page loads", docs/usb-network.md "ue0 and Wi-Fi", "Login".
Cause [V config and boots, I on the phone]: `usbnetcfg` (new in the root with SSH) gave default route and DNS to ue0, a host without NAT. Queue, link, Safari's crashes: not the cause.
Done: no `usbnetcfg` at boot, USB service without router or DNS, rank Last; `share-internet.sh` runs it; `LAUREL NET:` line; `dns asked N (v6 N)`; repo SSH key, `alpine` fallback without a prompt.
Not done, cause [U]: reason of the two sig 6 crashes: read over SSH now.
Next: owner's test 1 (no build: `usbnetcfg show` + `down` on the running phone), then root + kernel build and flash (owner approves).


## Mi A3: update the root in place, keep /private/var (2026-11-01, branch t3/laurel-root-update; host tests + read-only plan on the phone, NEVER RUN WRITING ON THE PHONE)
Owner: "Flash the latest images, but don't wipe userdata, or just append, so I don't have to reconnect Wi-Fi and whatnot." Doc: docs/laurel_sprout/root-update.md.
Done: `root-delta.py` in `root.sh` (stat snapshot after mkiosroot, delta after the table, `$APPLE/laurel-ios16-root.update`); `root-update.sh` (`--dry-run`, `--list`, `--rollback`, `--after-boot`; driver `rootupdate/`); `update-phone.sh` = `make laurel-update`; `root-flash-test.sh` stays for clean installs.
Results [V, merged with d571276]: root-update-test.sh 94/94 with GNU tools, 94/94 with toybox + dash; build-honest-test.sh 60/60; root-dry-run.sh PASS with AIRPLAY=0 CELL=0 (12 installed, 2 off, 9739 paths, 593 MB; their stages are not built here); first update simulated with the real launchd.plist and /var plists of the 21:57 image. One read-only plan on the real phone, 52 s (root-update.md section 8).
Unproven (root-update.md section 9): the whole write path on the phone, `pmregister`, `ctl reboot`, boot of an updated root; `sudo root.sh` was not run here, so no real payload exists yet.
Next: only when the owner asks (rule: no flash, reboot or write unless asked): build-all + `sudo root.sh`, `scripts/laurel/root-update.sh --dry-run`, then `scripts/bg.sh rupd-phone scripts/laurel/update-phone.sh`.
## Mi A3: radio online + mobile data built (2026-11-01, branch t3/laurel-cellular-radio, patches 2940-2942, `laurel-celld`; build + host tests, NOT BOOTED)
Owner: network first. Phone [V boot 22:50]: IPA handshake passes, no crash, Wi-Fi on; DMS 5 for the whole boot blocked ONLINE. Docs: docs/laurel_sprout/cellular.md section 11 (cause table, risk per step, expected lines, test order).
Done: 2940: no block on mode 5 after 20 s: low power + ONLINE, 6 bounded rounds, each answer one line; mode reason + hardware restricted, DMS indication, modem caps, NAS bind ok line, state keys. 2941: AP pipes 1, 9, 8 (GSI rings, endpoints, QMAP, polled). 2942: DPM, WDA, per-family WDS session, `pdp_ip0`, `kern.laurel_cell_net`. `laurel-celld` + launchd job: the service in configd.
Build [V]: 307/307 patches, 0 failed, 0 LSE, printf-arg-check OK, kernel sha256 10eb748e318af1cf, series 65f59ea3a66db510; laurel-celld + liblaurel-cellbar armv80 clean; test-cell 23/23; test-ipa PASS (vendor part skipped); build-honest-test 60/60; xnutils-test PASS; root-cell.sh on the real 20H392 launchd cache: job in, 524 jobs. No root image: sudo needs a password here.
Facts [V firmware]: LTE at most (`device_config.xml` no NR letter), DSDS L+L, max_active_voice 1. MCFG reads only digests: no activation.
Unproven: ONLINE at mode 5 ([U], the main risk, an assert stops Wi-Fi for the boot); registration; bars with real values; every data step; IPMonitor key names and Wi-Fi-first ranking [I]. Not built: LTE tag, Settings > Cellular, default SIM, network search, SMS, calls, APN setting.
`ipa=0` stays default in uefi-image.sh. Next: normal image, then `IPA_TEST=1` image; section 11.6.

## Mi A3: radio online, registration denied (2026-11-01 23:42, coordinator; last iOS flash, owner moved to Android)

[V, logs/laurel-boot-radio.txt, IPA test image on the 22:xx root] IPA on; `DMS SET_OPERATING_MODE online: ok`, `operating mode online (raw 0)`; `modem radio technologies: GSM,UMTS,LTE` (no 5G); no modem crash in 2 min; `nas1/nas2 BIND_SUBSCRIPTION: ok`.
Then at 23:43:59-23:44:37: card state USIM/7 -> USIM/6, `SIM1 present (USIM illegal), SIM2 present (USIM illegal); modem online; SIM1 registration denied rssi -104; SIM2 registration denied`. Cause unknown.
Owner rule from now on: no flashing unless the owner asks. Code work goes on and is pushed to laurel-sprout.

## Mi A3: Maps black, widgets refused (2026-11-01, branch t3/laurel-metal-black; NOT BOOTED)
Cause proven [V]: wired guard refused 239 surface creates from 23:31:25 (chronod 4), a refused create is a nil drawable. [I] Maps ran under it: Maps has no log at all. Path walked hop by hop, no break by source: gpu.md "Black layers".
Done: kernel 2916 (kept buffers first, 70 % for the app on the screen + chronod, `LAUREL WIRED: who:`, request 0x7b, seed moves of GPU writes push nothing), eagl 0006 + Mesa 0003 (`LAUREL BLANK`). Build: 308/308, 0 LSE, kernel 37beb26901de0f20; libtopaz-gl b1cd72f0449f97ed.
Next (owner decides any flash): kernel + matched root; open Maps with the USB log on, no `usbnetcfg down`; read the table in gpu.md.


## Rule from 2026-11-01 23:42: no flashing the Mi A3 unless the owner asks
The owner moved to a custom Android ROM (`../customronxiaomi`). Code work and pushes continue. Older "next: flash" lines in this file wait for the owner's request. Next test when asked: `scripts/laurel/update-phone.sh` (no userdata wipe; never yet run on a phone) or `root-flash-test.sh` (erases /private/var). Wired-guard fix 2916 and root parts (eagl 0005/0006, Mesa 0002/0003, the RenderBox answer) have not run together on the phone.
## Mi A3: why both SIMs are denied: read-only facts (2026-11-01, branch t3/laurel-cellular-denied, patch 2943; build + host test, NOT BOOTED)
Done: DMS IMEI verdict (no digit kept or logged), NAS reject by radio + domain + cause + network (indication 0x68, GET_SYSTEM_INFO), SIM reject state, selection preference, the moment a USIM turns illegal, rmtfs read/write facts. Cause in the `LAUREL CELL` line and `kern.laurel_cell_state`. Docs: docs/laurel_sprout/cellular.md section 12.
Results [V]: test-cell 26/26; kernel-linux.sh 309/309 on da447e0, 0 LSE, printf-arg-check OK. Decode of app state 6/7 is right. Observed: nothing sent by the AP sets "illegal". **No cause is proven; no attach behaviour changed.** Ranked guess [I]: IMEI, then authentication, then SIMs or network, then DSDS, EFS.
Next: the owner's decision. No boot needed first: do the same SIMs register on Android, do 2 IMEIs show. A boot of an `IPA_TEST=1` image with 2943 names the cause; table in section 12.4.
