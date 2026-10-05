//! The exact set of Vulkan entry points the RHI calls. vulkan-zig generates
//! wrappers only for these, which keeps compile times and the surface small.
const vk = @import("vulkan");

/// Entry points that can be called before an instance exists. In each of
/// these tables a field is named after its Vulkan command and is null until
/// the loader fills it in.
pub const BaseDispatch = struct {
    vkCreateInstance: ?vk.PfnCreateInstance = null,
    vkEnumerateInstanceExtensionProperties: ?vk.PfnEnumerateInstanceExtensionProperties = null,
    vkEnumerateInstanceVersion: ?vk.PfnEnumerateInstanceVersion = null,
};

/// Instance-level entry points: adapter queries, surface creation and the
/// debug messenger.
pub const InstanceDispatch = struct {
    vkCreateDebugUtilsMessengerEXT: ?vk.PfnCreateDebugUtilsMessengerEXT = null,
    vkCreateDevice: ?vk.PfnCreateDevice = null,
    vkCreateWaylandSurfaceKHR: ?vk.PfnCreateWaylandSurfaceKHR = null,
    vkCreateWin32SurfaceKHR: ?vk.PfnCreateWin32SurfaceKHR = null,
    vkCreateXlibSurfaceKHR: ?vk.PfnCreateXlibSurfaceKHR = null,
    vkDestroyDebugUtilsMessengerEXT: ?vk.PfnDestroyDebugUtilsMessengerEXT = null,
    vkDestroyInstance: ?vk.PfnDestroyInstance = null,
    vkDestroySurfaceKHR: ?vk.PfnDestroySurfaceKHR = null,
    vkEnumerateDeviceExtensionProperties: ?vk.PfnEnumerateDeviceExtensionProperties = null,
    vkEnumeratePhysicalDevices: ?vk.PfnEnumeratePhysicalDevices = null,
    vkGetPhysicalDeviceFeatures2: ?vk.PfnGetPhysicalDeviceFeatures2 = null,
    vkGetPhysicalDeviceMemoryProperties: ?vk.PfnGetPhysicalDeviceMemoryProperties = null,
    vkGetPhysicalDeviceProperties: ?vk.PfnGetPhysicalDeviceProperties = null,
    vkGetPhysicalDeviceQueueFamilyProperties: ?vk.PfnGetPhysicalDeviceQueueFamilyProperties = null,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: ?vk.PfnGetPhysicalDeviceSurfaceCapabilitiesKHR = null,
    vkGetPhysicalDeviceSurfaceFormatsKHR: ?vk.PfnGetPhysicalDeviceSurfaceFormatsKHR = null,
    vkGetPhysicalDeviceSurfacePresentModesKHR: ?vk.PfnGetPhysicalDeviceSurfacePresentModesKHR = null,
    vkGetPhysicalDeviceSurfaceSupportKHR: ?vk.PfnGetPhysicalDeviceSurfaceSupportKHR = null,
};

