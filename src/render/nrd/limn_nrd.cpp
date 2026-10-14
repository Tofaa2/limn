#include "limn_nrd.h"

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>

#include <NRD.h>

#include <cstring>
#include <new>
#include <vector>

/* The entry points this file calls, loaded for the renderer's device. */
struct Calls {
    PFN_vkGetPhysicalDeviceMemoryProperties GetPhysicalDeviceMemoryProperties;
    PFN_vkCreateImage CreateImage;
    PFN_vkDestroyImage DestroyImage;
    PFN_vkGetImageMemoryRequirements GetImageMemoryRequirements;
    PFN_vkAllocateMemory AllocateMemory;
    PFN_vkFreeMemory FreeMemory;
    PFN_vkBindImageMemory BindImageMemory;
    PFN_vkCreateImageView CreateImageView;
    PFN_vkDestroyImageView DestroyImageView;
    PFN_vkCreateSampler CreateSampler;
    PFN_vkDestroySampler DestroySampler;
    PFN_vkCreateBuffer CreateBuffer;
    PFN_vkDestroyBuffer DestroyBuffer;
    PFN_vkGetBufferMemoryRequirements GetBufferMemoryRequirements;
    PFN_vkBindBufferMemory BindBufferMemory;
    PFN_vkMapMemory MapMemory;
    PFN_vkCreateDescriptorSetLayout CreateDescriptorSetLayout;
    PFN_vkDestroyDescriptorSetLayout DestroyDescriptorSetLayout;
    PFN_vkCreatePipelineLayout CreatePipelineLayout;
    PFN_vkDestroyPipelineLayout DestroyPipelineLayout;
    PFN_vkCreateShaderModule CreateShaderModule;
    PFN_vkDestroyShaderModule DestroyShaderModule;
    PFN_vkCreateComputePipelines CreateComputePipelines;
    PFN_vkDestroyPipeline DestroyPipeline;
    PFN_vkCreateDescriptorPool CreateDescriptorPool;
    PFN_vkDestroyDescriptorPool DestroyDescriptorPool;
    PFN_vkResetDescriptorPool ResetDescriptorPool;
    PFN_vkAllocateDescriptorSets AllocateDescriptorSets;
    PFN_vkUpdateDescriptorSets UpdateDescriptorSets;
    PFN_vkCmdPipelineBarrier CmdPipelineBarrier;
    PFN_vkCmdBindPipeline CmdBindPipeline;
    PFN_vkCmdBindDescriptorSets CmdBindDescriptorSets;
    PFN_vkCmdDispatch CmdDispatch;
};

struct Pooled {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
};

struct Pass {
    VkDescriptorSetLayout set_layout = VK_NULL_HANDLE;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
};

static const uint32_t frames_kept = 3;
static const uint32_t constant_slots = 96;

struct LimnNrd {
    Calls vk = {};
    VkDevice device = VK_NULL_HANDLE;
    VkPhysicalDeviceMemoryProperties memory = {};
    nrd::Instance* instance = nullptr;
    uint32_t width = 0;
    uint32_t height = 0;
    VkSampler samplers[2] = {};
    std::vector<Pooled> permanent;
    std::vector<Pooled> transient;
    std::vector<Pass> passes;
    VkDescriptorPool pools[frames_kept] = {};
    VkBuffer constants = VK_NULL_HANDLE;
    VkDeviceMemory constants_memory = VK_NULL_HANDLE;
    uint8_t* constants_mapped = nullptr;
    uint32_t constant_stride = 0;
    uint32_t turn = 0;
    bool pooled_ready = false;
};

static const nrd::Identifier denoiser_id = 0;

