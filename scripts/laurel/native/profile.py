#!/usr/bin/env python3
"""profile.py IN.json OUT.json: the A610 profile of the native stack: scripts/laurel/a610-profile.py's estimate, with Turnip's own limits for what its floor makes too small (tu_device.cc tu_get_properties, Mesa 25.0.7, FD610) [V source]. CoreAnimation's dimming kernel dispatches 32 x 32 threads a group: at the floor's limit the translator refuses it. Run with python3 -I."""
import json
import sys

LIMITS = {
    "maxComputeWorkGroupInvocations": 1024,  # FD610: supports_double_threadsize is false
    "maxComputeWorkGroupSize": [1024, 1024, 1024],
    "maxComputeWorkGroupCount": [65535, 65535, 65535],
    "maxComputeSharedMemorySize": 16384,  # cs_shared_mem_size of the device row
}
d = json.load(open(sys.argv[1]))
limits = d["capabilities"]["vulkan10requirements"]["properties"]["VkPhysicalDeviceProperties"]["limits"]
limits.update(LIMITS)
json.dump(d, open(sys.argv[2], "w"), indent=1)
