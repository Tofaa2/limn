// See limn_ffx.h.
#include "limn_ffx.h"

#include <FidelityFX/host/backends/vk/ffx_vk.h>
#include <FidelityFX/host/ffx_fsr2.h>
#include <FidelityFX/host/ffx_fsr3upscaler.h>

#include <cfloat>
#include <cstdlib>
#include <new>

// Referenced by the backend; frame generation is not built in.
FfxErrorCode ffxSetFrameGenerationConfigToSwapchainVK(FfxFrameGenerationConfig const*) {
    return FFX_ERROR_BACKEND_API_ERROR;
}

struct LimnFfx {
    uint32_t generation = 0;
    void* scratch = nullptr;
    FfxInterface backend = {};
    FfxFsr2Context fsr2 = {};
    FfxFsr3UpscalerContext fsr3 = {};
    FfxResourceInternal shared[3] = {};
    bool context_made = false;
    bool shared_made = false;
    uint32_t output_width = 0;
    uint32_t output_height = 0;
};

static FfxResource imageResource(const LimnFfxImage& image, const wchar_t* name, bool written) {
    VkImageCreateInfo info = {};
    info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    info.imageType = VK_IMAGE_TYPE_2D;
    info.format = static_cast<VkFormat>(image.format);
    info.extent = {image.width, image.height, 1};
    info.mipLevels = 1;
    info.arrayLayers = 1;
    info.samples = VK_SAMPLE_COUNT_1_BIT;
    info.usage = VK_IMAGE_USAGE_SAMPLED_BIT | (written ? VK_IMAGE_USAGE_STORAGE_BIT : 0);
    const VkImage handle = reinterpret_cast<VkImage>(image.image);
    FfxResourceDescription description = ffxGetImageResourceDescriptionVK(handle, info, written ? FFX_RESOURCE_USAGE_UAV : FFX_RESOURCE_USAGE_READ_ONLY);
    return ffxGetResourceVK(reinterpret_cast<void*>(image.image), description, name, FFX_RESOURCE_STATE_COMPUTE_READ);
}