static VkFormat formatOf(nrd::Format format) {
    switch (format) {
        case nrd::Format::R8_UNORM: return VK_FORMAT_R8_UNORM;
        case nrd::Format::R8_SNORM: return VK_FORMAT_R8_SNORM;
        case nrd::Format::R8_UINT: return VK_FORMAT_R8_UINT;
        case nrd::Format::R8_SINT: return VK_FORMAT_R8_SINT;
        case nrd::Format::RG8_UNORM: return VK_FORMAT_R8G8_UNORM;
        case nrd::Format::RG8_SNORM: return VK_FORMAT_R8G8_SNORM;
        case nrd::Format::RG8_UINT: return VK_FORMAT_R8G8_UINT;
        case nrd::Format::RG8_SINT: return VK_FORMAT_R8G8_SINT;
        case nrd::Format::RGBA8_UNORM: return VK_FORMAT_R8G8B8A8_UNORM;
        case nrd::Format::RGBA8_SNORM: return VK_FORMAT_R8G8B8A8_SNORM;
        case nrd::Format::RGBA8_UINT: return VK_FORMAT_R8G8B8A8_UINT;
        case nrd::Format::RGBA8_SINT: return VK_FORMAT_R8G8B8A8_SINT;
        case nrd::Format::RGBA8_SRGB: return VK_FORMAT_R8G8B8A8_SRGB;
        case nrd::Format::R16_UNORM: return VK_FORMAT_R16_UNORM;
        case nrd::Format::R16_SNORM: return VK_FORMAT_R16_SNORM;
        case nrd::Format::R16_UINT: return VK_FORMAT_R16_UINT;
        case nrd::Format::R16_SINT: return VK_FORMAT_R16_SINT;
        case nrd::Format::R16_SFLOAT: return VK_FORMAT_R16_SFLOAT;
        case nrd::Format::RG16_UNORM: return VK_FORMAT_R16G16_UNORM;
        case nrd::Format::RG16_SNORM: return VK_FORMAT_R16G16_SNORM;
        case nrd::Format::RG16_UINT: return VK_FORMAT_R16G16_UINT;
        case nrd::Format::RG16_SINT: return VK_FORMAT_R16G16_SINT;
        case nrd::Format::RG16_SFLOAT: return VK_FORMAT_R16G16_SFLOAT;
        case nrd::Format::RGBA16_UNORM: return VK_FORMAT_R16G16B16A16_UNORM;
        case nrd::Format::RGBA16_SNORM: return VK_FORMAT_R16G16B16A16_SNORM;
        case nrd::Format::RGBA16_UINT: return VK_FORMAT_R16G16B16A16_UINT;
        case nrd::Format::RGBA16_SINT: return VK_FORMAT_R16G16B16A16_SINT;
        case nrd::Format::RGBA16_SFLOAT: return VK_FORMAT_R16G16B16A16_SFLOAT;
        case nrd::Format::R32_UINT: return VK_FORMAT_R32_UINT;
        case nrd::Format::R32_SINT: return VK_FORMAT_R32_SINT;
        case nrd::Format::R32_SFLOAT: return VK_FORMAT_R32_SFLOAT;
        case nrd::Format::RG32_UINT: return VK_FORMAT_R32G32_UINT;
        case nrd::Format::RG32_SINT: return VK_FORMAT_R32G32_SINT;
        case nrd::Format::RG32_SFLOAT: return VK_FORMAT_R32G32_SFLOAT;
        case nrd::Format::RGB32_UINT: return VK_FORMAT_R32G32B32_UINT;
        case nrd::Format::RGB32_SINT: return VK_FORMAT_R32G32B32_SINT;
        case nrd::Format::RGB32_SFLOAT: return VK_FORMAT_R32G32B32_SFLOAT;
        case nrd::Format::RGBA32_UINT: return VK_FORMAT_R32G32B32A32_UINT;
        case nrd::Format::RGBA32_SINT: return VK_FORMAT_R32G32B32A32_SINT;
        case nrd::Format::RGBA32_SFLOAT: return VK_FORMAT_R32G32B32A32_SFLOAT;
        case nrd::Format::R10_G10_B10_A2_UNORM: return VK_FORMAT_A2B10G10R10_UNORM_PACK32;
        case nrd::Format::R10_G10_B10_A2_UINT: return VK_FORMAT_A2B10G10R10_UINT_PACK32;
        case nrd::Format::R11_G11_B10_UFLOAT: return VK_FORMAT_B10G11R11_UFLOAT_PACK32;
        case nrd::Format::R9_G9_B9_E5_UFLOAT: return VK_FORMAT_E5B9G9R9_UFLOAT_PACK32;
        default: return VK_FORMAT_UNDEFINED;
    }
}

