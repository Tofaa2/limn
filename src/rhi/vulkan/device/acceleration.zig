//! Ray tracing acceleration structures. Internal to the device.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("../../types.zig");
const device_module = @import("../device.zig");

const Device = device_module.Device;
const AccelerationResource = device_module.AccelerationResource;
const retire = @import("objects.zig").retire;
const scratch_alignment = device_module.scratch_alignment;

/// Most structures that can wait for their compacted size at once.
pub const compaction_capacity = 512;

/// The geometries and triangle counts of `desc`, in `geometries` and
/// `triangles`; the count of geometries.
fn blasGeometries(self: *Device, desc: types.BlasDesc, geometries: *[types.max_blas_geometries]vk.AccelerationStructureGeometryKHR, triangles: *[types.max_blas_geometries]u32) !u32 {
    if (desc.geometries.len == 0 or desc.geometries.len > types.max_blas_geometries) return error.InvalidBlasDesc;
    for (desc.geometries, 0..) |geometry, index| {
        geometries[index] = .{
            .geometry_type = .triangles_khr,
            .flags = .{ .opaque_bit_khr = geometry.solid },
            .geometry = .{ .triangles = .{
                .vertex_format = .r32g32b32_sfloat,
                .vertex_data = .{ .device_address = self.bufferAddress(geometry.vertices) + geometry.vertex_offset },
                .vertex_stride = geometry.vertex_stride,
                .max_vertex = geometry.vertex_count - 1,
                .index_type = .uint32,
                .index_data = .{ .device_address = self.bufferAddress(geometry.indices) + geometry.index_offset },
                .transform_data = .{ .device_address = 0 },
            } },
        };
        triangles[index] = geometry.index_count / 3;
    }
    return @intCast(desc.geometries.len);
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
        .size = size,
    });
}

/// Sized for `desc`; build with `CommandEncoder.buildBlas`.
pub fn createBlas(self: *Device, desc: types.BlasDesc) !types.AccelerationStructure {
    if (!self.caps.ray_tracing) return error.RayTracingUnavailable;
    var geometries: [types.max_blas_geometries]vk.AccelerationStructureGeometryKHR = undefined;
    var triangles: [types.max_blas_geometries]u32 = undefined;
    const count = try blasGeometries(self, desc, &geometries, &triangles);
    var sizes: vk.AccelerationStructureBuildSizesInfoKHR = .{
        .acceleration_structure_size = 0,
        .update_scratch_size = 0,
        .build_scratch_size = 0,
    };
    self.vkd.getAccelerationStructureBuildSizesKHR(.device_khr, &.{
        .type = .bottom_level_khr,
        .flags = .{ .prefer_fast_trace_bit_khr = !desc.dynamic, .prefer_fast_build_bit_khr = desc.dynamic, .allow_update_bit_khr = desc.dynamic, .allow_compaction_bit_khr = !desc.dynamic },
        .mode = .build_khr,
        .geometry_count = count,
        .p_geometries = &geometries,
        .scratch_data = .{ .device_address = 0 },
    }, &triangles, &sizes);
    var total: u32 = 0;
    for (triangles[0..count]) |value| total += value;
    const blas = try createAcceleration(self, false, sizes.acceleration_structure_size, @max(sizes.build_scratch_size, sizes.update_scratch_size), total);
    self.accelerationResource(blas).dynamic = desc.dynamic;
    self.accelerationResource(blas).compactable = !desc.dynamic;
    return blas;
}

