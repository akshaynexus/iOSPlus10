# negroni patches for the Mi A3: port, adapt or skip

Review of all 190 `patches/xnu/*.patch` (negroni, OnePlus 10 Pro, slop base) against the topaz series
(201 patches, sweet base) used by laurel_sprout. 2026-10-31. [V] read in files, [I] inference.

Base facts [V]: the negroni kernel is plain arm64 (no ptrauth in any patch); kernel atomics are `__atomic_*` builtins,
so `-mcpu=cortex-a53` turns them into LDXR/STXR. slop started as a copy of sweet, but topaz renamed most files
(`Sweet*`, `Topaz*`, `Redwood*`) and the guard is `ARM64_BOARD_CONFIG_SWEET`, not `..._NEGRONI`. So nothing applies
mechanically: each port is re-written on the topaz files as `patches/laurel/xnu/2xxx-laurel-*.patch`.

## Port order

| # | negroni | What | Why on the Mi A3 | topaz file |
| --- | --- | --- | --- | --- |
| 1 | 0200 | no IORTC wait | topaz waits 30 s for IORTC on every boot (topaz NOTES.md:216) | `iokit/Kernel/IOStartIOKit.cpp` |
| 2 | 0390 | IOSurface plane bytesPerRow at +0x10 | topaz writes it at +0x08 (0046:704): multi-planar surfaces (video, YUV) get stride 0 | `SweetSurface.cpp` |
| 3 | 0388 | DisplayPipe dictionaries | topaz publishes `DisplayPipePlaneBaseAlignment` as a number: VideoToolbox image-queue crash | `SweetFramebuffer.cpp` |
| 4 | 0211, 0214, 0213 | power off / restart (PSCI), reboot mode | topaz has no halt/restart path; reboot reason via IMEM 0xc12565c / PM6125 PON | `SweetPlatformExpert.cpp` |
| 5 | 0222, 0386 | sandbox privileges, extension tokens (ops 5/6) | tccd/Camera authorization, identityservicesd | `bsd/kern/sweet_amfi.c` (conflicts with 0050) |
| 6 | root tweaks | daemon drop list, lsd jetsam 64 MiB, FBLaunchWatchdogScale, Bold Text guard | daemon loops, CPU burn, apps not opening | root image script |
| 7 | 0272, 0271, 0276, 0365 | charger (SMB5) + IOPMPowerSource % + SoC | PMI632 = same SMB5 map, SID 2; topaz 0091/0148 drive I2C chips the Mi A3 lacks | `SweetBattery.cpp`, `sweet_spmi.c` |
| 8 | 0204 bit 0 | UFS solid-state flag | no HFS defrag/hot-file work on flash (bit 1 is 16K only) | `sweet_ufs.c` |
| 9 | 0332, 0333, 0336, 0337 (+0330, 0331, 0334, 0335 adapted) | Bluetooth: iOS side (H4 kernel control, /dev/uart.bluetooth, /dev/btwake, VSC answers) + WCN3990 UART/HCI | the only proven path from a non-Apple controller to bluetoothd (negroni: "Bluetooth works") | new `sweet_bt*.c`, ADT `bluetooth` node |
| 10 | 0301, 0302 | vibrator IOService + UI haptics node | topaz userland already writes `/dev/redwood-haptic`; backend = PMI632 LDO ERM (SID 3, 0x5700) | new `SweetVibrator.cpp`, `sweet_haptic.c` |
| 11 | 0221-aks-passcode | software keybag passcode | lock screen and passcode | `SweetKeyStore.cpp` |
| 12 | 0203, 0212 | calendar from PM6125 RTC | correct time before NTP | `SweetPlatformExpert.cpp` |
| 13 | 0280, 0283, 0284 | thermal (TSENS) + cpufreq governor | topaz runs Gold at max with no thermal limit (0094) | new `sweet_thermal.c`, `sweet_cpufreq.c` |
| 14 | 0361, 0366, 0282 | USB throughput, reconnect | debug loop | `sweet_usb.c` |
| 15 | 0397 | GNSS QMI LOC client | reuse topaz modem boot (0113-0122) | `TopazModem.cpp` |

