/*
 * vkprobe: stage 0 of the Metal path (docs/metal-plan.md). Opens Turnip (libvulkan_freedreno.dylib) with dlopen
 * (iOS has no Vulkan loader), enumerates the instance and the physical devices, prints what metal2vulkan needs
 * (API version, driver, memory types, queue families, the extensions and features of docs/metal-design.md
 * "Vulkan requirements"), and with --clear runs one GPU job: clear a 64x64 RGBA8 image, copy it into a
 * host-visible buffer and check every pixel.
 *
 *   vkprobe [--icd PATH] [--clear] [--all-ext] [--quiet]
 *     --icd PATH   the Turnip dylib (default: $NEGRONI_TURNIP, then the copy inside NegroniMetal.bundle)
 *     --clear      submit a clear + copy and check the result (needs the kernel GPU user client)
 *     --all-ext    list every device extension, not only the required/optional ones
 * Exit code: 0 = all requested steps passed, 1 = a step failed, 2 = no ICD / no device.
 * Output lines start with "vkprobe:"; "PASS"/"FAIL"/"MISSING" are stable words for scripts.
 */
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>

#define DEFAULT_ICD "/System/Library/Extensions/NegroniMetal.bundle/libvulkan_freedreno.dylib"

static PFN_vkGetInstanceProcAddr gipa;
static bool quiet;

#define P(...) do { if (!quiet) printf("vkprobe: " __VA_ARGS__); } while (0)
#define R(...) printf("vkprobe: " __VA_ARGS__)

/*
 * Device extensions metal2vulkan's runtime and the frontend use (docs/metal-design.md "Vulkan requirements").
 * The runtime's floor is Vulkan 1.2 + timelineSemaphore (metal2vulkan 720ef1ce crates/metal2vulkan-runtime/src/enables.rs,
 * error.rs:114); everything else it enables when the device lists it. required = 1: no Metal for CoreAnimation without it.
 */
static const struct { const char *name; int required; const char *why; } wanted[] = {
	{ "VK_KHR_dynamic_rendering", 0, "render passes without VkRenderPass objects" },
	{ "VK_KHR_timeline_semaphore", 1, "command buffer completion, MTLSharedEvent" },
	{ "VK_KHR_synchronization2", 0, "barriers" },
	{ "VK_EXT_external_memory_host", 1, "IOSurface / no-copy buffers imported from host pages" },
	{ "VK_KHR_push_descriptor", 0, "argument binding fast path" },
	{ "VK_EXT_descriptor_indexing", 0, "argument buffers" },
	{ "VK_KHR_buffer_device_address", 0, "MTLBuffer gpuAddress (pointers inside buffers: QuartzCore)" },
	{ "VK_EXT_extended_dynamic_state", 0, "cull/winding/depth state without new pipelines" },
	{ "VK_EXT_extended_dynamic_state2", 0, "primitive restart, rasterizer discard" },
	{ "VK_EXT_rasterization_order_attachment_access", 0, "framebuffer fetch (programmable blending)" },
	{ "VK_ARM_rasterization_order_attachment_access", 0, "framebuffer fetch (ARM name)" },
	{ "VK_KHR_dynamic_rendering_local_read", 0, "framebuffer fetch inside dynamic rendering" },
	{ "VK_EXT_custom_border_color", 0, "MTLSamplerBorderColor" },
	{ "VK_EXT_depth_clip_enable", 0, "setDepthClipMode:" },
	{ "VK_KHR_shader_float16_int8", 0, "half precision (QuartzCore _lph shaders)" },
	{ "VK_KHR_16bit_storage", 0, "half in buffers" },
	{ "VK_KHR_8bit_storage", 0, "char in buffers" },
	{ "VK_EXT_shader_demote_to_helper_invocation", 0, "discard_fragment" },
	{ "VK_KHR_sampler_ycbcr_conversion", 0, "biplanar 420v/420f video surfaces" },
	{ "VK_EXT_robustness2", 0, "null descriptors (unbound textures)" },
	{ "VK_KHR_pipeline_library", 0, "pipeline caching" },
	{ "VK_EXT_graphics_pipeline_library", 0, "fast pipeline linking" },
	{ "VK_EXT_pipeline_creation_cache_control", 0, "pipeline cache" },
	{ "VK_KHR_maintenance4", 0, "" },
	{ "VK_EXT_memory_budget", 0, "recommendedMaxWorkingSetSize" },
};

