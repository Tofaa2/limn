//! The denoisers path tracing can hand its signals to, behind one slot:
//! `.builtin` needs no state of its own and DLSS Ray Reconstruction runs as
//! the view's upscaler, so the slot holds the backends that keep any. Each
//! reads the signal set of `path_tracing.Signals`.
const rhi = @import("../../rhi/rhi.zig");
const slot = @import("../core/slot.zig");
const nrd = @import("../nrd.zig");

/// What a denoiser was started for.
pub const Key = struct { size: [2]u32 };

pub const Running = union(enum) {
    nrd: nrd.Denoiser,

    pub fn startNrd(device: *rhi.Device, key: Key) ?Running {
        return .{ .nrd = nrd.Denoiser.create(device, key.size) orelse return null };
    }

    pub fn destroy(self: *Running) void {
        switch (self.*) {
            inline else => |*backend| backend.destroy(),
        }
    }
};

pub const Slot = slot.Slot(Running, Key);
