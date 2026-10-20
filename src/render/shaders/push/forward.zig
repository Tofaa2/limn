//! Push constants of the passes in forward.slang. The build writes each
//! struct as `forward.<Name>.slang`, which the shader includes.

pub const ForwardPush = extern struct {
    frame: u64,
    instance_index: u32,
    mode: u32,
    scene_texture: u32,
    opaque_depth: u32 = 0xffff_ffff,
    peel_depth: u32 = 0xffff_ffff,

    pub const references = .{ .frame = "FrameConstants" };
};
