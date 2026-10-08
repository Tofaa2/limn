#include "limn_ffx.h"

#include <FidelityFX/host/backends/vk/ffx_vk.h>
#include <FidelityFX/host/ffx_frameinterpolation.h>
#include <FidelityFX/host/ffx_fsr2.h>
#include <FidelityFX/host/ffx_fsr3upscaler.h>
#include <FidelityFX/host/ffx_opticalflow.h>

#include <cfloat>
#include <cstdlib>
#include <new>

FfxErrorCode ffxSetFrameGenerationConfigToSwapchainVK(FfxFrameGenerationConfig const*) {
    return FFX_ERROR_BACKEND_API_ERROR;
}

VkPipelineCache limnFfxPipelineCache = VK_NULL_HANDLE;

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

    FfxOpticalflowContext optical_flow = {};
    FfxFrameInterpolationContext interpolation = {};
    FfxResourceInternal flow[2] = {};
    bool generation_made = false;
    uint32_t shown_width = 0;
    uint32_t shown_height = 0;
    int32_t shown_format = 0;
    uint64_t frame_id = 0;
    uint32_t render_width = 0;
    uint32_t render_height = 0;
    float frame_milliseconds = 0;
    float camera_near = 0;
    float camera_fov_y = 0;
};

static const size_t max_contexts = 3;

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
    limnFfxPipelineCache = reinterpret_cast<VkPipelineCache>(desc->pipeline_cache);

    VkDeviceContext device_context = {};
    device_context.vkDevice = static_cast<VkDevice>(desc->device);
    device_context.vkPhysicalDevice = static_cast<VkPhysicalDevice>(desc->physical_device);
    device_context.vkDeviceProcAddr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(desc->get_device_proc_addr);
    const size_t scratch_size = ffxGetScratchMemorySizeVK(device_context.vkPhysicalDevice, max_contexts);
    ffx->scratch = std::calloc(1, scratch_size);
    if (!ffx->scratch || ffxGetInterfaceVK(&ffx->backend, ffxGetDeviceVK(&device_context), ffx->scratch, scratch_size, max_contexts) != FFX_OK) {
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
    ffx->render_width = frame->render_width;
    ffx->render_height = frame->render_height;
    ffx->frame_milliseconds = frame->frame_milliseconds;
    ffx->camera_near = frame->camera_near;
    ffx->camera_fov_y = frame->camera_fov_y;
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

static void destroyGeneration(LimnFfx* ffx) {
    if (!ffx->generation_made) return;
    for (int index = 0; index < 2; index++) ffx->backend.fpDestroyResource(&ffx->backend, ffx->flow[index], 0);
    ffxFrameInterpolationContextDestroy(&ffx->interpolation);
    ffxOpticalflowContextDestroy(&ffx->optical_flow);
    ffx->generation_made = false;
}

static bool createGeneration(LimnFfx* ffx, const LimnFfxGenerate* frame) {
    FfxOpticalflowContextDescription flow = {};
    flow.backendInterface = ffx->backend;
    flow.resolution = {frame->shown.width, frame->shown.height};
    if (ffxOpticalflowContextCreate(&ffx->optical_flow, &flow) != FFX_OK) return false;

    FfxFrameInterpolationContextDescription interpolation = {};
    interpolation.backendInterface = ffx->backend;
    interpolation.flags = FFX_FRAMEINTERPOLATION_ENABLE_DEPTH_INVERTED | FFX_FRAMEINTERPOLATION_ENABLE_DEPTH_INFINITE;
    interpolation.maxRenderSize = {ffx->render_width, ffx->render_height};
    interpolation.displaySize = {frame->shown.width, frame->shown.height};
    interpolation.backBufferFormat = ffxGetSurfaceFormatVK(static_cast<VkFormat>(frame->shown.format));
    interpolation.previousInterpolationSourceFormat = interpolation.backBufferFormat;
    if (ffxFrameInterpolationContextCreate(&ffx->interpolation, &interpolation) != FFX_OK) {
        ffxOpticalflowContextDestroy(&ffx->optical_flow);
        return false;
    }

    FfxOpticalflowSharedResourceDescriptions shared = {};
    bool made = ffxOpticalflowGetSharedResourceDescriptions(&ffx->optical_flow, &shared) == FFX_OK;
    made = made && ffx->backend.fpCreateResource(&ffx->backend, &shared.opticalFlowVector, 0, &ffx->flow[0]) == FFX_OK;
    if (made && ffx->backend.fpCreateResource(&ffx->backend, &shared.opticalFlowSCD, 0, &ffx->flow[1]) != FFX_OK) {
        ffx->backend.fpDestroyResource(&ffx->backend, ffx->flow[0], 0);
        made = false;
    }
    if (!made) {
        ffxFrameInterpolationContextDestroy(&ffx->interpolation);
        ffxOpticalflowContextDestroy(&ffx->optical_flow);
        return false;
    }
    ffx->generation_made = true;
    ffx->shown_width = frame->shown.width;
    ffx->shown_height = frame->shown.height;
    ffx->shown_format = frame->shown.format;
    return true;
}

int32_t limnFfxGenerateFrame(LimnFfx* ffx, const LimnFfxGenerate* frame) {
    if (ffx->generation != 3 || ffx->render_width == 0) return -1;
    bool reset = frame->reset != 0;
    if (ffx->generation_made && (ffx->shown_width != frame->shown.width || ffx->shown_height != frame->shown.height || ffx->shown_format != frame->shown.format)) {
        destroyGeneration(ffx);
    }
    if (!ffx->generation_made) {
        if (!createGeneration(ffx, frame)) return -1;
        reset = true;
    }
    const FfxCommandList commands = ffxGetCommandListVK(static_cast<VkCommandBuffer>(frame->command_buffer));
    const FfxResource shown = imageResource(frame->shown, L"limn shown", false);
    const FfxResource vectors = ffx->backend.fpGetResource(&ffx->backend, ffx->flow[0]);
    const FfxResource scene_change = ffx->backend.fpGetResource(&ffx->backend, ffx->flow[1]);
    const FfxBackbufferTransferFunction transfer = frame->pq ? FFX_BACKBUFFER_TRANSFER_FUNCTION_PQ : FFX_BACKBUFFER_TRANSFER_FUNCTION_SRGB;
    const float luminance[2] = {0.0f, frame->pq ? 1000.0f : 200.0f};

    FfxOpticalflowDispatchDescription flow = {};
    flow.commandList = commands;
    flow.color = shown;
    flow.opticalFlowVector = vectors;
    flow.opticalFlowSCD = scene_change;
    flow.reset = reset;
    flow.backbufferTransferFunction = transfer;
    flow.minMaxLuminance = {luminance[0], luminance[1]};
    if (ffxOpticalflowContextDispatch(&ffx->optical_flow, &flow) != FFX_OK) return -1;

    FfxFrameInterpolationDispatchDescription dispatch = {};
    dispatch.commandList = commands;
    dispatch.displaySize = {frame->shown.width, frame->shown.height};
    dispatch.renderSize = {ffx->render_width, ffx->render_height};
    dispatch.currentBackBuffer = shown;
    dispatch.output = imageResource(frame->output, L"limn generated", true);
    dispatch.interpolationRect = {0, 0, static_cast<int32_t>(frame->shown.width), static_cast<int32_t>(frame->shown.height)};
    dispatch.opticalFlowVector = vectors;
    dispatch.opticalFlowSceneChangeDetection = scene_change;
    dispatch.opticalFlowBlockSize = 8;
    dispatch.opticalFlowScale = {1.0f / frame->shown.width, 1.0f / frame->shown.height};
    dispatch.cameraNear = ffx->camera_near;
    dispatch.cameraFar = FLT_MAX;
    dispatch.cameraFovAngleVertical = ffx->camera_fov_y;
    dispatch.viewSpaceToMetersFactor = 1.0f;
    dispatch.frameTimeDelta = ffx->frame_milliseconds;
    dispatch.reset = reset;
    dispatch.backBufferTransferFunction = transfer;
    dispatch.minMaxLuminance[0] = luminance[0];
    dispatch.minMaxLuminance[1] = luminance[1];
    dispatch.frameID = ffx->frame_id++;
    dispatch.dilatedDepth = ffx->backend.fpGetResource(&ffx->backend, ffx->shared[0]);
    dispatch.dilatedMotionVectors = ffx->backend.fpGetResource(&ffx->backend, ffx->shared[1]);
    dispatch.reconstructedPrevDepth = ffx->backend.fpGetResource(&ffx->backend, ffx->shared[2]);
    if (ffxFrameInterpolationDispatch(&ffx->interpolation, &dispatch) != FFX_OK) return -1;
    return reset ? 0 : 1;
}

void limnFfxDestroy(LimnFfx* ffx) {
    if (!ffx) return;
    destroyGeneration(ffx);
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