/// Device-level entry points: everything called on the logical device, its
/// queue and its command buffers, including the swapchain and
/// acceleration-structure extensions.
pub const DeviceDispatch = struct {
    vkAcquireNextImageKHR: ?vk.PfnAcquireNextImageKHR = null,
    vkAllocateCommandBuffers: ?vk.PfnAllocateCommandBuffers = null,
    vkAllocateDescriptorSets: ?vk.PfnAllocateDescriptorSets = null,
    vkAllocateMemory: ?vk.PfnAllocateMemory = null,
    vkBeginCommandBuffer: ?vk.PfnBeginCommandBuffer = null,
    vkBindBufferMemory: ?vk.PfnBindBufferMemory = null,
    vkBindImageMemory: ?vk.PfnBindImageMemory = null,
    vkCmdBeginDebugUtilsLabelEXT: ?vk.PfnCmdBeginDebugUtilsLabelEXT = null,
    vkSetDebugUtilsObjectNameEXT: ?vk.PfnSetDebugUtilsObjectNameEXT = null,
    vkCmdBeginRendering: ?vk.PfnCmdBeginRendering = null,
    vkCmdBindDescriptorSets: ?vk.PfnCmdBindDescriptorSets = null,
    vkCmdBindIndexBuffer: ?vk.PfnCmdBindIndexBuffer = null,
    vkCmdBindPipeline: ?vk.PfnCmdBindPipeline = null,
    vkCmdBindVertexBuffers: ?vk.PfnCmdBindVertexBuffers = null,
    vkCmdBlitImage: ?vk.PfnCmdBlitImage = null,
    vkCmdBuildAccelerationStructuresKHR: ?vk.PfnCmdBuildAccelerationStructuresKHR = null,
    vkCreateAccelerationStructureKHR: ?vk.PfnCreateAccelerationStructureKHR = null,
    vkDestroyAccelerationStructureKHR: ?vk.PfnDestroyAccelerationStructureKHR = null,
    vkGetAccelerationStructureBuildSizesKHR: ?vk.PfnGetAccelerationStructureBuildSizesKHR = null,
    vkGetAccelerationStructureDeviceAddressKHR: ?vk.PfnGetAccelerationStructureDeviceAddressKHR = null,
    vkCmdCopyBuffer: ?vk.PfnCmdCopyBuffer = null,
    vkCmdCopyBufferToImage: ?vk.PfnCmdCopyBufferToImage = null,
    vkCmdCopyImageToBuffer: ?vk.PfnCmdCopyImageToBuffer = null,
    vkCmdDispatch: ?vk.PfnCmdDispatch = null,
    vkCmdClearAttachments: ?vk.PfnCmdClearAttachments = null,
    vkCmdDraw: ?vk.PfnCmdDraw = null,
    vkCmdDrawIndexed: ?vk.PfnCmdDrawIndexed = null,
    vkCmdDrawIndexedIndirectCount: ?vk.PfnCmdDrawIndexedIndirectCount = null,
    vkCmdEndDebugUtilsLabelEXT: ?vk.PfnCmdEndDebugUtilsLabelEXT = null,
    vkCmdEndRendering: ?vk.PfnCmdEndRendering = null,
    vkCmdFillBuffer: ?vk.PfnCmdFillBuffer = null,
    vkCmdPipelineBarrier2: ?vk.PfnCmdPipelineBarrier2 = null,
    vkCmdPushConstants: ?vk.PfnCmdPushConstants = null,
    vkCmdResetQueryPool: ?vk.PfnCmdResetQueryPool = null,
    vkCmdSetScissor: ?vk.PfnCmdSetScissor = null,
    vkCmdSetViewport: ?vk.PfnCmdSetViewport = null,
    vkCmdWriteTimestamp2: ?vk.PfnCmdWriteTimestamp2 = null,
    vkCreateBuffer: ?vk.PfnCreateBuffer = null,
    vkCreateCommandPool: ?vk.PfnCreateCommandPool = null,
    vkCreateComputePipelines: ?vk.PfnCreateComputePipelines = null,
    vkCreateDescriptorPool: ?vk.PfnCreateDescriptorPool = null,
    vkCreateDescriptorSetLayout: ?vk.PfnCreateDescriptorSetLayout = null,
    vkCreateFence: ?vk.PfnCreateFence = null,
    vkCreateGraphicsPipelines: ?vk.PfnCreateGraphicsPipelines = null,
    vkCreateImage: ?vk.PfnCreateImage = null,
    vkCreateImageView: ?vk.PfnCreateImageView = null,
    vkCreatePipelineCache: ?vk.PfnCreatePipelineCache = null,
    vkCreatePipelineLayout: ?vk.PfnCreatePipelineLayout = null,
    vkCreateQueryPool: ?vk.PfnCreateQueryPool = null,
    vkCreateSampler: ?vk.PfnCreateSampler = null,
    vkCreateSemaphore: ?vk.PfnCreateSemaphore = null,
    vkCreateShaderModule: ?vk.PfnCreateShaderModule = null,
    vkCreateSwapchainKHR: ?vk.PfnCreateSwapchainKHR = null,
    vkDestroyBuffer: ?vk.PfnDestroyBuffer = null,
    vkDestroyCommandPool: ?vk.PfnDestroyCommandPool = null,
    vkDestroyDescriptorPool: ?vk.PfnDestroyDescriptorPool = null,
    vkDestroyDescriptorSetLayout: ?vk.PfnDestroyDescriptorSetLayout = null,
    vkDestroyDevice: ?vk.PfnDestroyDevice = null,
    vkDestroyFence: ?vk.PfnDestroyFence = null,
    vkDestroyImage: ?vk.PfnDestroyImage = null,
    vkDestroyImageView: ?vk.PfnDestroyImageView = null,
    vkDestroyPipeline: ?vk.PfnDestroyPipeline = null,
    vkDestroyPipelineCache: ?vk.PfnDestroyPipelineCache = null,
    vkDestroyPipelineLayout: ?vk.PfnDestroyPipelineLayout = null,
    vkDestroyQueryPool: ?vk.PfnDestroyQueryPool = null,
    vkDestroySampler: ?vk.PfnDestroySampler = null,
    vkDestroySemaphore: ?vk.PfnDestroySemaphore = null,
    vkDestroyShaderModule: ?vk.PfnDestroyShaderModule = null,
    vkDestroySwapchainKHR: ?vk.PfnDestroySwapchainKHR = null,
    vkDeviceWaitIdle: ?vk.PfnDeviceWaitIdle = null,
    vkEndCommandBuffer: ?vk.PfnEndCommandBuffer = null,
    vkFreeMemory: ?vk.PfnFreeMemory = null,
    vkGetBufferDeviceAddress: ?vk.PfnGetBufferDeviceAddress = null,
    vkGetBufferMemoryRequirements: ?vk.PfnGetBufferMemoryRequirements = null,
    vkGetDeviceQueue: ?vk.PfnGetDeviceQueue = null,
    vkGetImageMemoryRequirements: ?vk.PfnGetImageMemoryRequirements = null,
    vkGetPipelineCacheData: ?vk.PfnGetPipelineCacheData = null,
    vkGetQueryPoolResults: ?vk.PfnGetQueryPoolResults = null,
    vkGetSwapchainImagesKHR: ?vk.PfnGetSwapchainImagesKHR = null,
    vkMapMemory: ?vk.PfnMapMemory = null,
    vkQueuePresentKHR: ?vk.PfnQueuePresentKHR = null,
    vkQueueSubmit2: ?vk.PfnQueueSubmit2 = null,
    vkResetCommandPool: ?vk.PfnResetCommandPool = null,
    vkResetFences: ?vk.PfnResetFences = null,
    vkUnmapMemory: ?vk.PfnUnmapMemory = null,
    vkUpdateDescriptorSets: ?vk.PfnUpdateDescriptorSets = null,
    vkWaitForFences: ?vk.PfnWaitForFences = null,
};

/// Function table and wrappers for the pre-instance entry points.
pub const Base = vk.BaseWrapperWithCustomDispatch(BaseDispatch);
/// Function table for one instance. `Instance` points at one of these, so
/// it must stay at a stable address.
pub const InstanceWrapper = vk.InstanceWrapperWithCustomDispatch(InstanceDispatch);
/// An instance handle paired with its `InstanceWrapper`; the type the RHI
/// calls instance functions through.
pub const Instance = vk.InstanceProxyWithCustomDispatch(InstanceDispatch);
/// Function table for one logical device. `Device` points at one of
/// these, so it must stay at a stable address.
pub const DeviceWrapper = vk.DeviceWrapperWithCustomDispatch(DeviceDispatch);
/// A device handle paired with its `DeviceWrapper`; the type the RHI calls
/// device functions through (`rhi.Device.vkd`).
pub const Device = vk.DeviceProxyWithCustomDispatch(DeviceDispatch);
