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
const required_api_version = vk.API_VERSION_1_3.toU32();

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

const Deletion = union(enum) {
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

const PendingUpload = union(enum) {
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
        // HDR surfaces are only listed when this extension is on.
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
        // The FidelityFX SDK asks for these by their pre-core names.
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

        self.buffers = .init(gpa);
        self.textures = .init(gpa);
        self.samplers = .init(gpa);
        self.pipelines = .init(gpa);
        self.accelerations = .init(gpa);
        self.texture_slots = try SlotAllocator.init(gpa, texture_capacity);
        self.storage_slots = try SlotAllocator.init(gpa, storage_capacity);
        self.sampler_slots = try SlotAllocator.init(gpa, sampler_capacity);

        try self.createDescriptorTable();
        const push_range = vk.PushConstantRange{ .stage_flags = self.shaderStages(), .offset = 0, .size = push_constant_size };
        self.pipeline_layout = try self.vkd.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_range),
        }, null);

        const cache_data = if (desc.pipeline_cache_path) |path| readFile(gpa, io, path) else null;
        defer if (cache_data) |bytes| gpa.free(bytes);
        self.pipeline_cache = try self.vkd.createPipelineCache(&.{
            .initial_data_size = if (cache_data) |bytes| bytes.len else 0,
            .p_initial_data = if (cache_data) |bytes| bytes.ptr else null,
        }, null);
        self.pipeline_cache_path = if (desc.pipeline_cache_path) |path| try gpa.dupe(u8, path) else null;

        for (&self.frames) |*frame| {
            const pool = try self.vkd.createCommandPool(&.{ .queue_family_index = self.queue_family }, null);
            var command: vk.CommandBuffer = undefined;
            try self.vkd.allocateCommandBuffers(&.{
                .command_pool = pool,
                .level = .primary,
                .command_buffer_count = 1,
            }, @ptrCast(&command));
            frame.* = .{
                .pool = pool,
                .command = command,
                .fence = try self.vkd.createFence(&.{ .flags = .{ .signaled_bit = true } }, null),
                .image_available = try self.vkd.createSemaphore(&.{}, null),
                .query_pool = try self.vkd.createQueryPool(&.{
                    .query_type = .timestamp,
                    .query_count = max_timing_scopes * 2,
                }, null),
            };
        }
        self.immediate_pool = try self.vkd.createCommandPool(&.{ .queue_family_index = self.queue_family }, null);
        if (self.detached_queue != null)
            self.detached_pool = try self.vkd.createCommandPool(&.{ .flags = .{ .reset_command_buffer_bit = true }, .queue_family_index = self.queue_family }, null);
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
        self.vkd.deviceWaitIdle() catch {};
        self.persistPipelineCache() catch |err| std.log.warn("could not persist pipeline cache: {}", .{err});
        self.destroySwapchain();
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
        for (self.deletions.items) |pending| self.destroyNow(pending.object);
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
        for (&self.frames) |*frame| {
            self.vkd.destroyQueryPool(frame.query_pool, null);
            self.vkd.destroySemaphore(frame.image_available, null);
            self.vkd.destroyFence(frame.fence, null);
            self.vkd.destroyCommandPool(frame.pool, null);
        }
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

    // ---------------------------------------------------------------- buffers

    /// Names a Vulkan object for debuggers; no-op unless `debug_labels`.
    fn setName(self: *Device, object_type: vk.ObjectType, handle: u64, label: [:0]const u8) void {
        if (!self.debug_labels) return;
        self.vkd.setDebugUtilsObjectNameEXT(&.{
            .object_type = object_type,
            .object_handle = handle,
            .p_object_name = label.ptr,
        }) catch {};
    }

    /// The address is fixed and host-visible kinds are mapped; contents start
    /// undefined. Fails with `error.InvalidBufferSize` for a size of 0.
    pub fn createBuffer(self: *Device, desc: types.BufferDesc) !types.Buffer {
        if (desc.size == 0) return error.InvalidBufferSize;
        const handle = try self.vkd.createBuffer(&.{
            .size = desc.size,
            .usage = .{
                .storage_buffer_bit = desc.usage.storage,
                .index_buffer_bit = desc.usage.index,
                .vertex_buffer_bit = desc.usage.vertex,
                .indirect_buffer_bit = desc.usage.indirect,
                .acceleration_structure_build_input_read_only_bit_khr = desc.usage.acceleration_input and self.ray_tracing,
                .acceleration_structure_storage_bit_khr = desc.usage.acceleration_storage and self.ray_tracing,
                .transfer_src_bit = desc.usage.copy_src,
                .transfer_dst_bit = true,
                .shader_device_address_bit = true,
            },
            .sharing_mode = .exclusive,
        }, null);
        self.setName(.buffer, @intFromEnum(handle), desc.name);
        errdefer self.vkd.destroyBuffer(handle, null);
        const allocation = try self.allocator.allocate(self.vkd.getBufferMemoryRequirements(handle), switch (desc.memory) {
            .gpu => .gpu,
            .cpu_to_gpu => .cpu_to_gpu,
            .gpu_to_cpu => .gpu_to_cpu,
        }, .buffer);
        errdefer self.allocator.free(allocation);
        try self.vkd.bindBufferMemory(handle, allocation.memory, allocation.offset);
        const address = self.vkd.getBufferDeviceAddress(&.{ .buffer = handle });
        return self.buffers.insert(.{
            .handle = handle,
            .allocation = allocation,
            .size = desc.size,
            .address = address,
        });
    }

    /// Drops queued uploads that target a resource being destroyed.
    fn cancelUploads(self: *Device, buffer: ?types.Buffer, texture: ?types.Texture) void {
        var write: usize = 0;
        var orphaned: [16]types.Buffer = undefined;
        var orphan_count: usize = 0;
        const items = self.uploads.items;
        for (items) |upload| {
            const staging: ?types.Buffer = switch (upload) {
                .buffer => |copy| if (buffer != null and sameHandle(copy.destination, buffer.?)) copy.staging else null,
                .texture => |copy| if (texture != null and sameHandle(copy.destination, texture.?)) (if (copy.last) copy.staging else types.Buffer.invalid) else null,
                .mips => |target| if (texture != null and sameHandle(target, texture.?)) types.Buffer.invalid else null,
                .copy => |copy| if (buffer != null and sameHandle(copy.destination, buffer.?)) copy.source else null,
            };
            if (staging) |value| {
                if (value.isValid() and orphan_count < orphaned.len) {
                    orphaned[orphan_count] = value;
                    orphan_count += 1;
                }
                continue;
            }
            items[write] = upload;
            write += 1;
        }
        self.uploads.items.len = write;
        for (orphaned[0..orphan_count]) |staging| self.destroyBuffer(staging);
    }

    /// Invalidates the handle at once; the buffer itself is released after
    /// `frames_in_flight` more frames, or by the next `waitIdle`,
    /// `flushUploadsBlocking` or `endImmediate`. Stale handles are ignored.
    pub fn destroyBuffer(self: *Device, buffer: types.Buffer) void {
        if (self.uploads.items.len != 0) self.cancelUploads(buffer, null);
        const resource = self.buffers.remove(buffer) orelse return;
        self.retire(.{ .buffer = .{ .handle = resource.handle, .allocation = resource.allocation } });
    }

    /// Panics on a stale handle. The pointer is valid until a buffer is
    /// created or destroyed.
    pub fn bufferResource(self: *Device, buffer: types.Buffer) *BufferResource {
        return self.buffers.get(buffer) orelse @panic("stale or invalid buffer handle");
    }

    /// GPU virtual address, for passing to shaders in push constants.
    pub fn bufferAddress(self: *Device, buffer: types.Buffer) u64 {
        return self.bufferResource(buffer).address;
    }

    /// Panics on a stale handle.
    pub fn bufferSize(self: *Device, buffer: types.Buffer) u64 {
        return self.bufferResource(buffer).size;
    }

    /// Mapped bytes of a `cpu_to_gpu` / `gpu_to_cpu` buffer; panics for `gpu`.
    pub fn mapped(self: *Device, buffer: types.Buffer) []u8 {
        const resource = self.bufferResource(buffer);
        return (resource.allocation.mapped orelse @panic("buffer is not host visible"))[0..@intCast(resource.size)];
    }

    /// `mapped` as a slice of `T`, dropping trailing bytes. Writes are not
    /// ordered against frames the GPU is still drawing.
    pub fn mappedSlice(self: *Device, comptime T: type, buffer: types.Buffer) []T {
        const bytes = self.mapped(buffer);
        return @alignCast(std.mem.bytesAsSlice(T, bytes[0 .. bytes.len - bytes.len % @sizeOf(T)]));
    }

    /// Host-visible buffers are written immediately; device-local ones are
    /// staged and copied at the start of the next frame or `flushUploads`.
    pub fn uploadBuffer(self: *Device, buffer: types.Buffer, offset: u64, data: []const u8) !void {
        if (data.len == 0) return;
        const resource = self.bufferResource(buffer);
        if (offset + data.len > resource.size) return error.UploadOutOfBounds;
        if (resource.allocation.mapped) |pointer| {
            @memcpy(pointer[@intCast(offset)..][0..data.len], data);
            return;
        }
        const staging = try self.createStaging(data);
        errdefer self.destroyBuffer(staging);
        try self.uploads.append(self.gpa, .{ .buffer = .{
            .staging = staging,
            .destination = buffer,
            .offset = offset,
            .size = data.len,
        } });
        self.pending_upload_bytes += data.len;
    }

    // --------------------------------------------------------------- textures

    /// Starts in `undefined` with no contents. A `sampled` texture takes one
    /// of 16384 bindless slots. Fails with `error.InvalidTextureDesc` or
    /// `error.BindlessTableFull`; format support is not checked.
    pub fn createTexture(self: *Device, desc: types.TextureDesc) !types.Texture {
        if (desc.width == 0 or desc.height == 0 or desc.mip_levels == 0 or desc.mip_levels > max_mip_levels)
            return error.InvalidTextureDesc;
        const layers: u32 = if (desc.kind == .cube) 6 else desc.layers;
        const format = vkFormat(desc.format);
        const image = try self.vkd.createImage(&.{
            .flags = .{ .cube_compatible_bit = desc.kind == .cube },
            .image_type = .@"2d",
            .format = format,
            .extent = .{ .width = desc.width, .height = desc.height, .depth = 1 },
            .mip_levels = desc.mip_levels,
            .array_layers = layers,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{
                .sampled_bit = desc.usage.sampled,
                .storage_bit = desc.usage.storage,
                .fragment_shading_rate_attachment_bit_khr = desc.usage.shading_rate,
                .color_attachment_bit = desc.usage.color_attachment,
                .depth_stencil_attachment_bit = desc.usage.depth_attachment,
                .transfer_src_bit = desc.usage.copy_src or desc.mip_levels > 1,
                .transfer_dst_bit = desc.usage.copy_dst or desc.mip_levels > 1,
            },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        self.setName(.image, @intFromEnum(image), desc.name);
        errdefer self.vkd.destroyImage(image, null);
        const allocation = try self.allocator.allocate(self.vkd.getImageMemoryRequirements(image), .gpu, .image);
        errdefer self.allocator.free(allocation);
        try self.vkd.bindImageMemory(image, allocation.memory, allocation.offset);
        return self.registerTexture(image, allocation, .{
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .mip_levels = desc.mip_levels,
            .layers = layers,
            .kind = desc.kind,
        }, desc.usage.sampled);
    }

    fn registerTexture(
        self: *Device,
        image: vk.Image,
        allocation: ?memory.Allocation,
        info: types.TextureInfo,
        sampled: bool,
    ) !types.Texture {
        const format = vkFormat(info.format);
        const aspect: vk.ImageAspectFlags = if (info.format.isDepth()) .{ .depth_bit = true } else .{ .color_bit = true };
        const view = try self.vkd.createImageView(&.{
            .image = image,
            .view_type = switch (info.kind) {
                .@"2d" => .@"2d",
                .@"2d_array" => .@"2d_array",
                .cube => .cube,
            },
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = aspect,
                .base_mip_level = 0,
                .level_count = info.mip_levels,
                .base_array_layer = 0,
                .layer_count = info.layers,
            },
        }, null);
        errdefer self.vkd.destroyImageView(view, null);
        var bindless_index: ?u32 = null;
        if (sampled) {
            const slot = try self.texture_slots.allocate();
            bindless_index = slot;
            const image_info = vk.DescriptorImageInfo{
                .sampler = .null_handle,
                .image_view = view,
                .image_layout = .read_only_optimal,
            };
            self.vkd.updateDescriptorSets(&.{.{
                .dst_set = self.descriptor_set,
                .dst_binding = 0,
                .dst_array_element = slot,
                .descriptor_count = 1,
                .descriptor_type = .sampled_image,
                .p_image_info = @ptrCast(&image_info),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            }}, &.{});
        }
        return self.textures.insert(.{
            .image = image,
            .allocation = allocation,
            .view = view,
            .info = info,
            .vk_format = format,
            .aspect = aspect,
            .bindless_index = bindless_index,
        });
    }

    /// Deferred like `destroyBuffer`, including the bindless slot. Backbuffers
    /// must not be destroyed.
    pub fn destroyTexture(self: *Device, texture: types.Texture) void {
        if (self.uploads.items.len != 0) self.cancelUploads(null, texture);
        var resource = self.textures.remove(texture) orelse return;
        for (resource.sub_views.items) |sub| self.retire(.{ .view = sub.view });
        resource.sub_views.deinit(self.gpa);
        for (resource.storage_slots.items) |storage| self.retire(.{ .storage_slot = storage.slot });
        resource.storage_slots.deinit(self.gpa);
        self.retire(.{ .view = resource.view });
        if (resource.bindless_index) |slot| self.retire(.{ .texture_slot = slot });
        // Swapchain images are owned by the swapchain.
        if (resource.allocation != null) self.retire(.{ .image = .{ .handle = resource.image, .allocation = resource.allocation } });
    }

    /// Panics on a stale handle. The pointer is valid until a texture is
    /// created or destroyed, including a swapchain rebuild.
    pub fn textureResource(self: *Device, texture: types.Texture) *TextureResource {
        return self.textures.get(texture) orelse @panic("stale or invalid texture handle");
    }

    /// Panics on a stale handle.
    pub fn textureInfo(self: *Device, texture: types.Texture) types.TextureInfo {
        return self.textureResource(texture).info;
    }

    /// Index in the global `textures[]` shader array. Panics unless the
    /// texture is `.sampled`.
    pub fn textureIndex(self: *Device, texture: types.Texture) u32 {
        return self.textureResource(texture).bindless_index orelse @panic("texture was not created with .sampled usage");
    }

    /// Index of one mip in the storage image table (`STORAGE` in common.glsl).
    /// Needs `TextureUsage.storage`; the mip must be in `TextureState.storage`
    /// while the shader runs.
    pub fn storageIndex(self: *Device, texture: types.Texture, mip: u32) !u32 {
        const resource = self.textureResource(texture);
        for (resource.storage_slots.items) |storage| if (storage.mip == mip) return storage.slot;
        const view = try self.subView(texture, mip, 0);
        const slot = try self.storage_slots.allocate();
        errdefer self.storage_slots.release(slot);
        try resource.storage_slots.append(self.gpa, .{ .mip = mip, .slot = slot });
        const image_info = vk.DescriptorImageInfo{ .sampler = .null_handle, .image_view = view, .image_layout = .general };
        self.vkd.updateDescriptorSets(&.{.{
            .dst_set = self.descriptor_set,
            .dst_binding = 2,
            .dst_array_element = slot,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = @ptrCast(&image_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, &.{});
        return slot;
    }

    /// View of a single mip/layer, used as a render attachment.
    pub fn subView(self: *Device, texture: types.Texture, mip: u32, layer: u32) !vk.ImageView {
        const resource = self.textureResource(texture);
        if (resource.info.mip_levels == 1 and resource.info.layers == 1) return resource.view;
        for (resource.sub_views.items) |sub| if (sub.mip == mip and sub.layer == layer) return sub.view;
        const view = try self.vkd.createImageView(&.{
            .image = resource.image,
            .view_type = .@"2d",
            .format = resource.vk_format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = resource.aspect,
                .base_mip_level = mip,
                .level_count = 1,
                .base_array_layer = layer,
                .layer_count = 1,
            },
        }, null);
        errdefer self.vkd.destroyImageView(view, null);
        try resource.sub_views.append(self.gpa, .{ .mip = mip, .layer = layer, .view = view });
        return view;
    }

    /// Stages tightly packed pixel data for one mip of one layer.
    pub fn uploadTexture(self: *Device, texture: types.Texture, mip: u32, layer: u32, data: []const u8) !void {
        const info = self.textureInfo(texture);
        const width = @max(info.width >> @intCast(mip), 1);
        const height = @max(info.height >> @intCast(mip), 1);
        if (data.len != info.format.dataSize(width, height)) return error.InvalidTextureData;
        const staging = try self.createStaging(data);
        errdefer self.destroyBuffer(staging);
        try self.uploads.append(self.gpa, .{ .texture = .{
            .staging = staging,
            .destination = texture,
            .mip = mip,
            .layer = layer,
        } });
        self.pending_upload_bytes += data.len;
    }

    /// Stages consecutive mips of one layer, from `first_mip`, packed back to
    /// back in `data`.
    pub fn uploadTextureLevels(self: *Device, texture: types.Texture, first_mip: u32, layer: u32, data: []const u8) !void {
        const info = self.textureInfo(texture);
        var total: usize = 0;
        var count: u32 = 0;
        while (total < data.len and first_mip + count < info.mip_levels) : (count += 1) {
            const mip = first_mip + count;
            total += @intCast(info.format.dataSize(@max(info.width >> @intCast(mip), 1), @max(info.height >> @intCast(mip), 1)));
        }
        if (total != data.len or count == 0) return error.InvalidTextureData;
        const staging = try self.createStaging(data);
        errdefer self.destroyBuffer(staging);
        try self.uploads.ensureUnusedCapacity(self.gpa, count);
        var offset: u64 = 0;
        for (0..count) |index| {
            const mip = first_mip + @as(u32, @intCast(index));
            self.uploads.appendAssumeCapacity(.{ .texture = .{
                .staging = staging,
                .destination = texture,
                .mip = mip,
                .layer = layer,
                .offset = offset,
                .last = index + 1 == count,
            } });
            offset += info.format.dataSize(@max(info.width >> @intCast(mip), 1), @max(info.height >> @intCast(mip), 1));
        }
        self.pending_upload_bytes += data.len;
    }

    /// Queues a copy ordered with the pending uploads; `source` is destroyed
    /// once it is recorded.
    pub fn queueBufferCopy(self: *Device, source: types.Buffer, destination: types.Buffer, size: u64) !void {
        try self.uploads.append(self.gpa, .{ .copy = .{ .source = source, .destination = destination, .size = size } });
    }

    /// Queues a blit chain filling every mip above 0, after earlier uploads.
    pub fn generateMips(self: *Device, texture: types.Texture) !void {
        try self.uploads.append(self.gpa, .{ .mips = texture });
    }

    /// For tests: after `after` more GPU allocations the next fails once with
    /// `error.OutOfDeviceMemory`. Null cancels.
    pub fn failGpuAllocation(self: *Device, after: ?u32) void {
        self.allocator.fail_after = after;
    }

    /// A `failGpuAllocation` failure is still to come.
    pub fn gpuAllocationFailurePending(self: *const Device) bool {
        return self.allocator.fail_after != null;
    }

    /// Reads back mip 0 / layer 0. Blocks until the GPU is idle; not for use
    /// during a frame.
    pub fn readTexture(self: *Device, gpa: std.mem.Allocator, texture: types.Texture) ![]u8 {
        std.debug.assert(!self.in_frame);
        const info = self.textureInfo(texture);
        const size = @as(u64, info.width) * info.height * info.format.bytesPerPixel();
        const staging = try self.createBuffer(.{ .name = "readback", .size = size, .usage = .{}, .memory = .gpu_to_cpu });
        defer self.destroyBuffer(staging);
        try self.vkd.deviceWaitIdle();
        var encoder = try self.beginImmediate();
        const previous = self.textureResource(texture).states[0];
        encoder.transition(texture, .copy_src);
        self.vkd.cmdCopyImageToBuffer(encoder.command, self.textureResource(texture).image, .transfer_src_optimal, self.bufferResource(staging).handle, &.{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = self.textureResource(texture).aspect, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = info.width, .height = info.height, .depth = 1 },
        }});
        if (previous != .undefined) encoder.transition(texture, previous);
        try self.endImmediate();
        return gpa.dupe(u8, self.mapped(staging)[0..@intCast(size)]);
    }

    /// Reads back the first `size` bytes. Blocks; between frames only. Needs
    /// `copy_src` usage.
    pub fn readBuffer(self: *Device, gpa: std.mem.Allocator, buffer: types.Buffer, size: u64) ![]u8 {
        std.debug.assert(!self.in_frame);
        const staging = try self.createBuffer(.{ .name = "readback", .size = size, .usage = .{}, .memory = .gpu_to_cpu });
        defer self.destroyBuffer(staging);
        try self.vkd.deviceWaitIdle();
        const encoder = try self.beginImmediate();
        self.vkd.cmdCopyBuffer(encoder.command, self.bufferResource(buffer).handle, self.bufferResource(staging).handle, &.{.{ .src_offset = 0, .dst_offset = 0, .size = size }});
        try self.endImmediate();
        return gpa.dupe(u8, self.mapped(staging)[0..@intCast(size)]);
    }

    // ------------------------------------------------- acceleration structures

    fn blasGeometry(self: *Device, desc: types.BlasDesc) vk.AccelerationStructureGeometryKHR {
        return .{
            .geometry_type = .triangles_khr,
            .flags = .{ .opaque_bit_khr = true },
            .geometry = .{ .triangles = .{
                .vertex_format = .r32g32b32_sfloat,
                .vertex_data = .{ .device_address = self.bufferAddress(desc.vertices) + desc.vertex_offset },
                .vertex_stride = desc.vertex_stride,
                .max_vertex = desc.vertex_count - 1,
                .index_type = .uint32,
                .index_data = .{ .device_address = self.bufferAddress(desc.indices) + desc.index_offset },
                .transform_data = .{ .device_address = 0 },
            } },
        };
    }

    fn createAcceleration(self: *Device, top_level: bool, size: u64, scratch_size: u64, capacity: u32) !types.AccelerationStructure {
        const buffer = try self.createBuffer(.{ .name = "acceleration structure", .size = size, .usage = .{ .acceleration_storage = true } });
        errdefer self.destroyBuffer(buffer);
        const handle = try self.vkd.createAccelerationStructureKHR(&.{
            .buffer = self.bufferResource(buffer).handle,
            .offset = 0,
            .size = size,
            .type = if (top_level) .top_level_khr else .bottom_level_khr,
        }, null);
        errdefer self.vkd.destroyAccelerationStructureKHR(handle, null);
        return self.accelerations.insert(.{
            .handle = handle,
            .buffer = buffer,
            .address = self.vkd.getAccelerationStructureDeviceAddressKHR(&.{ .acceleration_structure = handle }),
            .top_level = top_level,
            .scratch_size = scratch_size,
            .capacity = capacity,
        });
    }

    /// Sized for `desc`; build with `CommandEncoder.buildBlas`.
    pub fn createBlas(self: *Device, desc: types.BlasDesc) !types.AccelerationStructure {
        if (!self.ray_tracing) return error.RayTracingUnavailable;
        const geometry = self.blasGeometry(desc);
        var sizes: vk.AccelerationStructureBuildSizesInfoKHR = .{
            .acceleration_structure_size = 0,
            .update_scratch_size = 0,
            .build_scratch_size = 0,
        };
        const triangles = desc.index_count / 3;
        self.vkd.getAccelerationStructureBuildSizesKHR(.device_khr, &.{
            .type = .bottom_level_khr,
            .flags = .{ .prefer_fast_trace_bit_khr = !desc.dynamic, .prefer_fast_build_bit_khr = desc.dynamic, .allow_update_bit_khr = desc.dynamic },
            .mode = .build_khr,
            .geometry_count = 1,
            .p_geometries = @ptrCast(&geometry),
            .scratch_data = .{ .device_address = 0 },
        }, @ptrCast(&triangles), &sizes);
        const blas = try self.createAcceleration(false, sizes.acceleration_structure_size, sizes.build_scratch_size, triangles);
        self.accelerationResource(blas).dynamic = desc.dynamic;
        return blas;
    }

    /// Allocates a top-level structure with room for `max_instances`.
    pub fn createTlas(self: *Device, max_instances: u32) !types.AccelerationStructure {
        if (!self.ray_tracing) return error.RayTracingUnavailable;
        const geometry = tlasGeometry(0);
        var sizes: vk.AccelerationStructureBuildSizesInfoKHR = .{
            .acceleration_structure_size = 0,
            .update_scratch_size = 0,
            .build_scratch_size = 0,
        };
        self.vkd.getAccelerationStructureBuildSizesKHR(.device_khr, &.{
            .type = .top_level_khr,
            .flags = .{ .prefer_fast_build_bit_khr = true },
            .mode = .build_khr,
            .geometry_count = 1,
            .p_geometries = @ptrCast(&geometry),
            .scratch_data = .{ .device_address = 0 },
        }, @ptrCast(&max_instances), &sizes);
        const acceleration = try self.createAcceleration(true, sizes.acceleration_structure_size, sizes.build_scratch_size, max_instances);
        errdefer self.destroyAcceleration(acceleration);
        const resource = self.accelerationResource(acceleration);
        resource.scratch = try self.createBuffer(.{ .name = "tlas scratch", .size = sizes.build_scratch_size + scratch_alignment, .usage = .{ .storage = true } });
        return acceleration;
    }

    /// Deferred like `destroyBuffer`; also releases its buffers.
    pub fn destroyAcceleration(self: *Device, acceleration: types.AccelerationStructure) void {
        const resource = self.accelerations.remove(acceleration) orelse return;
        self.retire(.{ .acceleration = resource.handle });
        self.destroyBuffer(resource.buffer);
        if (resource.scratch) |scratch| self.destroyBuffer(scratch);
    }

    /// Panics on a stale handle. The pointer is valid until a structure is
    /// created or destroyed.
    pub fn accelerationResource(self: *Device, acceleration: types.AccelerationStructure) *AccelerationResource {
        return self.accelerations.get(acceleration) orelse @panic("stale or invalid acceleration structure handle");
    }

    /// What TLAS instances store for a BLAS and shaders take for a TLAS.
    pub fn accelerationAddress(self: *Device, acceleration: types.AccelerationStructure) u64 {
        return self.accelerationResource(acceleration).address;
    }

    pub fn accelerationBuilt(self: *Device, acceleration: types.AccelerationStructure) bool {
        return self.accelerationResource(acceleration).built;
    }

    /// Called by `CommandEncoder.buildBlas`; use that. `desc` must have the
    /// triangle count the structure was created for. A `dynamic` structure is
    /// refitted after its first build.
    pub fn buildBlasCommand(self: *Device, command: vk.CommandBuffer, blas: types.AccelerationStructure, desc: types.BlasDesc) !void {
        const resource = self.accelerationResource(blas);
        const geometry = self.blasGeometry(desc);
        if (resource.dynamic and resource.scratch == null)
            resource.scratch = try self.createBuffer(.{ .name = "blas scratch", .size = resource.scratch_size + scratch_alignment, .usage = .{ .storage = true } });
        const scratch = resource.scratch orelse try self.createBuffer(.{ .name = "blas scratch", .size = resource.scratch_size + scratch_alignment, .usage = .{ .storage = true } });
        defer if (resource.scratch == null) self.destroyBuffer(scratch);
        const range = vk.AccelerationStructureBuildRangeInfoKHR{
            .primitive_count = desc.index_count / 3,
            .primitive_offset = 0,
            .first_vertex = 0,
            .transform_offset = 0,
        };
        const ranges = [_][*]const vk.AccelerationStructureBuildRangeInfoKHR{@ptrCast(&range)};
        self.vkd.cmdBuildAccelerationStructuresKHR(command, &.{.{
            .type = .bottom_level_khr,
            .flags = .{ .prefer_fast_trace_bit_khr = !resource.dynamic, .prefer_fast_build_bit_khr = resource.dynamic, .allow_update_bit_khr = resource.dynamic },
            .mode = if (resource.dynamic and resource.built) .update_khr else .build_khr,
            .src_acceleration_structure = if (resource.dynamic and resource.built) resource.handle else .null_handle,
            .dst_acceleration_structure = resource.handle,
            .geometry_count = 1,
            .p_geometries = @ptrCast(&geometry),
            .scratch_data = .{ .device_address = std.mem.alignForward(u64, self.bufferAddress(scratch), scratch_alignment) },
        }}, &ranges);
        resource.built = true;
    }

    /// Called by `CommandEncoder.buildTlas`, which adds the barriers; use
    /// that. `instance_count` must not exceed the TLAS's `max_instances`.
    pub fn buildTlasCommand(self: *Device, command: vk.CommandBuffer, tlas: types.AccelerationStructure, instances_address: u64, instance_count: u32) void {
        const resource = self.accelerationResource(tlas);
        std.debug.assert(instance_count <= resource.capacity);
        const geometry = tlasGeometry(instances_address);
        const range = vk.AccelerationStructureBuildRangeInfoKHR{
            .primitive_count = instance_count,
            .primitive_offset = 0,
            .first_vertex = 0,
            .transform_offset = 0,
        };
        const ranges = [_][*]const vk.AccelerationStructureBuildRangeInfoKHR{@ptrCast(&range)};
        self.vkd.cmdBuildAccelerationStructuresKHR(command, &.{.{
            .type = .top_level_khr,
            .flags = .{ .prefer_fast_build_bit_khr = true },
            .mode = .build_khr,
            .dst_acceleration_structure = resource.handle,
            .geometry_count = 1,
            .p_geometries = @ptrCast(&geometry),
            .scratch_data = .{ .device_address = std.mem.alignForward(u64, self.bufferAddress(resource.scratch.?), scratch_alignment) },
        }}, &ranges);
    }

    // --------------------------------------------------------------- samplers

    /// Takes one of 256 bindless slots; `error.BindlessTableFull` beyond that.
    pub fn createSampler(self: *Device, desc: types.SamplerDesc) !types.Sampler {
        const anisotropy = std.math.clamp(desc.max_anisotropy, 1, self.properties.limits.max_sampler_anisotropy);
        const handle = try self.vkd.createSampler(&.{
            .mag_filter = vkFilter(desc.mag_filter),
            .min_filter = vkFilter(desc.min_filter),
            .mipmap_mode = if (desc.mip_filter == .linear) .linear else .nearest,
            .address_mode_u = vkAddressMode(desc.address_u),
            .address_mode_v = vkAddressMode(desc.address_v),
            .address_mode_w = vkAddressMode(desc.address_w),
            .mip_lod_bias = 0,
            .anisotropy_enable = if (anisotropy > 1) .true else .false,
            .max_anisotropy = anisotropy,
            .compare_enable = if (desc.compare != null) .true else .false,
            .compare_op = vkCompareOp(desc.compare orelse .always),
            .min_lod = 0,
            .max_lod = desc.max_lod,
            .border_color = .float_opaque_white,
            .unnormalized_coordinates = .false,
        }, null);
        errdefer self.vkd.destroySampler(handle, null);
        const slot = try self.sampler_slots.allocate();
        const image_info = vk.DescriptorImageInfo{ .sampler = handle, .image_view = .null_handle, .image_layout = .undefined };
        self.vkd.updateDescriptorSets(&.{.{
            .dst_set = self.descriptor_set,
            .dst_binding = 1,
            .dst_array_element = slot,
            .descriptor_count = 1,
            .descriptor_type = .sampler,
            .p_image_info = @ptrCast(&image_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, &.{});
        return try self.samplers.insert(.{ .handle = handle, .bindless_index = slot });
    }

    /// Deferred like `destroyBuffer`.
    pub fn destroySampler(self: *Device, sampler: types.Sampler) void {
        const resource = self.samplers.remove(sampler) orelse return;
        self.retire(.{ .sampler = resource.handle });
        self.retire(.{ .sampler_slot = resource.bindless_index });
    }

    /// Index in the global `samplers[]` shader array. Panics on a stale
    /// handle.
    pub fn samplerIndex(self: *Device, sampler: types.Sampler) u32 {
        return (self.samplers.get(sampler) orelse @panic("stale or invalid sampler handle")).bindless_index;
    }

    // -------------------------------------------------------------- pipelines

    /// `compileGraphicsPipeline` followed by `adoptPipeline`.
    pub fn createGraphicsPipeline(self: *Device, desc: types.GraphicsPipelineDesc) !types.Pipeline {
        const compiled = try self.compileGraphicsPipeline(self.gpa, desc);
        return self.adoptPipeline(compiled, desc.name);
    }

    /// Compiled by `compileGraphicsPipeline`, not yet adopted.
    pub const CompiledPipeline = struct { handle: vk.Pipeline };

    /// Registers a compiled pipeline. Render thread only.
    pub fn adoptPipeline(self: *Device, compiled: CompiledPipeline, label: [:0]const u8) !types.Pipeline {
        errdefer self.vkd.destroyPipeline(compiled.handle, null);
        self.setName(.pipeline, @intFromEnum(compiled.handle), label);
        return try self.pipelines.insert(.{ .handle = compiled.handle, .bind_point = .graphics });
    }

    /// Frees a compiled pipeline that will not be adopted.
    pub fn discardPipeline(self: *const Device, compiled: CompiledPipeline) void {
        self.vkd.destroyPipeline(compiled.handle, null);
    }

    /// Compiles without registering. May be called from any thread, also
    /// during rendering; `gpa` must be safe to use there. At most 16 shader
    /// constants, 16 vertex attributes and 8 color targets.
    pub fn compileGraphicsPipeline(self: *const Device, gpa: std.mem.Allocator, desc: types.GraphicsPipelineDesc) !CompiledPipeline {
        const vertex = if (desc.mesh == null) try self.shaderModule(gpa, desc.vertex) else .null_handle;
        defer if (vertex != .null_handle) self.vkd.destroyShaderModule(vertex, null);
        const mesh = if (desc.mesh) |bytes| try self.shaderModule(gpa, bytes) else .null_handle;
        defer if (mesh != .null_handle) self.vkd.destroyShaderModule(mesh, null);
        const task = if (desc.task) |bytes| try self.shaderModule(gpa, bytes) else .null_handle;
        defer if (task != .null_handle) self.vkd.destroyShaderModule(task, null);
        const fragment = if (desc.fragment) |bytes| try self.shaderModule(gpa, bytes) else .null_handle;
        defer if (fragment != .null_handle) self.vkd.destroyShaderModule(fragment, null);
        var constant_entries: [16]vk.SpecializationMapEntry = undefined;
        if (desc.fragment_constants.len > constant_entries.len) return error.TooManyShaderConstants;
        for (desc.fragment_constants, 0..) |_, index| constant_entries[index] = .{
            .constant_id = @intCast(index),
            .offset = @intCast(index * @sizeOf(u32)),
            .size = @sizeOf(u32),
        };
        const constants = vk.SpecializationInfo{
            .map_entry_count = @intCast(desc.fragment_constants.len),
            .p_map_entries = &constant_entries,
            .data_size = desc.fragment_constants.len * @sizeOf(u32),
            .p_data = @ptrCast(desc.fragment_constants.ptr),
        };
        var stages: [3]vk.PipelineShaderStageCreateInfo = undefined;
        var geometry_stages: u32 = 0;
        if (desc.mesh == null) {
            stages[0] = .{ .stage = .{ .vertex_bit = true }, .module = vertex, .p_name = "main" };
            geometry_stages = 1;
        } else {
            if (desc.task != null) {
                stages[0] = .{ .stage = .{ .task_bit_ext = true }, .module = task, .p_name = "main" };
                geometry_stages = 1;
            }
            stages[geometry_stages] = .{ .stage = .{ .mesh_bit_ext = true }, .module = mesh, .p_name = "main" };
            geometry_stages += 1;
        }
        stages[geometry_stages] = .{ .stage = .{ .fragment_bit = true }, .module = fragment, .p_name = "main", .p_specialization_info = if (desc.fragment_constants.len != 0) &constants else null };

        var attributes: [16]vk.VertexInputAttributeDescription = undefined;
        var binding = vk.VertexInputBindingDescription{ .binding = 0, .stride = 0, .input_rate = .vertex };
        var attribute_count: u32 = 0;
        if (desc.vertex_layout) |layout| {
            if (layout.attributes.len > attributes.len) return error.TooManyVertexAttributes;
            binding.stride = layout.stride;
            for (layout.attributes, 0..) |attribute, index| attributes[index] = .{
                .location = attribute.location,
                .binding = 0,
                .format = switch (attribute.format) {
                    .float2 => .r32g32_sfloat,
                    .float3 => .r32g32b32_sfloat,
                    .float4 => .r32g32b32a32_sfloat,
                    .unorm8x4 => .r8g8b8a8_unorm,
                    .uint1 => .r32_uint,
                },
                .offset = attribute.offset,
            };
            attribute_count = @intCast(layout.attributes.len);
        }
        const vertex_input = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = if (desc.vertex_layout != null) 1 else 0,
            .p_vertex_binding_descriptions = @ptrCast(&binding),
            .vertex_attribute_description_count = attribute_count,
            .p_vertex_attribute_descriptions = &attributes,
        };
        const assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = switch (desc.topology) {
                .triangle_list => .triangle_list,
                .line_list => .line_list,
            },
            .primitive_restart_enable = .false,
        };
        const viewport = vk.PipelineViewportStateCreateInfo{ .viewport_count = 1, .scissor_count = 1 };
        const depth_state = desc.depth orelse types.DepthState{ .@"test" = false, .write = false };
        const rasterization = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = if (depth_state.clamp) .true else .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = switch (desc.cull) {
                .none => .{},
                .front => .{ .front_bit = true },
                .back => .{ .back_bit = true },
            },
            .front_face = .counter_clockwise,
            .depth_bias_enable = if (depth_state.bias != null) .true else .false,
            .depth_bias_constant_factor = if (depth_state.bias) |bias| bias.constant else 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = if (depth_state.bias) |bias| bias.slope else 0,
            .line_width = 1,
        };
        const multisample = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 0,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };
        const stencil = vk.StencilOpState{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .always,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        };
        const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = if (desc.depth != null and depth_state.@"test") .true else .false,
            .depth_write_enable = if (desc.depth != null and depth_state.write) .true else .false,
            .depth_compare_op = vkCompareOp(depth_state.compare),
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = stencil,
            .back = stencil,
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
        };
        var blend_attachments: [8]vk.PipelineColorBlendAttachmentState = undefined;
        var color_formats: [8]vk.Format = undefined;
        if (desc.color_targets.len > blend_attachments.len) return error.TooManyColorTargets;
        for (desc.color_targets, 0..) |target, index| {
            color_formats[index] = vkFormat(target.format);
            blend_attachments[index] = blendState(target.blend);
        }
        const blend = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = @intCast(desc.color_targets.len),
            .p_attachments = &blend_attachments,
            .blend_constants = .{ 0, 0, 0, 0 },
        };
        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const dynamic = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };
        const rendering = vk.PipelineRenderingCreateInfo{
            .view_mask = 0,
            .color_attachment_count = @intCast(desc.color_targets.len),
            .p_color_attachment_formats = &color_formats,
            .depth_attachment_format = if (desc.depth) |depth| vkFormat(depth.format) else .undefined,
            .stencil_attachment_format = .undefined,
        };
        const shading_rate = vk.PipelineFragmentShadingRateStateCreateInfoKHR{
            .p_next = &rendering,
            .fragment_size = .{ .width = 1, .height = 1 },
            .combiner_ops = .{ .keep_khr, .replace_khr },
        };
        var result: [1]vk.Pipeline = undefined;
        _ = try self.vkd.createGraphicsPipelines(self.pipeline_cache, &.{.{
            .p_next = if (self.shading_rate_tile != 0) @as(?*const anyopaque, &shading_rate) else @as(?*const anyopaque, &rendering),
            .flags = .{ .rendering_fragment_shading_rate_attachment_bit_khr = self.shading_rate_tile != 0 },
            .stage_count = if (desc.fragment != null) geometry_stages + 1 else geometry_stages,
            .p_stages = &stages,
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &assembly,
            .p_viewport_state = &viewport,
            .p_rasterization_state = &rasterization,
            .p_multisample_state = &multisample,
            .p_depth_stencil_state = &depth_stencil,
            .p_color_blend_state = &blend,
            .p_dynamic_state = &dynamic,
            .layout = self.pipeline_layout,
            .subpass = 0,
            .base_pipeline_index = -1,
        }}, null, &result);
        return .{ .handle = result[0] };
    }

    /// Compiles on the calling thread and registers the pipeline.
    pub fn createComputePipeline(self: *Device, desc: types.ComputePipelineDesc) !types.Pipeline {
        const module = try self.createShaderModule(desc.shader);
        defer self.vkd.destroyShaderModule(module, null);
        var result: [1]vk.Pipeline = undefined;
        _ = try self.vkd.createComputePipelines(self.pipeline_cache, &.{.{
            .stage = .{ .stage = .{ .compute_bit = true }, .module = module, .p_name = "main" },
            .layout = self.pipeline_layout,
            .base_pipeline_index = -1,
        }}, null, &result);
        errdefer self.vkd.destroyPipeline(result[0], null);
        self.setName(.pipeline, @intFromEnum(result[0]), desc.name);
        return try self.pipelines.insert(.{ .handle = result[0], .bind_point = .compute });
    }

    /// Deferred like `destroyBuffer`, so the frame that last draws with it
    /// may destroy it.
    pub fn destroyPipeline(self: *Device, pipeline: types.Pipeline) void {
        const resource = self.pipelines.remove(pipeline) orelse return;
        self.retire(.{ .pipeline = resource.handle });
    }

    /// Panics on a stale handle. The pointer is valid until a pipeline is
    /// created or destroyed.
    pub fn pipelineResource(self: *Device, pipeline: types.Pipeline) *PipelineResource {
        return self.pipelines.get(pipeline) orelse @panic("stale or invalid pipeline handle");
    }

    // ------------------------------------------------------------- frame loop

    /// Format of the swapchain images.
    pub fn backbufferFormat(self: *Device) !types.Format {
        if (self.swapchain == null) return error.NoSurface;
        if (self.swapchain.?.handle == .null_handle) try self.recreateSwapchain();
        return switch (self.swapchain.?.format.format) {
            .b8g8r8a8_srgb => .bgra8_srgb,
            .b8g8r8a8_unorm => .bgra8_unorm,
            .r8g8b8a8_srgb => .rgba8_srgb,
            .r8g8b8a8_unorm => .rgba8_unorm,
            .a2b10g10r10_unorm_pack32 => .a2b10g10r10_unorm,
            else => error.UnsupportedSurfaceFormat,
        };
    }

    /// Swapchain image size in pixels, which may differ from `resize`. Zero
    /// when headless and before the swapchain exists.
    pub fn backbufferSize(self: *const Device) [2]u32 {
        const swapchain = self.swapchain orelse return .{ 0, 0 };
        return .{ swapchain.extent.width, swapchain.extent.height };
    }

    /// Tells the swapchain the window's framebuffer size changed.
    pub fn resize(self: *Device, width: u32, height: u32) void {
        if (self.swapchain) |*swapchain| {
            if (swapchain.requested_width == width and swapchain.requested_height == height) return;
            swapchain.requested_width = width;
            swapchain.requested_height = height;
            swapchain.dirty = true;
        }
    }

    /// Takes effect at the next swapchain rebuild. No-op when headless.
    pub fn setVsync(self: *Device, vsync: bool) void {
        if (self.swapchain) |*swapchain| {
            if (swapchain.vsync == vsync) return;
            swapchain.vsync = vsync;
            swapchain.dirty = true;
        }
    }

    /// `waitForFrame` + `prepareSurface` + `acquireImage` + `startFrame`.
    /// Returns null when there is nothing to draw to; try again next time.
    pub fn beginFrame(self: *Device) !?Frame {
        try self.waitForFrame();
        if (!try self.prepareSurface()) return null;
        if (!try self.acquireImage()) return null;
        return try self.startFrame();
    }

    /// Submits the frame and presents the backbuffer if there is one.
    pub fn endFrame(self: *Device) !void {
        try self.submitFrame();
        try self.presentFrame();
    }

    /// Blocks until the GPU has finished the frame whose slot is reused next.
    /// Touches no shared device state.
    pub fn waitForFrame(self: *Device) !void {
        const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
        _ = try self.vkd.waitForFences(&.{frame.fence}, .true, std.math.maxInt(u64));
    }

    /// Rebuilds the swapchain if the window changed. False while the window
    /// has no drawable area; always true when headless.
    pub fn prepareSurface(self: *Device) !bool {
        const swapchain = if (self.swapchain) |*value| value else return true;
        if (swapchain.requested_width == 0 or swapchain.requested_height == 0) return false;
        if (swapchain.dirty or swapchain.stale or swapchain.handle == .null_handle) try self.recreateSwapchain();
        return true;
    }

    /// May block on the compositor. False if the swapchain went out of date.
    /// May run outside a device lock.
    pub fn acquireImage(self: *Device) !bool {
        const swapchain = if (self.swapchain) |*value| value else return true;
        const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
        const acquired = self.vkd.acquireNextImageKHR(swapchain.handle, std.math.maxInt(u64), frame.image_available, .null_handle) catch |err| switch (err) {
            error.OutOfDateKHR => {
                swapchain.stale = true;
                return false;
            },
            else => return err,
        };
        if (acquired.result == .suboptimal_khr) swapchain.stale = true;
        swapchain.image_index = acquired.image_index;
        return true;
    }

    /// Begins recording, after `waitForFrame` and `acquireImage`. On failure
    /// the acquired image is abandoned.
    pub fn startFrame(self: *Device) !Frame {
        std.debug.assert(!self.in_frame);
        const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
        errdefer self.abandonAcquiredImage(frame);
        self.collectTimings(frame);
        self.collectGarbage(false);
        var backbuffer: ?types.Texture = null;
        if (self.swapchain) |*swapchain| {
            backbuffer = swapchain.textures.items[swapchain.image_index];
            self.textureResource(backbuffer.?).states[0] = .undefined;
        }
        try self.vkd.resetCommandPool(frame.pool, .{});
        try self.vkd.beginCommandBuffer(frame.command, &.{ .flags = .{ .one_time_submit_bit = true } });
        frame.scope_count = 0;
        self.vkd.cmdResetQueryPool(frame.command, frame.query_pool, 0, max_timing_scopes * 2);
        self.encoder = .{ .device = self, .command = frame.command, .frame = frame };
        self.in_frame = true;
        self.encoder.bindGlobals();
        try self.encoder.flushUploads();
        return .{ .cmd = &self.encoder, .backbuffer = backbuffer, .index = self.frame_number };
    }

    /// Ends recording and submits. On failure the image is abandoned and the
    /// slot's fence is left signaled.
    pub fn submitFrame(self: *Device) !void {
        std.debug.assert(self.in_frame);
        const frame = &self.frames[@intCast(self.frame_number % frames_in_flight)];
        std.debug.assert(self.encoder.scope_depth == 0);
        errdefer {
            self.in_frame = false;
            self.abandonAcquiredImage(frame);
        }
        const presenting = self.swapchain != null;
        if (presenting) self.encoder.transition(self.swapchain.?.textures.items[self.swapchain.?.image_index], .present);
        try self.vkd.endCommandBuffer(frame.command);
        self.in_frame = false;

        try self.vkd.resetFences(&.{frame.fence});
        errdefer if (self.vkd.createFence(&.{ .flags = .{ .signaled_bit = true } }, null)) |signaled| {
            self.vkd.destroyFence(frame.fence, null);
            frame.fence = signaled;
        } else |_| {};
        const command_info = vk.CommandBufferSubmitInfo{ .command_buffer = frame.command, .device_mask = 0 };
        var wait_info: vk.SemaphoreSubmitInfo = undefined;
        var signal_info: vk.SemaphoreSubmitInfo = undefined;
        if (self.swapchain) |*swapchain| {
            wait_info = .{ .semaphore = frame.image_available, .value = 0, .stage_mask = .{ .all_commands_bit = true }, .device_index = 0 };
            signal_info = .{
                .semaphore = swapchain.render_finished.items[swapchain.image_index],
                .value = 0,
                .stage_mask = .{ .all_commands_bit = true },
                .device_index = 0,
            };
        }
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        try self.vkd.queueSubmit2(self.queue, &.{.{
            .wait_semaphore_info_count = if (presenting) 1 else 0,
            .p_wait_semaphore_infos = @ptrCast(&wait_info),
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast(&command_info),
            .signal_semaphore_info_count = if (presenting) 1 else 0,
            .p_signal_semaphore_infos = @ptrCast(&signal_info),
        }}, frame.fence);
        if (self.swapchain) |*swapchain| swapchain.present_pending = true;
        frame.submitted = true;
        self.frame_number += 1;
    }

    /// Marks the image acquired for `frame` as never presented: the swapchain
    /// and the acquire semaphore are recreated before the next frame.
    fn abandonAcquiredImage(self: *Device, frame: *FrameData) void {
        const swapchain = if (self.swapchain) |*value| value else return;
        swapchain.stale = true;
        frame.acquire_abandoned = true;
    }

    /// May block on vsync. May run outside a device lock.
    pub fn presentFrame(self: *Device) !void {
        const swapchain = if (self.swapchain) |*value| value else return;
        if (!swapchain.present_pending) return;
        swapchain.present_pending = false;
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        const result = self.vkd.queuePresentKHR(self.queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&swapchain.render_finished.items[swapchain.image_index]),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&swapchain.handle),
            .p_image_indices = @ptrCast(&swapchain.image_index),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => vk.Result.suboptimal_khr,
            else => return err,
        };
        if (result == .suboptimal_khr) swapchain.stale = true;
    }

    /// Closes the open render pass and timing scopes of a frame whose
    /// recording failed. `submitFrame` must still follow.
    pub fn closeFailedFrame(self: *Device) void {
        std.debug.assert(self.in_frame);
        if (self.encoder.rendering) self.encoder.endRendering();
        while (self.encoder.scope_depth > 0) self.encoder.endScope();
    }

    /// Blocks until every submitted frame has finished on the GPU.
    pub fn waitIdle(self: *Device) !void {
        {
            self.queue_mutex.lockUncancelable(self.io);
            defer self.queue_mutex.unlock(self.io);
            try self.vkd.deviceWaitIdle();
        }
        if (!self.in_frame) self.collectGarbage(true);
    }

    /// Records and submits every queued upload, blocking until done.
    pub fn flushUploadsBlocking(self: *Device) !void {
        std.debug.assert(!self.in_frame);
        if (self.uploads.items.len == 0) return;
        var encoder = try self.beginImmediate();
        try encoder.flushUploads();
        try self.endImmediate();
        self.collectGarbage(true);
    }

    /// Staged bytes no flush has recorded yet, including cancelled uploads.
    pub fn pendingUploadBytes(self: *const Device) u64 {
        return self.pending_upload_bytes;
    }

    // ---------------------------------------------------------------- private

    /// The shader stages push constants and the table of textures reach.
    pub fn shaderStages(self: *const Device) vk.ShaderStageFlags {
        return .{ .vertex_bit = true, .fragment_bit = true, .compute_bit = true, .task_bit_ext = self.mesh_shaders, .mesh_bit_ext = self.mesh_shaders };
    }

    /// Starts a command buffer for the second queue, or null where the GPU
    /// has one queue. While it runs it must not touch what a frame writes nor
    /// write what a frame reads. Finish with `submitDetached`.
    pub fn beginDetached(self: *Device) !?CommandEncoder {
        if (self.detached_queue == null) return null;
        var command: vk.CommandBuffer = undefined;
        try self.vkd.allocateCommandBuffers(&.{
            .command_pool = self.detached_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command));
        errdefer self.vkd.freeCommandBuffers(self.detached_pool, &.{command});
        try self.vkd.beginCommandBuffer(command, &.{ .flags = .{ .one_time_submit_bit = true } });
        var encoder = CommandEncoder{ .device = self, .command = command, .frame = null };
        encoder.bindGlobals();
        return encoder;
    }

    /// Submits without waiting; poll `detachedDone`, then `releaseDetached`.
    pub fn submitDetached(self: *Device, encoder: CommandEncoder) !Detached {
        errdefer self.vkd.freeCommandBuffers(self.detached_pool, &.{encoder.command});
        try self.vkd.endCommandBuffer(encoder.command);
        const fence = try self.vkd.createFence(&.{}, null);
        errdefer self.vkd.destroyFence(fence, null);
        const command_info = vk.CommandBufferSubmitInfo{ .command_buffer = encoder.command, .device_mask = 0 };
        try self.vkd.queueSubmit2(self.detached_queue.?, &.{.{
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast(&command_info),
        }}, fence);
        self.detached_outstanding += 1;
        return .{ .command = encoder.command, .fence = fence };
    }

    pub fn detachedDone(self: *Device, job: Detached) bool {
        return (self.vkd.getFenceStatus(job.fence) catch return false) == .success;
    }

    /// Waits for the job if it is still running.
    pub fn releaseDetached(self: *Device, job: Detached) void {
        _ = self.vkd.waitForFences(&.{job.fence}, .true, std.math.maxInt(u64)) catch {};
        self.vkd.destroyFence(job.fence, null);
        self.vkd.freeCommandBuffers(self.detached_pool, &.{job.command});
        self.detached_outstanding -= 1;
    }

    /// Starts a one-off command buffer; finish with `endImmediate`.
    pub fn beginImmediate(self: *Device) !CommandEncoder {
        std.debug.assert(!self.in_frame);
        try self.vkd.resetCommandPool(self.immediate_pool, .{});
        try self.vkd.beginCommandBuffer(self.immediate_command, &.{ .flags = .{ .one_time_submit_bit = true } });
        var encoder = CommandEncoder{ .device = self, .command = self.immediate_command, .frame = null };
        encoder.bindGlobals();
        return encoder;
    }

    /// Submits and blocks until the GPU is idle, then runs all deferred
    /// destruction. The encoder must not be used afterwards.
    pub fn endImmediate(self: *Device) !void {
        try self.vkd.endCommandBuffer(self.immediate_command);
        const fence = try self.vkd.createFence(&.{}, null);
        defer self.vkd.destroyFence(fence, null);
        const command_info = vk.CommandBufferSubmitInfo{ .command_buffer = self.immediate_command, .device_mask = 0 };
        {
            self.queue_mutex.lockUncancelable(self.io);
            defer self.queue_mutex.unlock(self.io);
            try self.vkd.queueSubmit2(self.queue, &.{.{
                .command_buffer_info_count = 1,
                .p_command_buffer_infos = @ptrCast(&command_info),
            }}, fence);
        }
        _ = try self.vkd.waitForFences(&.{fence}, .true, std.math.maxInt(u64));
        try self.waitIdle();
    }

    fn createStaging(self: *Device, data: []const u8) !types.Buffer {
        const staging = try self.createBuffer(.{
            .name = "staging",
            .size = data.len,
            .usage = .{ .copy_src = true },
            .memory = .cpu_to_gpu,
        });
        @memcpy(self.mapped(staging)[0..data.len], data);
        return staging;
    }

    /// Called by `CommandEncoder.flushUploads`; use that. The caller owns the
    /// list (free with `gpa`) and must record and destroy its staging buffers.
    pub fn takeUploads(self: *Device) std.ArrayList(PendingUpload) {
        const result = self.uploads;
        self.uploads = .empty;
        self.pending_upload_bytes = 0;
        return result;
    }

    fn createShaderModule(self: *Device, bytes: []const u8) !vk.ShaderModule {
        return self.shaderModule(self.gpa, bytes);
    }

    fn shaderModule(self: *const Device, gpa: std.mem.Allocator, bytes: []const u8) !vk.ShaderModule {
        if (bytes.len == 0 or bytes.len % 4 != 0) return error.InvalidSpirv;
        const words = try gpa.alloc(u32, bytes.len / 4);
        defer gpa.free(words);
        @memcpy(std.mem.sliceAsBytes(words), bytes);
        return self.vkd.createShaderModule(&.{ .code_size = bytes.len, .p_code = words.ptr }, null);
    }

    fn createDescriptorTable(self: *Device) !void {
        const all_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = texture_capacity, .stage_flags = self.shaderStages() },
            .{ .binding = 1, .descriptor_type = .sampler, .descriptor_count = sampler_capacity, .stage_flags = self.shaderStages() },
            .{ .binding = 2, .descriptor_type = .storage_image, .descriptor_count = storage_capacity, .stage_flags = .{ .compute_bit = true } },
        };
        // The last is left out where the GPU cannot update it while bound.
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

    fn retire(self: *Device, object: Deletion) void {
        self.deletions.append(self.gpa, .{ .frame = self.frame_number, .object = object }) catch {
            self.vkd.deviceWaitIdle() catch {};
            self.destroyNow(object);
        };
    }

    /// Destroys retired objects no in-flight frame can reference.
    fn collectGarbage(self: *Device, everything: bool) void {
        var write: usize = 0;
        for (self.deletions.items) |pending| {
            // A detached job may still be reading what a frame let go of.
            if (everything or (self.detached_outstanding == 0 and pending.frame + frames_in_flight <= self.frame_number)) {
                self.destroyNow(pending.object);
            } else {
                self.deletions.items[write] = pending;
                write += 1;
            }
        }
        self.deletions.items.len = write;
    }

    fn destroyNow(self: *Device, object: Deletion) void {
        switch (object) {
            .buffer => |buffer| {
                self.vkd.destroyBuffer(buffer.handle, null);
                self.allocator.free(buffer.allocation);
            },
            .image => |image| {
                self.vkd.destroyImage(image.handle, null);
                if (image.allocation) |allocation| self.allocator.free(allocation);
            },
            .view => |view| self.vkd.destroyImageView(view, null),
            .sampler => |sampler| self.vkd.destroySampler(sampler, null),
            .pipeline => |pipeline| self.vkd.destroyPipeline(pipeline, null),
            .acceleration => |acceleration| self.vkd.destroyAccelerationStructureKHR(acceleration, null),
            .texture_slot => |slot| self.texture_slots.release(slot),
            .storage_slot => |slot| self.storage_slots.release(slot),
            .sampler_slot => |slot| self.sampler_slots.release(slot),
        }
    }

    fn collectTimings(self: *Device, frame: *FrameData) void {
        if (!frame.submitted or frame.scope_count == 0) return;
        var raw: [max_timing_scopes * 2]u64 = undefined;
        _ = self.vkd.getQueryPoolResults(
            frame.query_pool,
            0,
            frame.scope_count * 2,
            @sizeOf(u64) * frame.scope_count * 2,
            &raw,
            @sizeOf(u64),
            .{ .@"64_bit" = true },
        ) catch return;
        const period: f64 = self.properties.limits.timestamp_period;
        for (frame.scopes[0..frame.scope_count], 0..) |scope, index| {
            const ticks = raw[index * 2 + 1] -% raw[index * 2];
            self.timings[index] = .{
                .name = scope.name,
                .milliseconds = @floatCast(@as(f64, @floatFromInt(ticks)) * period / 1e6),
                .depth = scope.depth,
            };
        }
        self.timing_count = frame.scope_count;
    }

    fn recreateSwapchain(self: *Device) !void {
        const swapchain = &self.swapchain.?;
        try self.vkd.deviceWaitIdle();
        const capabilities = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical, self.surface);
        const formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(self.physical, self.surface, self.gpa);
        defer self.gpa.free(formats);
        const modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(self.physical, self.surface, self.gpa);
        defer self.gpa.free(modes);
        if (formats.len == 0 or modes.len == 0) return error.SurfaceUnsupported;

        var format = formats[0];
        for (formats) |candidate| {
            if (candidate.color_space != .srgb_nonlinear_khr) continue;
            if (candidate.format == .b8g8r8a8_srgb or candidate.format == .r8g8b8a8_srgb) {
                format = candidate;
                break;
            }
        }
        swapchain_hdr: {
            self.hdr_active = false;
            if (!self.hdr_wanted) break :swapchain_hdr;
            for (formats) |candidate| {
                if (candidate.color_space == .hdr10_st2084_ext and candidate.format == .a2b10g10r10_unorm_pack32) {
                    format = candidate;
                    self.hdr_active = true;
                    break;
                }
            }
        }
        var present_mode: vk.PresentModeKHR = .fifo_khr;
        if (!swapchain.vsync) {
            for (modes) |mode| if (mode == .mailbox_khr) {
                present_mode = mode;
            };
            for (modes) |mode| if (mode == .immediate_khr) {
                present_mode = mode;
            };
        }
        const extent: vk.Extent2D = if (capabilities.current_extent.width != std.math.maxInt(u32))
            capabilities.current_extent
        else
            .{
                .width = std.math.clamp(swapchain.requested_width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
                .height = std.math.clamp(swapchain.requested_height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
            };
        if (extent.width == 0 or extent.height == 0) return error.SurfaceUnsupported;
        var image_count = @max(capabilities.min_image_count + 1, 3);
        if (capabilities.max_image_count != 0) image_count = @min(image_count, capabilities.max_image_count);
        var composite_alpha: vk.CompositeAlphaFlagsKHR = .{ .opaque_bit_khr = true };
        if (!capabilities.supported_composite_alpha.opaque_bit_khr) composite_alpha = .{ .inherit_bit_khr = true };

        const old = swapchain.handle;
        const handle = try self.vkd.createSwapchainKHR(&.{
            .surface = self.surface,
            .min_image_count = image_count,
            .image_format = format.format,
            .image_color_space = format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = composite_alpha,
            .present_mode = present_mode,
            .clipped = .true,
            .old_swapchain = old,
        }, null);
        self.releaseSwapchainImages();
        if (old != .null_handle) self.vkd.destroySwapchainKHR(old, null);
        for (&self.frames) |*frame| {
            if (!frame.acquire_abandoned) continue;
            const fresh = try self.vkd.createSemaphore(&.{}, null);
            self.vkd.destroySemaphore(frame.image_available, null);
            frame.image_available = fresh;
            frame.acquire_abandoned = false;
        }
        swapchain.handle = handle;
        swapchain.format = format;
        swapchain.extent = extent;
        swapchain.dirty = false;
        swapchain.stale = false;

        const images = try self.vkd.getSwapchainImagesAllocKHR(handle, self.gpa);
        defer self.gpa.free(images);
        const texture_format: types.Format = switch (format.format) {
            .b8g8r8a8_srgb => .bgra8_srgb,
            .b8g8r8a8_unorm => .bgra8_unorm,
            .r8g8b8a8_srgb => .rgba8_srgb,
            .r8g8b8a8_unorm => .rgba8_unorm,
            .a2b10g10r10_unorm_pack32 => .a2b10g10r10_unorm,
            else => return error.UnsupportedSurfaceFormat,
        };
        for (images) |image| {
            try swapchain.textures.append(self.gpa, try self.registerTexture(image, null, .{
                .width = extent.width,
                .height = extent.height,
                .format = texture_format,
                .mip_levels = 1,
                .layers = 1,
                .kind = .@"2d",
            }, false));
            try swapchain.render_finished.append(self.gpa, try self.vkd.createSemaphore(&.{}, null));
        }
    }

    fn releaseSwapchainImages(self: *Device) void {
        const swapchain = &self.swapchain.?;
        for (swapchain.textures.items) |texture| {
            const resource = self.textures.remove(texture) orelse continue;
            self.vkd.destroyImageView(resource.view, null);
        }
        for (swapchain.render_finished.items) |semaphore| self.vkd.destroySemaphore(semaphore, null);
        swapchain.textures.clearRetainingCapacity();
        swapchain.render_finished.clearRetainingCapacity();
    }

    fn destroySwapchain(self: *Device) void {
        if (self.swapchain == null) return;
        self.releaseSwapchainImages();
        const swapchain = &self.swapchain.?;
        swapchain.textures.deinit(self.gpa);
        swapchain.render_finished.deinit(self.gpa);
        if (swapchain.handle != .null_handle) self.vkd.destroySwapchainKHR(swapchain.handle, null);
        self.swapchain = null;
    }

    fn persistPipelineCache(self: *Device) !void {
        const path = self.pipeline_cache_path orelse return;
        var size: usize = 0;
        _ = try self.vkd.getPipelineCacheData(self.pipeline_cache, &size, null);
        const data = try self.gpa.alloc(u8, size);
        defer self.gpa.free(data);
        _ = try self.vkd.getPipelineCacheData(self.pipeline_cache, &size, data.ptr);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, data[0..size]);
    }
};