Also ADAPT later: 0220 (AKS selectors topaz lacks), 0210/0360 USB command server, 0367 UFS boot log,
0398 framebuffer blend/scale, 0399 wired-memory guard, 0288 PSCI cpuidle (trinket idle states), 0382 adaptive polls,
0297 mmio-try, 0387 torch (PMI632 flash), 0253 refresh step, 0363/0378 (only if laurel moves to Mu + UniXNU).

## Skip [V]

GPU 0230-0237, 0281, 0285-0287, 0298, 0384, 0389, 0402 (Adreno 730 / GMU / 120 Hz); topaz has its own A610 stack.
Display 0250-0259, 0267-0269, 0275, 0292-0296, 0364, 0391 (SM8450 DPU, VRR; topaz 0104-0106/0143/0948 cover the rest).
Audio 0240-0249, 0400 (SM8450 + TFA9874). Wi-Fi 0260-0266, 0320-0329, 0339-0345 (WCN6855 PCIe/ath11k; topaz 0113-0130
+ 0900 work on WCN39xx). Camera 0310-0318, fingerprint 0350-0354, SLPI 0376, haptics 0300/0303 (PM8350B LRA).
Charger 0270 (SPMI v7), 0273/0274/0368-0374/0385 (ADSP charger PD, VOOC). 0201/0202/0205/0221-amfi/0223/0257/0289
(topaz has the same or better). 0362 (diagnostic only). 0383 (RPMh). 0401 (DarwinBoot RAM window). 0395 placement
(assumes one SMP pset; topaz 4K uses Edge P/E) - only its frequency policy is worth adapting.

## Userland / root image

PORT: `scripts/ios16/root-tweaks-extra.py` drop list (fairplayd.H2, vmd, ReportCrash, spindump, tailspind, aggregated,
activityawardsd), ExtensionKit cache signing off, `FBLaunchWatchdogScale` 3, lsd jetsam 64 MiB; `root-tweaks-boldtext.py`;
`userland/bluetooth` + `scripts/bt/*` + ADT bluetooth node; `userland/ssh` + `scripts/net/*`; `userland/screenshot`,
`userland/uiopen`. ADAPT: `userland/rebootapp` (after 0211), `userland/location`, `userland/flashlight`.
SKIP: `userland/audio` (topaz `audio_plugin.c` has the same devices), camera/fp/metal/negronigl/turnip/gpu-policy.

## Risks

- SM6125 uses RPM (SMD), not RPMh: every rail/clock vote goes through topaz `TopazRpm` (0145).
- SPMI: topaz/sweet `sweet_spmi.c` is arbiter v5, read-only, and hard-codes core 0x0c440000 (SM7150, 0062:490).
  The Mi A3 arbiter is core 0x1c40000 / chnls 0x1e00000 / obsrvr 0x3e00000: fix before battery, RTC, haptics; add a
  write path with an owner check (as negroni 0270/0272).
- Hot conflict files: `SweetFramebuffer.cpp` (39 topaz patches), `SweetSurface.cpp` (27), `sweet_amfi.c`, `sweet_usb.c`,
  `SweetBattery.cpp`, `osfmk/arm64/sleh.c` (topaz 0081 LSE emulation).
- Licences: `negroni_cpuperf.c` (0395) is GPL-2.0-only; HackiOS-derived code is APSL/MIT: keep notices.
- Bluetooth [I]: WCN3990 has no BT_EN (regulators + power pulse, Linux `hci_qca` wcn399x), firmware `crbtfw*.tlv` /
  `crnv*.bin` from the `bluetooth` partition (`BTFM.bin` in the stock ROM).
- Haptics [I]: an ERM spins up slowly; short taps need a minimum on-time.
