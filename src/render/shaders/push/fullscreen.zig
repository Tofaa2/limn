//! Push constants of the passes in fullscreen.slang. The build writes each
//! struct as `fullscreen.<Name>.slang`, which the shader includes.

pub const CopyPush = extern struct {
    frame: u64,
    source_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
