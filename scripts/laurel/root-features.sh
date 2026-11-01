#!/bin/bash
# Install every Mi A3 root feature into a mounted root, then write the one table (scripts/laurel/root-manifest.py). root.sh calls it.
#   scripts/laurel/root-features.sh MOUNTED_ROOT --inputs FILE --sidecar PATH
# A step that fails or skips does not stop the next one: each feature gets its row. Exit 1 = a feature is missing (not by its own =0 switch).
# Switches (one each; =0 = off): GPU METAL HEVC AUDIO BT CAMERA STATUSBAR NOTCH CELL TORCH BRIGHTNESS XNUTILS AIRPLAY AWDL SSH. Runs as the user too (test on a copy: no chown).
# A new feature: one `feature` line here, one row in root-manifest.py FEATURES.
set -uo pipefail
R=${1:?usage: $0 MOUNTED_ROOT --inputs FILE --sidecar PATH}
INPUTS=${3:?}; SIDECAR=${5:?}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
L=$REPO/scripts/laurel
STEPS=$(mktemp -d)
trap 'rm -rf -- "$STEPS"' EXIT

# feature NAME CMD...: run one install step, keep its output for the table's reason and its exit code
feature() {
  local n=$1 rc=0; shift
  "$@" 2>&1 | tee "$STEPS/$n.log" || rc=$?
  echo "$rc" > "$STEPS/$n.rc"
}

# GPU user space (docs/laurel_sprout/gpu.md): Mesa + EAGL GL + backboardd loader + the phone's own GPU firmware
feature gpu env GPU="${GPU:-1}" bash "$L/root-add-gpu.sh" "$R"
# Metal path (docs/laurel_sprout/metal.md): NegroniMetal.bundle (Turnip a610 + metal2vulkan) + probes. After gpu: it checks for the backboardd wrapper
feature metal env METAL="${METAL:-1}" sh "$L/root-add-metal.sh" "$R"
# Test option, never the default (docs/laurel_sprout/ios26-metal.md section 6): backboardd on Metal, GL stays the fallback
if [ "${METAL_BACKBOARDD:-0}" = 1 ]; then feature bbdmetal sh "$L/root-add-bbd-metal.sh" "$R"; fi
# HEVC/HEIC: software decoder in VideoToolbox's empty HEVCH8 slot (docs/laurel_sprout/hevc.md)
feature hevc env HEVC="${HEVC:-1}" bash "$L/root-hevc.sh" "$R"
# speaker audio (kernel patch 2500): RedwoodAudio.driver HAL plug-in, VirtualAudio back, BTAudio off
feature audio env AUDIO="${AUDIO:-1}" bash "$L/root-audio.sh" "$R"
# Bluetooth (kernel patch 2600): bluetoothd job back + the BlueTool stand-in
feature bt env BT="${BT:-1}" bash "$L/root-bt.sh" "$R"
# rear camera (kernel patches 2771, 2772): the phone's stock sensor libraries (tables read by the kernel) + the mediaserverd plug-in
feature camera env CAMERA="${CAMERA:-1}" bash "$L/root-camera.sh" "$R"
# status bar at the native 720x1560 @2x screen (2103): UIKit's own provider override = _FixedSplit, else the red rdar:45025538 bar;
# plus the waterdrop as SpringBoard's notch rect (liblaurel-notch.dylib + laurel-springboard). docs/laurel_sprout/rtc-statusbar.md B, C
feature statusbar env STATUSBAR="${STATUSBAR:-1}" NOTCH="${NOTCH:-1}" python3 -I "$L/root-statusbar.py" "$R"
# cellular bridge (kernel patch 2786): SIM, bars, network name in iOS; laurel-springboard above inserts it. docs/laurel_sprout/cellular.md section 9
feature cell env CELL="${CELL:-1}" NOTCH="${NOTCH:-1}" STATUSBAR="${STATUSBAR:-1}" bash "$L/root-cell.sh" "$R"
# flashlight (kernel patches 2781, 2783): one owner: NegroniCamera.driver when root-camera.sh put it in, else LaurelFlashlight.driver
feature torch env TORCH="${TORCH:-1}" bash "$L/root-flashlight.sh" "$R"
# auto-brightness off: no ambient light sensor for iOS (kernel 2201; docs/laurel_sprout/brightness.md)
feature brightness env BRIGHTNESS="${BRIGHTNESS:-1}" python3 -I "$L/root-brightness.py" "$R"
# XNUtils (docs/laurel_sprout/xnutils.md): system app + setuid helper; live stats, Metal and GL switches, power actions
feature xnutils env XNUTILS="${XNUTILS:-1}" bash "$L/root-xnutils.sh" "$R"
# AirPlay self-check (LAUREL AIRPLAY line) + AirDrop on en0 (managed preferences; AIRDROP_LAN=0 skips them). docs/laurel_sprout/airplay-airdrop.md
feature airplay env AIRPLAY="${AIRPLAY:-1}" AIRDROP_LAN="${AIRDROP_LAN:-1}" AIRPLAY_LEGACY="${AIRPLAY_LEGACY:-1}" bash "$L/root-airplay.sh" "$R"
# AWDL for AirDrop with iPhones and Macs: daemon laurel-awdld + job com.laurel.awdl (kernel 2932). docs/laurel_sprout/airdrop-awdl.md
feature awdl env AWDL="${AWDL:-1}" bash "$L/root-awdl.sh" "$R"
# SSH (dropbear on 192.168.7.2:22, dash, toybox, usbreboot, oslogstream; docs/usb-network.md). Host key and known_hosts as root-add-ssh.py.
if [ "${SSH:-1}" != 0 ]; then feature ssh env SSH=1 sh "$REPO/scripts/net/root-add-ssh.sh" "$R"; fi

python3 -I "$L/root-manifest.py" finish "$R" --steps "$STEPS" --inputs "$INPUTS" --sidecar "$SIDECAR"
