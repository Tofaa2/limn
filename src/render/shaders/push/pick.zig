//! Push constants of the passes in pick.slang. The build writes each
//! struct as `pick.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    result: u64,
    visibility_texture: u32,
    depth_texture: u32,
    pixel: [2]i32,

    pub const references = .{ .frame = "FrameConstants", .result = "PickResult*" };
};
