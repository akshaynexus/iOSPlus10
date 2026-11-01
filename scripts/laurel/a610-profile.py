#!/usr/bin/env python3
"""a610-profile.py FLOOR.json OUT.json: an estimated Vulkan profile of Turnip (Mesa 25.0.7 + our 0102) on the Adreno 610,
for the host shader check (scripts/metal/host-translate.sh, shader-corpus-test.sh).

It is scripts/metal/a730-profile.py minus what tu_device.cc does not answer for FD610 (freedreno_devices.py a6xx_gen1_low
over a6xx_base [V source, read 2026-11-01]):
  storage_16bit  False -> storageBuffer16BitAccess, VK_KHR_16bit_storage  (a6xx gen3/gen4 only; tu_device.cc:158, 398)
  storage_8bit   False -> storageBuffer8BitAccess, VK_KHR_8bit_storage    (a7xx only; tu_device.cc:157, 414)
  has_sampler_minmax False -> samplerFilterMinmax                         (tu_device.cc:446; not in the A730 list either)
  has_getfiberid False, has_dp2acc as a6xx_base
multiview stays: 0102 answers what TU_DEBUG=noconform answers (userland/laurel/metal/turnip-patches/0102-*). Limits: the floor +
the few that tu_device.cc answers above it and that system shaders need (LIMITS). A source reading [I], not a capture: replace
it with a vkprobe capture when the phone has run one.
"""
import importlib.util
import json
import os
import sys

DROP_FEATURES = {"VkPhysicalDeviceVulkan11Features": {"storageBuffer16BitAccess"},
                 "VkPhysicalDeviceVulkan12Features": {"storageBuffer8BitAccess"}}


# tu_device.cc tu_get_properties: the floor's 0 clip distances and 4 storage images fail shaders that Turnip runs
LIMITS = {"maxTessellationGenerationLevel": 64, "maxTessellationPatchSize": 32, "maxVertexOutputComponents": 128, "maxFragmentInputComponents": 124, "maxTessellationEvaluationOutputComponents": 128,
          "maxTessellationEvaluationInputComponents": 128, "maxClipDistances": 8, "maxCullDistances": 8, "maxCombinedClipAndCullDistances": 8,
          "maxPerStageDescriptorStorageImages": 1024, "maxPerStageDescriptorStorageBuffers": 1024,
          "maxPerStageDescriptorSampledImages": 1024, "maxPerStageDescriptorSamplers": 1024,
          "maxPerStageDescriptorUniformBuffers": 1024, "maxPerStageResources": 1024}
ADD_FEATURES = {"VkPhysicalDeviceVulkan12Features": ("shaderStorageImageArrayNonUniformIndexing", "shaderStorageBufferArrayNonUniformIndexing",
                                                     "shaderUniformBufferArrayNonUniformIndexing")}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("a730", os.path.join(here, "..", "metal", "a730-profile.py"))
    a730 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(a730)
    d = json.load(open(sys.argv[1]))
    (old, prof), = d["profiles"].items()
    features = {block: {k: v for k, v in kv.items() if k not in DROP_FEATURES.get(block, ())} for block, kv in a730.FEATURES.items()}
    for blk, names in ADD_FEATURES.items():
        features[blk].update({k: True for k in names})
    d["capabilities"]["vulkan10requirements"]["properties"]["VkPhysicalDeviceProperties"]["limits"].update(LIMITS)
    block = "laurel_a610_turnip_25_0_7"
    d["capabilities"][block] = {"extensions": {e: 1 for e in a730.EXTENSIONS}, "features": features}
    prof = dict(prof)
    prof["capabilities"] = list(prof["capabilities"]) + [block]
    prof["label"] = "Adreno 610, Turnip Mesa 25.0.7 + 0102 (estimate from tu_device.cc, floor limits)"
    d["profiles"] = {"VP_M2V_laurel_a610_est": prof}
    d["provenance"] = dict(d.get("provenance", {}), laurel=(
        "vk12-floor + Mesa 25.0.7 tu_device.cc features/extensions for FD610 (a6xx_gen1_low); "
        "scripts/laurel/a610-profile.py; an estimate [I], not a device capture"))
    json.dump(d, open(sys.argv[2], "w"), indent=1)
    print(f"{sys.argv[2]}: {old} + {block}")


if __name__ == "__main__":
    main()