/// Allocates a top-level structure with room for `desc.max_instances`.
pub fn createTlas(self: *Device, desc: types.TlasDesc) !types.AccelerationStructure {
    if (!self.caps.ray_tracing) return error.RayTracingUnavailable;
    const geometry = tlasGeometry(0);
    var sizes: vk.AccelerationStructureBuildSizesInfoKHR = .{
        .acceleration_structure_size = 0,
        .update_scratch_size = 0,
        .build_scratch_size = 0,
    };
    self.vkd.getAccelerationStructureBuildSizesKHR(.device_khr, &.{
        .type = .top_level_khr,
        .flags = tlasFlags(desc.updatable),
        .mode = .build_khr,
        .geometry_count = 1,
        .p_geometries = @ptrCast(&geometry),
        .scratch_data = .{ .device_address = 0 },
    }, @ptrCast(&desc.max_instances), &sizes);
    const scratch_size = @max(sizes.build_scratch_size, sizes.update_scratch_size);
    const acceleration = try createAcceleration(self, true, sizes.acceleration_structure_size, scratch_size, desc.max_instances);
    errdefer self.destroyAcceleration(acceleration);
    const resource = self.accelerationResource(acceleration);
    resource.updatable = desc.updatable;
    resource.scratch = try self.createBuffer(.{ .name = "tlas scratch", .size = scratch_size + scratch_alignment, .usage = .{ .storage = true } });
    return acceleration;
}

fn tlasFlags(updatable: bool) vk.BuildAccelerationStructureFlagsKHR {
    return .{ .prefer_fast_build_bit_khr = true, .allow_update_bit_khr = updatable };
}

