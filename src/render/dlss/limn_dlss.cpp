#include "limn_dlss.h"

#include <vulkan/vulkan.h>

#include <nvsdk_ngx_vk.h>

#include <nvsdk_ngx_helpers.h>
#include <nvsdk_ngx_helpers_vk.h>

#include <nvsdk_ngx_helpers_dlssd_vk.h>

#include <cstdlib>
#include <cwchar>
#include <new>

struct LimnDlss {
    uint32_t feature = 0;
    NVSDK_NGX_Handle* handle = nullptr;
    NVSDK_NGX_Parameter* parameters = nullptr;
    uint32_t render_width = 0;
    uint32_t render_height = 0;
};

static const char* const project_id = "6d1f0c52-8a3e-4b7e-9c41-2f5d7a90e3b6";

static bool succeeded(NVSDK_NGX_Result result) {
    return NVSDK_NGX_SUCCEED(result);
}

static NVSDK_NGX_PerfQuality_Value qualityFor(const LimnDlssCreate& desc) {
    const float ratio = static_cast<float>(desc.output_height) / static_cast<float>(desc.render_height);
    if (ratio < 1.2f) return NVSDK_NGX_PerfQuality_Value_DLAA;
    if (ratio < 1.6f) return NVSDK_NGX_PerfQuality_Value_MaxQuality;
    if (ratio < 1.85f) return NVSDK_NGX_PerfQuality_Value_Balanced;
    if (ratio < 2.5f) return NVSDK_NGX_PerfQuality_Value_MaxPerf;
    return NVSDK_NGX_PerfQuality_Value_UltraPerformance;
}

static NVSDK_NGX_Resource_VK imageResource(const LimnDlssImage& image, VkImageAspectFlags aspect, bool written) {
    const VkImageSubresourceRange range = {aspect, 0, 1, 0, 1};
    return NVSDK_NGX_Create_ImageView_Resource_VK(
        reinterpret_cast<VkImageView>(image.view), reinterpret_cast<VkImage>(image.image), range,
        static_cast<VkFormat>(image.format), image.width, image.height, written);
}

static void silentLog(const char*, NVSDK_NGX_Logging_Level, NVSDK_NGX_Feature) {}

uint32_t limnDlssStart(const LimnDlssStart* desc) {
    wchar_t libraries[1024];
    wchar_t data[1024];
    if (std::mbstowcs(libraries, desc->library_directory, 1023) == static_cast<size_t>(-1)) return 0;
    if (std::mbstowcs(data, desc->data_directory, 1023) == static_cast<size_t>(-1)) return 0;
    libraries[1023] = 0;
    data[1023] = 0;
    const wchar_t* paths[] = {libraries};
    NVSDK_NGX_FeatureCommonInfo common = {};
    common.PathListInfo.Path = paths;
    common.PathListInfo.Length = libraries[0] != 0 ? 1 : 0;
    if (desc->logging != 0) {
        common.LoggingInfo.MinimumLoggingLevel = NVSDK_NGX_LOGGING_LEVEL_ON;
    } else {
        common.LoggingInfo.LoggingCallback = silentLog;
        common.LoggingInfo.MinimumLoggingLevel = NVSDK_NGX_LOGGING_LEVEL_OFF;
        common.LoggingInfo.DisableOtherLoggingSinks = true;
    }
    const NVSDK_NGX_Result started = NVSDK_NGX_VULKAN_Init_with_ProjectID(
        project_id, NVSDK_NGX_ENGINE_TYPE_CUSTOM, "1", data,
        static_cast<VkInstance>(desc->instance), static_cast<VkPhysicalDevice>(desc->physical_device), static_cast<VkDevice>(desc->device),
        reinterpret_cast<PFN_vkGetInstanceProcAddr>(desc->get_instance_proc_addr),
        reinterpret_cast<PFN_vkGetDeviceProcAddr>(desc->get_device_proc_addr), &common);
    if (!succeeded(started)) return 0;
    NVSDK_NGX_Parameter* capabilities = nullptr;
    if (!succeeded(NVSDK_NGX_VULKAN_GetCapabilityParameters(&capabilities)) || capabilities == nullptr) {
        NVSDK_NGX_VULKAN_Shutdown1(static_cast<VkDevice>(desc->device));
        return 0;
    }
    uint32_t features = 0;
    int available = 0;
    if (succeeded(NVSDK_NGX_Parameter_GetI(capabilities, NVSDK_NGX_Parameter_SuperSampling_Available, &available)) && available != 0) features |= LIMN_DLSS_SUPER_RESOLUTION;
    available = 0;
    if (succeeded(NVSDK_NGX_Parameter_GetI(capabilities, NVSDK_NGX_Parameter_SuperSamplingDenoising_Available, &available)) && available != 0) features |= LIMN_DLSS_RAY_RECONSTRUCTION;
    NVSDK_NGX_VULKAN_DestroyParameters(capabilities);
    if (features == 0) NVSDK_NGX_VULKAN_Shutdown1(static_cast<VkDevice>(desc->device));
    return features;
}

