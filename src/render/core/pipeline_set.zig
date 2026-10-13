//! Pipelines named by an enum and built the first time each is asked for.
//! Internal to the renderer.
const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");

/// A pipeline for each value of the enum `Id`, built by `make` on first use.
/// Not thread-safe.
pub fn PipelineSet(comptime Id: type, comptime make: fn (device: *rhi.Device, id: Id) anyerror!rhi.Pipeline) type {
    return struct {
        const Self = @This();

        device: *rhi.Device,
        made: std.EnumArray(Id, ?rhi.Pipeline) = .initFill(null),

        pub fn init(device: *rhi.Device) Self {
            return .{ .device = device };
        }

        /// The pipeline `id`, built now if this is its first use.
        pub fn get(self: *Self, id: Id) !rhi.Pipeline {
            if (self.made.get(id)) |pipeline| return pipeline;
            const pipeline = try make(self.device, id);
            self.made.set(id, pipeline);
            return pipeline;
        }

        /// The pipeline `id` if it has been built.
        pub fn peek(self: *const Self, id: Id) ?rhi.Pipeline {
            return self.made.get(id);
        }

        /// Number of pipelines built so far.
        pub fn count(self: *const Self) u32 {
            var total: u32 = 0;
            for (self.made.values) |entry| total += @intFromBool(entry != null);
            return total;
        }

        /// Destroys every pipeline built; each is built again on its next use.
        pub fn reset(self: *Self) void {
            for (&self.made.values) |*entry| {
                if (entry.*) |pipeline| self.device.destroyPipeline(pipeline);
                entry.* = null;
            }
        }
    };
}
