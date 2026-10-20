//! Push constants of the passes in cluster.slang. The build writes each
//! struct as `cluster.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    z_near: f32,
    z_ratio: f32,

    pub const references = .{ .frame = "FrameConstants" };
};
