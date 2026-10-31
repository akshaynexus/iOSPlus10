# ios-apollo (Mi 10T / 10T Pro, SM8250) as a reference for the Mi A3

Reference clone `external/ios-apollo` (aTechGeekDev/ios-apollo, pinned c0b44006, 2026-10-31; `scripts/setup/get-references.sh`).
It is an **ios-sweet descendant like topaz** (same `sweet*` drivers and boot-args, 171 xnu patches), so its patches sit on
almost the same base as our topaz series and port more easily than the negroni (slop) ones. Status from its README [V]:

| Feature | apollo state | apollo patches | Mi A3 hardware | Port plan |
| --- | --- | --- | --- | --- |
| Bluetooth | works (90 %): scan, pairing, A2DP, HFP, AVRCP | 0136 QCA6390, 0137 address order, 0141 vendor commands, 0142 transport speed, 0143 legacy LE, 0145 faster UART; userland `libsweet-bt` injected into bluetoothd/BlueTool; `sweetbt=6` | WCN3990 over QUP1 SE9 HS-UART (same QCA HCI family) | **port first**: iOS side as is; transport to SE9 UART 0x4c90000, WCN3990 power (regulators + pulse, no BT_EN), firmware crbtfw/crnv from BTFM.bin |
| Vibration | works (75 %): taps, ringtone patterns, duty-cycle limits | 0146 mic/haptic feeder, 0147 haptic limits; `apollo_haptic=5` | PMI632 LDO ERM (SID 3, 0x5700) | port the iOS side + limits; backend = PMI632 LDO on/off + voltage over SPMI |
| Speakers | works (85 %) | 0138 audio DSP boot, 0139 audio port; CS35L41 amps | ADSP + WCD937x + MAX98927 | DSP boot path as reference; codec/amp differ |
| Brightness | works (95 %), smooth fade | 0151 backlight fade, 0154 brightness slider | DCS 0x51 (max 2047) | port 0154 (+0151) |
| Sleep | not started | - | - | - |

Apollo boots like topaz (`fastboot boot` of a shim). The Mi A3 path is moving to Mu-Silicium + UniXNU (docs/laurel_sprout/uefi-boot.md);
the driver patches above are independent of the boot path.

## ios-redfin (Pixel 5, SM7250) - also a reference

`external/ios-redfin` (DenialOfGravity/ios-redfin, pinned 0c4433cf, 2026-10-29), an ios-sweet descendant via ios-flame:
8 cores with DVFS + thermal caps, Metal via Turnip/metal2vulkan, haptics (DRV2624 through the RedwoodAudio actuator),
sound, mic, camera, Wi-Fi from userland. Owner's report (2026-11-01): killing `vmd` (broken without a network/modem)
brought the average CPU load to ~5 %. Not in the pushed repo yet; the same fix is in negroni's
`scripts/ios16/root-tweaks-extra.py` DROP list, which `scripts/laurel/root.sh` now applies (9 jobs removed incl.
com.apple.voicemail.vmd; CA_HEARTBEAT_RATE=60; lsd/widget jetsam 64 MiB; Bold Text off).
