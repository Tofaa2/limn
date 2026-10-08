//! Choosing the physical device and reading what it supports. Internal to the device.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("../types.zig");
const dispatch = @import("../dispatch.zig");
const device_module = @import("../device.zig");

const ray_query_extensions = device_module.ray_query_extensions;
const required_api_version = device_module.required_api_version;

const SelectedDevice = struct {
    physical: vk.PhysicalDevice,
    queue_family: u32,
    queue_count: u32,
    properties: vk.PhysicalDeviceProperties,
    score: u32,
};

pub fn selectPhysicalDevice(
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

pub fn createSurface(instance: dispatch.Instance, window: types.NativeWindow) !vk.SurfaceKHR {
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

/// Tile size of shading rate textures on this GPU, or 0 when unsupported.
pub fn shadingRateTile(gpa: std.mem.Allocator, instance: dispatch.Instance, physical: vk.PhysicalDevice) !u32 {
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

pub fn deviceExtensionListed(gpa: std.mem.Allocator, instance: dispatch.Instance, physical: vk.PhysicalDevice, name: [*:0]const u8) !bool {
    const available = try instance.enumerateDeviceExtensionPropertiesAlloc(physical, null, gpa);
    defer gpa.free(available);
    for (available) |extension| {
        if (std.mem.eql(u8, std.mem.sliceTo(&extension.extension_name, 0), std.mem.span(name))) return true;
    }
    return false;
}

pub fn supportsMeshShaders(gpa: std.mem.Allocator, instance: dispatch.Instance, physical: vk.PhysicalDevice) !bool {
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

pub fn supportsRayQueries(gpa: std.mem.Allocator, instance: dispatch.Instance, physical: vk.PhysicalDevice) !bool {
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

pub fn instanceExtensionAvailable(gpa: std.mem.Allocator, base: dispatch.Base, name: [*:0]const u8) !bool {
    const available = try base.enumerateInstanceExtensionPropertiesAlloc(null, gpa);
    defer gpa.free(available);
    for (available) |extension| {
        if (std.mem.orderZ(u8, @ptrCast(&extension.extension_name), name) == .eq) return true;
    }
    return false;
}