static bool memoryType(const LimnNrd& nrd, uint32_t allowed, VkMemoryPropertyFlags wanted, uint32_t& index) {
    for (uint32_t i = 0; i < nrd.memory.memoryTypeCount; i++) {
        if ((allowed & (1u << i)) != 0 && (nrd.memory.memoryTypes[i].propertyFlags & wanted) == wanted) {
            index = i;
            return true;
        }
    }
    return false;
}

static bool makePooled(LimnNrd& nrd, const nrd::TextureDesc& desc, Pooled& made) {
    const uint32_t divide = desc.downsampleFactor == 0 ? 1 : desc.downsampleFactor;
    VkImageCreateInfo image = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    image.imageType = VK_IMAGE_TYPE_2D;
    image.format = formatOf(desc.format);
    image.extent = {(nrd.width + divide - 1) / divide, (nrd.height + divide - 1) / divide, 1};
    image.mipLevels = 1;
    image.arrayLayers = 1;
    image.samples = VK_SAMPLE_COUNT_1_BIT;
    image.tiling = VK_IMAGE_TILING_OPTIMAL;
    image.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT;
    image.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    image.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (nrd.vk.CreateImage(nrd.device, &image, nullptr, &made.image) != VK_SUCCESS) return false;
    VkMemoryRequirements needs = {};
    nrd.vk.GetImageMemoryRequirements(nrd.device, made.image, &needs);
    VkMemoryAllocateInfo allocation = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    allocation.allocationSize = needs.size;
    if (!memoryType(nrd, needs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, allocation.memoryTypeIndex)) return false;
    if (nrd.vk.AllocateMemory(nrd.device, &allocation, nullptr, &made.memory) != VK_SUCCESS) return false;
    if (nrd.vk.BindImageMemory(nrd.device, made.image, made.memory, 0) != VK_SUCCESS) return false;
    VkImageViewCreateInfo view = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
    view.image = made.image;
    view.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view.format = image.format;
    view.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    return nrd.vk.CreateImageView(nrd.device, &view, nullptr, &made.view) == VK_SUCCESS;
}

static void dropPooled(LimnNrd& nrd, std::vector<Pooled>& pool) {
    for (Pooled& made : pool) {
        if (made.view) nrd.vk.DestroyImageView(nrd.device, made.view, nullptr);
        if (made.image) nrd.vk.DestroyImage(nrd.device, made.image, nullptr);
        if (made.memory) nrd.vk.FreeMemory(nrd.device, made.memory, nullptr);
    }
    pool.clear();
}