static const char *vr(uint32_t v, char *b, size_t n)
{
	snprintf(b, n, "%u.%u.%u", VK_API_VERSION_MAJOR(v), VK_API_VERSION_MINOR(v), VK_API_VERSION_PATCH(v));
	return b;
}

#define GET(inst, name) PFN_##name name = (PFN_##name)gipa(inst, #name)

static int clear_test(VkInstance inst, VkPhysicalDevice pd, uint32_t qfam);

int main(int argc, char **argv)
{
	const char *icd = getenv("NEGRONI_TURNIP");
	bool do_clear = false, all_ext = false;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--icd") && i + 1 < argc)
			icd = argv[++i];
		else if (!strcmp(argv[i], "--clear"))
			do_clear = true;
		else if (!strcmp(argv[i], "--all-ext"))
			all_ext = true;
		else if (!strcmp(argv[i], "--quiet"))
			quiet = true;
		else {
			fprintf(stderr, "usage: %s [--icd PATH] [--clear] [--all-ext] [--quiet]\n", argv[0]);
			return 2;
		}
	}
	if (!icd || !*icd)
		icd = DEFAULT_ICD;

	void *h = dlopen(icd, RTLD_NOW | RTLD_LOCAL);
	if (!h) {
		R("FAIL dlopen %s: %s\n", icd, dlerror());
		return 2;
	}
	/* Turnip built for Darwin exports vkGetInstanceProcAddr (UniXNU turnip-darwin-kmd patch); every Mesa ICD has vk_icd* */
	gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vkGetInstanceProcAddr");
	const char *how = "vkGetInstanceProcAddr";
	if (!gipa) {
		PFN_vkVoidFunction (*neg)(uint32_t *) = (PFN_vkVoidFunction (*)(uint32_t *))dlsym(h, "vk_icdNegotiateLoaderICDInterfaceVersion");
		if (neg) {
			uint32_t v = 5;
			((VkResult (*)(uint32_t *))neg)(&v);
			P("ICD interface version %u\n", v);
		}
		gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vk_icdGetInstanceProcAddr");
		how = "vk_icdGetInstanceProcAddr";
	}
	if (!gipa) {
		R("FAIL %s exports neither vkGetInstanceProcAddr nor vk_icdGetInstanceProcAddr\n", icd);
		return 2;
	}
	P("ICD %s (%s)\n", icd, how);

	char b1[32], b2[32];
	GET(NULL, vkEnumerateInstanceVersion);
	uint32_t iv = VK_API_VERSION_1_0;
	if (vkEnumerateInstanceVersion)
		vkEnumerateInstanceVersion(&iv);
	P("instance version %s\n", vr(iv, b1, sizeof(b1)));

	GET(NULL, vkEnumerateInstanceExtensionProperties);
	uint32_t n = 0;
	vkEnumerateInstanceExtensionProperties(NULL, &n, NULL);
	VkExtensionProperties *ie = calloc(n ? n : 1, sizeof(*ie));
	vkEnumerateInstanceExtensionProperties(NULL, &n, ie);
	P("instance extensions (%u):", n);
	for (uint32_t i = 0; i < n; i++)
		if (!quiet)
			printf(" %s", ie[i].extensionName);
	if (!quiet)
		printf("\n");
	free(ie);

	GET(NULL, vkCreateInstance);
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vkprobe",
				  .apiVersion = iv >= VK_API_VERSION_1_3 ? VK_API_VERSION_1_3 : iv };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	VkResult r = vkCreateInstance(&ici, NULL, &inst);
	if (r != VK_SUCCESS) {
		R("FAIL vkCreateInstance %d\n", r);
		return 2;
	}
	GET(inst, vkEnumeratePhysicalDevices);
	GET(inst, vkGetPhysicalDeviceProperties2);
	GET(inst, vkGetPhysicalDeviceFeatures2);
	GET(inst, vkGetPhysicalDeviceMemoryProperties);
	GET(inst, vkGetPhysicalDeviceQueueFamilyProperties);
	GET(inst, vkEnumerateDeviceExtensionProperties);
	GET(inst, vkDestroyInstance);

	uint32_t npd = 0;
	r = vkEnumeratePhysicalDevices(inst, &npd, NULL);
	if (r != VK_SUCCESS || npd == 0) {
		R("FAIL no physical device (result %d, count %u): kernel user client missing or GPU not up\n", r, npd);
		vkDestroyInstance(inst, NULL);
		return 2;
	}
	VkPhysicalDevice pds[8];
	if (npd > 8)
		npd = 8;
	vkEnumeratePhysicalDevices(inst, &npd, pds);
	int rc = 0;
	for (uint32_t d = 0; d < npd; d++) {
		VkPhysicalDeviceDriverProperties drv = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
		VkPhysicalDeviceProperties2 p2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &drv };
		vkGetPhysicalDeviceProperties2(pds[d], &p2);
		VkPhysicalDeviceProperties *p = &p2.properties;
		R("device %u: %s, API %s, driver %s %s, vendor 0x%x device 0x%x, type %d\n", d, p->deviceName,
		  vr(p->apiVersion, b1, sizeof(b1)), drv.driverName, drv.driverInfo, p->vendorID, p->deviceID, p->deviceType);
		P("  limits: image2D %u, maxBoundDescriptorSets %u, maxPushConstants %u, maxComputeWorkGroupInvocations %u, "
		  "maxColorAttachments %u, maxVertexInputAttributes %u, nonCoherentAtomSize %llu, minStorageBufferOffsetAlignment %llu\n",
		  p->limits.maxImageDimension2D, p->limits.maxBoundDescriptorSets, p->limits.maxPushConstantsSize,
		  p->limits.maxComputeWorkGroupInvocations, p->limits.maxColorAttachments, p->limits.maxVertexInputAttributes,
		  (unsigned long long)p->limits.nonCoherentAtomSize, (unsigned long long)p->limits.minStorageBufferOffsetAlignment);

		VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
		VkPhysicalDeviceVulkan12Features f12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &f13 };
		VkPhysicalDeviceVulkan11Features f11 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &f12 };
		VkPhysicalDeviceFeatures2 f2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f11 };
		vkGetPhysicalDeviceFeatures2(pds[d], &f2);
		R("  features: timelineSemaphore %d, bufferDeviceAddress %d, descriptorIndexing %d, shaderFloat16 %d, "
		  "storageBuffer16BitAccess %d, dynamicRendering %d, synchronization2 %d, independentBlend %d, dualSrcBlend %d, "
		  "depthClamp %d, fillModeNonSolid %d, samplerAnisotropy %d, textureCompressionETC2 %d, textureCompressionASTC_LDR %d, "
		  "textureCompressionBC %d, imageCubeArray %d, shaderInt16 %d\n",
		  f12.timelineSemaphore, f12.bufferDeviceAddress, f12.descriptorIndexing, f12.shaderFloat16,
		  f11.storageBuffer16BitAccess, f13.dynamicRendering, f13.synchronization2, f2.features.independentBlend,
		  f2.features.dualSrcBlend, f2.features.depthClamp, f2.features.fillModeNonSolid, f2.features.samplerAnisotropy,
		  f2.features.textureCompressionETC2, f2.features.textureCompressionASTC_LDR, f2.features.textureCompressionBC,
		  f2.features.imageCubeArray, f2.features.shaderInt16);

		VkPhysicalDeviceMemoryProperties mp;
		vkGetPhysicalDeviceMemoryProperties(pds[d], &mp);
		for (uint32_t i = 0; i < mp.memoryHeapCount; i++)
			P("  heap %u: %llu MiB flags 0x%x\n", i, (unsigned long long)(mp.memoryHeaps[i].size >> 20), mp.memoryHeaps[i].flags);
		for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
			P("  memory type %u: heap %u flags 0x%x\n", i, mp.memoryTypes[i].heapIndex, mp.memoryTypes[i].propertyFlags);

		uint32_t nq = 0;
		vkGetPhysicalDeviceQueueFamilyProperties(pds[d], &nq, NULL);
		VkQueueFamilyProperties qf[8];
		if (nq > 8)
			nq = 8;
		vkGetPhysicalDeviceQueueFamilyProperties(pds[d], &nq, qf);
		uint32_t gfx = UINT32_MAX;
		for (uint32_t i = 0; i < nq; i++) {
			P("  queue family %u: flags 0x%x count %u timestampValidBits %u\n", i, qf[i].queueFlags, qf[i].queueCount,
			  qf[i].timestampValidBits);
			if (gfx == UINT32_MAX && (qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT))
				gfx = i;
		}

		uint32_t ne = 0;
		vkEnumerateDeviceExtensionProperties(pds[d], NULL, &ne, NULL);
		VkExtensionProperties *de = calloc(ne ? ne : 1, sizeof(*de));
		vkEnumerateDeviceExtensionProperties(pds[d], NULL, &ne, de);
		P("  device extensions: %u\n", ne);
		int missing_req = 0;
		for (size_t w = 0; w < sizeof(wanted) / sizeof(wanted[0]); w++) {
			bool have = false;
			for (uint32_t i = 0; i < ne && !have; i++)
				have = !strcmp(de[i].extensionName, wanted[w].name);
			/* core in 1.3: dynamic rendering, timeline semaphore (1.2), synchronization2 */
			if (!have && p->apiVersion >= VK_API_VERSION_1_3 &&
			    (!strcmp(wanted[w].name, "VK_KHR_dynamic_rendering") || !strcmp(wanted[w].name, "VK_KHR_synchronization2") ||
			     !strcmp(wanted[w].name, "VK_KHR_timeline_semaphore")))
				have = true;
			if (!have && wanted[w].required)
				missing_req++;
			if (!have)
				R("  %s %s (%s)\n", wanted[w].required ? "MISSING required" : "missing optional", wanted[w].name, wanted[w].why);
			else
				P("  have %s\n", wanted[w].name);
		}
		if (all_ext)
			for (uint32_t i = 0; i < ne; i++)
				R("  ext %s %u\n", de[i].extensionName, de[i].specVersion);
		free(de);
		if (p->apiVersion < VK_API_VERSION_1_2 || !f12.timelineSemaphore) {
			R("  MISSING required Vulkan 1.2 + timelineSemaphore (API %s, timelineSemaphore %d)\n",
			  vr(p->apiVersion, b2, sizeof(b2)), f12.timelineSemaphore);
			missing_req++;
		}
		R("  %s requirements for metal2vulkan (%d required missing)\n", missing_req ? "FAIL" : "PASS", missing_req);
		if (missing_req)
			rc = 1;

		if (do_clear && d == 0) {
			if (gfx == UINT32_MAX) {
				R("FAIL clear: no graphics queue\n");
				rc = 1;
			} else if (clear_test(inst, pds[d], gfx) != 0)
				rc = 1;
		}
	}
	vkDestroyInstance(inst, NULL);
	return rc;
}

