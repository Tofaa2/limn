//! Block suballocator for device memory. Buffers and images never share a
//! block, which avoids bufferImageGranularity.
const std = @import("std");
const vk = @import("vulkan");
const Device = @import("dispatch.zig").Device;

/// How the CPU accesses an allocation.
pub const Class = enum {
    /// Device-local, not mapped.
    gpu,
    /// Host-visible, persistently mapped.
    cpu_to_gpu,
    /// Host-visible, cached when available; for readback.
    gpu_to_cpu,
};

/// What an allocation backs. A block only ever holds one kind.
pub const Kind = enum { buffer, image };

/// A range of device memory from `Allocator.allocate`.
pub const Allocation = struct {
    memory: vk.DeviceMemory,
    /// Byte offset inside `memory`.
    offset: u64,
    /// Requested size in bytes.
    size: u64,
    /// Start of the range for host-visible classes; null for `gpu`.
    mapped: ?[*]u8,
    /// Null when the allocation has a memory object of its own.
    block_index: ?u32,
};

const Range = struct { offset: u64, size: u64 };

const Block = struct {
    memory: vk.DeviceMemory,
    size: u64,
    cursor: u64 = 0,
    memory_type: u32,
    kind: Kind,
    mapped: ?[*]u8,
    live_allocations: u32 = 0,
    active: bool = true,
    /// Has room for one more range per live allocation (reserved by
    /// `allocate`), so freeing never allocates.
    free_ranges: std.ArrayList(Range) = .empty,
};

pub const Stats = struct {
    /// Shared blocks held from the driver.
    block_count: usize = 0,
    /// Bytes held from the driver: whole blocks plus dedicated allocations.
    reserved_bytes: u64 = 0,
    /// Bytes of live allocations, as requested (excluding alignment padding).
    used_bytes: u64 = 0,
    /// For tests: allocations to succeed before one fails; null never fails.
    fail_after: ?u32 = null,
    /// Live allocations that have a memory object of their own.
    dedicated_allocations: usize = 0,
};

const block_size_gpu = 128 * 1024 * 1024;
const block_size_host = 32 * 1024 * 1024;

