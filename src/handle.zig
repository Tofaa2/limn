const std = @import("std");

/// 64-bit generational handle: a slot index plus the slot's generation at
/// issue. `Tag` only makes handles of different resources distinct types.
pub fn Handle(comptime Tag: type) type {
    return packed struct(u64) {
        /// Low 24 bits.
        index: u24,
        /// High 40 bits; never 0 for a live handle.
        generation: u40,

        /// Refers to nothing; never issued.
        pub const invalid: @This() = .{
            .index = std.math.maxInt(u24),
            .generation = 0,
        };

        /// False for `invalid` and a zeroed handle. Consults no table, so a
        /// stale handle still reports true; `HandleTable.get` tests that.
        pub fn isValid(self: @This()) bool {
            _ = Tag;
            return self.index != std.math.maxInt(u24) and self.generation != 0;
        }
    };
}

/// Growable table of `T` addressed by `Handle(Tag)`. Freed slots are reused
/// with a new generation, so stale handles stop resolving; the generation is
/// 40 bits, so a slot would need 2^40 reuses to repeat one. Up to 2^24 - 1
/// values. Not thread safe.
pub fn HandleTable(comptime T: type, comptime Tag: type) type {
    return struct {
        const Self = @This();
        pub const Id = Handle(Tag);
        const Slot = struct {
            generation: u40 = 1,
            next_free: u24 = none,
            value: ?T = null,
        };
        const none = std.math.maxInt(u24);

        allocator: std.mem.Allocator,
        slots: std.ArrayList(Slot) = .empty,
        free_head: u24 = none,

        /// Allocates nothing until the first `insert`.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Values still stored are dropped without cleanup.
        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        /// May grow the slot array, invalidating pointers from `get`. Fails
        /// with `error.HandleTableFull` or `error.OutOfMemory`.
        pub fn insert(self: *Self, value: T) !Id {
            if (self.free_head != none) {
                const index = self.free_head;
                const slot = &self.slots.items[index];
                self.free_head = slot.next_free;
                slot.next_free = none;
                slot.value = value;
                return .{ .index = index, .generation = slot.generation };
            }
            if (self.slots.items.len >= none) return error.HandleTableFull;
            const index: u24 = @intCast(self.slots.items.len);
            try self.slots.append(self.allocator, .{ .value = value });
            return .{ .index = index, .generation = 1 };
        }

        /// Null if `id` is invalid, stale or out of range. The pointer is
        /// valid until the next `insert` or the value's removal.
        pub fn get(self: *Self, id: Id) ?*T {
            if (id.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.index];
            if (slot.generation != id.generation) return null;
            return if (slot.value) |*value| value else null;
        }

        /// Removes and returns the value, or null if `id` does not resolve.
        pub fn remove(self: *Self, id: Id) ?T {
            if (id.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.index];
            if (slot.generation != id.generation) return null;
            const value = slot.value orelse return null;
            slot.value = null;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.next_free = self.free_head;
            self.free_head = id.index;
            return value;
        }

        /// Removes and returns the live value in the lowest slot, or null
        /// when empty. Scans from the first slot on every call.
        pub fn popAny(self: *Self) ?T {
            for (self.slots.items, 0..) |slot, index| {
                if (slot.value != null) return self.remove(.{
                    .index = @intCast(index),
                    .generation = slot.generation,
                });
            }
            return null;
        }

        /// Snapshot of every live handle, in slot order. Caller frees.
        pub fn handlesAlloc(self: *const Self, allocator: std.mem.Allocator) ![]Id {
            var result: std.ArrayList(Id) = .empty;
            errdefer result.deinit(allocator);
            for (self.slots.items, 0..) |slot, index| if (slot.value != null) {
                try result.append(allocator, .{ .index = @intCast(index), .generation = slot.generation });
            };
            return result.toOwnedSlice(allocator);
        }
    };
}

test "generational handles reject stale IDs and reuse slots" {
    const Tag = enum { buffer };
    var table = HandleTable(u32, Tag).init(std.testing.allocator);
    defer table.deinit();
    const first = try table.insert(11);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(@TypeOf(first)));
    try std.testing.expectEqual(@as(u32, 11), table.get(first).?.*);
    try std.testing.expectEqual(@as(u32, 11), table.remove(first).?);
    try std.testing.expect(table.get(first) == null);
    const second = try table.insert(22);
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    const handles = try table.handlesAlloc(std.testing.allocator);
    defer std.testing.allocator.free(handles);
    try std.testing.expectEqual(@as(usize, 1), handles.len);
    try std.testing.expectEqual(second, handles[0]);
}

test "a reused slot never revives a stale handle" {
    const Tag = enum { resource };
    var table = HandleTable(u8, Tag).init(std.testing.allocator);
    defer table.deinit();
    const first = try table.insert(1);
    var handle = first;
    for (0..512) |iteration| {
        const stale = handle;
        try std.testing.expectEqual(@as(u8, 1), table.remove(handle).?);
        try std.testing.expect(table.get(stale) == null);
        try std.testing.expect(table.get(first) == null);
        handle = try table.insert(1);
        try std.testing.expect(handle.isValid());
        try std.testing.expectEqual(@as(u24, 0), handle.index);
        _ = iteration;
    }
}

test "popAny invalidates every returned slot" {
    const Tag = enum { resource };
    var table = HandleTable(u8, Tag).init(std.testing.allocator);
    defer table.deinit();
    const first = try table.insert(1);
    const second = try table.insert(2);
    try std.testing.expect(table.popAny() != null);
    try std.testing.expect(table.popAny() != null);
    try std.testing.expect(table.popAny() == null);
    try std.testing.expect(table.get(first) == null);
    try std.testing.expect(table.get(second) == null);
}
