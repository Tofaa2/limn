//! Push constants of the passes in bloom.slang. The build writes each
//! struct as `bloom.<Name>.slang`, which the shader includes.

pub const DownPush = extern struct {
    frame: u64,
    source_texture: u32,
    first_level: u32,
    source_texel: [2]f32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const UpPush = extern struct {
    frame: u64,
    source_texture: u32,
    pad: u32,
    source_texel: [2]f32,

    pub const references = .{ .frame = "FrameConstants" };
};