/// Suballocates from 128 MiB (device-local) or 32 MiB (host-visible) blocks;
/// requests of a quarter block or more get a dedicated memory object. Not
/// thread-safe.
pub const Allocator = struct {
    /// For bookkeeping, not device memory.
    allocator: std.mem.Allocator,
    device: Device,
    properties: vk.PhysicalDeviceMemoryProperties,
    blocks: std.ArrayList(Block) = .empty,
    dedicated_allocations: usize = 0,
    dedicated_bytes: u64 = 0,
    used_bytes: u64 = 0,
    /// For tests: allocations to succeed before one fails; null never fails.
    fail_after: ?u32 = null,

    /// No device memory is reserved until the first `allocate`.
    pub fn init(allocator: std.mem.Allocator, device: Device, properties: vk.PhysicalDeviceMemoryProperties) Allocator {
        return .{ .allocator = allocator, .device = device, .properties = properties };
    }

    /// Frees every block. Dedicated allocations must already be freed.
    pub fn deinit(self: *Allocator) void {
        for (self.blocks.items) |*block| {
            if (!block.active) continue;
            if (block.mapped != null) self.device.unmapMemory(block.memory);
            self.device.freeMemory(block.memory, null);
            block.free_ranges.deinit(self.allocator);
        }
        self.blocks.deinit(self.allocator);
        self.* = undefined;
    }

    /// Host-visible classes come back mapped. Fails with
    /// `error.MemoryTypeUnavailable`, `error.MapMemoryFailed` or the driver's
    /// out-of-memory errors.
    pub fn allocate(self: *Allocator, requirements: vk.MemoryRequirements, class: Class, kind: Kind) !Allocation {
        if (self.fail_after) |*remaining| {
            if (remaining.* == 0) {
                self.fail_after = null;
                return error.OutOfDeviceMemory;
            }
            remaining.* -= 1;
        }
        const memory_type = self.findMemoryType(requirements.memory_type_bits, class) orelse
            return error.MemoryTypeUnavailable;
        const mapped = class != .gpu;
        const block_size: u64 = if (class == .gpu) block_size_gpu else block_size_host;
        self.used_bytes += requirements.size;
        errdefer self.used_bytes -= requirements.size;

        if (requirements.size >= block_size / 4) {
            const memory = try self.allocateMemory(requirements.size, memory_type);
            errdefer self.device.freeMemory(memory, null);
            const pointer: ?[*]u8 = if (mapped)
                @ptrCast((try self.device.mapMemory(memory, 0, requirements.size, .{})) orelse return error.MapMemoryFailed)
            else
                null;
            self.dedicated_allocations += 1;
            self.dedicated_bytes += requirements.size;
            return .{ .memory = memory, .offset = 0, .size = requirements.size, .mapped = pointer, .block_index = null };
        }

        for (self.blocks.items, 0..) |*block, index| {
            if (!block.active or block.memory_type != memory_type or block.kind != kind or
                (block.mapped != null) != mapped) continue;
            if (try self.allocateFromBlock(block, requirements)) |offset| {
                block.live_allocations += 1;
                return blockAllocation(block, @intCast(index), offset, requirements.size);
            }
        }

        var index: u32 = @intCast(self.blocks.items.len);
        for (self.blocks.items, 0..) |block, candidate| if (!block.active) {
            index = @intCast(candidate);
            break;
        };
        const memory = try self.allocateMemory(block_size, memory_type);
        errdefer self.device.freeMemory(memory, null);
        var new_block = Block{
            .memory = memory,
            .size = block_size,
            .memory_type = memory_type,
            .kind = kind,
            .mapped = if (mapped)
                @ptrCast((try self.device.mapMemory(memory, 0, block_size, .{})) orelse return error.MapMemoryFailed)
            else
                null,
        };
        new_block.cursor = requirements.size;
        new_block.live_allocations = 1;
        try new_block.free_ranges.ensureUnusedCapacity(self.allocator, 1);
        errdefer new_block.free_ranges.deinit(self.allocator);
        if (index == self.blocks.items.len)
            try self.blocks.append(self.allocator, new_block)
        else
            self.blocks.items[index] = new_block;
        return blockAllocation(&self.blocks.items[index], index, 0, requirements.size);
    }

    /// The bound resource must already be destroyed. An emptied block is
    /// returned to the driver at once.
    pub fn free(self: *Allocator, allocation: Allocation) void {
        self.used_bytes -= allocation.size;
        if (allocation.block_index) |index| {
            const block = &self.blocks.items[index];
            std.debug.assert(block.active and block.live_allocations != 0);
            block.live_allocations -= 1;
            if (block.live_allocations == 0) {
                if (block.mapped != null) self.device.unmapMemory(block.memory);
                self.device.freeMemory(block.memory, null);
                block.free_ranges.deinit(self.allocator);
                block.active = false;
                block.mapped = null;
                return;
            }
            block.free_ranges.appendAssumeCapacity(.{ .offset = allocation.offset, .size = allocation.size });
            coalesce(block);
            return;
        }
        if (allocation.mapped != null) self.device.unmapMemory(allocation.memory);
        self.device.freeMemory(allocation.memory, null);
        self.dedicated_allocations -= 1;
        self.dedicated_bytes -= allocation.size;
    }

    pub fn stats(self: *const Allocator) Stats {
        var result: Stats = .{
            .reserved_bytes = self.dedicated_bytes,
            .used_bytes = self.used_bytes,
            .dedicated_allocations = self.dedicated_allocations,
        };
        for (self.blocks.items) |block| {
            if (!block.active) continue;
            result.block_count += 1;
            result.reserved_bytes += block.size;
        }
        return result;
    }

    fn allocateFromBlock(self: *Allocator, block: *Block, requirements: vk.MemoryRequirements) !?u64 {
        try block.free_ranges.ensureUnusedCapacity(self.allocator, block.live_allocations + 2);
        for (block.free_ranges.items, 0..) |range, index| {
            const offset = std.mem.alignForward(u64, range.offset, requirements.alignment);
            const padding = offset - range.offset;
            if (padding + requirements.size > range.size) continue;
            _ = block.free_ranges.orderedRemove(index);
            if (padding != 0) block.free_ranges.appendAssumeCapacity(.{ .offset = range.offset, .size = padding });
            const suffix_offset = offset + requirements.size;
            const suffix_size = range.offset + range.size - suffix_offset;
            if (suffix_size != 0) block.free_ranges.appendAssumeCapacity(.{ .offset = suffix_offset, .size = suffix_size });
            return offset;
        }
        const offset = std.mem.alignForward(u64, block.cursor, requirements.alignment);
        if (offset + requirements.size > block.size) return null;
        // Record alignment padding as free so the block coalesces fully.
        if (offset != block.cursor)
            block.free_ranges.appendAssumeCapacity(.{ .offset = block.cursor, .size = offset - block.cursor });
        block.cursor = offset + requirements.size;
        return offset;
    }

    fn allocateMemory(self: *Allocator, size: u64, memory_type: u32) !vk.DeviceMemory {
        const flags = vk.MemoryAllocateFlagsInfo{ .flags = .{ .device_address_bit = true }, .device_mask = 0 };
        return self.device.allocateMemory(&.{
            .p_next = &flags,
            .allocation_size = size,
            .memory_type_index = memory_type,
        }, null);
    }

    fn findMemoryType(self: *const Allocator, allowed_types: u32, class: Class) ?u32 {
        const preferences: []const vk.MemoryPropertyFlags = switch (class) {
            .gpu => &.{ .{ .device_local_bit = true }, .{} },
            .cpu_to_gpu => &.{.{ .host_visible_bit = true, .host_coherent_bit = true }},
            .gpu_to_cpu => &.{
                .{ .host_visible_bit = true, .host_coherent_bit = true, .host_cached_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            },
        };
        for (preferences) |required| {
            for (0..self.properties.memory_type_count) |index| {
                if (allowed_types & (@as(u32, 1) << @intCast(index)) == 0) continue;
                if (self.properties.memory_types[index].property_flags.contains(required)) return @intCast(index);
            }
        }
        return null;
    }
};

fn blockAllocation(block: *const Block, block_index: u32, offset: u64, size: u64) Allocation {
    return .{
        .memory = block.memory,
        .offset = offset,
        .size = size,
        .mapped = if (block.mapped) |base| base + @as(usize, @intCast(offset)) else null,
        .block_index = block_index,
    };
}

fn coalesce(block: *Block) void {
    std.mem.sort(Range, block.free_ranges.items, {}, struct {
        fn lessThan(_: void, left: Range, right: Range) bool {
            return left.offset < right.offset;
        }
    }.lessThan);
    if (block.free_ranges.items.len < 2) return;
    var write: usize = 0;
    for (block.free_ranges.items[1..]) |range| {
        const current = &block.free_ranges.items[write];
        if (current.offset + current.size == range.offset) {
            current.size += range.size;
        } else {
            write += 1;
            block.free_ranges.items[write] = range;
        }
    }
    block.free_ranges.items.len = write + 1;
}
