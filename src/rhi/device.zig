//! The Vulkan device layer: instance, device, queue, resources, the bindless
//! table and the frame loop. Shaders reach textures and samplers through one
//! global descriptor set and buffers through device addresses.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("types.zig");
const loader = @import("loader.zig");
const dispatch = @import("dispatch.zig");
const memory = @import("memory.zig");
const HandleTable = @import("../handle.zig").HandleTable;
const CommandEncoder = @import("command.zig").CommandEncoder;
const buffers_module = @import("device/buffers.zig");
const textures_module = @import("device/textures.zig");
const acceleration_module = @import("device/acceleration.zig");
const pipelines_module = @import("device/pipelines.zig");
const presentation_module = @import("device/presentation.zig");
const frames_module = @import("device/frames.zig");
const adapter_module = @import("device/adapter.zig");
const objects_module = @import("device/objects.zig");

/// Frames the CPU may record before waiting for the GPU; a destroyed
/// resource outlives this many submitted frames.
pub const frames_in_flight = 2;
pub const max_mip_levels = 16;
/// Regions per frame `CommandEncoder.beginScope` can time; further ones
/// get no timing.
pub const max_timing_scopes = 48;
/// Bytes of the push constant block shared by every pipeline and stage.
pub const push_constant_size = 256;
const texture_capacity = 16384;
const sampler_capacity = 256;
const storage_capacity = 1024;
pub const required_api_version = vk.API_VERSION_1_3.toU32();

/// From `Device.bufferResource`.
pub const BufferResource = struct {
    handle: vk.Buffer,
    allocation: memory.Allocation,
    /// Requested size in bytes.
    size: u64,
    address: u64,
};

const SubView = struct { mip: u32, layer: u32, view: vk.ImageView };
const StorageSlot = struct { mip: u32, slot: u32 };

/// From `Device.textureResource`.
pub const TextureResource = struct {
    image: vk.Image,
    /// Null for swapchain images, whose memory the swapchain owns.
    allocation: ?memory.Allocation,
    /// View of every mip and layer.
    view: vk.ImageView,
    info: types.TextureInfo,
    vk_format: vk.Format,
    aspect: vk.ImageAspectFlags,
    /// Null unless created with `sampled`.
    bindless_index: ?u32,
    /// State of each mip as of the commands recorded so far; maintained by
    /// the encoder's transitions.
    states: [max_mip_levels]types.TextureState = @splat(.undefined),
    /// Single mip/layer views, made on demand by `Device.subView`.
    sub_views: std.ArrayList(SubView) = .empty,
    /// Storage image slots per mip, made on demand by `Device.storageIndex`.
    storage_slots: std.ArrayList(StorageSlot) = .empty,
};

const SamplerResource = struct { handle: vk.Sampler, bindless_index: u32 };

/// From `Device.accelerationResource`.
pub const AccelerationResource = struct {
    handle: vk.AccelerationStructureKHR,
    /// Buffer holding the structure; destroyed with it.
    buffer: types.Buffer,
    address: u64,
    top_level: bool,
    /// Kept for structures that are rebuilt every frame.
    scratch: ?types.Buffer = null,
    scratch_size: u64,
    /// Rebuilt every frame: built for speed, scratch memory kept.
    dynamic: bool = false,
    /// A built dynamic structure is refitted instead of rebuilt.
    built: bool = false,
    /// Triangles (bottom level) or instances (top level) it was sized for.
    capacity: u32 = 0,
};

/// From `Device.pipelineResource`.
pub const PipelineResource = struct {
    handle: vk.Pipeline,
    bind_point: vk.PipelineBindPoint,
};

pub const Deletion = union(enum) {
    buffer: struct { handle: vk.Buffer, allocation: memory.Allocation },
    image: struct { handle: vk.Image, allocation: ?memory.Allocation },
    view: vk.ImageView,
    sampler: vk.Sampler,
    pipeline: vk.Pipeline,
    acceleration: vk.AccelerationStructureKHR,
    texture_slot: u32,
    sampler_slot: u32,
    storage_slot: u32,
};

const PendingDeletion = struct { frame: u64, object: Deletion };

/// Work submitted to the second queue by `Device.submitDetached`.
pub const Detached = struct {
    command: vk.CommandBuffer,
    fence: vk.Fence,
};

pub const PendingUpload = union(enum) {
    buffer: struct { staging: types.Buffer, destination: types.Buffer, offset: u64, size: u64 },
    /// `offset` is the level's start in the staging buffer, which levels
    /// may share; the entry marked `last` releases it.
    texture: struct { staging: types.Buffer, destination: types.Texture, mip: u32, layer: u32, offset: u64 = 0, last: bool = true },
    mips: types.Texture,
    /// The source is destroyed afterwards.
    copy: struct { source: types.Buffer, destination: types.Buffer, size: u64 },
};

const Scope = struct { name: []const u8, depth: u8 };

