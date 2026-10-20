//! Push constants of the passes in shadow.slang. The build writes each
//! struct as `shadow.<Name>.slang`, which the shader includes.

pub const MaskedPush = extern struct {
    frame: u64,
    tinted: u32,

    pub const references = .{ .frame = "FrameConstants" };
};

pub const ColorPush = extern struct {
    frame: u64,

    pub const references = .{ .frame = "FrameConstants" };
};
