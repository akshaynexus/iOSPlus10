#!/usr/bin/env python3
"""a730-profile.py FLOOR.json OUT.json: an estimated Vulkan profile of Turnip (Mesa 25.0.7) on the Adreno 730,
for the host shader check (scripts/metal/host-translate.sh).

It is metal2vulkan's vk12-floor profile (Vulkan 1.2 minimum limits and formats) plus the features and extensions
that Mesa 25.0.7 src/freedreno/vulkan/tu_device.cc answers for an a7xx_gen1 GPU (FD730, freedreno_devices.py:
storage_16bit, storage_8bit, has_hw_multiview). Limits stay at the floor, so a function that passes here passes on
a device with bigger limits. This is a source reading [I], not a capture of the phone: replace it with a
`vulkaninfo --json` / vkprobe capture of Turnip on the phone when one exists (docs/metal-plan.md "Host results").
"""
import json
import sys

FEATURES = {
    "VkPhysicalDeviceFeatures": {
        k: True for k in (
            "robustBufferAccess fullDrawIndexUint32 imageCubeArray independentBlend geometryShader "
            "tessellationShader sampleRateShading dualSrcBlend logicOp multiDrawIndirect depthClamp "
            "fillModeNonSolid depthBounds largePoints samplerAnisotropy textureCompressionETC2 "
            "textureCompressionASTC_LDR textureCompressionBC occlusionQueryPrecise pipelineStatisticsQuery "
            "vertexPipelineStoresAndAtomics fragmentStoresAndAtomics shaderImageGatherExtended "
            "shaderStorageImageExtendedFormats shaderStorageImageReadWithoutFormat "
            "shaderStorageImageWriteWithoutFormat shaderUniformBufferArrayDynamicIndexing "
            "shaderSampledImageArrayDynamicIndexing shaderStorageBufferArrayDynamicIndexing "
            "shaderStorageImageArrayDynamicIndexing shaderClipDistance shaderCullDistance shaderInt64 "
            "shaderInt16 variableMultisampleRate inheritedQueries").split()
    },
    "VkPhysicalDeviceVulkan11Features": {
        k: True for k in ("storageBuffer16BitAccess multiview variablePointersStorageBuffer variablePointers "
                          "samplerYcbcrConversion shaderDrawParameters").split()
    },
    "VkPhysicalDeviceVulkan12Features": {
        k: True for k in (
            "samplerMirrorClampToEdge drawIndirectCount storageBuffer8BitAccess shaderFloat16 shaderInt8 "
            "descriptorIndexing shaderSampledImageArrayNonUniformIndexing descriptorBindingPartiallyBound "
            "runtimeDescriptorArray scalarBlockLayout imagelessFramebuffer uniformBufferStandardLayout "
            "shaderSubgroupExtendedTypes separateDepthStencilLayouts hostQueryReset timelineSemaphore "
            "bufferDeviceAddress vulkanMemoryModel vulkanMemoryModelDeviceScope shaderOutputViewportIndex "
            "shaderOutputLayer subgroupBroadcastDynamicId").split()
    },
    "VkPhysicalDeviceRasterizationOrderAttachmentAccessFeaturesEXT": {
        "rasterizationOrderColorAttachmentAccess": True,
        "rasterizationOrderDepthAttachmentAccess": True,
        "rasterizationOrderStencilAttachmentAccess": True,
    },
    "VkPhysicalDeviceDynamicRenderingLocalReadFeaturesKHR": {"dynamicRenderingLocalRead": True},
    "VkPhysicalDeviceCustomBorderColorFeaturesEXT": {"customBorderColors": True,
                                                     "customBorderColorWithoutFormat": True},
    "VkPhysicalDeviceRobustness2FeaturesEXT": {"robustBufferAccess2": True, "robustImageAccess2": True, "nullDescriptor": True},
    "VkPhysicalDeviceDepthClipEnableFeaturesEXT": {"depthClipEnable": True},
    "VkPhysicalDeviceExtendedDynamicStateFeaturesEXT": {"extendedDynamicState": True},
    "VkPhysicalDeviceExtendedDynamicState2FeaturesEXT": {"extendedDynamicState2": True,
                                                         "extendedDynamicState2LogicOp": True,
                                                         "extendedDynamicState2PatchControlPoints": True},
    "VkPhysicalDeviceVertexAttributeDivisorFeaturesKHR": {"vertexAttributeInstanceRateDivisor": True,
                                                          "vertexAttributeInstanceRateZeroDivisor": True},
}
EXTENSIONS = (
    "VK_KHR_buffer_device_address VK_KHR_dynamic_rendering_local_read VK_KHR_vertex_attribute_divisor "
    "VK_EXT_custom_border_color VK_EXT_depth_clip_enable VK_EXT_extended_dynamic_state "
    "VK_EXT_extended_dynamic_state2 VK_EXT_rasterization_order_attachment_access VK_EXT_robustness2 "
    "VK_EXT_vertex_attribute_divisor VK_ARM_rasterization_order_attachment_access").split()


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    d = json.load(open(src))
    (old, prof), = d["profiles"].items()
    block = "negroni_a730_turnip_25_0_7"
    d["capabilities"][block] = {"extensions": {e: 1 for e in EXTENSIONS}, "features": FEATURES}
    prof = dict(prof)
    prof["capabilities"] = list(prof["capabilities"]) + [block]
    prof["label"] = "Adreno 730, Turnip Mesa 25.0.7 (estimate from tu_device.cc, floor limits)"
    d["profiles"] = {"VP_M2V_negroni_a730_est": prof}
    d["provenance"] = dict(d.get("provenance", {}), negroni=(
        "vk12-floor + Mesa 25.0.7 tu_device.cc features/extensions for FD730 (a7xx_gen1); "
        "scripts/metal/a730-profile.py; an estimate [I], not a device capture"))
    json.dump(d, open(out, "w"), indent=1)
    print(f"{out}: {old} + {block}")


if __name__ == "__main__":
    main()