static bool makePass(LimnNrd& nrd, const nrd::InstanceDesc& desc, const nrd::PipelineDesc& pipeline, Pass& pass) {
    const nrd::SPIRVBindingOffsets& offsets = nrd::GetLibraryDesc().spirvBindingOffsets;
    std::vector<VkDescriptorSetLayoutBinding> bindings;
    if (pipeline.hasConstantData) {
        bindings.push_back({offsets.constantBufferOffset + desc.constantBufferRegisterIndex, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr});
    }
    for (uint32_t i = 0; i < desc.samplersNum; i++) {
        const VkSampler* fixed = &nrd.samplers[desc.samplers[i] == nrd::Sampler::LINEAR_CLAMP ? 1 : 0];
        bindings.push_back({offsets.samplerOffset + desc.samplersBaseRegisterIndex + i, VK_DESCRIPTOR_TYPE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT, fixed});
    }
    for (uint32_t r = 0; r < pipeline.resourceRangesNum; r++) {
        const nrd::ResourceRangeDesc& range = pipeline.resourceRanges[r];
        const bool written = range.descriptorType == nrd::DescriptorType::STORAGE_TEXTURE;
        const uint32_t base = (written ? offsets.storageTextureAndBufferOffset : offsets.textureOffset) + range.baseRegisterIndex;
        for (uint32_t i = 0; i < range.descriptorsNum; i++) {
            bindings.push_back({base + i, written ? VK_DESCRIPTOR_TYPE_STORAGE_IMAGE : VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr});
        }
    }
    VkDescriptorSetLayoutCreateInfo set_layout = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    set_layout.bindingCount = static_cast<uint32_t>(bindings.size());
    set_layout.pBindings = bindings.data();
    if (nrd.vk.CreateDescriptorSetLayout(nrd.device, &set_layout, nullptr, &pass.set_layout) != VK_SUCCESS) return false;
    VkPipelineLayoutCreateInfo layout = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    layout.setLayoutCount = 1;
    layout.pSetLayouts = &pass.set_layout;
    if (nrd.vk.CreatePipelineLayout(nrd.device, &layout, nullptr, &pass.layout) != VK_SUCCESS) return false;
    VkShaderModuleCreateInfo code = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    code.codeSize = static_cast<size_t>(pipeline.computeShaderSPIRV.size);
    code.pCode = static_cast<const uint32_t*>(pipeline.computeShaderSPIRV.bytecode);
    VkShaderModule shader = VK_NULL_HANDLE;
    if (code.pCode == nullptr || nrd.vk.CreateShaderModule(nrd.device, &code, nullptr, &shader) != VK_SUCCESS) return false;
    VkComputePipelineCreateInfo compute = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    compute.stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
    compute.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    compute.stage.module = shader;
    compute.stage.pName = pipeline.shaderEntryPointName;
    compute.layout = pass.layout;
    const VkResult made = nrd.vk.CreateComputePipelines(nrd.device, VK_NULL_HANDLE, 1, &compute, nullptr, &pass.pipeline);
    nrd.vk.DestroyShaderModule(nrd.device, shader, nullptr);
    return made == VK_SUCCESS;
}

void limnNrdDestroy(LimnNrd* nrd) {
    if (nrd == nullptr) return;
    for (Pass& pass : nrd->passes) {
        if (pass.pipeline) nrd->vk.DestroyPipeline(nrd->device, pass.pipeline, nullptr);
        if (pass.layout) nrd->vk.DestroyPipelineLayout(nrd->device, pass.layout, nullptr);
        if (pass.set_layout) nrd->vk.DestroyDescriptorSetLayout(nrd->device, pass.set_layout, nullptr);
    }
    for (VkDescriptorPool pool : nrd->pools) {
        if (pool) nrd->vk.DestroyDescriptorPool(nrd->device, pool, nullptr);
    }
    dropPooled(*nrd, nrd->permanent);
    dropPooled(*nrd, nrd->transient);
    for (VkSampler sampler : nrd->samplers) {
        if (sampler) nrd->vk.DestroySampler(nrd->device, sampler, nullptr);
    }
    if (nrd->constants) nrd->vk.DestroyBuffer(nrd->device, nrd->constants, nullptr);
    if (nrd->constants_memory) nrd->vk.FreeMemory(nrd->device, nrd->constants_memory, nullptr);
    if (nrd->instance) nrd::DestroyInstance(*nrd->instance);
    delete nrd;
}

LimnNrd* limnNrdCreate(const LimnNrdCreate* create) {
    LimnNrd* nrd = new (std::nothrow) LimnNrd();
    if (nrd == nullptr) return nullptr;
    nrd->device = static_cast<VkDevice>(create->device);
    nrd->width = create->width;
    nrd->height = create->height;
    const PFN_vkGetInstanceProcAddr of_instance = reinterpret_cast<PFN_vkGetInstanceProcAddr>(create->get_instance_proc_addr);
    const PFN_vkGetDeviceProcAddr of_device = reinterpret_cast<PFN_vkGetDeviceProcAddr>(create->get_device_proc_addr);
    nrd->vk.GetPhysicalDeviceMemoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
        of_instance(static_cast<VkInstance>(create->instance), "vkGetPhysicalDeviceMemoryProperties"));
