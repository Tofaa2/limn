//! Fluid constants, `FrameConstants.fluids`. The shader struct is generated
//! from it by the build, so it imports nothing but the frame constants.
const frame_constants = @import("../../core/frame_constants.zig");
const invalid_id = frame_constants.invalid_id;

pub const FluidConstants = extern struct {
    /// The `FluidList`.
    list: u64 = 0,
    /// 1 when smoke shadows the sun.
    shadows: u32 = 0,
    /// 1 when rays (reflections, probes) pass through smoke and see fire.
    rays: u32 = 0,

    pub const references = .{ .list = "FluidList" };
};

comptime {
    @import("std").debug.assert(@sizeOf(FluidConstants) % 8 == 0);
}
