//! Push constants of the passes in shading_rate.slang. The build writes each
//! struct as `shading_rate.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    history_texture: u32,
    depth_texture: u32,
    tile: u32,
    contrast: f32,

    pub const references = .{ .frame = "FrameConstants" };
};