#define CHECK(x) do { VkResult _r = (x); if (_r != VK_SUCCESS) { R("FAIL clear: %s = %d\n", #x, _r); goto out; } } while (0)

static int find_mem(VkPhysicalDeviceMemoryProperties *mp, uint32_t bits, VkMemoryPropertyFlags want)
{
	for (uint32_t i = 0; i < mp->memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp->memoryTypes[i].propertyFlags & want) == want)
			return (int)i;
	return -1;
}

/* Clear a 64x64 RGBA8 image to (0.25, 0.5, 0.75, 1.0), copy it into a host-visible buffer, check every pixel. */
static int clear_test(VkInstance inst, VkPhysicalDevice pd, uint32_t qfam)
{
	GET(inst, vkCreateDevice);
	GET(inst, vkGetPhysicalDeviceMemoryProperties);
	int ok = -1;
	const uint32_t W = 64, H = 64;
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = qfam,
					.queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkDevice dev = VK_NULL_HANDLE;
	VkResult cr = vkCreateDevice(pd, &dci, NULL, &dev);
	if (cr != VK_SUCCESS) {
		R("FAIL clear: vkCreateDevice = %d\n", cr);
		return -1;
	}
	PFN_vkGetDeviceProcAddr gdpa = (PFN_vkGetDeviceProcAddr)gipa(inst, "vkGetDeviceProcAddr");
#define DGET(name) PFN_##name name = (PFN_##name)gdpa(dev, #name)
	DGET(vkGetDeviceQueue); DGET(vkCreateImage); DGET(vkGetImageMemoryRequirements); DGET(vkAllocateMemory);
	DGET(vkBindImageMemory); DGET(vkCreateBuffer); DGET(vkGetBufferMemoryRequirements); DGET(vkBindBufferMemory);
	DGET(vkMapMemory); DGET(vkCreateCommandPool); DGET(vkAllocateCommandBuffers); DGET(vkBeginCommandBuffer);
	DGET(vkCmdPipelineBarrier); DGET(vkCmdClearColorImage); DGET(vkCmdCopyImageToBuffer); DGET(vkEndCommandBuffer);
	DGET(vkCreateFence); DGET(vkQueueSubmit); DGET(vkWaitForFences); DGET(vkDestroyDevice);
	DGET(vkInvalidateMappedMemoryRanges);

	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	VkQueue q;
	vkGetDeviceQueue(dev, qfam, 0, &q);

	VkImageCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
				 .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
				 .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
				 .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
				 .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
	VkImage img;
	CHECK(vkCreateImage(dev, &ii, NULL, &img));
	VkMemoryRequirements imr;
	vkGetImageMemoryRequirements(dev, img, &imr);
	int it = find_mem(&mp, imr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = imr.size, .memoryTypeIndex = (uint32_t)it };
	VkDeviceMemory imem;
	CHECK(vkAllocateMemory(dev, &mai, NULL, &imem));
	CHECK(vkBindImageMemory(dev, img, imem, 0));

	VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = W * H * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buf;
	CHECK(vkCreateBuffer(dev, &bi, NULL, &buf));
	VkMemoryRequirements bmr;
	vkGetBufferMemoryRequirements(dev, buf, &bmr);
	int bt = find_mem(&mp, bmr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
	VkMemoryAllocateInfo bai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = bmr.size, .memoryTypeIndex = (uint32_t)bt };
	VkDeviceMemory bmem;
	CHECK(vkAllocateMemory(dev, &bai, NULL, &bmem));
	CHECK(vkBindBufferMemory(dev, buf, bmem, 0));
	uint32_t *px;
	CHECK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&px));
	memset(px, 0xcd, W * H * 4);

	VkCommandPoolCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = qfam };
	VkCommandPool pool;
	CHECK(vkCreateCommandPool(dev, &cpi, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
					    .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer cb;
	CHECK(vkAllocateCommandBuffers(dev, &cai, &cb));
	VkCommandBufferBeginInfo cbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CHECK(vkBeginCommandBuffer(cb, &cbi));
	VkImageSubresourceRange rng = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
	VkImageMemoryBarrier b0 = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
				    .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
				    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
				    .image = img, .subresourceRange = rng };
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b0);
	VkClearColorValue cc = { .float32 = { 0.25f, 0.5f, 0.75f, 1.0f } };
	vkCmdClearColorImage(cb, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &cc, 1, &rng);
	VkImageMemoryBarrier b1 = b0;
	b1.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
	b1.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
	b1.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
	b1.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b1);
	VkBufferImageCopy reg = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } };
	vkCmdCopyImageToBuffer(cb, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &reg);
	VkBufferMemoryBarrier hb = { .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
				     .dstAccessMask = VK_ACCESS_HOST_READ_BIT, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
				     .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .buffer = buf, .size = VK_WHOLE_SIZE };
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL, 1, &hb, 0, NULL);
	CHECK(vkEndCommandBuffer(cb));
	VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	VkFence fence;
	CHECK(vkCreateFence(dev, &fci, NULL, &fence));
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
	CHECK(vkQueueSubmit(q, 1, &si, fence));
	CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 5ull * 1000 * 1000 * 1000));
	VkMappedMemoryRange mr = { .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory = bmem, .size = VK_WHOLE_SIZE };
	vkInvalidateMappedMemoryRanges(dev, 1, &mr);
	/* 0.25 -> 64 (0x40), 0.5 -> 128 (0x80), 0.75 -> 191 (0xbf), 1.0 -> 255: RGBA little-endian 0xffbf8040 (UNORM rounding: 0x3f..0x41 accepted) */
	uint32_t bad = 0;
	for (uint32_t i = 0; i < W * H; i++) {
		uint32_t v = px[i];
		int r8 = v & 0xff, g8 = (v >> 8) & 0xff, b8 = (v >> 16) & 0xff, a8 = v >> 24;
		if (r8 < 0x3f || r8 > 0x41 || g8 < 0x7f || g8 > 0x81 || b8 < 0xbe || b8 > 0xc0 || a8 != 0xff)
			bad++;
	}
	if (bad)
		R("FAIL clear: %u of %u pixels wrong (first 0x%08x)\n", bad, W * H, px[0]);
	else
		R("PASS clear: %ux%u pixels 0x%08x\n", W, H, px[0]);
	ok = bad ? -1 : 0;
out:
	vkDestroyDevice(dev, NULL);
	return ok;
}
