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
/// values. Slots live in chunks that never move, so `get` may run on any
/// thread beside an `insert`; changes need one writer at a time.
pub fn HandleTable(comptime T: type, comptime Tag: type) type {
    return struct {
        const Self = @This();
        pub const Id = Handle(Tag);
        pub const Slot = struct {
            generation: u40 = 1,
            next_free: u24 = none,
            value: ?T = null,
        };
        const none = std.math.maxInt(u24);
        /// Slots in the first chunk; each next one holds twice as many.
        const first_chunk = 64;
        const chunk_count = 19;

        allocator: std.mem.Allocator,
        chunks: [chunk_count]?[*]Slot = @splat(null),
        /// Slots in use, published after the slot is written.
        len: std.atomic.Value(u32) = .init(0),
        free_head: u24 = none,
        /// No live value sits below this slot; where `popAny` starts.
        pop_from: u24 = 0,

        /// Allocates nothing until the first `insert`.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Values still stored are dropped without cleanup.
        pub fn deinit(self: *Self) void {
            for (self.chunks, 0..) |chunk, index| {
                if (chunk) |slots| self.allocator.free(slots[0 .. @as(usize, first_chunk) << @intCast(index)]);
            }
            self.* = undefined;
        }

        fn place(index: u32) struct { chunk: usize, offset: usize } {
            const chunk = std.math.log2_int(u32, index / first_chunk + 1);
            return .{ .chunk = chunk, .offset = index - first_chunk * ((@as(u32, 1) << chunk) - 1) };
        }

        /// Slots so far, live or free; for walking every slot with `slotAt`.
        pub fn slotCount(self: *const Self) usize {
            return self.len.load(.acquire);
        }

        /// Slot `index`, below `slotCount`.
        pub fn slotAt(self: *const Self, index: usize) *Slot {
            const at = place(@intCast(index));
            return &self.chunks[at.chunk].?[at.offset];
        }

        /// Pointers from `get` stay valid until the value is removed. Fails
        /// with `error.HandleTableFull` or `error.OutOfMemory`.
        pub fn insert(self: *Self, value: T) !Id {
            if (self.free_head != none) {
                const index = self.free_head;
                const slot = self.slotAt(index);
                self.free_head = slot.next_free;
                self.pop_from = @min(self.pop_from, index);
                slot.next_free = none;
                slot.value = value;
                return .{ .index = index, .generation = slot.generation };
            }
            const count = self.len.raw;
            if (count >= none) return error.HandleTableFull;
            const at = place(count);
            if (self.chunks[at.chunk] == null) {
                const slots = try self.allocator.alloc(Slot, @as(usize, first_chunk) << @intCast(at.chunk));
                self.chunks[at.chunk] = slots.ptr;
            }
            self.chunks[at.chunk].?[at.offset] = .{ .value = value };
            self.len.store(count + 1, .release);
            return .{ .index = @intCast(count), .generation = 1 };
        }

        /// Null if `id` is invalid, stale or out of range.
        pub fn get(self: *const Self, id: Id) ?*T {
            if (id.index >= self.slotCount()) return null;
            const slot = self.slotAt(id.index);
            if (slot.generation != id.generation) return null;
            return if (slot.value) |*value| value else null;
        }

        /// Removes and returns the value, or null if `id` does not resolve.
        pub fn remove(self: *Self, id: Id) ?T {
            if (id.index >= self.slotCount()) return null;
            const slot = self.slotAt(id.index);
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
        /// when empty. Emptying a table this way visits each slot once.
        pub fn popAny(self: *Self) ?T {
            const count = self.slotCount();
            for (self.pop_from..count) |index| {
                const slot = self.slotAt(index);
                if (slot.value == null) continue;
                self.pop_from = @intCast(index);
                return self.remove(.{ .index = @intCast(index), .generation = slot.generation });
            }
            self.pop_from = @intCast(count);
            return null;
        }

        /// Snapshot of every live handle, in slot order. Caller frees.
        pub fn handlesAlloc(self: *const Self, allocator: std.mem.Allocator) ![]Id {
            var result: std.ArrayList(Id) = .empty;
            errdefer result.deinit(allocator);
            for (0..self.slotCount()) |index| {
                const slot = self.slotAt(index);
                if (slot.value != null) try result.append(allocator, .{ .index = @intCast(index), .generation = slot.generation });
            }
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

test "popAny finds values inserted below where it left off" {
    const Tag = enum { resource };
    var table = HandleTable(u8, Tag).init(std.testing.allocator);
    defer table.deinit();
    _ = try table.insert(1);
    _ = try table.insert(2);
    try std.testing.expectEqual(@as(?u8, 1), table.popAny());
    _ = try table.insert(3);
    try std.testing.expectEqual(@as(?u8, 3), table.popAny());
    try std.testing.expectEqual(@as(?u8, 2), table.popAny());
    try std.testing.expectEqual(@as(?u8, null), table.popAny());
}

test "values keep their place while the table grows" {
    const Tag = enum { texture };
    var table = HandleTable(u32, Tag).init(std.testing.allocator);
    defer table.deinit();
    const first = try table.insert(7);
    const kept = table.get(first).?;
    for (0..5000) |value| _ = try table.insert(@intCast(value));
    try std.testing.expectEqual(kept, table.get(first).?);
    try std.testing.expectEqual(@as(usize, 5001), table.slotCount());
    try std.testing.expectEqual(@as(u32, 4999), table.slotAt(5000).value.?);
}
