//! Push constants of the passes in taa.slang. The build writes each
//! struct as `taa.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    color_texture: u32,
    history_texture: u32,
    motion_texture: u32,
    depth_texture: u32,
    history_valid: u32,
    settled: f32,
    previous_motion_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
