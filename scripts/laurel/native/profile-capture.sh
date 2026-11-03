#!/bin/bash
# Turnip's format table for FD610 from the real driver (vulkaninfo on Mesa's drm-shim, the patched Mesa of the stacks), into scripts/laurel/native/a610-formats.json. No GPU.
#   scripts/bg.sh nmn-formats scripts/laurel/native/profile-capture.sh
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/metal-env.sh"
H=$OUT/ios26/native/mesa-host
TU=$(find "$H/" -name libvulkan_freedreno.so | head -1)
SHIM=$(find "$H/" -name libfreedreno_noop_drm_shim.so | head -1)
W=$OUT/ios26/native/profile-capture
rm -rf "$W"; mkdir -p "$W"
printf '{ "ICD": { "api_version": "1.3.0", "library_path": "%s" }, "file_format_version": "1.0.0" }\n' "$TU" > "$W/icd.json"
(cd "$W" && VK_ICD_FILENAMES=$W/icd.json VK_DRIVER_FILES=$W/icd.json TU_DEBUG=noconform FD_GPU_ID=610 LD_PRELOAD=$SHIM vulkaninfo -j -o a610.json > vulkaninfo.log 2>&1)
python3 -I -c 'import json,sys; f=json.load(open(sys.argv[1]))["capabilities"]["device"]["formats"]; json.dump(f,open(sys.argv[2],"w"),indent=0,sort_keys=True); print(len(f),"formats")' "$W/a610.json" "$REPO/scripts/laurel/native/a610-formats.json"
