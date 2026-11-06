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
# Turnip's real format table on this GPU (scripts/laurel/native/profile-capture.sh, committed beside this file): the estimate's floor left Depth32Float_Stencil8 out, which RenderBox asks for
import os
formats = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "a610-formats.json")))
d["capabilities"]["m2v_vulkan12_required_formats"]["formats"].update(formats)
# What Turnip answers on this GPU for how a shader ends a fragment and treats floats (tu_device.cc: EXT_shader_demote_to_helper_invocation,
# KHR_shader_subgroup_uniform_control_flow, the float-control properties; values of the capture a610-capture.json). Without them metal2vulkan
# gave native another shader than Turnip for the same key: OpKill in place of demote, and float folding that put CoreAnimation's generic
# fragment program into register spills (196 stp/ldp against 0, docs/laurel_sprout/ios26-native-metal.md section 13).
caps = d["capabilities"]["laurel_a610_turnip_25_0_7"]
caps["extensions"].update({"VK_EXT_shader_demote_to_helper_invocation": 1, "VK_KHR_shader_subgroup_uniform_control_flow": 1})
caps["features"]["VkPhysicalDeviceShaderDemoteToHelperInvocationFeaturesEXT"] = {"shaderDemoteToHelperInvocation": True}
caps["features"]["VkPhysicalDeviceShaderSubgroupUniformControlFlowFeaturesKHR"] = {"shaderSubgroupUniformControlFlow": True}
captured = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "a610-capture.json")))
p12 = d["capabilities"]["vulkan12requirements"]["properties"]["VkPhysicalDeviceVulkan12Properties"]
p12.update(captured["VkPhysicalDeviceVulkan12Properties"])
json.dump(d, open(sys.argv[2], "w"), indent=1)