/// Deferred like `destroyBuffer`; also releases its buffers.
pub fn destroyAcceleration(self: *Device, acceleration: types.AccelerationStructure) void {
    const resource = self.accelerations.remove(acceleration) orelse return;
    if (resource.compaction_slot) |slot| self.compaction_slots.unset(slot);
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

/// Structures `buildBlasesCommand` records in one call.
const batch_size = 16;

/// Called by `CommandEncoder.buildBlases`; use that. Each `desc` must have
/// the geometries and triangle counts its structure was created for. A
/// `dynamic` structure is refitted after its first build.
pub fn buildBlasesCommand(self: *Device, command: vk.CommandBuffer, builds: []const types.BlasBuild) !void {
    var start: usize = 0;
    while (start < builds.len) : (start += batch_size) {
        const batch = builds[start..@min(start + batch_size, builds.len)];
        var geometries: [batch_size][types.max_blas_geometries]vk.AccelerationStructureGeometryKHR = undefined;
        var triangles: [batch_size][types.max_blas_geometries]u32 = undefined;
        var ranges: [batch_size][types.max_blas_geometries]vk.AccelerationStructureBuildRangeInfoKHR = undefined;
        var range_pointers: [batch_size][*]const vk.AccelerationStructureBuildRangeInfoKHR = undefined;
        var infos: [batch_size]vk.AccelerationStructureBuildGeometryInfoKHR = undefined;
        for (batch, 0..) |build, index| {
            const resource = self.accelerationResource(build.blas);
            const count = try blasGeometries(self, build.desc, &geometries[index], &triangles[index]);
            for (0..count) |at| ranges[index][at] = .{ .primitive_count = triangles[index][at], .primitive_offset = 0, .first_vertex = 0, .transform_offset = 0 };
            range_pointers[index] = &ranges[index];
            if (resource.dynamic and resource.scratch == null)
                resource.scratch = try self.createBuffer(.{ .name = "blas scratch", .size = resource.scratch_size + scratch_alignment, .usage = .{ .storage = true } });
            const scratch = resource.scratch orelse try self.createBuffer(.{ .name = "blas scratch", .size = resource.scratch_size + scratch_alignment, .usage = .{ .storage = true } });
            const scratch_address = std.mem.alignForward(u64, self.bufferAddress(scratch), scratch_alignment);
            if (resource.scratch == null) self.destroyBuffer(scratch);
            const refit = resource.dynamic and resource.built;
            infos[index] = .{
                .type = .bottom_level_khr,
                .flags = .{ .prefer_fast_trace_bit_khr = !resource.dynamic, .prefer_fast_build_bit_khr = resource.dynamic, .allow_update_bit_khr = resource.dynamic, .allow_compaction_bit_khr = resource.compactable },
                .mode = if (refit) .update_khr else .build_khr,
                .src_acceleration_structure = if (refit) resource.handle else .null_handle,
                .dst_acceleration_structure = resource.handle,
                .geometry_count = count,
                .p_geometries = &geometries[index],
                .scratch_data = .{ .device_address = scratch_address },
            };
            resource.built = true;
        }
        self.vkd.cmdBuildAccelerationStructuresKHR(command, infos[0..batch.len], range_pointers[0..batch.len]);
    }
}

/// Called by `CommandEncoder.measureBlas`; use that. Asks for the size a
/// built structure compacts to. Does nothing for one that cannot be
/// compacted or while too many wait to be read.
pub fn measureBlasCommand(self: *Device, command: vk.CommandBuffer, blas: types.AccelerationStructure) !void {
    const resource = self.accelerationResource(blas);
    if (!resource.compactable or resource.compaction_slot != null) return;
    if (self.compaction_pool == .null_handle) {
        self.compaction_pool = try self.vkd.createQueryPool(&.{
            .query_type = .acceleration_structure_compacted_size_khr,
            .query_count = compaction_capacity,
        }, null);
    }
    var free = self.compaction_slots.iterator(.{ .kind = .unset });
    const slot: u32 = @intCast(free.next() orelse return);
    self.compaction_slots.set(slot);
    resource.compaction_slot = slot;
    self.vkd.cmdResetQueryPool(command, self.compaction_pool, slot, 1);
    self.vkd.cmdWriteAccelerationStructuresPropertiesKHR(command, &.{resource.handle}, .acceleration_structure_compacted_size_khr, self.compaction_pool, slot);
}

/// The size `blas` compacts to, once the commands that measured it have
/// run. Null before that, and for one that was not measured or would not
/// get smaller. Answers once.
pub fn compactedBlasSize(self: *Device, blas: types.AccelerationStructure) ?u64 {
    const resource = self.accelerationResource(blas);
    const slot = resource.compaction_slot orelse return null;
    var size: u64 = 0;
    const outcome = self.vkd.getQueryPoolResults(self.compaction_pool, slot, 1, @sizeOf(u64), &size, @sizeOf(u64), .{ .@"64_bit" = true }) catch return null;
    if (outcome != .success) return null;
    self.compaction_slots.unset(slot);
    resource.compaction_slot = null;
    return if (size != 0 and size < resource.size) size else null;
}

/// Whether `blas` still waits for `compactedBlasSize` to answer.
pub fn blasMeasured(self: *Device, blas: types.AccelerationStructure) bool {
    return self.accelerationResource(blas).compaction_slot != null;
}

/// An empty structure of `size` bytes for `CommandEncoder.compactBlas` to
/// fill from `source`.
pub fn createCompactBlas(self: *Device, source: types.AccelerationStructure, size: u64) !types.AccelerationStructure {
    const capacity = self.accelerationResource(source).capacity;
    return createAcceleration(self, false, size, 0, capacity);
}

/// Called by `CommandEncoder.compactBlas`, which adds the barriers; use that.
pub fn compactBlasCommand(self: *Device, command: vk.CommandBuffer, source: types.AccelerationStructure, destination: types.AccelerationStructure) void {
    const from = self.accelerationResource(source).handle;
    const to = self.accelerationResource(destination);
    self.vkd.cmdCopyAccelerationStructureKHR(command, &.{ .src = from, .dst = to.handle, .mode = .compact_khr });
    to.built = true;
}

/// Called by `CommandEncoder.buildTlas` and `updateTlas`, which add the
/// barriers; use those. `instance_count` must not exceed the TLAS's
/// `max_instances`. `update` is honoured only for an updatable structure
/// built before with the same instance count.
pub fn buildTlasCommand(self: *Device, command: vk.CommandBuffer, tlas: types.AccelerationStructure, instances_address: u64, instance_count: u32, update: bool) void {
    const resource = self.accelerationResource(tlas);
    std.debug.assert(instance_count <= resource.capacity);
    const refit = update and resource.updatable and resource.built and resource.instance_count == instance_count;
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
        .flags = tlasFlags(resource.updatable),
        .mode = if (refit) .update_khr else .build_khr,
        .src_acceleration_structure = if (refit) resource.handle else .null_handle,
        .dst_acceleration_structure = resource.handle,
        .geometry_count = 1,
        .p_geometries = @ptrCast(&geometry),
        .scratch_data = .{ .device_address = std.mem.alignForward(u64, self.bufferAddress(resource.scratch.?), scratch_alignment) },
    }}, &ranges);
    resource.built = true;
    resource.instance_count = instance_count;
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
