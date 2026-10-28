//! Push constants of the passes in edge_antialiasing.slang. The build writes each
//! struct as `edge_antialiasing.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    source_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