// The SDK samples depth as SHADER_READ_ONLY_OPTIMAL; the renderer keeps it
// in READ_ONLY_OPTIMAL.
static void moveDepth(const LimnFfxFrame* frame, VkImageLayout from, VkImageLayout to) {
    const VkFormat format = static_cast<VkFormat>(frame->depth.format);
    const bool stencil = format == VK_FORMAT_D24_UNORM_S8_UINT || format == VK_FORMAT_D32_SFLOAT_S8_UINT || format == VK_FORMAT_D16_UNORM_S8_UINT;
    VkImageMemoryBarrier barrier = {};
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT;
    barrier.oldLayout = from;
    barrier.newLayout = to;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = reinterpret_cast<VkImage>(frame->depth.image);
    barrier.subresourceRange = {static_cast<VkImageAspectFlags>(VK_IMAGE_ASPECT_DEPTH_BIT | (stencil ? VK_IMAGE_ASPECT_STENCIL_BIT : 0)), 0, 1, 0, 1};
    vkCmdPipelineBarrier(static_cast<VkCommandBuffer>(frame->command_buffer), VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
}

static int32_t dispatch(LimnFfx* ffx, const LimnFfxFrame* frame);

int32_t limnFfxDispatch(LimnFfx* ffx, const LimnFfxFrame* frame) {
    moveDepth(frame, VK_IMAGE_LAYOUT_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    const int32_t result = dispatch(ffx, frame);
    moveDepth(frame, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_READ_ONLY_OPTIMAL);
    return result;
}

LimnFfx* limnFfxCreate(const LimnFfxCreate* desc) {
    LimnFfx* ffx = new (std::nothrow) LimnFfx();
    if (!ffx) return nullptr;
    ffx->generation = desc->generation;
    ffx->output_width = desc->output_width;
    ffx->output_height = desc->output_height;

    volkLoadDevice(static_cast<VkDevice>(desc->device));

    VkDeviceContext device_context = {};
    device_context.vkDevice = static_cast<VkDevice>(desc->device);
    device_context.vkPhysicalDevice = static_cast<VkPhysicalDevice>(desc->physical_device);
    device_context.vkDeviceProcAddr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(desc->get_device_proc_addr);
    const size_t scratch_size = ffxGetScratchMemorySizeVK(device_context.vkPhysicalDevice, 1);
    ffx->scratch = std::calloc(1, scratch_size);
    if (!ffx->scratch || ffxGetInterfaceVK(&ffx->backend, ffxGetDeviceVK(&device_context), ffx->scratch, scratch_size, 1) != FFX_OK) {
        limnFfxDestroy(ffx);
        return nullptr;
    }

    if (ffx->generation == 2) {
        FfxFsr2ContextDescription context = {};
        context.flags = FFX_FSR2_ENABLE_HIGH_DYNAMIC_RANGE | FFX_FSR2_ENABLE_DEPTH_INVERTED | FFX_FSR2_ENABLE_DEPTH_INFINITE | FFX_FSR2_ENABLE_AUTO_EXPOSURE;
        context.maxRenderSize = {desc->render_width, desc->render_height};
        context.displaySize = {desc->output_width, desc->output_height};
        context.backendInterface = ffx->backend;
        if (ffxFsr2ContextCreate(&ffx->fsr2, &context) != FFX_OK) {
            limnFfxDestroy(ffx);
            return nullptr;
        }
        ffx->context_made = true;
        return ffx;
    }

    FfxFsr3UpscalerContextDescription context = {};
    context.flags = FFX_FSR3UPSCALER_ENABLE_HIGH_DYNAMIC_RANGE | FFX_FSR3UPSCALER_ENABLE_DEPTH_INVERTED | FFX_FSR3UPSCALER_ENABLE_DEPTH_INFINITE | FFX_FSR3UPSCALER_ENABLE_AUTO_EXPOSURE;
    context.maxRenderSize = {desc->render_width, desc->render_height};
    context.maxUpscaleSize = {desc->output_width, desc->output_height};
    context.backendInterface = ffx->backend;
    if (ffxFsr3UpscalerContextCreate(&ffx->fsr3, &context) != FFX_OK) {
        limnFfxDestroy(ffx);
        return nullptr;
    }
    ffx->context_made = true;
    FfxFsr3UpscalerSharedResourceDescriptions shared = {};
    if (ffxFsr3UpscalerGetSharedResourceDescriptions(&ffx->fsr3, &shared) != FFX_OK) {
        limnFfxDestroy(ffx);
        return nullptr;
    }
    const FfxCreateResourceDescription* wanted[3] = {&shared.dilatedDepth, &shared.dilatedMotionVectors, &shared.reconstructedPrevNearestDepth};
    for (int index = 0; index < 3; index++) {
        if (ffx->backend.fpCreateResource(&ffx->backend, wanted[index], 0, &ffx->shared[index]) != FFX_OK) {
            limnFfxDestroy(ffx);
            return nullptr;
        }
    }
    ffx->shared_made = true;
    return ffx;
}

static int32_t dispatch(LimnFfx* ffx, const LimnFfxFrame* frame) {
    if (ffx->generation == 2) {
        FfxFsr2DispatchDescription dispatch = {};
        dispatch.commandList = ffxGetCommandListVK(static_cast<VkCommandBuffer>(frame->command_buffer));
        dispatch.color = imageResource(frame->color, L"limn color", false);
        dispatch.depth = imageResource(frame->depth, L"limn depth", false);
        dispatch.motionVectors = imageResource(frame->motion, L"limn motion", false);
        dispatch.output = imageResource(frame->output, L"limn upscaled", true);
        dispatch.jitterOffset = {frame->jitter[0], frame->jitter[1]};
        dispatch.motionVectorScale = {frame->motion_scale[0], frame->motion_scale[1]};
        dispatch.renderSize = {frame->render_width, frame->render_height};
        dispatch.enableSharpening = frame->sharpness > 0.0f;
        dispatch.sharpness = frame->sharpness;
        dispatch.frameTimeDelta = frame->frame_milliseconds;
        dispatch.preExposure = 1.0f;
        dispatch.reset = frame->reset != 0;
        dispatch.cameraNear = frame->camera_near;
        dispatch.cameraFar = FLT_MAX;
        dispatch.cameraFovAngleVertical = frame->camera_fov_y;
        dispatch.viewSpaceToMetersFactor = 1.0f;
        return static_cast<int32_t>(ffxFsr2ContextDispatch(&ffx->fsr2, &dispatch));
    }
    FfxFsr3UpscalerDispatchDescription dispatch = {};
    dispatch.commandList = ffxGetCommandListVK(static_cast<VkCommandBuffer>(frame->command_buffer));
    dispatch.color = imageResource(frame->color, L"limn color", false);
    dispatch.depth = imageResource(frame->depth, L"limn depth", false);
    dispatch.motionVectors = imageResource(frame->motion, L"limn motion", false);
    dispatch.output = imageResource(frame->output, L"limn upscaled", true);
    dispatch.dilatedDepth = ffx->backend.fpGetResource(&ffx->backend, ffx->shared[0]);
    dispatch.dilatedMotionVectors = ffx->backend.fpGetResource(&ffx->backend, ffx->shared[1]);
    dispatch.reconstructedPrevNearestDepth = ffx->backend.fpGetResource(&ffx->backend, ffx->shared[2]);
    dispatch.jitterOffset = {frame->jitter[0], frame->jitter[1]};
    dispatch.motionVectorScale = {frame->motion_scale[0], frame->motion_scale[1]};
    dispatch.renderSize = {frame->render_width, frame->render_height};
    dispatch.upscaleSize = {ffx->output_width, ffx->output_height};
    dispatch.enableSharpening = frame->sharpness > 0.0f;
    dispatch.sharpness = frame->sharpness;
    dispatch.frameTimeDelta = frame->frame_milliseconds;
    dispatch.preExposure = 1.0f;
    dispatch.reset = frame->reset != 0;
    dispatch.cameraNear = frame->camera_near;
    dispatch.cameraFar = FLT_MAX;
    dispatch.cameraFovAngleVertical = frame->camera_fov_y;
    dispatch.viewSpaceToMetersFactor = 1.0f;
    return static_cast<int32_t>(ffxFsr3UpscalerContextDispatch(&ffx->fsr3, &dispatch));
}

void limnFfxDestroy(LimnFfx* ffx) {
    if (!ffx) return;
    if (ffx->shared_made) {
        for (int index = 0; index < 3; index++) ffx->backend.fpDestroyResource(&ffx->backend, ffx->shared[index], 0);
    }
    if (ffx->context_made) {
        if (ffx->generation == 2) ffxFsr2ContextDestroy(&ffx->fsr2);
        else ffxFsr3UpscalerContextDestroy(&ffx->fsr3);
    }
    std::free(ffx->scratch);
    delete ffx;
}