/// One of the `frames_in_flight` slots of the frame loop.
pub const FrameData = struct {
    pool: vk.CommandPool,
    command: vk.CommandBuffer,
    /// Signaled when the GPU has finished the slot's last frame.
    fence: vk.Fence,
    /// Signaled when the acquired swapchain image is ready.
    image_available: vk.Semaphore,
    /// The same for the image a generated frame goes to.
    generated_available: vk.Semaphore,
    /// Two timestamps per timing scope.
    query_pool: vk.QueryPool,
    /// Scopes opened this frame, in `beginScope` order.
    scopes: [max_timing_scopes]Scope = undefined,
    scope_count: u32 = 0,
    /// Submitted at least once, so its queries can be read back.
    submitted: bool = false,
    /// An image was acquired and never presented; see
    /// `Device.abandonAcquiredImage`.
    acquire_abandoned: bool = false,
};

const Swapchain = struct {
    handle: vk.SwapchainKHR = .null_handle,
    format: vk.SurfaceFormatKHR = undefined,
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    textures: std.ArrayList(types.Texture) = .empty,
    render_finished: std.ArrayList(vk.Semaphore) = .empty,
    requested_width: u32,
    requested_height: u32,
    vsync: bool,
    /// Set by `resize`/`setVsync`; may be written under an external lock.
    dirty: bool = true,
    /// Set by acquire/present; owned by the frame loop.
    stale: bool = false,
    present_pending: bool = false,
    image_index: u32 = 0,
    /// The backbuffer copied for the frame generator and what it writes, in
    /// the UNORM form of the swapchain format. Null when there is no
    /// generator or the swapchain cannot serve one.
    generated: ?[2]types.Texture = null,
    /// The image this frame's generated picture is in; presented first.
    generated_index: ?u32 = null,
    /// Presents queue for the display's refresh, which spaces a generated
    /// picture from the one after it. Otherwise `Device.paced` does.
    fifo: bool = true,
};

/// Makes the picture shown between two frames; see `Device.setFrameGenerator`.
pub const FrameGenerator = struct {
    context: *anyopaque,
    /// `shown` is a copy of this frame's backbuffer. Both textures are in
    /// `shader_read` and must be left in it. False when there is no picture
    /// to show, as on the first frame.
    generate: *const fn (context: *anyopaque, cmd: *CommandEncoder, shown: types.Texture, output: types.Texture) bool,
};

/// A frame being recorded; valid until it is submitted.
pub const Frame = struct {
    /// Globals are bound and queued uploads already recorded.
    cmd: *CommandEncoder,
    /// Null when headless.
    backbuffer: ?types.Texture,
    /// Frame counter, starting at 0.
    index: u64,
};

const createSurface = adapter_module.createSurface;
const destroyNow = objects_module.destroyNow;
const destroySwapchain = presentation_module.destroySwapchain;
const deviceExtensionListed = adapter_module.deviceExtensionListed;
const instanceExtensionAvailable = adapter_module.instanceExtensionAvailable;
const persistPipelineCache = pipelines_module.persistPipelineCache;
const selectPhysicalDevice = adapter_module.selectPhysicalDevice;
const shadingRateTile = adapter_module.shadingRateTile;
const supportsMeshShaders = adapter_module.supportsMeshShaders;
const supportsRayQueries = adapter_module.supportsRayQueries;