#define LOAD(name) nrd->vk.name = reinterpret_cast<PFN_vk##name>(of_device(nrd->device, "vk" #name))
    LOAD(CreateImage);
    LOAD(DestroyImage);
    LOAD(GetImageMemoryRequirements);
    LOAD(AllocateMemory);
    LOAD(FreeMemory);
    LOAD(BindImageMemory);
    LOAD(CreateImageView);
    LOAD(DestroyImageView);
    LOAD(CreateSampler);
    LOAD(DestroySampler);
    LOAD(CreateBuffer);
    LOAD(DestroyBuffer);
    LOAD(GetBufferMemoryRequirements);
    LOAD(BindBufferMemory);
    LOAD(MapMemory);
    LOAD(CreateDescriptorSetLayout);
    LOAD(DestroyDescriptorSetLayout);
    LOAD(CreatePipelineLayout);
    LOAD(DestroyPipelineLayout);
    LOAD(CreateShaderModule);
    LOAD(DestroyShaderModule);
    LOAD(CreateComputePipelines);
    LOAD(DestroyPipeline);
    LOAD(CreateDescriptorPool);
    LOAD(DestroyDescriptorPool);
    LOAD(ResetDescriptorPool);
    LOAD(AllocateDescriptorSets);
    LOAD(UpdateDescriptorSets);
    LOAD(CmdPipelineBarrier);
    LOAD(CmdBindPipeline);
    LOAD(CmdBindDescriptorSets);
    LOAD(CmdDispatch);
