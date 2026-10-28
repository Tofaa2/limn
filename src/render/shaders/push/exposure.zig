//! Push constants of the passes in exposure.slang. The build writes each
//! struct as `exposure.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    source_texture: u32,
    automatic: u32,
    compensation: f32,
    min_luminance: f32,
    max_luminance: f32,
    speed: f32,
    reset: u32,
    depth_texture: u32,
    focus_speed: f32,
    ignore_dark: f32,
    ignore_bright: f32,

    pub const references = .{ .frame = "FrameConstants" };
};
