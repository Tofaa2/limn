//! Ray tracing acceleration structures. Internal to the device.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("../types.zig");
const device_module = @import("../device.zig");

const Device = device_module.Device;
const AccelerationResource = device_module.AccelerationResource;
const retire = @import("objects.zig").retire;
const scratch_alignment = device_module.scratch_alignment;

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
    const geometry = blasGeometry(self, desc);
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
    const blas = try createAcceleration(self, false, sizes.acceleration_structure_size, sizes.build_scratch_size, triangles);
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
    const acceleration = try createAcceleration(self, true, sizes.acceleration_structure_size, sizes.build_scratch_size, max_instances);
    errdefer self.destroyAcceleration(acceleration);
    const resource = self.accelerationResource(acceleration);
    resource.scratch = try self.createBuffer(.{ .name = "tlas scratch", .size = sizes.build_scratch_size + scratch_alignment, .usage = .{ .storage = true } });
    return acceleration;
}

/// Deferred like `destroyBuffer`; also releases its buffers.
pub fn destroyAcceleration(self: *Device, acceleration: types.AccelerationStructure) void {
    const resource = self.accelerations.remove(acceleration) orelse return;
    retire(self, .{ .acceleration = resource.handle });
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
    const geometry = blasGeometry(self, desc);
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
