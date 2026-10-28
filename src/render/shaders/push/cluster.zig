//! Push constants of the passes in cluster.slang. The build writes each
//! struct as `cluster.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    /// The first word counts the light index list's entries taken so far.
    cursors: u64,
    z_near: f32,
    z_ratio: f32,
    /// Room in the light index list.
    capacity: u32,
    pad: u32 = 0,

    pub const references = .{ .frame = "FrameConstants", .cursors = "uint*" };
};