void limnDlssStop(void* device) {
    NVSDK_NGX_VULKAN_Shutdown1(static_cast<VkDevice>(device));
}

LimnDlss* limnDlssCreate(const LimnDlssCreate* desc) {
    LimnDlss* dlss = new (std::nothrow) LimnDlss();
    if (dlss == nullptr) return nullptr;
    dlss->feature = desc->feature;
    dlss->render_width = desc->render_width;
    dlss->render_height = desc->render_height;
    if (!succeeded(NVSDK_NGX_VULKAN_AllocateParameters(&dlss->parameters)) || dlss->parameters == nullptr) {
        delete dlss;
        return nullptr;
    }
    const int flags = NVSDK_NGX_DLSS_Feature_Flags_IsHDR | NVSDK_NGX_DLSS_Feature_Flags_MVLowRes | NVSDK_NGX_DLSS_Feature_Flags_DepthInverted | NVSDK_NGX_DLSS_Feature_Flags_AutoExposure;
    const VkDevice device = static_cast<VkDevice>(desc->device);
    const VkCommandBuffer commands = static_cast<VkCommandBuffer>(desc->command_buffer);
    NVSDK_NGX_Result made;
    if (desc->feature == LIMN_DLSS_RAY_RECONSTRUCTION) {
        NVSDK_NGX_DLSSD_Create_Params create = {};
        create.InDenoiseMode = NVSDK_NGX_DLSS_Denoise_Mode_DLUnified;
        create.InRoughnessMode = NVSDK_NGX_DLSS_Roughness_Mode_Packed;
        create.InUseHWDepth = NVSDK_NGX_DLSS_Depth_Type_HW;
        create.InWidth = desc->render_width;
        create.InHeight = desc->render_height;
        create.InTargetWidth = desc->output_width;
        create.InTargetHeight = desc->output_height;
        create.InPerfQualityValue = qualityFor(*desc);
        create.InFeatureCreateFlags = flags;
        made = NGX_VULKAN_CREATE_DLSSD_EXT1(device, commands, 1, 1, &dlss->handle, dlss->parameters, &create);
    } else {
        NVSDK_NGX_DLSS_Create_Params create = {};
        create.Feature.InWidth = desc->render_width;
        create.Feature.InHeight = desc->render_height;
        create.Feature.InTargetWidth = desc->output_width;
        create.Feature.InTargetHeight = desc->output_height;
        create.Feature.InPerfQualityValue = qualityFor(*desc);
        create.InFeatureCreateFlags = flags;
        made = NGX_VULKAN_CREATE_DLSS_EXT1(device, commands, 1, 1, &dlss->handle, dlss->parameters, &create);
    }
    if (!succeeded(made) || dlss->handle == nullptr) {
        NVSDK_NGX_VULKAN_DestroyParameters(dlss->parameters);
        delete dlss;
        return nullptr;
    }
    return dlss;
}

