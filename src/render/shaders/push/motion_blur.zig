//! Push constants of the passes in motion_blur.slang. The build writes each
//! struct as `motion_blur.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    color_texture: u32,
    motion_texture: u32,
    shutter: f32,
    max_length: f32,
    tap_count: i32,
    spread: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