#undef LOAD
    if (nrd->vk.GetPhysicalDeviceMemoryProperties == nullptr || nrd->vk.CmdDispatch == nullptr) {
        delete nrd;
        return nullptr;
    }
    nrd->vk.GetPhysicalDeviceMemoryProperties(static_cast<VkPhysicalDevice>(create->physical_device), &nrd->memory);

    const nrd::DenoiserDesc denoisers[] = {{denoiser_id, nrd::Denoiser::RELAX_DIFFUSE_SPECULAR}};
    nrd::InstanceCreationDesc creation = {};
    creation.denoisers = denoisers;
    creation.denoisersNum = 1;
    if (nrd::CreateInstance(creation, nrd->instance) != nrd::Result::SUCCESS) {
        nrd->instance = nullptr;
        limnNrdDestroy(nrd);
        return nullptr;
    }
    const nrd::InstanceDesc& desc = nrd::GetInstanceDesc(*nrd->instance);

    bool made = true;
    for (uint32_t i = 0; i < 2 && made; i++) {
        VkSamplerCreateInfo sampler = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
        sampler.magFilter = sampler.minFilter = i == 0 ? VK_FILTER_NEAREST : VK_FILTER_LINEAR;
        sampler.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
        sampler.addressModeU = sampler.addressModeV = sampler.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        made = nrd->vk.CreateSampler(nrd->device, &sampler, nullptr, &nrd->samplers[i]) == VK_SUCCESS;
    }
    nrd->permanent.resize(desc.permanentPoolSize);
    for (uint32_t i = 0; i < desc.permanentPoolSize && made; i++) made = makePooled(*nrd, desc.permanentPool[i], nrd->permanent[i]);
    nrd->transient.resize(desc.transientPoolSize);
    for (uint32_t i = 0; i < desc.transientPoolSize && made; i++) made = makePooled(*nrd, desc.transientPool[i], nrd->transient[i]);
    nrd->passes.resize(desc.pipelinesNum);
    for (uint32_t i = 0; i < desc.pipelinesNum && made; i++) made = makePass(*nrd, desc, desc.pipelines[i], nrd->passes[i]);

    for (uint32_t i = 0; i < frames_kept && made; i++) {
        const VkDescriptorPoolSize sizes[] = {
            {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, constant_slots},
            {VK_DESCRIPTOR_TYPE_SAMPLER, constant_slots * 2},
            {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, constant_slots * 16},
            {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, constant_slots * 8},
        };
        VkDescriptorPoolCreateInfo pool = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        pool.maxSets = constant_slots;
        pool.poolSizeCount = 4;
        pool.pPoolSizes = sizes;
        made = nrd->vk.CreateDescriptorPool(nrd->device, &pool, nullptr, &nrd->pools[i]) == VK_SUCCESS;
    }
    if (made) {
        nrd->constant_stride = (desc.constantBufferMaxDataSize + 255u) & ~255u;
        VkBufferCreateInfo buffer = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        buffer.size = static_cast<VkDeviceSize>(nrd->constant_stride) * constant_slots * frames_kept;
        buffer.usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        buffer.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        made = nrd->vk.CreateBuffer(nrd->device, &buffer, nullptr, &nrd->constants) == VK_SUCCESS;
        VkMemoryRequirements needs = {};
        VkMemoryAllocateInfo allocation = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        if (made) {
            nrd->vk.GetBufferMemoryRequirements(nrd->device, nrd->constants, &needs);
            allocation.allocationSize = needs.size;
            made = memoryType(*nrd, needs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, allocation.memoryTypeIndex);
        }
        made = made && nrd->vk.AllocateMemory(nrd->device, &allocation, nullptr, &nrd->constants_memory) == VK_SUCCESS;
        made = made && nrd->vk.BindBufferMemory(nrd->device, nrd->constants, nrd->constants_memory, 0) == VK_SUCCESS;
        void* mapped = nullptr;
        made = made && nrd->vk.MapMemory(nrd->device, nrd->constants_memory, 0, VK_WHOLE_SIZE, 0, &mapped) == VK_SUCCESS;
        nrd->constants_mapped = static_cast<uint8_t*>(mapped);
    }
    if (!made) {
        limnNrdDestroy(nrd);
        return nullptr;
    }
    return nrd;
}

static void readyPooled(const LimnNrd& nrd, VkCommandBuffer command, const std::vector<Pooled>& pool) {
    for (const Pooled& made : pool) {
        VkImageMemoryBarrier barrier = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;
        barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = made.image;
        barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        nrd.vk.CmdPipelineBarrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
    }
}

static void wholeBarrier(const LimnNrd& nrd, VkCommandBuffer command) {
    VkMemoryBarrier barrier = {VK_STRUCTURE_TYPE_MEMORY_BARRIER};
    barrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
    nrd.vk.CmdPipelineBarrier(command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, nullptr, 0, nullptr);
}