/// Not movable, and not thread-safe except: `compileGraphicsPipeline` and
/// `validationErrorCount` run on any thread; `waitForFrame`, `acquireImage`
/// and `presentFrame` may run outside the caller's device lock.
pub const Device = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// `instance` and `vkd` point at these wrappers.
    instance_wrapper: dispatch.InstanceWrapper,
    instance: dispatch.Instance,
    physical: vk.PhysicalDevice,
    device_wrapper: dispatch.DeviceWrapper,
    vkd: dispatch.Device,
    /// The only queue; submit under `queue_mutex`.
    queue: vk.Queue,
    queue_family: u32,
    properties: vk.PhysicalDeviceProperties,
    allocator: memory.Allocator,
    debug_messenger: vk.DebugUtilsMessengerEXT = .null_handle,
    /// Validation or `DeviceDesc.debug_names` is on.
    debug_labels: bool,
    /// BC texture formats can be used.
    bc_textures: bool = false,
    /// The surface is HDR10: the backbuffer takes PQ-encoded Rec.2020.
    hdr_active: bool = false,
    /// HDR output was requested; `hdr_active` says whether it was granted.
    hdr_wanted: bool = false,
    /// Ray queries and acceleration structures are available.
    ray_tracing: bool = false,
    /// Compute shaders can write textures (`TextureUsage.storage`).
    storage_images: bool = false,
    /// Pixels per shading rate texel each way; 0 when unsupported.
    shading_rate_tile: u32 = 0,
    /// Task and mesh shaders are available.
    mesh_shaders: bool = false,
    accelerations: HandleTable(AccelerationResource, types.AccelerationTag),
    /// Read with `validationErrorCount`.
    validation_errors: std.atomic.Value(u32) = .init(0),
    surface: vk.SurfaceKHR = .null_handle,
    swapchain: ?Swapchain = null,
    frame_generator: ?FrameGenerator = null,
    /// Held to acquire from or present to the swapchain.
    swapchain_mutex: std.Io.Mutex = .init,
    /// The backbuffer's present, held back half a frame behind a generated
    /// picture's. `pacing` is set while it is outstanding.
    paced: ?std.Io.Future(void) = null,
    paced_mutex: std.Io.Mutex = .init,
    pacing: std.atomic.Value(bool) = .init(false),
    last_present: ?std.Io.Timestamp = null,
    /// Images presented since the device was made, generated ones included.
    presented: std.atomic.Value(u64) = .init(0),

    /// The bindless set: sampled images at binding 0, samplers at binding 1.
    descriptor_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor_set: vk.DescriptorSet,
    /// Shared by every pipeline: the bindless set plus the push constants.
    pipeline_layout: vk.PipelineLayout,
    pipeline_cache: vk.PipelineCache,
    pipeline_cache_path: ?[]u8,
    texture_slots: SlotAllocator,
    storage_slots: SlotAllocator,
    sampler_slots: SlotAllocator,

    buffers: HandleTable(BufferResource, types.BufferTag),
    textures: HandleTable(TextureResource, types.TextureTag),
    samplers: HandleTable(SamplerResource, types.SamplerTag),
    pipelines: HandleTable(PipelineResource, types.PipelineTag),

    frames: [frames_in_flight]FrameData,
    /// Frames submitted so far; the index of the frame being recorded.
    frame_number: u64 = 0,
    /// True between `startFrame` and `submitFrame`.
    in_frame: bool = false,
    /// Meaningful while `in_frame`.
    encoder: CommandEncoder = undefined,
    /// Destroyed objects waiting out the frames in flight.
    deletions: std.ArrayList(PendingDeletion) = .empty,
    uploads: std.ArrayList(PendingUpload) = .empty,
    pending_upload_bytes: u64 = 0,
    timings: [max_timing_scopes]types.PassTiming = undefined,
    timing_count: u32 = 0,
    /// Command pool and buffer behind `beginImmediate`.
    immediate_pool: vk.CommandPool,
    immediate_command: vk.CommandBuffer,
    /// Serializes queue submission and presentation.
    queue_mutex: std.Io.Mutex = .init,
    /// Second queue, where the GPU has one, for `beginDetached` work.
    detached_queue: ?vk.Queue = null,
    detached_pool: vk.CommandPool = .null_handle,
    /// Detached jobs submitted and not yet released.
    detached_outstanding: u32 = 0,

    /// Creates a device on the best Vulkan 1.3 adapter. Keeps `gpa` and `io`;
    /// the window must outlive it. Fails with `error.VulkanLoaderUnavailable`,
    /// `error.Vulkan13Unavailable` or `error.NoSuitableDevice`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, desc: types.DeviceDesc) !*Device {
        try loader.acquire(io);
        errdefer loader.release(io);
        const self = try gpa.create(Device);
        errdefer gpa.destroy(self);
        inline for (@typeInfo(Device).@"struct".fields) |field| {
            if (field.defaultValue()) |value| @field(self, field.name) = value;
        }

        const base = loader.base();
        const loader_version = if (base.dispatch.vkEnumerateInstanceVersion != null)
            try base.enumerateInstanceVersion()
        else
            vk.API_VERSION_1_0.toU32();
        if (loader_version < required_api_version) return error.Vulkan13Unavailable;

        var instance_extensions: [5][*:0]const u8 = undefined;
        var instance_extension_count: u32 = 0;
        var hdr_wanted = false;
        const debug_utils = desc.validation or (desc.debug_names and try instanceExtensionAvailable(gpa, base, vk.extensions.ext_debug_utils.name));
        if (debug_utils) {
            instance_extensions[instance_extension_count] = vk.extensions.ext_debug_utils.name;
            instance_extension_count += 1;
        }
        if (desc.surface != null and desc.hdr_output and try instanceExtensionAvailable(gpa, base, vk.extensions.ext_swapchain_colorspace.name)) {
            instance_extensions[instance_extension_count] = vk.extensions.ext_swapchain_colorspace.name;
            instance_extension_count += 1;
            hdr_wanted = true;
        }
        if (desc.surface) |surface| {
            instance_extensions[instance_extension_count] = vk.extensions.khr_surface.name;
            instance_extension_count += 1;
            instance_extensions[instance_extension_count] = switch (surface.window) {
                .xlib => vk.extensions.khr_xlib_surface.name,
                .wayland => vk.extensions.khr_wayland_surface.name,
                .win32 => vk.extensions.khr_win_32_surface.name,
            };
            instance_extension_count += 1;
        }
        const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
        const validation_enables = [_]vk.ValidationFeatureEnableEXT{.synchronization_validation_ext};
        const validation_features = vk.ValidationFeaturesEXT{
            .enabled_validation_feature_count = validation_enables.len,
            .p_enabled_validation_features = &validation_enables,
        };
        const instance_handle = try base.createInstance(&.{
            .p_next = if (desc.validation) &validation_features else null,
            .p_application_info = &.{
                .p_application_name = desc.application_name,
                .application_version = 1,
                .p_engine_name = "limn",
                .engine_version = 1,
                .api_version = required_api_version,
            },
            .enabled_layer_count = if (desc.validation) validation_layers.len else 0,
            .pp_enabled_layer_names = &validation_layers,
            .enabled_extension_count = instance_extension_count,
            .pp_enabled_extension_names = &instance_extensions,
        }, null);

        self.gpa = gpa;
        self.io = io;
        self.instance_wrapper = loader.instance(io, instance_handle);
        self.instance = dispatch.Instance.init(instance_handle, &self.instance_wrapper);
        errdefer self.instance.destroyInstance(null);
        self.debug_messenger = .null_handle;
        self.debug_labels = debug_utils;
        self.hdr_wanted = hdr_wanted;
        self.validation_errors = .init(0);
        self.surface = .null_handle;
        self.swapchain = null;
        self.frame_number = 0;
        self.in_frame = false;
        self.deletions = .empty;
        self.uploads = .empty;
        self.pending_upload_bytes = 0;
        self.timing_count = 0;
        self.queue_mutex = .init;

        if (desc.validation) {
            self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&.{
                .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true },
                .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true },
                .pfn_user_callback = debugCallback,
                .p_user_data = self,
            }, null);
        }
        errdefer if (self.debug_messenger != .null_handle)
            self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);

        if (desc.surface) |surface| self.surface = try createSurface(self.instance, surface.window);
        errdefer if (self.surface != .null_handle) self.instance.destroySurfaceKHR(self.surface, null);

        const selected = try selectPhysicalDevice(gpa, self.instance, self.surface, desc.preferred_device);
        self.physical = selected.physical;
        self.queue_family = selected.queue_family;
        const queue_count: u32 = @min(selected.queue_count, 2);
        self.properties = selected.properties;

        self.ray_tracing = desc.ray_tracing and try supportsRayQueries(gpa, self.instance, self.physical);
        self.bc_textures = blk: {
            var supported = vk.PhysicalDeviceFeatures2{ .features = .{} };
            self.instance.getPhysicalDeviceFeatures2(self.physical, &supported);
            break :blk supported.features.texture_compression_bc == .true;
        };
        self.storage_images = blk: {
            var supported12 = vk.PhysicalDeviceVulkan12Features{};
            var supported = vk.PhysicalDeviceFeatures2{ .p_next = &supported12, .features = .{} };
            self.instance.getPhysicalDeviceFeatures2(self.physical, &supported);
            break :blk supported.features.shader_storage_image_array_dynamic_indexing == .true and
                supported.features.shader_storage_image_write_without_format == .true and
                supported12.descriptor_binding_storage_image_update_after_bind == .true;
        };
        self.shading_rate_tile = try shadingRateTile(gpa, self.instance, self.physical);
        self.mesh_shaders = desc.mesh_shaders and try supportsMeshShaders(gpa, self.instance, self.physical);
        var mesh_shader_features = vk.PhysicalDeviceMeshShaderFeaturesEXT{ .task_shader = .true, .mesh_shader = .true };
        var shading_rate_features = vk.PhysicalDeviceFragmentShadingRateFeaturesKHR{
            .p_next = if (self.mesh_shaders) &mesh_shader_features else null,
            .pipeline_fragment_shading_rate = .true,
            .attachment_fragment_shading_rate = .true,
        };
        const after_shading_rate: ?*anyopaque = if (self.mesh_shaders) &mesh_shader_features else null;
        const after_rays: ?*anyopaque = if (self.shading_rate_tile != 0) &shading_rate_features else after_shading_rate;
        var ray_query_features = vk.PhysicalDeviceRayQueryFeaturesKHR{
            .p_next = after_rays,
            .ray_query = .true,
        };
        var acceleration_features = vk.PhysicalDeviceAccelerationStructureFeaturesKHR{
            .p_next = &ray_query_features,
            .acceleration_structure = .true,
        };
        var features13 = vk.PhysicalDeviceVulkan13Features{
            .p_next = if (self.ray_tracing) @as(?*anyopaque, &acceleration_features) else after_rays,
            .synchronization_2 = .true,
            .dynamic_rendering = .true,
            .shader_demote_to_helper_invocation = .true,
            .maintenance_4 = .true,
        };
        var features12 = vk.PhysicalDeviceVulkan12Features{
            .p_next = &features13,
            .descriptor_indexing = .true,
            .shader_sampled_image_array_non_uniform_indexing = .true,
            .descriptor_binding_sampled_image_update_after_bind = .true,
            .descriptor_binding_storage_image_update_after_bind = if (self.storage_images) .true else .false,
            .descriptor_binding_update_unused_while_pending = .true,
            .descriptor_binding_partially_bound = .true,
            .runtime_descriptor_array = .true,
            .scalar_block_layout = .true,
            .buffer_device_address = .true,
            .draw_indirect_count = .true,
        };
        var features11 = vk.PhysicalDeviceVulkan11Features{
            .p_next = &features12,
            .shader_draw_parameters = .true,
        };
        const features = vk.PhysicalDeviceFeatures2{
            .p_next = &features11,
            .features = .{
                .sampler_anisotropy = .true,
                .multi_draw_indirect = .true,
                .draw_indirect_first_instance = .true,
                .independent_blend = .true,
                .depth_clamp = .true,
                .depth_bias_clamp = .true,
                .shader_int_64 = .true,
                .geometry_shader = .true,
                .image_cube_array = .true,
                .texture_compression_bc = if (self.bc_textures) .true else .false,
                .shader_clip_distance = .true,
                .shader_storage_image_array_dynamic_indexing = if (self.storage_images) .true else .false,
                .shader_storage_image_write_without_format = if (self.storage_images) .true else .false,
            },
        };
        const queue_priorities = [2]f32{ 1, 0.5 };
        var device_extensions: [8][*:0]const u8 = undefined;
        var device_extension_count: u32 = 0;
        if (self.shading_rate_tile != 0) {
            device_extensions[device_extension_count] = vk.extensions.khr_fragment_shading_rate.name;
            device_extension_count += 1;
        }
        if (self.mesh_shaders) {
            device_extensions[device_extension_count] = vk.extensions.ext_mesh_shader.name;
            device_extension_count += 1;
        }
        if (self.surface != .null_handle) {
            device_extensions[device_extension_count] = vk.extensions.khr_swapchain.name;
            device_extension_count += 1;
        }
        if (self.ray_tracing) {
            for (ray_query_extensions) |extension| {
                device_extensions[device_extension_count] = extension;
                device_extension_count += 1;
            }
        }
        for ([_][*:0]const u8{ vk.extensions.khr_get_memory_requirements_2.name, vk.extensions.khr_dedicated_allocation.name }) |extension| {
            if (try deviceExtensionListed(gpa, self.instance, self.physical, extension)) {
                device_extensions[device_extension_count] = extension;
                device_extension_count += 1;
            }
        }
        const device_handle = try self.instance.createDevice(self.physical, &.{
            .p_next = &features,
            .queue_create_info_count = 1,
            .p_queue_create_infos = &.{.{
                .queue_family_index = self.queue_family,
                .queue_count = queue_count,
                .p_queue_priorities = &queue_priorities,
            }},
            .enabled_extension_count = device_extension_count,
            .pp_enabled_extension_names = &device_extensions,
        }, null);
        self.device_wrapper = loader.device(io, device_handle);
        self.vkd = dispatch.Device.init(device_handle, &self.device_wrapper);
        errdefer self.vkd.destroyDevice(null);
        self.queue = self.vkd.getDeviceQueue(self.queue_family, 0);
        self.detached_queue = if (queue_count > 1) self.vkd.getDeviceQueue(self.queue_family, 1) else null;
        self.allocator = memory.Allocator.init(gpa, self.vkd, self.instance.getPhysicalDeviceMemoryProperties(self.physical));
        errdefer self.allocator.deinit();

        self.buffers = .init(gpa);
        self.textures = .init(gpa);
        self.samplers = .init(gpa);
        self.pipelines = .init(gpa);
        self.accelerations = .init(gpa);
        self.texture_slots = try SlotAllocator.init(gpa, texture_capacity);
        errdefer self.texture_slots.deinit(gpa);
        self.storage_slots = try SlotAllocator.init(gpa, storage_capacity);
        errdefer self.storage_slots.deinit(gpa);
        self.sampler_slots = try SlotAllocator.init(gpa, sampler_capacity);
        errdefer self.sampler_slots.deinit(gpa);

        try self.createDescriptorTable();
        errdefer {
            self.vkd.destroyDescriptorPool(self.descriptor_pool, null);
            self.vkd.destroyDescriptorSetLayout(self.descriptor_layout, null);
        }
        const push_range = vk.PushConstantRange{ .stage_flags = self.shaderStages(), .offset = 0, .size = push_constant_size };
        self.pipeline_layout = try self.vkd.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_range),
        }, null);
        errdefer self.vkd.destroyPipelineLayout(self.pipeline_layout, null);

        const cache_data = if (desc.pipeline_cache_path) |path| readFile(gpa, io, path) else null;
        defer if (cache_data) |bytes| gpa.free(bytes);
        self.pipeline_cache = try self.vkd.createPipelineCache(&.{
            .initial_data_size = if (cache_data) |bytes| bytes.len else 0,
            .p_initial_data = if (cache_data) |bytes| bytes.ptr else null,
        }, null);
        errdefer self.vkd.destroyPipelineCache(self.pipeline_cache, null);
        self.pipeline_cache_path = if (desc.pipeline_cache_path) |path| try gpa.dupe(u8, path) else null;
        errdefer if (self.pipeline_cache_path) |path| gpa.free(path);

        var frames_made: usize = 0;
        errdefer for (self.frames[0..frames_made]) |*frame| destroyFrame(self, frame);
        for (&self.frames) |*frame| {
            const pool = try self.vkd.createCommandPool(&.{ .queue_family_index = self.queue_family }, null);
            errdefer self.vkd.destroyCommandPool(pool, null);
            var command: vk.CommandBuffer = undefined;
            try self.vkd.allocateCommandBuffers(&.{
                .command_pool = pool,
                .level = .primary,
                .command_buffer_count = 1,
            }, @ptrCast(&command));
            const fence = try self.vkd.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
            errdefer self.vkd.destroyFence(fence, null);
            const image_available = try self.vkd.createSemaphore(&.{}, null);
            errdefer self.vkd.destroySemaphore(image_available, null);
            const generated_available = try self.vkd.createSemaphore(&.{}, null);
            errdefer self.vkd.destroySemaphore(generated_available, null);
            frame.* = .{
                .pool = pool,
                .command = command,
                .fence = fence,
                .image_available = image_available,
                .generated_available = generated_available,
                .query_pool = try self.vkd.createQueryPool(&.{
                    .query_type = .timestamp,
                    .query_count = max_timing_scopes * 2,
                }, null),
            };
            frames_made += 1;
        }
        self.immediate_pool = try self.vkd.createCommandPool(&.{ .queue_family_index = self.queue_family }, null);
        errdefer self.vkd.destroyCommandPool(self.immediate_pool, null);
        if (self.detached_queue != null)
            self.detached_pool = try self.vkd.createCommandPool(&.{ .flags = .{ .reset_command_buffer_bit = true }, .queue_family_index = self.queue_family }, null);
        errdefer if (self.detached_pool != .null_handle) self.vkd.destroyCommandPool(self.detached_pool, null);
        try self.vkd.allocateCommandBuffers(&.{
            .command_pool = self.immediate_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&self.immediate_command));

        if (desc.surface) |surface| self.swapchain = .{
            .requested_width = surface.width,
            .requested_height = surface.height,
            .vsync = surface.vsync,
        };
        return self;
    }

    /// Waits for the GPU, writes the pipeline cache and destroys everything,
    /// including resources the application leaked. All handles become invalid.
    pub fn deinit(self: *Device) void {
        presentation_module.finishPacedPresent(self);
        frames_module.waitQueue(self) catch {};
        persistPipelineCache(self) catch |err| std.log.warn("could not persist pipeline cache: {}", .{err});
        destroySwapchain(self);
        while (self.pipelines.popAny()) |pipeline| self.vkd.destroyPipeline(pipeline.handle, null);
        while (self.accelerations.popAny()) |acceleration| {
            self.vkd.destroyAccelerationStructureKHR(acceleration.handle, null);
            self.destroyBuffer(acceleration.buffer);
            if (acceleration.scratch) |scratch| self.destroyBuffer(scratch);
        }
        while (self.samplers.popAny()) |sampler| self.vkd.destroySampler(sampler.handle, null);
        while (self.textures.popAny()) |texture_value| {
            var texture = texture_value;
            for (texture.sub_views.items) |sub| self.vkd.destroyImageView(sub.view, null);
            texture.sub_views.deinit(self.gpa);
            texture.storage_slots.deinit(self.gpa);
            self.vkd.destroyImageView(texture.view, null);
            if (texture.allocation) |allocation| {
                self.vkd.destroyImage(texture.image, null);
                self.allocator.free(allocation);
            }
        }
        while (self.buffers.popAny()) |buffer| {
            self.vkd.destroyBuffer(buffer.handle, null);
            self.allocator.free(buffer.allocation);
        }
        for (self.deletions.items) |pending| destroyNow(self, pending.object);
        self.deletions.deinit(self.gpa);
        self.uploads.deinit(self.gpa);
        self.buffers.deinit();
        self.textures.deinit();
        self.samplers.deinit();
        self.pipelines.deinit();
        self.accelerations.deinit();
        self.texture_slots.deinit(self.gpa);
        self.storage_slots.deinit(self.gpa);
        self.sampler_slots.deinit(self.gpa);
        for (&self.frames) |*frame| destroyFrame(self, frame);
        self.vkd.destroyCommandPool(self.immediate_pool, null);
        if (self.detached_pool != .null_handle) self.vkd.destroyCommandPool(self.detached_pool, null);
        self.vkd.destroyPipelineCache(self.pipeline_cache, null);
        if (self.pipeline_cache_path) |path| self.gpa.free(path);
        self.vkd.destroyPipelineLayout(self.pipeline_layout, null);
        self.vkd.destroyDescriptorPool(self.descriptor_pool, null);
        self.vkd.destroyDescriptorSetLayout(self.descriptor_layout, null);
        self.allocator.deinit();
        self.vkd.destroyDevice(null);
        if (self.debug_messenger != .null_handle)
            self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        if (self.surface != .null_handle) self.instance.destroySurfaceKHR(self.surface, null);
        self.instance.destroyInstance(null);
        const gpa = self.gpa;
        const io = self.io;
        gpa.destroy(self);
        loader.release(io);
    }

    /// Adapter name; the slice points into the device.
    pub fn name(self: *const Device) []const u8 {
        return std.mem.sliceTo(&self.properties.device_name, 0);
    }

    /// Validation errors (not warnings) since `init`; 0 without validation.
    /// Thread-safe.
    pub fn validationErrorCount(self: *const Device) u32 {
        return self.validation_errors.load(.acquire);
    }

    /// Swapchain images are not counted.
    pub fn memoryStats(self: *const Device) types.MemoryStats {
        const stats = self.allocator.stats();
        return .{ .reserved_bytes = stats.reserved_bytes, .used_bytes = stats.used_bytes };
    }

    pub fn adapterInfo(self: *const Device) types.AdapterInfo {
        var memory_bytes: u64 = 0;
        const heaps = self.allocator.properties;
        for (heaps.memory_heaps[0..heaps.memory_heap_count]) |heap| {
            if (heap.flags.device_local_bit) memory_bytes += heap.size;
        }
        return .{
            .kind = switch (self.properties.device_type) {
                .discrete_gpu => .discrete,
                .integrated_gpu => .integrated,
                .virtual_gpu => .virtual,
                .cpu => .software,
                else => .other,
            },
            .vendor_id = self.properties.vendor_id,
            .memory_bytes = memory_bytes,
            .ray_tracing = self.ray_tracing,
        };
    }

    /// GPU time of each `beginScope` region of the most recent frame whose
    /// results are available.
    pub fn passTimings(self: *const Device) []const types.PassTiming {
        return self.timings[0..self.timing_count];
    }

    pub const createBuffer = buffers_module.createBuffer;
    pub const destroyBuffer = buffers_module.destroyBuffer;
    pub const bufferResource = buffers_module.bufferResource;
    pub const bufferAddress = buffers_module.bufferAddress;
    pub const bufferSize = buffers_module.bufferSize;
    pub const mapped = buffers_module.mapped;
    pub const mappedSlice = buffers_module.mappedSlice;
    pub const uploadBuffer = buffers_module.uploadBuffer;
    pub const createTexture = textures_module.createTexture;
    pub const destroyTexture = textures_module.destroyTexture;
    pub const textureResource = textures_module.textureResource;
    pub const textureInfo = textures_module.textureInfo;
    pub const textureExists = textures_module.textureExists;
    pub const textureIndex = textures_module.textureIndex;
    pub const storageIndex = textures_module.storageIndex;
    pub const subView = textures_module.subView;
    pub const uploadTexture = textures_module.uploadTexture;
    pub const uploadTextureLevels = textures_module.uploadTextureLevels;
    pub const queueBufferCopy = frames_module.queueBufferCopy;
    pub const generateMips = textures_module.generateMips;

    /// For tests: after `after` more GPU allocations the next fails once with
    /// `error.OutOfDeviceMemory`. Null cancels.
    pub fn failGpuAllocation(self: *Device, after: ?u32) void {
        self.allocator.fail_after = after;
    }

    /// A `failGpuAllocation` failure is still to come.
    pub fn gpuAllocationFailurePending(self: *const Device) bool {
        return self.allocator.fail_after != null;
    }

    pub const readTexture = textures_module.readTexture;
    pub const readBuffer = buffers_module.readBuffer;
    pub const createBlas = acceleration_module.createBlas;
    pub const createTlas = acceleration_module.createTlas;
    pub const destroyAcceleration = acceleration_module.destroyAcceleration;
    pub const accelerationResource = acceleration_module.accelerationResource;
    pub const accelerationAddress = acceleration_module.accelerationAddress;
    pub const accelerationBuilt = acceleration_module.accelerationBuilt;
    pub const buildBlasCommand = acceleration_module.buildBlasCommand;
    pub const buildTlasCommand = acceleration_module.buildTlasCommand;
    pub const createSampler = textures_module.createSampler;
    pub const destroySampler = textures_module.destroySampler;
    pub const samplerIndex = textures_module.samplerIndex;
    pub const createGraphicsPipeline = pipelines_module.createGraphicsPipeline;
    pub const CompiledPipeline = pipelines_module.CompiledPipeline;
    pub const adoptPipeline = pipelines_module.adoptPipeline;
    pub const discardPipeline = pipelines_module.discardPipeline;
    pub const compileGraphicsPipeline = pipelines_module.compileGraphicsPipeline;
    pub const createComputePipeline = pipelines_module.createComputePipeline;
    pub const destroyPipeline = pipelines_module.destroyPipeline;
    pub const pipelineResource = pipelines_module.pipelineResource;
    pub const backbufferFormat = presentation_module.backbufferFormat;
    pub const backbufferSize = presentation_module.backbufferSize;
    pub const resize = presentation_module.resize;
    pub const setVsync = presentation_module.setVsync;
    pub const setFrameGenerator = presentation_module.setFrameGenerator;
    pub const beginFrame = frames_module.beginFrame;
    pub const endFrame = frames_module.endFrame;
    pub const waitForFrame = frames_module.waitForFrame;
    pub const prepareSurface = presentation_module.prepareSurface;
    pub const acquireImage = presentation_module.acquireImage;
    pub const startFrame = frames_module.startFrame;
    pub const submitFrame = frames_module.submitFrame;
    pub const presentFrame = presentation_module.presentFrame;
    pub const closeFailedFrame = frames_module.closeFailedFrame;
    pub const waitIdle = frames_module.waitIdle;
    pub const flushUploadsBlocking = frames_module.flushUploadsBlocking;
    pub const pendingUploadBytes = frames_module.pendingUploadBytes;
    pub const shaderStages = pipelines_module.shaderStages;
    pub const beginDetached = frames_module.beginDetached;
    pub const submitDetached = frames_module.submitDetached;
    pub const detachedDone = frames_module.detachedDone;
    pub const releaseDetached = frames_module.releaseDetached;
    pub const beginImmediate = frames_module.beginImmediate;
    pub const endImmediate = frames_module.endImmediate;
    pub const takeUploads = frames_module.takeUploads;

    fn createDescriptorTable(self: *Device) !void {
        const all_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = texture_capacity, .stage_flags = self.shaderStages() },
            .{ .binding = 1, .descriptor_type = .sampler, .descriptor_count = sampler_capacity, .stage_flags = self.shaderStages() },
            .{ .binding = 2, .descriptor_type = .storage_image, .descriptor_count = storage_capacity, .stage_flags = .{ .compute_bit = true } },
        };
        const count: u32 = if (self.storage_images) all_bindings.len else all_bindings.len - 1;
        const binding_flags: [all_bindings.len]vk.DescriptorBindingFlags = @splat(.{
            .update_after_bind_bit = true,
            .update_unused_while_pending_bit = true,
            .partially_bound_bit = true,
        });
        const flags_info = vk.DescriptorSetLayoutBindingFlagsCreateInfo{
            .binding_count = count,
            .p_binding_flags = &binding_flags,
        };
        self.descriptor_layout = try self.vkd.createDescriptorSetLayout(&.{
            .p_next = &flags_info,
            .flags = .{ .update_after_bind_pool_bit = true },
            .binding_count = count,
            .p_bindings = &all_bindings,
        }, null);
        const sizes = [_]vk.DescriptorPoolSize{
            .{ .type = .sampled_image, .descriptor_count = texture_capacity },
            .{ .type = .sampler, .descriptor_count = sampler_capacity },
            .{ .type = .storage_image, .descriptor_count = storage_capacity },
        };
        self.descriptor_pool = try self.vkd.createDescriptorPool(&.{
            .flags = .{ .update_after_bind_bit = true },
            .max_sets = 1,
            .pool_size_count = count,
            .p_pool_sizes = &sizes,
        }, null);
        try self.vkd.allocateDescriptorSets(&.{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_layout),
        }, @ptrCast(&self.descriptor_set));
    }
};

