//! Ambient occlusion constants, `FrameConstants.ambient_occlusion`. The shader struct is generated
//! from it by the build, so it imports nothing but the frame constants.
const frame_constants = @import("../../core/frame_constants.zig");
const invalid_id = frame_constants.invalid_id;

pub const AmbientOcclusionConstants = extern struct {
    /// 1 when the view has ambient occlusion.
    enabled: u32 = 0,
    pad: u32 = 0,
};

comptime {
    @import("std").debug.assert(@sizeOf(AmbientOcclusionConstants) % 8 == 0);
}
