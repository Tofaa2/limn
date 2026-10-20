//! Push constants of the passes in oit_composite.slang. The build writes each
//! struct as `oit_composite.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    accumulation_texture: u32,
    reveal_texture: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
