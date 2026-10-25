# Plan and status

Status date: 2026-10-25.

## Done

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

- GPU clock root cause (2026-10-25): PERF_TABLE sent MHz, the GMU wants kHz; GPU ran at ~5 MHz (0236 probe). Patch 0237
  fixes the units. Next: boot it, read `gxclk`, then the GL path (scripts/gpu/phone-gl.sh) and Metal A/B.

- Metal at the real clock (2026-10-25 23:35): backboardd on Metal 150 s, no crash, 4.5-8 ms per command buffer,
  up to 83 GPU presents/s, late ticks 0. Next: Metal for all processes (SpringBoard), GL path A/B, zero-copy flip,
  then a GPU DCVS governor instead of the fixed level 12.

## First boot (2026-10-24, 19:48)

- Flash: userdata from fastbootd (45 x 256 MiB, 303 s), then vendor_boot_a, vbmeta_a, dtbo_a,
  boot_a, slot a: all OKAY.
- Screen: the ABL log text, then **DarwinBoot's green bar** ("the kernel entry code ran"), then
  nothing. Debug image (`negronifb_noconsole=0`, `negroniusb=2`): same screen, no USB device.
  -> the kernel stops before its console starts.
- Likely cause: Mu "Kernel RAM" was 0x840000000+0x140000000 (the port's later iOS 17 / 4K value; the
  notes say that setup hangs right after the green bar). The 16K iOS 16 kernel needs
  0x841000000+0x13F000000, so DarwinBoot's window (0x841004000) keeps a 32 MiB-aligned VA-PA delta
  (slop NOTES 2026-10-20). Fixed in `patches/mu/0001-negroni-kernel-ram-16k.patch` (applied by
  `scripts/uefi/prepare.sh`); Mu and both boot images rebuilt.

## iOS 16 boots on the NE2211 (2026-10-24, 20:10)

With the Kernel RAM fix (debug image: `negroniusb=2`, `negronifb_noconsole=0`), the live USB log
(`make usblog`) shows the iOS userland: backboardd ("NEGRONI FB: display on"), SpringBoard
(AppleKeyStore calls), com.apple.datamigrator (first-boot migration), thermalmonitord,
CAReportingService, localizationswitcherd, symptomsd. bluetoothd and fairplayd.H2 are relaunched
every ~10 s (no hardware; the port dropped their jobs in its later root). Next: the screen state,
then the normal image (`make flash-boot`).

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
