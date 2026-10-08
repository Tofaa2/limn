//! Buffers: creation, mapping, uploads and readback. Internal to the device.
const std = @import("std");
const types = @import("../types.zig");
const device_module = @import("../device.zig");

const Device = device_module.Device;
const BufferResource = device_module.BufferResource;
const createStaging = @import("frames.zig").createStaging;
const waitQueue = @import("frames.zig").waitQueue;
const retire = @import("objects.zig").retire;
const sameHandle = device_module.sameHandle;
const setName = @import("objects.zig").setName;

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
    setName(self, .buffer, @intFromEnum(handle), desc.name);
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
pub fn cancelUploads(self: *Device, buffer: ?types.Buffer, texture: ?types.Texture) void {
    var orphaned: [16]types.Buffer = undefined;
    var orphan_count: usize = orphaned.len;
    while (orphan_count == orphaned.len) {
        orphan_count = cancelSomeUploads(self, buffer, texture, &orphaned);
        for (orphaned[0..orphan_count]) |staging| self.destroyBuffer(staging);
    }
}

/// One pass of `cancelUploads`, which stops dropping uploads once
/// `orphaned` is full. Returns how many staging buffers it put there.
fn cancelSomeUploads(self: *Device, buffer: ?types.Buffer, texture: ?types.Texture, orphaned: *[16]types.Buffer) usize {
    var write: usize = 0;
    var orphan_count: usize = 0;
    const items = self.uploads.items;
    for (items) |upload| {
        const staging: ?types.Buffer = switch (upload) {
            .buffer => |copy| if (buffer != null and sameHandle(copy.destination, buffer.?)) copy.staging else null,
            .texture => |copy| if (texture != null and sameHandle(copy.destination, texture.?)) (if (copy.last) copy.staging else types.Buffer.invalid) else null,
            .mips => |target| if (texture != null and sameHandle(target, texture.?)) types.Buffer.invalid else null,
            .copy => |copy| if (buffer != null and sameHandle(copy.destination, buffer.?)) copy.source else null,
        };
        if (staging) |value| if (orphan_count < orphaned.len) {
            if (value.isValid()) {
                orphaned[orphan_count] = value;
                orphan_count += 1;
            }
            continue;
        };
        items[write] = upload;
        write += 1;
    }
    self.uploads.items.len = write;
    return orphan_count;
}

/// Invalidates the handle at once; the buffer itself is released after
/// `frames_in_flight` more frames, or by the next `waitIdle`,
/// `flushUploadsBlocking` or `endImmediate`. Stale handles are ignored.
pub fn destroyBuffer(self: *Device, buffer: types.Buffer) void {
    if (self.uploads.items.len != 0) cancelUploads(self, buffer, null);
    const resource = self.buffers.remove(buffer) orelse return;
    retire(self, .{ .buffer = .{ .handle = resource.handle, .allocation = resource.allocation } });
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
    const staging = try createStaging(self, data);
    errdefer self.destroyBuffer(staging);
    try self.uploads.append(self.gpa, .{ .buffer = .{
        .staging = staging,
        .destination = buffer,
        .offset = offset,
        .size = data.len,
    } });
    self.pending_upload_bytes += data.len;
}

/// Reads back the first `size` bytes. Blocks; between frames only. Needs
/// `copy_src` usage.
pub fn readBuffer(self: *Device, gpa: std.mem.Allocator, buffer: types.Buffer, size: u64) ![]u8 {
    std.debug.assert(!self.in_frame);
    const staging = try self.createBuffer(.{ .name = "readback", .size = size, .usage = .{}, .memory = .gpu_to_cpu });
    defer self.destroyBuffer(staging);
    try waitQueue(self);
    const encoder = try self.beginImmediate();
    self.vkd.cmdCopyBuffer(encoder.command, self.bufferResource(buffer).handle, self.bufferResource(staging).handle, &.{.{ .src_offset = 0, .dst_offset = 0, .size = size }});
    try self.endImmediate();
    return gpa.dupe(u8, self.mapped(staging)[0..@intCast(size)]);
}
