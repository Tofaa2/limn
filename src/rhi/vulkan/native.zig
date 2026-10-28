//! Native handles for handing the device's objects to an external SDK. The
//! only place outside the device layer that sees them.
const rhi = @import("../rhi.zig");
const loader = @import("loader.zig");

/// The device as Vulkan handles. Dispatchable handles are pointers, the pipeline
/// cache a 64-bit handle.
pub const Device = struct {
    instance: usize,
    physical_device: usize,
    device: usize,
    queue: usize,
    queue_family: u32,
    pipeline_cache: u64,
    /// `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr`.
    get_instance_proc_addr: *const anyopaque,
    get_device_proc_addr: *const anyopaque,
};

/// A texture as a `VkImage`, the `VkImageView` of all of it and its `VkFormat`.
pub const Image = struct {
    image: u64,
    view: u64,
    format: i32,
    width: u32,
    height: u32,
};

pub fn device(source: *const rhi.Device) Device {
    return .{
        .instance = @intFromEnum(source.instance.handle),
        .physical_device = @intFromEnum(source.physical),
        .device = @intFromEnum(source.vkd.handle),
        .queue = @intFromEnum(source.queue),
        .queue_family = source.queue_family,
        .pipeline_cache = @intFromEnum(source.pipeline_cache),
        .get_instance_proc_addr = loader.instanceProcAddr(),
        .get_device_proc_addr = loader.deviceProcAddr(),
    };
}

pub fn image(source: *rhi.Device, texture: rhi.Texture) Image {
    const resource = source.textureResource(texture);
    return .{
        .image = @intFromEnum(resource.image),
        .view = @intFromEnum(resource.view),
        .format = @intFromEnum(resource.vk_format),
        .width = resource.info.width,
        .height = resource.info.height,
    };
}

/// The encoder's `VkCommandBuffer`, for an SDK to record into, with every
/// owed texture back in `shader_read`. Call `restore` once it has.
pub fn commandBuffer(cmd: *rhi.CommandEncoder) usize {
    cmd.settle();
    return @intFromEnum(cmd.command);
}

/// Rebinds what external code recording into the encoder may have unbound.
pub fn restore(cmd: *rhi.CommandEncoder) void {
    cmd.bindGlobals();
}