int32_t limnNrdDispatch(LimnNrd* nrd, const LimnNrdFrame* frame) {
    const VkCommandBuffer command = static_cast<VkCommandBuffer>(frame->command_buffer);
    const bool first = !nrd->pooled_ready;
    if (first) {
        readyPooled(*nrd, command, nrd->permanent);
        readyPooled(*nrd, command, nrd->transient);
        nrd->pooled_ready = true;
    }

    nrd::CommonSettings common = {};
    std::memcpy(common.viewToClipMatrix, frame->view_to_clip, sizeof(common.viewToClipMatrix));
    std::memcpy(common.viewToClipMatrixPrev, frame->view_to_clip_previous, sizeof(common.viewToClipMatrixPrev));
    std::memcpy(common.worldToViewMatrix, frame->world_to_view, sizeof(common.worldToViewMatrix));
    std::memcpy(common.worldToViewMatrixPrev, frame->world_to_view_previous, sizeof(common.worldToViewMatrixPrev));
    common.motionVectorScale[0] = frame->motion_scale[0];
    common.motionVectorScale[1] = frame->motion_scale[1];
    common.motionVectorScale[2] = 0.0f;
    common.cameraJitter[0] = frame->jitter[0];
    common.cameraJitter[1] = frame->jitter[1];
    common.cameraJitterPrev[0] = frame->jitter_previous[0];
    common.cameraJitterPrev[1] = frame->jitter_previous[1];
    common.resourceSize[0] = common.resourceSizePrev[0] = common.rectSize[0] = common.rectSizePrev[0] = static_cast<uint16_t>(nrd->width);
    common.resourceSize[1] = common.resourceSizePrev[1] = common.rectSize[1] = common.rectSizePrev[1] = static_cast<uint16_t>(nrd->height);
    common.timeDeltaBetweenFrames = frame->frame_milliseconds;
    common.denoisingRange = 50000.0f;
    common.frameIndex = frame->frame_index;
    common.accumulationMode = first ? nrd::AccumulationMode::CLEAR_AND_RESTART : (frame->reset ? nrd::AccumulationMode::RESTART : nrd::AccumulationMode::CONTINUE);
    common.isMotionVectorInWorldSpace = false;
    if (nrd::SetCommonSettings(*nrd->instance, common) != nrd::Result::SUCCESS) return 1;
    nrd::RelaxSettings relax = {};
    relax.enableAntiFirefly = true;
    relax.diffusePrepassBlurRadius = frame->blur_radius;
    relax.specularPrepassBlurRadius = frame->blur_radius;
    relax.diffuseMaxAccumulatedFrameNum = relax.specularMaxAccumulatedFrameNum = frame->history_frames;
    relax.diffuseMaxFastAccumulatedFrameNum = relax.specularMaxFastAccumulatedFrameNum = frame->fast_history_frames;
    if (nrd::SetDenoiserSettings(*nrd->instance, denoiser_id, &relax) != nrd::Result::SUCCESS) return 2;

    const nrd::DispatchDesc* dispatches = nullptr;
    uint32_t dispatch_count = 0;
    if (nrd::GetComputeDispatches(*nrd->instance, &denoiser_id, 1, dispatches, dispatch_count) != nrd::Result::SUCCESS) return 3;
    if (dispatch_count > constant_slots) return 4;

    const nrd::InstanceDesc& desc = nrd::GetInstanceDesc(*nrd->instance);
    const nrd::SPIRVBindingOffsets& offsets = nrd::GetLibraryDesc().spirvBindingOffsets;
    nrd->turn = (nrd->turn + 1) % frames_kept;
    const VkDescriptorPool pool = nrd->pools[nrd->turn];
    nrd->vk.ResetDescriptorPool(nrd->device, pool, 0);
    const VkDeviceSize constants_base = static_cast<VkDeviceSize>(nrd->turn) * constant_slots * nrd->constant_stride;
    uint32_t constant_slot = 0;
    uint32_t constant_offset = 0;

    for (uint32_t d = 0; d < dispatch_count; d++) {
        const nrd::DispatchDesc& dispatch = dispatches[d];
        const nrd::PipelineDesc& pipeline = desc.pipelines[dispatch.pipelineIndex];
        const Pass& pass = nrd->passes[dispatch.pipelineIndex];

        VkDescriptorSetAllocateInfo allocation = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        allocation.descriptorPool = pool;
        allocation.descriptorSetCount = 1;
        allocation.pSetLayouts = &pass.set_layout;
        VkDescriptorSet set = VK_NULL_HANDLE;
        if (nrd->vk.AllocateDescriptorSets(nrd->device, &allocation, &set) != VK_SUCCESS) return 5;

        VkDescriptorImageInfo images[32];
        VkWriteDescriptorSet writes[33];
        uint32_t write_count = 0;
        uint32_t resource = 0;
        for (uint32_t r = 0; r < pipeline.resourceRangesNum; r++) {
            const nrd::ResourceRangeDesc& range = pipeline.resourceRanges[r];
            const bool written = range.descriptorType == nrd::DescriptorType::STORAGE_TEXTURE;
            const uint32_t base = (written ? offsets.storageTextureAndBufferOffset : offsets.textureOffset) + range.baseRegisterIndex;
            for (uint32_t i = 0; i < range.descriptorsNum; i++, resource++) {
                if (resource >= dispatch.resourcesNum || write_count >= 32) return 6;
                const nrd::ResourceDesc& wanted = dispatch.resources[resource];
                VkImageView view = VK_NULL_HANDLE;
                VkImageLayout layout = VK_IMAGE_LAYOUT_GENERAL;
                switch (wanted.type) {
                    case nrd::ResourceType::PERMANENT_POOL: view = nrd->permanent[wanted.indexInPool].view; break;
                    case nrd::ResourceType::TRANSIENT_POOL: view = nrd->transient[wanted.indexInPool].view; break;
                    case nrd::ResourceType::IN_MV: view = (VkImageView)frame->motion; layout = (VkImageLayout)frame->input_layout; break;
                    case nrd::ResourceType::IN_NORMAL_ROUGHNESS: view = (VkImageView)frame->normal_roughness; layout = (VkImageLayout)frame->input_layout; break;
                    case nrd::ResourceType::IN_VIEWZ: view = (VkImageView)frame->view_depth; layout = (VkImageLayout)frame->input_layout; break;
                    case nrd::ResourceType::IN_DIFF_RADIANCE_HITDIST: view = (VkImageView)frame->diffuse; layout = (VkImageLayout)frame->input_layout; break;
                    case nrd::ResourceType::IN_SPEC_RADIANCE_HITDIST: view = (VkImageView)frame->specular; layout = (VkImageLayout)frame->input_layout; break;
                    case nrd::ResourceType::OUT_DIFF_RADIANCE_HITDIST: view = (VkImageView)frame->diffuse_out; break;
                    case nrd::ResourceType::OUT_SPEC_RADIANCE_HITDIST: view = (VkImageView)frame->specular_out; break;
                    default: return 7;
                }
                images[write_count] = {VK_NULL_HANDLE, view, layout};
                writes[write_count] = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
                writes[write_count].dstSet = set;
                writes[write_count].dstBinding = base + i;
                writes[write_count].descriptorCount = 1;
                writes[write_count].descriptorType = written ? VK_DESCRIPTOR_TYPE_STORAGE_IMAGE : VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
                writes[write_count].pImageInfo = &images[write_count];
                write_count++;
            }
        }
        VkDescriptorBufferInfo constants = {nrd->constants, constants_base, nrd->constant_stride};
        if (pipeline.hasConstantData) {
            if (dispatch.constantBufferDataSize != 0 && !(dispatch.constantBufferDataMatchesPreviousDispatch && d != 0)) {
                if (dispatch.constantBufferDataSize > nrd->constant_stride) return 8;
                constant_offset = constant_slot * nrd->constant_stride;
                std::memcpy(nrd->constants_mapped + constants_base + constant_offset, dispatch.constantBufferData, dispatch.constantBufferDataSize);
                constant_slot++;
            }
            writes[write_count] = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
            writes[write_count].dstSet = set;
            writes[write_count].dstBinding = offsets.constantBufferOffset + desc.constantBufferRegisterIndex;
            writes[write_count].descriptorCount = 1;
            writes[write_count].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
            writes[write_count].pBufferInfo = &constants;
            write_count++;
        }
        nrd->vk.UpdateDescriptorSets(nrd->device, write_count, writes, 0, nullptr);

        wholeBarrier(*nrd, command);
        nrd->vk.CmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, pass.pipeline);
        nrd->vk.CmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE, pass.layout, 0, 1, &set, pipeline.hasConstantData ? 1 : 0, &constant_offset);
        nrd->vk.CmdDispatch(command, dispatch.gridWidth, dispatch.gridHeight, 1);
    }
    wholeBarrier(*nrd, command);
    return 0;
}
