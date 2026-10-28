//! Reflection constants, `FrameConstants.reflections`. The shader struct is generated
//! from it by the build, so it imports nothing but the frame constants.
const frame_constants = @import("../../core/frame_constants.zig");
const invalid_id = frame_constants.invalid_id;

pub const ReflectionConstants = extern struct {
    /// 1 when screen or traced reflections are drawn.
    enabled: u32 = 0,
    /// 1 when reflection rays also meet see-through surfaces.
    transparent: u32 = 0,
};

comptime {
    @import("std").debug.assert(@sizeOf(ReflectionConstants) % 8 == 0);
}
