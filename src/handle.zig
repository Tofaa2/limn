const std = @import("std");

/// A 32-bit generational handle: a slot index and the generation the slot
/// had when the handle was issued. `Tag` takes no part in the layout; it
/// only makes handles to different kinds of resource distinct types, so
/// one cannot be passed where another is expected. A plain value, safe to
/// copy and to keep after the resource is gone: a `HandleTable` rejects it
/// once its slot has been reused.
pub fn Handle(comptime Tag: type) type {
    return packed struct(u32) {
        /// Slot in the table that issued the handle (the low 24 bits).
        index: u24,
        /// Generation of that slot at the time (the high 8 bits). Live
        /// handles never have generation 0.
        generation: u8,

        /// The handle that refers to nothing; no table ever issues it.
        pub const invalid: @This() = .{
            .index = std.math.maxInt(u24),
            .generation = 0,
        };

        /// Whether the handle could have been issued by a table at all:
        /// false for `invalid` and for a zeroed handle. It does not look
        /// in any table, so a handle whose resource has since been removed
        /// still reports true; `HandleTable.get` is the test for that.
        pub fn isValid(self: @This()) bool {
            _ = Tag;
            return self.index != std.math.maxInt(u24) and self.generation != 0;
        }
    };
}

/// A growable table of `T` addressed by `Handle(Tag)`. Slots of removed
/// values are reused, most recently freed first, and each reuse gets a new
/// generation, so handles to the old value stop resolving instead of
/// reaching the new one. The generation is 8 bits and wraps (skipping 0):
/// a handle kept across 255 reuses of its slot would resolve again.
///
/// Holds up to 2^24 - 1 values. Not thread safe; callers serialize access.
pub fn HandleTable(comptime T: type, comptime Tag: type) type {
    return struct {
        const Self = @This();
        /// The handle type this table issues and accepts.
        pub const Id = Handle(Tag);
        const Slot = struct {
            generation: u8 = 1,
            next_free: u24 = none,
            value: ?T = null,
        };
        const none = std.math.maxInt(u24);

        allocator: std.mem.Allocator,
        slots: std.ArrayList(Slot) = .empty,
        free_head: u24 = none,

        /// An empty table. Nothing is allocated until the first `insert`;
        /// `allocator` is kept and used for the slot array.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Frees the slot array. Values still in the table are dropped
        /// without being cleaned up: drain it with `popAny` first if they
        /// own anything.
        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        /// Stores `value` and returns the handle to it, reusing a free
        /// slot when there is one. May grow the slot array, which
        /// invalidates pointers returned by `get`. Fails with
        /// `error.HandleTableFull` when every index is taken, or
        /// `error.OutOfMemory`.
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

        /// The value `id` refers to, or null if `id` is invalid, stale
        /// (its value was removed) or out of range. The pointer is into
        /// the table: valid until the next `insert`, or until the value is
        /// removed.
        pub fn get(self: *Self, id: Id) ?*T {
            if (id.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[id.index];
            if (slot.generation != id.generation) return null;
            return if (slot.value) |*value| value else null;
        }

        /// Takes the value `id` refers to out of the table and returns it
        /// for the caller to clean up, or null if `id` does not resolve
        /// (so removing twice is harmless). Every copy of `id` is stale
        /// from then on and the slot is free for reuse.
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

        /// Removes and returns one live value (the one in the lowest
        /// slot), or null when the table is empty. For draining a table at
        /// shutdown: `while (table.popAny()) |value| destroy(value);`.
        /// Each call scans from the first slot.
        pub fn popAny(self: *Self) ?T {
            for (self.slots.items, 0..) |slot, index| {
                if (slot.value != null) return self.remove(.{
                    .index = @intCast(index),
                    .generation = slot.generation,
                });
            }
            return null;
        }

        /// Handles of every live value, in slot order, as a new slice the
        /// caller frees with `allocator`. A snapshot: it does not follow
        /// later inserts and removals.
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
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(@TypeOf(first)));
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

test "generation wrap never creates an invalid live handle" {
    const Tag = enum { resource };
    var table = HandleTable(u8, Tag).init(std.testing.allocator);
    defer table.deinit();
    var handle = try table.insert(1);
    for (0..512) |iteration| {
        const stale = handle;
        try std.testing.expectEqual(@as(u8, 1), table.remove(handle).?);
        try std.testing.expect(table.get(stale) == null);
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
