//! Cloud constants, `FrameConstants.clouds`. The shader struct is generated
//! from it by the build, so it imports nothing but the frame constants.
const frame_constants = @import("../../core/frame_constants.zig");
const invalid_id = frame_constants.invalid_id;

pub const CloudConstants = extern struct {
    /// The `Clouds` record; 0 when the scene has none.
    layer: u64 = 0,
    /// 1 when the clouds shadow the sun.
    shadows: u32 = 0,
    pad: u32 = 0,

    pub const references = .{ .layer = "CloudRef" };
};

comptime {
    @import("std").debug.assert(@sizeOf(CloudConstants) % 8 == 0);
}

/// `CloudData` in common.slang.
pub const Clouds = extern struct {
    offset: [3]f32,
    period: f32,
    albedo: [3]f32,
    density: f32,
    bottom: f32,
    top: f32,
    coverage: f32,
    detail: f32,
    planet_radius: f32,
    max_distance: f32,
    variation: f32,
    ambient: f32,
    noise: u32,
    steps: i32,
    light_steps: i32,
    history: u32,
    history_blend: f32,
    anisotropy: f32,
    depth: u32,
    shadow_strength: f32 = 0,
    cirrus: f32 = 0,
    anvil: f32 = 0,
    cloud_pad: [2]f32 = .{ 0, 0 },
    /// A lightning flash inside the layer: position and brightness.
    flash: [4]f32 = .{ 0, 0, 0, 0 },
};