/// Fixed-capacity index allocator for bindless descriptor slots.
const SlotAllocator = struct {
    free: std.ArrayList(u32) = .empty,
    next: u32 = 0,
    capacity: u32,

    fn init(gpa: std.mem.Allocator, capacity: u32) !SlotAllocator {
        var self = SlotAllocator{ .capacity = capacity };
        // Reserved up front so `release` can never fail.
        try self.free.ensureTotalCapacity(gpa, capacity);
        return self;
    }

    fn deinit(self: *SlotAllocator, gpa: std.mem.Allocator) void {
        self.free.deinit(gpa);
    }

    fn allocate(self: *SlotAllocator) !u32 {
        if (self.free.pop()) |slot| return slot;
        if (self.next == self.capacity) return error.BindlessTableFull;
        defer self.next += 1;
        return self.next;
    }

    fn release(self: *SlotAllocator, slot: u32) void {
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

fn vkFilter(filter: types.Filter) vk.Filter {
    return if (filter == .linear) .linear else .nearest;
}

fn vkAddressMode(mode: types.AddressMode) vk.SamplerAddressMode {
    return switch (mode) {
        .repeat => .repeat,
        .mirrored_repeat => .mirrored_repeat,
        .clamp_to_edge => .clamp_to_edge,
        .clamp_to_border => .clamp_to_border,
    };
}

fn vkCompareOp(op: types.CompareOp) vk.CompareOp {
    return switch (op) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_or_equal => .less_or_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_or_equal => .greater_or_equal,
        .always => .always,
    };
}

fn blendState(mode: types.BlendMode) vk.PipelineColorBlendAttachmentState {
    const write_all = vk.ColorComponentFlags{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true };
    return switch (mode) {
        .none => .{
            .blend_enable = .false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
        .alpha => .{
            .blend_enable = .true,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
        .premultiplied => .{
            .blend_enable = .true,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
        .tint => .{
            .blend_enable = .true,
            .src_color_blend_factor = .dst_color,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = .min,
            .color_write_mask = write_all,
        },
        .minimum, .maximum => .{
            .blend_enable = .true,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .one,
            .color_blend_op = if (mode == .minimum) .min else .max,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = if (mode == .minimum) .min else .max,
            .color_write_mask = write_all,
        },
        .under => .{
            .blend_enable = .true,
            .src_color_blend_factor = .one_minus_dst_alpha,
            .dst_color_blend_factor = .one,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one_minus_dst_alpha,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
        .revealage => .{
            .blend_enable = .true,
            .src_color_blend_factor = .zero,
            .dst_color_blend_factor = .one_minus_src_color,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .zero,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
        .additive => .{
            .blend_enable = .true,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .one,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = .add,
            .color_write_mask = write_all,
        },
    };
}

const SelectedDevice = struct {
    physical: vk.PhysicalDevice,
    queue_family: u32,
    queue_count: u32,
    properties: vk.PhysicalDeviceProperties,
    score: u32,
};

fn selectPhysicalDevice(
    gpa: std.mem.Allocator,
    instance: dispatch.Instance,
    surface: vk.SurfaceKHR,
    preferred: ?[]const u8,
) !SelectedDevice {
    const devices = try instance.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(devices);
    var best: ?SelectedDevice = null;
    for (devices) |physical| {
        const properties = instance.getPhysicalDeviceProperties(physical);
        if (properties.api_version < required_api_version) continue;
        if (preferred) |wanted| {
            if (std.mem.indexOf(u8, std.mem.sliceTo(&properties.device_name, 0), wanted) == null) continue;
        }
        if (!supportsRequiredFeatures(instance, physical)) continue;
        const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical, gpa);
        defer gpa.free(families);
        for (families, 0..) |family, index| {
            if (family.queue_count == 0 or !family.queue_flags.graphics_bit or !family.queue_flags.compute_bit) continue;
            if (surface != .null_handle and
                (try instance.getPhysicalDeviceSurfaceSupportKHR(physical, @intCast(index), surface)) != .true) continue;
            const score: u32 = switch (properties.device_type) {
                .discrete_gpu => 4,
                .integrated_gpu => 3,
                .virtual_gpu => 2,
                else => 1,
            };
            if (best == null or score > best.?.score) best = .{
                .physical = physical,
                .queue_family = @intCast(index),
                .queue_count = family.queue_count,
                .properties = properties,
                .score = score,
            };
            break;
        }
    }
    return best orelse error.NoSuitableDevice;
}

fn supportsRequiredFeatures(instance: dispatch.Instance, physical: vk.PhysicalDevice) bool {
    var features13 = vk.PhysicalDeviceVulkan13Features{};
    var features12 = vk.PhysicalDeviceVulkan12Features{ .p_next = &features13 };
    var features11 = vk.PhysicalDeviceVulkan11Features{ .p_next = &features12 };
    var features = vk.PhysicalDeviceFeatures2{ .p_next = &features11, .features = .{} };
    instance.getPhysicalDeviceFeatures2(physical, &features);
    return features.features.multi_draw_indirect == .true and
        features.features.draw_indirect_first_instance == .true and
        features.features.sampler_anisotropy == .true and
        features.features.depth_clamp == .true and
        features.features.shader_int_64 == .true and
        features.features.geometry_shader == .true and
        features.features.shader_clip_distance == .true and
        features11.shader_draw_parameters == .true and
        features12.descriptor_indexing == .true and
        features12.runtime_descriptor_array == .true and
        features12.descriptor_binding_partially_bound == .true and
        features12.descriptor_binding_sampled_image_update_after_bind == .true and
        features12.shader_sampled_image_array_non_uniform_indexing == .true and
        features12.scalar_block_layout == .true and
        features12.buffer_device_address == .true and
        features12.draw_indirect_count == .true and
        features13.synchronization_2 == .true and
        features13.dynamic_rendering == .true;
}

fn createSurface(instance: dispatch.Instance, window: types.NativeWindow) !vk.SurfaceKHR {
    return switch (window) {
        .xlib => |native| instance.createXlibSurfaceKHR(&.{
            .dpy = @ptrCast(native.display),
            .window = @intCast(native.window),
        }, null),
        .wayland => |native| instance.createWaylandSurfaceKHR(&.{
            .display = @ptrCast(native.display),
            .surface = @ptrCast(native.surface),
        }, null),
        .win32 => |native| instance.createWin32SurfaceKHR(&.{
            .hinstance = @ptrCast(native.instance),
            .hwnd = @ptrCast(native.window),
        }, null),
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

fn sameHandle(a: anytype, b: @TypeOf(a)) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}

const scratch_alignment = 256;

const ray_query_extensions = [_][*:0]const u8{
    vk.extensions.khr_deferred_host_operations.name,
    vk.extensions.khr_acceleration_structure.name,
    vk.extensions.khr_ray_query.name,
};

fn tlasGeometry(instances_address: u64) vk.AccelerationStructureGeometryKHR {
    return .{
        .geometry_type = .instances_khr,
        .flags = .{ .opaque_bit_khr = true },
        .geometry = .{ .instances = .{
            .array_of_pointers = .false,
            .data = .{ .device_address = instances_address },
        } },
    };
}

/// Tile size of shading rate textures on this GPU, or 0 when unsupported.
fn shadingRateTile(gpa: std.mem.Allocator, instance: dispatch.Instance, physical: vk.PhysicalDevice) !u32 {
    const available = try instance.enumerateDeviceExtensionPropertiesAlloc(physical, null, gpa);
    defer gpa.free(available);
    var found = false;
    for (available) |extension| {
        if (std.mem.eql(u8, std.mem.sliceTo(&extension.extension_name, 0), vk.extensions.khr_fragment_shading_rate.name)) found = true;
    }
    if (!found) return 0;
    var rate = vk.PhysicalDeviceFragmentShadingRateFeaturesKHR{};
    var features = vk.PhysicalDeviceFeatures2{ .p_next = &rate, .features = .{} };
    instance.getPhysicalDeviceFeatures2(physical, &features);
    if (rate.pipeline_fragment_shading_rate != .true or rate.attachment_fragment_shading_rate != .true) return 0;
    var limits = std.mem.zeroInit(vk.PhysicalDeviceFragmentShadingRatePropertiesKHR, .{});
    var properties = vk.PhysicalDeviceProperties2{ .p_next = &limits, .properties = undefined };
    instance.getPhysicalDeviceProperties2(physical, &properties);
    const smallest = limits.min_fragment_shading_rate_attachment_texel_size.width;
    const largest = limits.max_fragment_shading_rate_attachment_texel_size.width;
    if (smallest == 0 or largest == 0) return 0;
    return std.math.clamp(16, smallest, largest);
}

fn deviceExtensionListed(gpa: std.mem.Allocator, instance: dispatch.Instance, physical: vk.PhysicalDevice, name: [*:0]const u8) !bool {
    const available = try instance.enumerateDeviceExtensionPropertiesAlloc(physical, null, gpa);
    defer gpa.free(available);
    for (available) |extension| {
        if (std.mem.eql(u8, std.mem.sliceTo(&extension.extension_name, 0), std.mem.span(name))) return true;
    }
    return false;
}

fn supportsMeshShaders(gpa: std.mem.Allocator, instance: dispatch.Instance, physical: vk.PhysicalDevice) !bool {
    const available = try instance.enumerateDeviceExtensionPropertiesAlloc(physical, null, gpa);
    defer gpa.free(available);
    var found = false;
    for (available) |extension| {
        if (std.mem.eql(u8, std.mem.sliceTo(&extension.extension_name, 0), vk.extensions.ext_mesh_shader.name)) found = true;
    }
    if (!found) return false;
    var mesh = vk.PhysicalDeviceMeshShaderFeaturesEXT{};
    var features = vk.PhysicalDeviceFeatures2{ .p_next = &mesh, .features = .{} };
    instance.getPhysicalDeviceFeatures2(physical, &features);
    return mesh.task_shader == .true and mesh.mesh_shader == .true;
}

fn supportsRayQueries(gpa: std.mem.Allocator, instance: dispatch.Instance, physical: vk.PhysicalDevice) !bool {
    const available = try instance.enumerateDeviceExtensionPropertiesAlloc(physical, null, gpa);
    defer gpa.free(available);
    for (ray_query_extensions) |wanted| {
        var found = false;
        for (available) |extension| {
            if (std.mem.eql(u8, std.mem.sliceTo(&extension.extension_name, 0), std.mem.span(wanted))) found = true;
        }
        if (!found) return false;
    }
    var ray_query = vk.PhysicalDeviceRayQueryFeaturesKHR{};
    var acceleration = vk.PhysicalDeviceAccelerationStructureFeaturesKHR{ .p_next = &ray_query };
    var features = vk.PhysicalDeviceFeatures2{ .p_next = &acceleration, .features = .{} };
    instance.getPhysicalDeviceFeatures2(physical, &features);
    return ray_query.ray_query == .true and acceleration.acceleration_structure == .true;
}

fn instanceExtensionAvailable(gpa: std.mem.Allocator, base: dispatch.Base, name: [*:0]const u8) !bool {
    const available = try base.enumerateInstanceExtensionPropertiesAlloc(null, gpa);
    defer gpa.free(available);
    for (available) |extension| {
        if (std.mem.orderZ(u8, @ptrCast(&extension.extension_name), name) == .eq) return true;
    }
    return false;
}
