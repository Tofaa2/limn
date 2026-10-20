//! The lifecycle every pluggable technique shares: one running backend,
//! restarted when what it was started for changes, not retried once it has
//! refused, and told when its history is stale.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");

/// A place for one `Backend`, which has `destroy`, started for a `Key`.
pub fn Slot(comptime Backend: type, comptime Key: type) type {
    return struct {
        const Self = @This();

        running: ?Backend = null,
        key: ?Key = null,
        /// What would not start or failed, the latest last; left alone until
        /// `forgive`.
        refused: [4]?Key = @splat(null),
        /// Frame the backend last ran in.
        used: u64 = 0,
        fresh: bool = false,

        /// The backend for `key`, started with `start` if none runs for it.
        /// Null when it has refused.
        pub fn ensure(self: *Self, device: *rhi.Device, key: Key, context: anytype, comptime start: fn (@TypeOf(context), Key) ?Backend) !?*Backend {
            if (self.refuses(key)) return null;
            if (self.running) |*backend| {
                if (std.meta.eql(self.key.?, key)) return backend;
                try device.waitIdle();
                backend.destroy();
                self.running = null;
                self.key = null;
            }
            self.running = start(context, key) orelse {
                self.remember(key);
                return null;
            };
            self.key = key;
            self.fresh = true;
            return &self.running.?;
        }

        /// Whether `key` has refused.
        pub fn refuses(self: *const Self, key: Key) bool {
            for (self.refused) |maybe| if (maybe) |no| if (std.meta.eql(no, key)) return true;
            return false;
        }

        fn remember(self: *Self, key: Key) void {
            std.mem.copyForwards(?Key, self.refused[0 .. self.refused.len - 1], self.refused[1..]);
            self.refused[self.refused.len - 1] = key;
        }

        /// Marks the backend as run in `frame`. False when it did not run in
        /// the frame before, so what it remembers is stale.
        pub fn continues(self: *Self, frame: u64) bool {
            const unbroken = !self.fresh and self.used +% 1 == frame;
            self.used = frame;
            self.fresh = false;
            return unbroken;
        }

        /// Gives up on what runs now; `ensure` returns null for it from here.
        pub fn refuse(self: *Self) void {
            if (self.key) |key| if (!self.refuses(key)) self.remember(key);
        }

        pub fn forgive(self: *Self) void {
            self.refused = @splat(null);
        }

        pub fn deinit(self: *Self, device: *rhi.Device) void {
            if (self.running) |*backend| {
                device.waitIdle() catch {};
                backend.destroy();
            }
            self.* = .{};
        }
    };
}

test "a slot restarts on a new key and leaves a refusal alone" {
    const Backend = struct {
        id: u32,
        var destroyed: u32 = 0;
        fn destroy(_: *@This()) void {
            destroyed += 1;
        }
    };
    const start = struct {
        fn run(limit: u32, key: u32) ?Backend {
            return if (key < limit) .{ .id = key } else null;
        }
    }.run;
    var slot: Slot(Backend, u32) = .{};
    const device: *rhi.Device = undefined;
    try std.testing.expect(try slot.ensure(device, 9, @as(u32, 5), start) == null);
    try std.testing.expect(try slot.ensure(device, 9, @as(u32, 50), start) == null);
    slot.forgive();
    const started = (try slot.ensure(device, 9, @as(u32, 50), start)).?;
    try std.testing.expectEqual(@as(u32, 9), started.id);
    try std.testing.expect(!slot.continues(7));
    try std.testing.expect(slot.continues(8));
    try std.testing.expect(!slot.continues(10));
    slot.refuse();
    try std.testing.expect(try slot.ensure(device, 9, @as(u32, 50), start) == null);
    var other: Slot(Backend, u32) = .{};
    try std.testing.expect(try other.ensure(device, 9, @as(u32, 5), start) == null);
    try std.testing.expect(try other.ensure(device, 30, @as(u32, 20), start) == null);
    try std.testing.expect(other.refuses(9) and other.refuses(30));
}