int32_t limnDlssDispatch(LimnDlss* dlss, const LimnDlssFrame* frame) {
    const VkCommandBuffer commands = static_cast<VkCommandBuffer>(frame->command_buffer);
    NVSDK_NGX_Resource_VK color = imageResource(frame->color, VK_IMAGE_ASPECT_COLOR_BIT, false);
    NVSDK_NGX_Resource_VK depth = imageResource(frame->depth, VK_IMAGE_ASPECT_DEPTH_BIT, false);
    NVSDK_NGX_Resource_VK motion = imageResource(frame->motion, VK_IMAGE_ASPECT_COLOR_BIT, false);
    NVSDK_NGX_Resource_VK output = imageResource(frame->output, VK_IMAGE_ASPECT_COLOR_BIT, true);
    if (dlss->feature == LIMN_DLSS_RAY_RECONSTRUCTION) {
        NVSDK_NGX_Resource_VK diffuse = imageResource(frame->diffuse_albedo, VK_IMAGE_ASPECT_COLOR_BIT, false);
        NVSDK_NGX_Resource_VK specular = imageResource(frame->specular_albedo, VK_IMAGE_ASPECT_COLOR_BIT, false);
        NVSDK_NGX_Resource_VK normals = imageResource(frame->normal_roughness, VK_IMAGE_ASPECT_COLOR_BIT, false);
        NVSDK_NGX_VK_DLSSD_Eval_Params eval = {};
        eval.pInColor = &color;
        eval.pInOutput = &output;
        eval.pInDepth = &depth;
        eval.pInMotionVectors = &motion;
        eval.pInDiffuseAlbedo = &diffuse;
        eval.pInSpecularAlbedo = &specular;
        eval.pInNormals = &normals;
        eval.pInRoughness = &normals;
        eval.InJitterOffsetX = frame->jitter[0];
        eval.InJitterOffsetY = frame->jitter[1];
        eval.InRenderSubrectDimensions = {dlss->render_width, dlss->render_height};
        eval.InReset = frame->reset != 0 ? 1 : 0;
        eval.InMVScaleX = frame->motion_scale[0];
        eval.InMVScaleY = frame->motion_scale[1];
        eval.pInWorldToViewMatrix = const_cast<float*>(frame->world_to_view);
        eval.pInViewToClipMatrix = const_cast<float*>(frame->view_to_clip);
        eval.InFrameTimeDeltaInMsec = frame->frame_milliseconds;
        return succeeded(NGX_VULKAN_EVALUATE_DLSSD_EXT(commands, dlss->handle, dlss->parameters, &eval)) ? 0 : -1;
    }
    NVSDK_NGX_VK_DLSS_Eval_Params eval = {};
    eval.Feature.pInColor = &color;
    eval.Feature.pInOutput = &output;
    eval.pInDepth = &depth;
    eval.pInMotionVectors = &motion;
    eval.InJitterOffsetX = frame->jitter[0];
    eval.InJitterOffsetY = frame->jitter[1];
    eval.InRenderSubrectDimensions = {dlss->render_width, dlss->render_height};
    eval.InReset = frame->reset != 0 ? 1 : 0;
    eval.InMVScaleX = frame->motion_scale[0];
    eval.InMVScaleY = frame->motion_scale[1];
    eval.InFrameTimeDeltaInMsec = frame->frame_milliseconds;
    return succeeded(NGX_VULKAN_EVALUATE_DLSS_EXT(commands, dlss->handle, dlss->parameters, &eval)) ? 0 : -1;
}

void limnDlssDestroy(LimnDlss* dlss) {
    if (dlss == nullptr) return;
    if (dlss->handle != nullptr) NVSDK_NGX_VULKAN_ReleaseFeature(dlss->handle);
    if (dlss->parameters != nullptr) NVSDK_NGX_VULKAN_DestroyParameters(dlss->parameters);
    delete dlss;
}