/// Fixed-capacity index allocator for bindless descriptor slots.
const SlotAllocator = struct {
    free: std.ArrayList(u32) = .empty,
    next: u32 = 0,
    capacity: u32,

    pub fn init(gpa: std.mem.Allocator, capacity: u32) !SlotAllocator {
        var self = SlotAllocator{ .capacity = capacity };
        try self.free.ensureTotalCapacity(gpa, capacity);
        return self;
    }

    pub fn deinit(self: *SlotAllocator, gpa: std.mem.Allocator) void {
        self.free.deinit(gpa);
    }

    pub fn allocate(self: *SlotAllocator) !u32 {
        if (self.free.pop()) |slot| return slot;
        if (self.next == self.capacity) return error.BindlessTableFull;
        defer self.next += 1;
        return self.next;
    }

    pub fn release(self: *SlotAllocator, slot: u32) void {
        self.free.appendAssumeCapacity(slot);
    }
};

pub fn vkFormat(format: types.Format) vk.Format {
    return switch (format) {
        .r8_unorm => .r8_unorm,
        .rg8_unorm => .r8g8_unorm,
        .rgba8_unorm => .r8g8b8a8_unorm,
        .rgba8_srgb => .r8g8b8a8_srgb,
        .bgra8_unorm => .b8g8r8a8_unorm,
        .bgra8_srgb => .b8g8r8a8_srgb,
        .rg16_unorm => .r16g16_unorm,
        .rgba16_unorm => .r16g16b16a16_unorm,
        .r16_float => .r16_sfloat,
        .rg16_float => .r16g16_sfloat,
        .rgba16_float => .r16g16b16a16_sfloat,
        .rgba32_float => .r32g32b32a32_sfloat,
        .r32_float => .r32_sfloat,
        .r32_uint => .r32_uint,
        .r8_uint => .r8_uint,
        .b10g11r11_float => .b10g11r11_ufloat_pack32,
        .a2b10g10r10_unorm => .a2b10g10r10_unorm_pack32,
        .bc7_unorm => .bc7_unorm_block,
        .bc7_srgb => .bc7_srgb_block,
        .bc5_unorm => .bc5_unorm_block,
        .bc4_unorm => .bc4_unorm_block,
        .bc1_unorm => .bc1_rgba_unorm_block,
        .bc1_srgb => .bc1_rgba_srgb_block,
        .bc3_unorm => .bc3_unorm_block,
        .bc3_srgb => .bc3_srgb_block,
        .bc6h_ufloat => .bc6h_ufloat_block,
        .depth16_unorm => .d16_unorm,
        .depth32_float => .d32_sfloat,
    };
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > 256 * 1024 * 1024) return null;
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.readAlloc(gpa, @intCast(stat.size)) catch null;
}

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    const self: *Device = @ptrCast(@alignCast(user_data.?));
    const message = if (data) |value| (if (value.p_message) |pointer| std.mem.span(pointer) else "") else "";
    if (severity.error_bit_ext) {
        _ = self.validation_errors.fetchAdd(1, .acq_rel);
        std.log.err("vulkan: {s}", .{message});
    } else {
        std.log.warn("vulkan: {s}", .{message});
    }
    return .false;
}

fn destroyFrame(self: *Device, frame: *FrameData) void {
    self.vkd.destroyQueryPool(frame.query_pool, null);
    self.vkd.destroySemaphore(frame.image_available, null);
    self.vkd.destroySemaphore(frame.generated_available, null);
    self.vkd.destroyFence(frame.fence, null);
    self.vkd.destroyCommandPool(frame.pool, null);
}

pub fn sameHandle(a: anytype, b: @TypeOf(a)) bool {
    return std.meta.eql(a, b);
}

pub const scratch_alignment = 256;

pub const ray_query_extensions = [_][*:0]const u8{
    vk.extensions.khr_deferred_host_operations.name,
    vk.extensions.khr_acceleration_structure.name,
    vk.extensions.khr_ray_query.name,
};
